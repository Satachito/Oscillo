import Foundation

/// One selectable input range, described by the straight line that maps a
/// voltage at the probe tip to a voltage at the converter.
///
/// Everything else about the analogue front end — dividers, op amps, which
/// analogue switch is closed — lives on the board and in its documentation.
/// This is the only shape the application needs.
public struct InputRange: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    /// Converter volts per volt at the input.
    public var gain: Double
    /// Converter volts with 0 V at the input.
    public var offset: Double
    /// Which position the board's range switch has to be in.
    public var switchPosition: Int

    public var id: String { name }

    public init(name: String, gain: Double, offset: Double, switchPosition: Int) {
        self.name = name
        self.gain = gain
        self.offset = offset
        self.switchPosition = switchPosition
    }

    public var lowestInput: Double { -offset / gain }
    public func highestInput(reference: Double) -> Double { (reference - offset) / gain }

    public func span(reference: Double) -> Double {
        highestInput(reference: reference) - lowestInput
    }

    /// Volts per division, if the whole converter span is drawn over the grid.
    public func voltsPerDivision(reference: Double, probe: Double, divisions: Int) -> Double {
        span(reference: reference) * probe / Double(divisions)
    }
}

/// The ranges a particular board offers.
public enum FrontEnd {
    /// Inputs straight on the converter pins: one range, 0 V to the reference,
    /// and nothing to switch.
    public static let bareBoard = [
        InputRange(name: "0 – 3.3 V", gain: 1.0, offset: 0.0, switchPosition: 0)
    ]

    /// PiLyzer analogue front end rev A. Both ranges sit on the same
    /// attenuator and the same mid-rail bias; the switch only changes the gain
    /// of the stage after it, so the attenuator's frequency compensation never
    /// has to change with the range. The constants come from the nominal
    /// resistor values in `hardware/pilyzer-afe`.
    public static let revA = [
        InputRange(name: "±25 V", gain: 0.062645, offset: 1.650515, switchPosition: 0),
        InputRange(name: "±5 V", gain: 0.297269, offset: 1.652442, switchPosition: 1),
    ]

    public static func ranges(forBoard boardID: UInt32) -> [InputRange] {
        boardID == 0 ? bareBoard : revA
    }
}

/// Per channel, per range: the correction a two-point calibration leaves
/// behind. The resistors are ordinary 1% parts, so this is where their
/// tolerance goes instead of into a trimmer.
public struct ChannelCalibration: Codable, Equatable, Sendable {
    /// Volts at the input that read as zero.
    public var zero: Double
    /// Correction to the nominal gain.
    public var scale: Double

    public init(zero: Double = 0, scale: Double = 1) {
        self.zero = zero
        self.scale = scale
    }

    public var isDefault: Bool { zero == 0 && scale == 1 }

    /// Solves for both constants from two measured points.
    ///
    /// `low` and `high` are what the instrument read with `lowTrue` and
    /// `highTrue` actually applied.
    public static func from(low: Double, lowTrue: Double,
                            high: Double, highTrue: Double) -> ChannelCalibration? {
        let measuredSpan = high - low
        guard abs(measuredSpan) > 1e-9 else { return nil }
        let scale = (highTrue - lowTrue) / measuredSpan
        return ChannelCalibration(zero: low - lowTrue / scale, scale: scale)
    }

    public func apply(_ volts: Double) -> Double { (volts - zero) * scale }
}

/// Converts converter readings to volts at the probe tip.
public struct VoltageScale: Equatable, Sendable {
    public var reference: Double
    public var fullScale: Double
    public var range: InputRange
    public var calibration: ChannelCalibration
    public var probe: Double

    public init(reference: Double, fullScale: Double, range: InputRange,
                calibration: ChannelCalibration = ChannelCalibration(), probe: Double = 1) {
        self.reference = reference
        self.fullScale = fullScale
        self.range = range
        self.calibration = calibration
        self.probe = probe
    }

    public func volts(_ sample: UInt16) -> Double { volts(code: Double(sample)) }

    public func volts(code: Double) -> Double {
        calibration.apply(uncalibratedVolts(code: code)) * probe
    }

    /// Input volts before calibration and probe multiplication. A grounded
    /// reading in this space replaces ChannelCalibration.zero directly.
    public func uncalibratedVolts(code: Double) -> Double {
        (code / fullScale * reference - range.offset) / range.gain
    }

    /// The reading a given input voltage would produce, which is how the
    /// trigger level reaches the instrument.
    public func code(forVolts volts: Double) -> Double {
        let uncorrected = volts / probe / calibration.scale + calibration.zero
        let converter = uncorrected * range.gain + range.offset
        return converter / reference * fullScale
    }

    public var lowestVolts: Double { volts(code: 0) }
    public var highestVolts: Double { volts(code: fullScale) }
    public var centreVolts: Double { (lowestVolts + highestVolts) / 2 }
    public var spanVolts: Double { highestVolts - lowestVolts }
}
