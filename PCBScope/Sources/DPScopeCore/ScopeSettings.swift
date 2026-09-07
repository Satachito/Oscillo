import Foundation

/// Calibration constants of the DPScope SE analogue front end, taken from the
/// V1.1 schematic.
public enum FrontEnd {
    /// Input divider R3 / (R1 + R3) = 100 kΩ / 1009 kΩ.
    public static let inputDivider = 100.0 / 1009.0
    /// The ×10 stage: 1 + R7 / (R4 ∥ R6) = 1 + 4.53 kΩ / 500 Ω.
    public static let secondStageGain = 1 + 4530.0 / 500.0

    /// Fraction of the input voltage that reaches the converter.
    public static func attenuation(_ path: InputPath) -> Double {
        switch path {
        case .gain1: return inputDivider
        case .gain10: return inputDivider * secondStageGain
        }
    }
}

/// Which of the two amplifier outputs a channel is read from.
public enum InputPath: String, CaseIterable, Codable, Sendable {
    case gain1
    case gain10

    public func adcChannel(forChannel channel: Int) -> ADCChannel {
        switch (channel, self) {
        case (0, .gain1): return .channel1Gain1
        case (0, .gain10): return .channel1Gain10
        case (_, .gain1): return .channel2Gain1
        case (_, .gain10): return .channel2Gain10
        }
    }
}

/// The scope stores 8 of the converter's 10 bits; which 8 is the "digital gain".
///
/// The firmware computes `sample = (raw - 2 × subtract) >> shift`, which was
/// confirmed on hardware — only this form keeps 0 V (raw 512) at code 128 for
/// all three settings.
public enum DigitalGain: Int, CaseIterable, Codable, Sendable {
    case x1 = 1
    case x2 = 2
    case x4 = 4

    public var shift: UInt8 {
        switch self {
        case .x1: return 2
        case .x2: return 1
        case .x4: return 0
        }
    }

    public var subtract: UInt8 {
        switch self {
        case .x1: return 0
        case .x2: return 128
        case .x4: return 192
        }
    }

    /// Reconstructs the 10-bit reading from a stored sample.
    public func rawCode(from sample: UInt8) -> Double {
        Double(Int(sample) << Int(shift)) + 2 * Double(subtract)
    }
}

/// One vertical sensitivity step: an amplifier path plus a digital gain.
public struct VerticalRange: Hashable, Codable, Sendable, Identifiable {
    public var path: InputPath
    public var digitalGain: DigitalGain

    public var id: String { "\(path.rawValue)-\(digitalGain.rawValue)" }

    public init(path: InputPath, digitalGain: DigitalGain) {
        self.path = path
        self.digitalGain = digitalGain
    }

    /// Coarse to fine, the six combinations the hardware offers.
    public static let all: [VerticalRange] = [
        VerticalRange(path: .gain1, digitalGain: .x1),
        VerticalRange(path: .gain1, digitalGain: .x2),
        VerticalRange(path: .gain1, digitalGain: .x4),
        VerticalRange(path: .gain10, digitalGain: .x1),
        VerticalRange(path: .gain10, digitalGain: .x2),
        VerticalRange(path: .gain10, digitalGain: .x4),
    ]

    /// Volts at the top of the screen, for the given supply rail.
    public func fullScaleVolts(supply: Double, probe: ProbeAttenuation = .x1) -> Double {
        (ScopeRecord.zeroCode * supply / 1023.0)
            / FrontEnd.attenuation(path)
            / Double(digitalGain.rawValue)
            * probe.rawValue
    }

    public func voltsPerDivision(supply: Double, probe: ProbeAttenuation = .x1) -> Double {
        fullScaleVolts(supply: supply, probe: probe) / Double(ScopeGrid.verticalDivisions / 2)
    }

    public func label(supply: Double, probe: ProbeAttenuation = .x1) -> String {
        "±" + Format.voltage(fullScaleVolts(supply: supply, probe: probe))
    }
}

public enum ProbeAttenuation: Double, CaseIterable, Codable, Sendable {
    case x1 = 1
    case x10 = 10

    public var label: String { self == .x1 ? "1:1" : "1:10" }
}

/// Display grid geometry, shared by the view and the scaling maths.
public enum ScopeGrid {
    public static let horizontalDivisions = 10
    public static let verticalDivisions = 8
}

/// How the record is paced.
public enum SamplingMode: String, Codable, Sendable {
    /// Timer0 paces the converter; the whole record comes from one event.
    case realTime
    /// The scope walks the sample point across many trigger events, which needs
    /// a repetitive signal but reaches far shorter intervals.
    case equivalentTime
}

/// A horizontal step, together with the timer settings that produce it.
public struct Timebase: Sendable, Equatable, Identifiable {
    public let secondsPerDivision: Double
    public let mode: SamplingMode
    public let preload: UInt16
    public let prescaler: Prescaler
    /// Equivalent-time interval in 0.5 µs steps (`CMD_ARM` byte 17).
    public let equivalentTimeSteps: UInt8
    /// The interval actually achieved, which is what the time axis uses.
    public let sampleInterval: Double

    public var id: String { label }

    public var label: String { Format.time(secondsPerDivision) + "/div" }

    /// The converter's own time sets the floor: the fastest real-time sample
    /// pair measured on hardware was 29.5 µs, so anything quicker has to be
    /// sampled in equivalent time.
    public static let fastestRealTimeInterval = 40e-6

    /// Builds the step closest to a requested sweep speed.
    public static func nearest(secondsPerDivision requested: Double) -> Timebase {
        let wantedInterval = requested * Double(ScopeGrid.horizontalDivisions) / Double(ScopeRecord.sampleCount)

        if wantedInterval < fastestRealTimeInterval {
            let steps = UInt8(min(max((wantedInterval / 0.5e-6).rounded(), 1), 255))
            let interval = Double(steps) * 0.5e-6
            return Timebase(
                secondsPerDivision: interval * Double(ScopeRecord.sampleCount) / Double(ScopeGrid.horizontalDivisions),
                mode: .equivalentTime,
                preload: 65_036,
                prescaler: .bypassed,
                equivalentTimeSteps: steps,
                sampleInterval: interval
            )
        }

        let (preload, prescaler) = AcquisitionSetup.timing(forSampleInterval: wantedInterval)
        let interval = AcquisitionSetup(timerPreload: preload, prescaler: prescaler).sampleInterval
        return Timebase(
            secondsPerDivision: interval * Double(ScopeRecord.sampleCount) / Double(ScopeGrid.horizontalDivisions),
            mode: .realTime,
            preload: preload,
            prescaler: prescaler,
            equivalentTimeSteps: 0,
            sampleInterval: interval
        )
    }

    /// The sweep speeds offered in the UI, in a 1–2–5 sequence.
    public static let all: [Timebase] = {
        var steps: [Double] = []
        var decade = 10e-6
        while decade <= 1.0 {
            for multiplier in [1.0, 2.0, 5.0] { steps.append(decade * multiplier) }
            decade *= 10
        }
        return steps.map(Timebase.nearest)
    }()

    /// How long one record takes to acquire.
    public var recordDuration: Double {
        sampleInterval * Double(ScopeRecord.sampleCount)
    }
}

public enum AcquisitionMode: String, CaseIterable, Codable, Sendable {
    case scope = "Scope"
    case datalog = "Data log"
}

public struct ChannelSettings: Sendable, Equatable, Codable {
    public var isEnabled: Bool
    public var rangeIndex: Int
    public var probeAttenuation: ProbeAttenuation
    /// Where 0 V sits on the display, in divisions from the centre line.
    public var positionDivisions: Double
    /// Converter reading for 0 V in, per amplifier path.
    ///
    /// The board's offset trimmer sets this, and the ×10 stage amplifies
    /// whatever error the trimmer leaves, so the two paths are calibrated
    /// separately. 512 is the nominal value from the vendor's documentation.
    public var zeroGain1: Double
    public var zeroGain10: Double

    public init(
        isEnabled: Bool = true,
        rangeIndex: Int = 3,
        probeAttenuation: ProbeAttenuation = .x1,
        positionDivisions: Double = 0,
        zeroGain1: Double = ScopeRecord.zeroCode,
        zeroGain10: Double = ScopeRecord.zeroCode
    ) {
        self.isEnabled = isEnabled
        self.rangeIndex = rangeIndex
        self.probeAttenuation = probeAttenuation
        self.positionDivisions = positionDivisions
        self.zeroGain1 = zeroGain1
        self.zeroGain10 = zeroGain10
    }

    /// The measured zero for the path this channel is currently reading.
    public var zeroCode: Double {
        range.path == .gain10 ? zeroGain10 : zeroGain1
    }

    public mutating func setZero(_ code: Double, for path: InputPath) {
        switch path {
        case .gain1: zeroGain1 = code
        case .gain10: zeroGain10 = code
        }
    }

    public var isZeroCalibrated: Bool {
        zeroGain1 != ScopeRecord.zeroCode || zeroGain10 != ScopeRecord.zeroCode
    }

    public var range: VerticalRange {
        VerticalRange.all[min(max(rangeIndex, 0), VerticalRange.all.count - 1)]
    }

    public func fullScaleVolts(supply: Double) -> Double {
        range.fullScaleVolts(supply: supply, probe: probeAttenuation)
    }

    public func voltsPerDivision(supply: Double) -> Double {
        range.voltsPerDivision(supply: supply, probe: probeAttenuation)
    }

    /// Converts one stored sample to volts at the probe tip.
    public func volts(sample: UInt8, supply: Double) -> Double {
        volts(code: range.digitalGain.rawCode(from: sample), supply: supply)
    }

    /// Converts a direct 10-bit reading (`CMD_READADC`) to volts.
    public func volts(rawCode: UInt16, supply: Double) -> Double {
        volts(code: Double(rawCode), supply: supply)
    }

    private func volts(code: Double, supply: Double) -> Double {
        (code - zeroCode) * (supply / 1023.0)
            / FrontEnd.attenuation(range.path)
            * probeAttenuation.rawValue
    }
}

public enum TriggerMode: String, CaseIterable, Codable, Sendable {
    /// Free-running: the scope samples immediately.
    case auto = "Auto"
    /// Waits for the edge, and reports back when nothing arrives.
    case normal = "Normal"
}

public enum TriggerSource: String, CaseIterable, Codable, Sendable {
    case channel1 = "Ch1"
    case external = "Ext"

    public func channel(for path: InputPath) -> TriggerChannel {
        switch self {
        case .external: return .external
        case .channel1: return path == .gain10 ? .channel1Gain10 : .channel1Gain1
        }
    }
}

public struct TriggerSettings: Sendable, Equatable, Codable {
    public var mode: TriggerMode
    public var source: TriggerSource
    public var risingEdge: Bool
    /// Threshold as a fraction of full scale, −1 … +1.
    public var level: Double

    public init(
        mode: TriggerMode = .auto,
        source: TriggerSource = .channel1,
        risingEdge: Bool = true,
        level: Double = 0
    ) {
        self.mode = mode
        self.source = source
        self.risingEdge = risingEdge
        self.level = level
    }

    /// The comparator threshold byte: an 8-bit PWM level spanning the supply,
    /// compared against the amplifier output, where mid-scale is 0 V in.
    public func levelByte(fullScaleFraction: Double = 1) -> UInt8 {
        let clamped = min(max(level, -1), 1)
        let code = 127.5 + clamped * 127.5 * fullScaleFraction
        return UInt8(min(max(code.rounded(), 0), 255))
    }

    /// The threshold in volts at the probe tip, for readouts and the marker.
    public func levelVolts(channel: ChannelSettings, supply: Double) -> Double {
        min(max(level, -1), 1) * channel.fullScaleVolts(supply: supply)
    }
}

/// Everything the acquisition engine needs.
public struct ScopeSettings: Sendable, Equatable, Codable {
    public var mode: AcquisitionMode
    public var channel1: ChannelSettings
    public var channel2: ChannelSettings
    public var timebaseIndex: Int
    public var trigger: TriggerSettings
    public var averaging: Int

    public init(
        mode: AcquisitionMode = .scope,
        channel1: ChannelSettings = ChannelSettings(),
        channel2: ChannelSettings = ChannelSettings(),
        timebaseIndex: Int = 6,
        trigger: TriggerSettings = TriggerSettings(),
        averaging: Int = 1
    ) {
        self.mode = mode
        self.channel1 = channel1
        self.channel2 = channel2
        self.timebaseIndex = timebaseIndex
        self.trigger = trigger
        self.averaging = averaging
    }

    public var timebase: Timebase {
        Timebase.all[min(max(timebaseIndex, 0), Timebase.all.count - 1)]
    }

    /// True when the sweep needs a trigger whatever the trigger mode says.
    public var requiresTrigger: Bool {
        mode == .scope && timebase.mode == .equivalentTime
    }

    public var hasEnabledChannel: Bool { channel1.isEnabled || channel2.isEnabled }

    public var effectiveAveraging: Int { min(max(averaging, 1), 100) }

    /// The `CMD_ARM` packet for these settings.
    public func acquisitionSetup() -> AcquisitionSetup {
        let timebase = self.timebase
        return AcquisitionSetup(
            firstChannel: channel1.range.path.adcChannel(forChannel: 0),
            secondChannel: channel2.range.path.adcChannel(forChannel: 1),
            timerPreload: timebase.preload,
            prescaler: timebase.prescaler,
            firstShift: channel1.range.digitalGain.shift,
            secondShift: channel2.range.digitalGain.shift,
            firstSubtract: channel1.range.digitalGain.subtract,
            secondSubtract: channel2.range.digitalGain.subtract,
            // Equivalent-time sampling assembles one record from many trigger
            // events, so it is meaningless without a trigger: free-running, the
            // points come from arbitrary phases and a single sine comes back as
            // several overlaid ones.
            waitsForTrigger: trigger.mode == .normal || timebase.mode == .equivalentTime,
            risingEdge: trigger.risingEdge,
            triggerLevel: trigger.levelByte(),
            equivalentTime: timebase.mode == .equivalentTime,
            equivalentTimeInterval: timebase.equivalentTimeSteps,
            equivalentTimeStability: max(timebase.equivalentTimeSteps / 2, 1),
            triggerChannel: trigger.source.channel(for: channel1.range.path)
        )
    }
}
