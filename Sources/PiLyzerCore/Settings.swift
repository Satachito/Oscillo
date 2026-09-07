import Foundation

public enum WorkMode: String, CaseIterable, Codable, Sendable {
    case scope = "Scope"
    case spectrum = "Spectrum"
    case logic = "Logic"
    case meter = "Meter"

    public var usesAnalogRecord: Bool { self == .scope || self == .spectrum }
}

public struct AnalogChannelSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var rangeIndex: Int
    public var probeAttenuation: Double
    /// Where 0 V sits on the screen, in divisions from the centre line.
    public var positionDivisions: Double
    /// Removes the mean of the record before drawing. The hardware is DC
    /// coupled, so this is done in software and says so on the panel.
    public var removesMean: Bool
    /// Volts a division on screen. Zero means "show the whole range", which is
    /// the sensible default when the hardware has only a couple of ranges and
    /// the rest of the zooming is done here.
    public var voltsPerDivision: Double
    public var calibration: [ChannelCalibration]

    public init(isEnabled: Bool = true, rangeIndex: Int = 0, probeAttenuation: Double = 1,
                positionDivisions: Double = 0, removesMean: Bool = false,
                voltsPerDivision: Double = 0, calibration: [ChannelCalibration] = []) {
        self.isEnabled = isEnabled
        self.rangeIndex = rangeIndex
        self.probeAttenuation = probeAttenuation
        self.positionDivisions = positionDivisions
        self.removesMean = removesMean
        self.voltsPerDivision = voltsPerDivision
        self.calibration = calibration
    }

    /// What a division is actually worth, once "show the whole range" is
    /// resolved against the range that is selected.
    public func effectiveVoltsPerDivision(reference: Double, ranges: [InputRange],
                                          divisions: Int) -> Double {
        if voltsPerDivision > 0 { return voltsPerDivision }
        let span = range(from: ranges).span(reference: reference) * probeAttenuation
        return span / Double(divisions)
    }

    /// The 1–2–5 choices offered for this range, from the whole span down to a
    /// hundredth of it.
    public static func verticalSteps(span: Double, divisions: Int) -> [Double] {
        let coarsest = span / Double(divisions)
        var steps: [Double] = []
        var decade = 1e-4
        while decade <= 100 {
            for multiplier in [1.0, 2.0, 5.0] {
                let value = decade * multiplier
                if value <= coarsest * 1.001 && value >= coarsest / 100 { steps.append(value) }
            }
            decade *= 10
        }
        return steps.reversed()
    }

    public func range(from ranges: [InputRange]) -> InputRange {
        ranges[min(max(rangeIndex, 0), ranges.count - 1)]
    }

    public func calibration(forRange index: Int) -> ChannelCalibration {
        index < calibration.count ? calibration[index] : ChannelCalibration()
    }

    public mutating func setCalibration(_ value: ChannelCalibration, forRange index: Int) {
        while calibration.count <= index { calibration.append(ChannelCalibration()) }
        calibration[index] = value
    }

    public mutating func calibrateZero(to uncalibratedVolts: Double, forRange index: Int) {
        var correction = calibration(forRange: index)
        correction.zero = uncalibratedVolts
        setCalibration(correction, forRange: index)
    }

    public func scale(reference: Double, fullScale: Double, ranges: [InputRange]) -> VoltageScale {
        let index = min(max(rangeIndex, 0), ranges.count - 1)
        return VoltageScale(reference: reference, fullScale: fullScale,
                            range: ranges[index], calibration: calibration(forRange: index),
                            probe: probeAttenuation)
    }
}

public struct AnalogTriggerSettings: Codable, Equatable, Sendable {
    public var mode: TriggerMode
    public var source: Int
    public var slope: TriggerSlope
    public var levelVolts: Double
    /// Where the trigger sits across the screen, 0 at the left, 1 at the right.
    public var position: Double
    /// Noise rejection, as a fraction of the converter's span.
    public var hysteresis: Double
    public var autoTimeout: Double

    public init(mode: TriggerMode = .auto, source: Int = 0, slope: TriggerSlope = .rising,
                levelVolts: Double = 0, position: Double = 0.1,
                hysteresis: Double = 0.004, autoTimeout: Double = 0.1) {
        self.mode = mode
        self.source = source
        self.slope = slope
        self.levelVolts = levelVolts
        self.position = position
        self.hysteresis = hysteresis
        self.autoTimeout = autoTimeout
    }
}

public struct LogicSettings: Codable, Equatable, Sendable {
    public var enabledChannels: Set<Int>
    public var sampleRate: Double
    public var recordLength: Int
    public var triggerMode: TriggerMode
    public var triggerChannel: Int
    public var triggerSlope: TriggerSlope
    public var triggerPosition: Double
    public var autoTimeout: Double

    public init(enabledChannels: Set<Int> = Set(0..<8), sampleRate: Double = 10_000_000,
                recordLength: Int = 4096, triggerMode: TriggerMode = .auto,
                triggerChannel: Int = 0, triggerSlope: TriggerSlope = .rising,
                triggerPosition: Double = 0.1, autoTimeout: Double = 0.2) {
        self.enabledChannels = enabledChannels
        self.sampleRate = sampleRate
        self.recordLength = recordLength
        self.triggerMode = triggerMode
        self.triggerChannel = triggerChannel
        self.triggerSlope = triggerSlope
        self.triggerPosition = triggerPosition
        self.autoTimeout = autoTimeout
    }

    public func configuration(capabilities: DeviceCapabilities) -> LogicConfiguration {
        let period = max(1 / max(sampleRate, 1), 1 / Double(capabilities.logicClockHz))
        let record = min(max(recordLength, 64), capabilities.logicMaxRecord)
        let pretrigger = min(Int(Double(record) * min(max(triggerPosition, 0), 0.95)),
                             capabilities.logicMaxPretrigger)
        return LogicConfiguration(triggerMode: triggerMode, triggerChannel: triggerChannel,
                                  triggerSlope: triggerSlope, samplePeriod: period,
                                  recordSamples: record, pretriggerSamples: pretrigger,
                                  autoTimeout: autoTimeout)
    }

    /// The rates the capture clock can actually produce, coarsest first.
    public static func availableRates(capabilities: DeviceCapabilities) -> [Double] {
        let top = Double(capabilities.logicClockHz)
        var rates: [Double] = []
        var step = 1000.0
        while step <= top {
            for multiplier in [1.0, 2.0, 5.0] where step * multiplier <= top {
                rates.append(step * multiplier)
            }
            step *= 10
        }
        if rates.last != top { rates.append(top) }
        return rates
    }
}

public struct ScopeSettings: Codable, Equatable, Sendable {
    public var mode: WorkMode
    public var channels: [AnalogChannelSettings]
    public var secondsPerDivision: Double
    public var recordLength: Int
    public var trigger: AnalogTriggerSettings
    public var averaging: Int
    public var logic: LogicSettings
    public var spectrum: SpectrumSettings
    public var showsXY: Bool
    public var calibrationOutputEnabled: Bool
    public var calibrationOutputFrequency: Int

    public init(mode: WorkMode = .scope,
                channels: [AnalogChannelSettings] = [AnalogChannelSettings(), AnalogChannelSettings()],
                secondsPerDivision: Double = 1e-3, recordLength: Int = 2048,
                trigger: AnalogTriggerSettings = AnalogTriggerSettings(), averaging: Int = 1,
                logic: LogicSettings = LogicSettings(), spectrum: SpectrumSettings = SpectrumSettings(),
                showsXY: Bool = false, calibrationOutputEnabled: Bool = true,
                calibrationOutputFrequency: Int = 1000) {
        self.mode = mode
        self.channels = channels
        self.secondsPerDivision = secondsPerDivision
        self.recordLength = recordLength
        self.trigger = trigger
        self.averaging = averaging
        self.logic = logic
        self.spectrum = spectrum
        self.showsXY = showsXY
        self.calibrationOutputEnabled = calibrationOutputEnabled
        self.calibrationOutputFrequency = calibrationOutputFrequency
    }

    public static let horizontalDivisions = 10
    public static let verticalDivisions = 8
    /// Below this a trace is a handful of dots, not a waveform.
    public static let minimumRecord = 50

    public var enabledMask: UInt8 {
        var mask: UInt8 = 0
        for (index, channel) in channels.enumerated() where channel.isEnabled { mask |= 1 << index }
        return mask == 0 ? 0b01 : mask
    }

    public var enabledChannelCount: Int {
        let mask = enabledMask
        return (0..<channels.count).reduce(0) { $0 + ((mask & (1 << $1)) != 0 ? 1 : 0) }
    }

    /// Spectra can share an averaging history only while their input and
    /// acquisition conditions agree. Display units and markers do not matter.
    public func hasSameSpectrumInput(as other: ScopeSettings) -> Bool {
        mode == other.mode && channels == other.channels
            && secondsPerDivision == other.secondsPerDivision
            && recordLength == other.recordLength && trigger == other.trigger
            && averaging == other.averaging && spectrum.window == other.spectrum.window
            && calibrationOutputEnabled == other.calibrationOutputEnabled
            && calibrationOutputFrequency == other.calibrationOutputFrequency
    }

    /// Turns the front panel into the request the instrument understands.
    ///
    /// The sample rate is pinned at the converter's fastest whenever the sweep
    /// asks for more points than it can deliver, and the record shrinks
    /// instead — so a fast sweep shows fewer, real samples rather than a
    /// smooth line the hardware never measured.
    public func analogConfiguration(capabilities: DeviceCapabilities,
                                    scales: [VoltageScale]) -> AnalogConfiguration {
        let mask = enabledMask
        let channelCount = enabledChannelCount
        let floorPeriod = capabilities.minimumSamplePeriod(channels: channelCount)
        let screenTime = secondsPerDivision * Double(Self.horizontalDivisions)

        var record = min(max(recordLength, Self.minimumRecord), capabilities.analogMaxRecord)
        var period = screenTime / Double(record)
        if period < floorPeriod {
            period = floorPeriod
            record = min(max(Int((screenTime / floorPeriod).rounded()), Self.minimumRecord),
                         capabilities.analogMaxRecord)
        }

        let source = min(max(trigger.source, 0), max(channels.count - 1, 0))
        // An unavailable trigger source falls back to the first enabled
        // physical channel, whose scale must be used for the voltage code.
        let effectiveSource = mask & (1 << source) != 0 ? source : (mask & 1 != 0 ? 0 : 1)
        let scale = scales.indices.contains(effectiveSource) ? scales[effectiveSource] : scales.first
        let levelCode = scale.map { $0.code(forVolts: trigger.levelVolts) } ?? capabilities.analogFullScale / 2
        let level = UInt16(min(max(levelCode.rounded(), 0), capabilities.analogFullScale))
        let hysteresis = UInt16(min(max(trigger.hysteresis * capabilities.analogFullScale, 0), 4095))

        // The wire source is a slot in the interleaved acquisition record.
        let slot = (mask == 0b11) ? effectiveSource : 0

        let pretrigger = min(Int(Double(record) * min(max(trigger.position, 0), 0.95)),
                             capabilities.analogMaxPretrigger)

        return AnalogConfiguration(channelMask: mask, triggerMode: trigger.mode,
                                   triggerSource: slot, triggerSlope: trigger.slope,
                                   triggerLevel: level, triggerHysteresis: hysteresis,
                                   samplePeriod: period, recordSamples: record,
                                   pretriggerSamples: pretrigger, autoTimeout: trigger.autoTimeout)
    }

    /// Sweep speeds in a 1–2–5 sequence, starting at the fastest the converter
    /// can actually fill a usable trace at.
    public static func timebases(capabilities: DeviceCapabilities, channels: Int) -> [Double] {
        let floor = capabilities.minimumSamplePeriod(channels: max(channels, 1))
            * Double(minimumRecord) / Double(horizontalDivisions)
        var steps: [Double] = []
        var decade = 1e-9
        while decade <= 10 {
            for multiplier in [1.0, 2.0, 5.0] {
                let value = decade * multiplier
                if value >= floor && value <= 5 { steps.append(value) }
            }
            decade *= 10
        }
        return steps
    }
}
