import AVFoundation
import CoreAudio
import Foundation

/// The Mac's own sound input as an instrument: the built-in microphone, or
/// better the line input of an audio interface. What it hears is read on
/// this Mac and goes nowhere else.
///
/// It is not a PiLyzer and does not pretend to be one on the wire. It answers
/// the commands a board answers out of a buffer the audio thread keeps
/// filling, and finds the trigger in software, comparing converter codes the
/// way the firmware does.
///
/// What it reads is the sound card's own scale: ±1 is full scale, and there
/// is no direct current. A channel's gain calibration turns that into volts
/// against a known signal, as it does for any front end.
public final class SoundInstrument: Instrument {
    /// −1…+1 across the converter codes, against a 2 V reference.
    public static let range = InputRange(name: "±1 full scale", gain: 1, offset: 1, switchPosition: 0)

    public let identity: DeviceIdentity
    public let capabilities: DeviceCapabilities
    public let sampleRate: Double
    let buffer: SoundBuffer
    private let engine: AVAudioEngine?

    private var configuration = AnalogConfiguration()
    private var plan = AcquisitionPlan.empty
    private var decimation = 1
    private var trigger: SoundTrigger?
    private var armedAt = Date.distantPast
    private var since = 0
    private var record: [UInt16] = []
    private var finished: AcquisitionStatus?

    /// The Mac's sound inputs, the default one first: anything with an input
    /// stream, from the built-in microphone to an audio interface.
    public static func inputs() -> [(uid: String, name: String)] {
        let fallback = defaultInputDevice()
        let found = allDevices().compactMap { device -> (id: AudioDeviceID, uid: String, name: String)? in
            guard hasInput(device), !isHidden(device),
                  let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = string(device, kAudioObjectPropertyName) ?? "Sound input"
            // Core Audio makes these for itself, the engine's own included;
            // they are not inputs anybody plugged in.
            guard !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return (device, uid, name)
        }
        return (found.filter { $0.id == fallback } + found.filter { $0.id != fallback }).map { ($0.uid, $0.name) }
    }

    /// Opens the input with this UID. The first time, macOS asks whether
    /// PiLyzer may use the microphone, and this waits for the answer.
    public static func open(uid: String) throws -> SoundInstrument {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            let answered = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0; answered.signal() }
            answered.wait()
            guard granted else { throw SoundError.notAllowed }
        default:
            throw SoundError.notAllowed
        }
        guard let device = allDevices().first(where: { hasInput($0) && string($0, kAudioDevicePropertyDeviceUID) == uid })
        else { throw SoundError.noInput }
        let name = string(device, kAudioObjectPropertyName) ?? "Sound input"

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The engine's input follows the system's default unless told otherwise.
        var chosen = device
        guard let unit = input.audioUnit,
              AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                   &chosen, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { throw SoundError.couldNotStart("the input could not be selected") }
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw SoundError.noInput }
        let channels = min(Int(format.channelCount), 8)
        let instrument = SoundInstrument(name: name, channels: channels,
                                         sampleRate: format.sampleRate, engine: engine)
        let buffer = instrument.buffer
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { block, _ in
            guard let data = block.floatChannelData else { return }
            let frames = Int(block.frameLength)
            buffer.push((0..<min(Int(block.format.channelCount), channels)).map {
                UnsafeBufferPointer(start: data[$0], count: frames)
            })
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SoundError.couldNotStart(error.localizedDescription)
        }
        return instrument
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func allDevices() -> [AudioDeviceID] {
        var where_ = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var where_ = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    private static func isHidden(_ device: AudioDeviceID) -> Bool {
        var where_ = address(kAudioDevicePropertyIsHidden)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var where_ = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &where_, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var where_ = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// For the tests: a buffer filled by hand rather than by the audio thread.
    init(name: String, channels: Int, sampleRate: Double, engine: AVAudioEngine? = nil,
         capacity: Int = 1 << 20) {
        self.sampleRate = sampleRate
        self.engine = engine
        buffer = SoundBuffer(channels: channels, capacity: capacity)
        identity = DeviceIdentity(protocolVersion: Wire.version, firmwareVersion: 0,
                                  boardID: Self.boardID, name: name)
        capabilities = DeviceCapabilities(
            analogChannels: channels, analogBits: 16, logicChannels: 0, analogRanges: 1,
            analogClockHz: UInt32(sampleRate.rounded()), analogMinPeriodCycles: 1,
            analogMaxRecord: 65536, analogMaxPretrigger: 65535,
            logicClockHz: 0, logicMaxRecord: 0, logicMaxPretrigger: 0,
            referenceVolts: 2, flags: 16, simultaneous: true)
    }

    /// No board has this id; it marks a sound input wherever the identity is
    /// all there is to go on.
    public static let boardID: UInt32 = 0x534E

    public func close() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    public func inputRanges() throws -> [InputRange] { [Self.range] }

    // MARK: - Analogue

    public func configureAnalog(_ configuration: AnalogConfiguration) throws -> AcquisitionPlan {
        guard configuration.triggerLowPassHz == 0 else {
            throw InstrumentError.rejected(.analogConfigure, .badArgument)
        }
        let channels = configuration.channels
        guard channels > 0,
              configuration.channelMask & ~UInt8((1 << capabilities.analogChannels) - 1) == 0 else {
            throw InstrumentError.rejected(.analogConfigure, .badArgument)
        }
        self.configuration = configuration
        decimation = max(Int((configuration.samplePeriod * sampleRate).rounded()), 1)
        // A record longer than half the ring would be overwritten while it is read.
        let count = max(2, min(configuration.recordSamples, capabilities.analogMaxRecord,
                               buffer.capacity / 2 / decimation))
        // The interval is decimation / rate: one cycle of a clock running at
        // the rate times the channels, taken once a channel and decimated.
        plan = AcquisitionPlan(clockHz: UInt32((sampleRate * Double(channels)).rounded()),
                               divisorQ8: 256, decimation: UInt32(decimation),
                               recordSamples: count,
                               pretriggerSamples: min(configuration.pretriggerSamples, count - 1),
                               channelMask: configuration.channelMask,
                               conversionsPerSample: channels)
        return plan
    }

    public func armAnalog() throws {
        since = buffer.written
        armedAt = Date()
        record = []
        finished = nil
        let slots = plan.enabledChannels
        let source = slots.indices.contains(Int(configuration.triggerSource))
            ? slots[Int(configuration.triggerSource)] : slots.first ?? 0
        trigger = configuration.triggerMode == .freeRun ? nil : SoundTrigger(
            channel: source, level: Int(configuration.triggerLevel),
            hysteresis: Int(configuration.triggerHysteresis),
            rising: configuration.triggerSlope == .rising, decimation: decimation,
            before: plan.pretriggerSamples, after: plan.recordSamples - plan.pretriggerSamples,
            next: since)
    }

    /// Sweeps are taken from audio that arrived after Arm. Free running takes
    /// the newest whole record; Auto waits its timeout past the record for an
    /// edge and then takes the newest; Normal waits for as long as it takes.
    public func analogStatus() throws -> AcquisitionStatus {
        if let finished { return finished }
        guard plan.recordSamples > 0, armedAt != .distantPast else {
            return AcquisitionStatus(state: .idle, triggered: false, samplesAvailable: 0, triggerIndex: 0)
        }
        let span = plan.recordSamples * decimation
        let slots = plan.enabledChannels
        return buffer.read { reader in
            if var search = trigger {
                let edge = search.scan(reader)
                trigger = search
                if let edge {
                    return finish(reader, start: edge - plan.pretriggerSamples * decimation,
                                  triggered: true, slots: slots)
                }
            }
            let fresh = reader.written - span >= since
            let patience = plan.duration + max(configuration.autoTimeout, 0.05)
            if fresh && (configuration.triggerMode == .freeRun
                         || (configuration.triggerMode == .auto && Date().timeIntervalSince(armedAt) > patience)) {
                return finish(reader, start: reader.written - span, triggered: false, slots: slots)
            }
            return AcquisitionStatus(state: .waiting, triggered: false, samplesAvailable: 0, triggerIndex: 0)
        }
    }

    private func finish(_ reader: SoundBuffer.Reader, start: Int, triggered: Bool,
                        slots: [Int]) -> AcquisitionStatus {
        record = soundRecord(reader, channels: slots, start: start,
                             count: plan.recordSamples, decimation: decimation)
        let status = AcquisitionStatus(state: .complete, triggered: triggered,
                                       samplesAvailable: plan.recordSamples,
                                       triggerIndex: triggered ? plan.pretriggerSamples : 0)
        finished = status
        return status
    }

    public func readAnalog(offset: Int, count: Int) throws -> [UInt16] {
        let channels = max(plan.conversionsPerSample, 1)
        let take = min(count, max(record.count / channels - offset, 0))
        guard take > 0 else { return [] }
        return Array(record[(offset * channels)..<((offset + take) * channels)])
    }

    public func abortAnalog() throws {
        armedAt = .distantPast
        trigger = nil
        finished = nil
    }

    /// The meter: each input's RMS over the last tenth of a second.
    public func sampleAnalog(averages: Int) throws -> [UInt16] {
        buffer.read { soundLevels($0, channels: capabilities.analogChannels, frames: Int(sampleRate / 10)) }
    }

    // MARK: - What a sound card does not have

    public func configureLogic(_ configuration: LogicConfiguration) throws -> AcquisitionPlan {
        throw InstrumentError.logicUnavailable
    }
    public func armLogic() throws { throw InstrumentError.logicUnavailable }
    public func logicStatus() throws -> AcquisitionStatus { throw InstrumentError.logicUnavailable }
    public func readLogic(offset: Int, count: Int) throws -> [UInt8] { throw InstrumentError.logicUnavailable }
    public func abortLogic() throws {}
    public func setRange(channel: Int, range: Int) throws {}
    public func setLED(_ on: Bool) throws {}
    @discardableResult public func setCalibrationOutput(enabled: Bool, frequency: Int) throws -> Int { 0 }
    @discardableResult public func setSignals(enabled: Bool, sineHz: Int) throws -> Int { 0 }
}

public enum SoundError: Error, LocalizedError, Equatable {
    case notAllowed
    case noInput
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed:
            return "PiLyzer is not allowed to use the microphone. Allow it in System Settings → "
                + "Privacy & Security → Microphone, then connect again."
        case .noInput:
            return "This Mac has no sound input. Plug one in, or choose it in System Settings → Sound → Input."
        case let .couldNotStart(reason):
            return "The sound input would not start: \(reason)"
        }
    }
}
