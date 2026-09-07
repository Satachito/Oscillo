import Foundation

/// A synthetic PiLyzer, so the application is complete and testable with no
/// hardware attached.
///
/// It answers the same command set with the same timing rules: a record only
/// finishes after the time it would really take, the trigger really has to be
/// found in the waveform, and the samples come back through the same 16-bit
/// converter space as the instrument's.
public final class SimulatedInstrument: Instrument {
    public struct Tone: Sendable {
        public var frequency: Double
        public var amplitude: Double
        public var offset: Double
        public var isSquare: Bool
        /// Third-harmonic distortion, as a fraction — so the spectrum has
        /// something to measure.
        public var distortion: Double

        public init(frequency: Double, amplitude: Double, offset: Double = 0,
                    isSquare: Bool = false, distortion: Double = 0) {
            self.frequency = frequency
            self.amplitude = amplitude
            self.offset = offset
            self.isSquare = isSquare
            self.distortion = distortion
        }
    }

    public var tones: [Tone] = [
        Tone(frequency: 1000, amplitude: 2.0, distortion: 0.01),
        Tone(frequency: 500, amplitude: 1.0, offset: 0.25, isSquare: true),
        Tone(frequency: 194, amplitude: 1.5),
    ]
    public var noise = 0.0015
    /// When false, nothing ever crosses the trigger level in normal mode.
    public var signalPresent = true

    public let identity = DeviceIdentity(protocolVersion: Wire.version,
                                         firmwareVersion: 0x0105,
                                         boardID: 1,
                                         name: "Demo signal")
    public let capabilities = DeviceCapabilities(
        analogChannels: 3, analogBits: 12, logicChannels: 8, analogRanges: 2,
        analogClockHz: 48_000_000, analogMinPeriodCycles: 96,
        analogMaxRecord: 16384, analogMaxPretrigger: 16383,
        logicClockHz: 150_000_000, logicMaxRecord: 65536, logicMaxPretrigger: 65535,
        referenceVolts: 3.3, flags: 1 | 2 | 8)

    private var ranges = [0, 0, 0]
    private let epoch = Date()

    private var analogPlan = AcquisitionPlan.empty
    private var analogConfiguration = AnalogConfiguration()
    private var analogRecord: [UInt16] = []
    private var analogReadyAt = Date.distantFuture
    private var analogTriggered = false
    private var analogTriggerIndex = 0
    private var analogArmed = false

    private var logicPlan = AcquisitionPlan.empty
    private var logicConfiguration = LogicConfiguration()
    private var logicRecord: [UInt8] = []
    private var logicReadyAt = Date.distantFuture
    private var logicArmed = false

    public init() {}
    public func close() {}

    // MARK: - Signal

    private func voltage(_ channel: Int, at time: Double) -> Double {
        guard channel < tones.count, signalPresent else { return 0 }
        let tone = tones[channel]
        let phase = 2 * Double.pi * tone.frequency * time
        var value: Double
        if tone.isSquare {
            value = sin(phase) >= 0 ? tone.amplitude : -tone.amplitude
        } else {
            value = tone.amplitude * sin(phase)
            if tone.distortion > 0 {
                value += tone.amplitude * tone.distortion * sin(3 * phase)
            }
        }
        return value + tone.offset + Double.random(in: -noise...noise)
    }

    private func scale(for channel: Int) -> VoltageScale {
        let list = FrontEnd.ranges(forBoard: identity.boardID)
        let index = min(max(ranges[min(channel, ranges.count - 1)], 0), list.count - 1)
        return VoltageScale(reference: capabilities.referenceVolts,
                            fullScale: capabilities.analogFullScale,
                            range: list[index])
    }

    private func code(_ channel: Int, at time: Double) -> UInt16 {
        let raw = scale(for: channel).code(forVolts: voltage(channel, at: time))
        let quantised = (raw / 16).rounded() * 16      // the converter's own 12 bits
        return UInt16(min(max(quantised, 0), capabilities.analogFullScale))
    }

    // MARK: - Analogue

    public func configureAnalog(_ configuration: AnalogConfiguration) throws -> AcquisitionPlan {
        guard configuration.triggerLowPassHz == 0 || (100...100_000).contains(configuration.triggerLowPassHz) else {
            throw InstrumentError.rejected(.analogConfigure, .badArgument)
        }
        guard configuration.channelMask != 0,
              configuration.channelMask & ~UInt8((1 << capabilities.analogChannels) - 1) == 0 else {
            throw InstrumentError.rejected(.analogConfigure, .badArgument)
        }
        analogConfiguration = configuration
        let channels = max(configuration.channels, 1)
        let floor = capabilities.minimumConversionPeriod
        let requested = max(configuration.samplePeriod, floor * Double(channels))
        let decimation = max(UInt32(requested / (floor * Double(channels))), 1)
        let conversion = requested / Double(channels) / Double(decimation)
        let divisor = UInt32(max((conversion * Double(capabilities.analogClockHz) * 256).rounded(),
                                 Double(capabilities.analogMinPeriodCycles) * 256))
        analogPlan = AcquisitionPlan(
            clockHz: capabilities.analogClockHz,
            divisorQ8: divisor,
            decimation: decimation,
            recordSamples: min(configuration.recordSamples, capabilities.analogMaxRecord),
            pretriggerSamples: min(configuration.pretriggerSamples, configuration.recordSamples - 1),
            channelMask: configuration.channelMask,
            conversionsPerSample: channels)
        return analogPlan
    }

    public func armAnalog() throws {
        let period = analogPlan.samplePeriod
        let count = analogPlan.recordSamples
        let channels = max(analogPlan.conversionsPerSample, 1)
        let slots = analogPlan.enabledChannels

        // Hunt for the trigger the same way the instrument does, in a window
        // three records wide, so a repetitive signal stands still on screen.
        let now = Date().timeIntervalSince(epoch)
        var start = now
        analogTriggered = false
        if analogConfiguration.triggerMode != .freeRun && signalPresent {
            let sourceSlot = min(Int(analogConfiguration.triggerSource), channels - 1)
            let sourceChannel = slots.indices.contains(sourceSlot) ? slots[sourceSlot] : 0
            let level = Int(analogConfiguration.triggerLevel)
            let hysteresis = Int(analogConfiguration.triggerHysteresis)
            let rising = analogConfiguration.triggerSlope == .rising
            var filter = TriggerFilter(cutoffHz: analogConfiguration.triggerLowPassHz, samplePeriod: period)
            let searchLength = filter.remaining + count * 3
            var armed = false
            for step in 0..<searchLength {
                let time = now + Double(step) * period
                let value = filter.sample(code(sourceChannel, at: time))
                guard step >= analogPlan.pretriggerSamples, filter.remaining == 0 else { continue }
                if !armed {
                    armed = rising ? value < level - hysteresis : value > level + hysteresis
                } else if rising ? value >= level : value <= level {
                    start = time - Double(analogPlan.pretriggerSamples) * period
                    analogTriggered = true
                    break
                }
            }
        }
        if !analogTriggered && analogConfiguration.triggerMode == .normal {
            analogRecord = []
            analogReadyAt = .distantFuture
            analogArmed = true
            return
        }

        var record = [UInt16](repeating: 0, count: count * channels)
        for index in 0..<count {
            let time = start + Double(index) * period
            for (slot, channel) in slots.enumerated() where slot < channels {
                record[index * channels + slot] = code(channel, at: time)
            }
        }
        analogRecord = record
        analogTriggerIndex = analogPlan.pretriggerSamples
        analogReadyAt = Date().addingTimeInterval(period * Double(count))
        analogArmed = true
    }

    public func analogStatus() throws -> AcquisitionStatus {
        guard analogArmed else {
            return AcquisitionStatus(state: .idle, triggered: false, samplesAvailable: 0, triggerIndex: 0)
        }
        if Date() < analogReadyAt {
            return AcquisitionStatus(state: analogTriggered ? .postTrigger : .waiting,
                                     triggered: false, samplesAvailable: 0, triggerIndex: 0)
        }
        return AcquisitionStatus(state: .complete, triggered: analogTriggered,
                                 samplesAvailable: analogPlan.recordSamples,
                                 triggerIndex: analogTriggerIndex)
    }

    public func readAnalog(offset: Int, count: Int) throws -> [UInt16] {
        let channels = max(analogPlan.conversionsPerSample, 1)
        let available = max(analogRecord.count / channels - offset, 0)
        let take = min(count, available)
        guard take > 0 else { return [] }
        return Array(analogRecord[(offset * channels)..<((offset + take) * channels)])
    }

    public func abortAnalog() throws {
        analogArmed = false
        analogReadyAt = .distantFuture
    }

    public func sampleAnalog(averages: Int) throws -> [UInt16] {
        let now = Date().timeIntervalSince(epoch)
        return (0..<capabilities.analogChannels).map { code($0, at: now) }
    }

    // MARK: - Logic

    /// Eight signals worth looking at: a ripple counter, a UART sending a
    /// short message, and an SPI burst — so the decoders have something real
    /// to chew on with nothing plugged in.
    private func logicByte(at time: Double) -> UInt8 {
        var value: UInt8 = 0
        let counterHz = 100_000.0
        for bit in 0..<4 {
            let divided = counterHz / pow(2, Double(bit))
            if fmod(time * divided, 1.0) < 0.5 { value |= UInt8(1 << bit) }
        }

        // D4: 115200 8N1, "PiLyzer ", idling high.
        let message = Array("PiLyzer ".utf8)
        let bitTime = 1.0 / 115200.0
        let frameTime = bitTime * 10
        let messageTime = frameTime * Double(message.count)
        let intoMessage = fmod(max(time, 0), messageTime)
        let byteIndex = min(Int(intoMessage / frameTime), message.count - 1)
        let intoFrame = intoMessage - Double(byteIndex) * frameTime
        let bitIndex = Int(intoFrame / bitTime)
        var uart = true
        if bitIndex == 0 { uart = false }
        else if bitIndex <= 8 { uart = message[byteIndex] & (1 << UInt8(bitIndex - 1)) != 0 }
        if uart { value |= 1 << 4 }

        // D5 clock, D6 data, D7 chip select: eight bits of 0xA5 every 100 µs.
        let spiPeriod = 100e-6
        let spiClock = 1_000_000.0
        let intoSPI = fmod(max(time, 0), spiPeriod)
        let clockTime = 1 / spiClock
        let burst = clockTime * 8
        if intoSPI < burst {
            let bit = min(Int(intoSPI / clockTime), 7)
            if fmod(intoSPI * spiClock, 1.0) >= 0.5 { value |= 1 << 5 }
            if (0xA5 as UInt8) & (1 << UInt8(7 - bit)) != 0 { value |= 1 << 6 }
        } else {
            value |= 1 << 7                                   // chip select idles high
        }
        return value
    }

    public func configureLogic(_ configuration: LogicConfiguration) throws -> AcquisitionPlan {
        logicConfiguration = configuration
        let clock = Double(capabilities.logicClockHz)
        let divisor = UInt32(min(max((configuration.samplePeriod * clock * 256).rounded(), 256), 0xFF_FFFF))
        logicPlan = AcquisitionPlan(clockHz: capabilities.logicClockHz,
                                    divisorQ8: divisor, decimation: 1,
                                    recordSamples: min(configuration.recordSamples, capabilities.logicMaxRecord),
                                    pretriggerSamples: min(configuration.pretriggerSamples,
                                                           configuration.recordSamples - 1),
                                    channelMask: 0xFF, conversionsPerSample: 1)
        return logicPlan
    }

    public func armLogic() throws {
        let period = logicPlan.samplePeriod
        let count = logicPlan.recordSamples
        let now = Date().timeIntervalSince(epoch)
        var start = now

        if logicConfiguration.triggerMode != .freeRun && signalPresent {
            let mask = UInt8(1 << UInt8(logicConfiguration.triggerChannel))
            let rising = logicConfiguration.triggerSlope == .rising
            var previous = logicByte(at: now) & mask != 0
            for step in 1...(count * 3) {
                let time = now + Double(step) * period
                let level = logicByte(at: time) & mask != 0
                if rising ? (!previous && level) : (previous && !level) {
                    start = time - Double(logicPlan.pretriggerSamples) * period
                    break
                }
                previous = level
            }
        }

        logicRecord = (0..<count).map { logicByte(at: start + Double($0) * period) }
        logicReadyAt = Date().addingTimeInterval(period * Double(count))
        logicArmed = true
    }

    public func logicStatus() throws -> AcquisitionStatus {
        guard logicArmed else {
            return AcquisitionStatus(state: .idle, triggered: false, samplesAvailable: 0, triggerIndex: 0)
        }
        if Date() < logicReadyAt {
            return AcquisitionStatus(state: .waiting, triggered: false, samplesAvailable: 0, triggerIndex: 0)
        }
        return AcquisitionStatus(state: .complete, triggered: logicConfiguration.triggerMode != .freeRun,
                                 samplesAvailable: logicPlan.recordSamples,
                                 triggerIndex: logicPlan.pretriggerSamples)
    }

    public func readLogic(offset: Int, count: Int) throws -> [UInt8] {
        let available = max(logicRecord.count - offset, 0)
        let take = min(count, available)
        guard take > 0 else { return [] }
        return Array(logicRecord[offset..<(offset + take)])
    }

    public func abortLogic() throws {
        logicArmed = false
        logicReadyAt = .distantFuture
    }

    // MARK: - Peripherals

    public func setRange(channel: Int, range: Int) throws {
        guard channel < ranges.count else { return }
        ranges[channel] = range
    }

    public func setLED(_ on: Bool) throws {}

    @discardableResult
    public func setCalibrationOutput(enabled: Bool, frequency: Int) throws -> Int {
        enabled ? max(frequency, 1) : 0
    }
}
