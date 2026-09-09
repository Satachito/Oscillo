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

    /// One `InputRange` as the device reports it — see `docs/protocol.md`.
    /// Gain arrives in millionths of a volt per volt and offset in microvolts,
    /// which is finer than the 1% resistors that set them by three orders of
    /// magnitude.
    public static let wireSize = 32

    public init?(wire bytes: ArraySlice<UInt8>) {
        guard bytes.count >= Self.wireSize else { return nil }
        var reader = ByteReader(Data(bytes))
        let position = Int(reader.uint8())
        _ = reader.uint8()                       // flags, reserved
        _ = reader.uint16()                      // reserved
        let gain = Double(Int32(bitPattern: reader.uint32())) / 1e6
        let offset = Double(Int32(bitPattern: reader.uint32())) / 1e6
        let name = reader.string(20)
        guard gain != 0, !name.isEmpty else { return nil }
        self.init(name: name, gain: gain, offset: offset, switchPosition: position)
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

    /// The voltage the screen's centre line carries when a channel is not
    /// shifted: the middle of what this channel can actually measure.
    ///
    /// A range that straddles zero puts zero there — snapped exactly, so the
    /// centre line is zero volts and not the few millivolts of asymmetry that
    /// ordinary resistors leave. A range that reaches only one side of zero
    /// puts its own midpoint there instead, so a 0–3.3 V rail uses the whole
    /// screen rather than the half above the middle.
    public var screenCentreVolts: Double {
        let centre = centreVolts
        return abs(centre) < abs(spanVolts) / 1000 ? 0 : centre
    }

    /// True when zero volts is inside the range rather than at its edge.
    public var straddlesZero: Bool { lowestVolts < 0 && highestVolts > 0 }

    /// Keeps a trigger level somewhere the signal can actually reach. A level
    /// sitting on the rail never fires, which looks exactly like a broken
    /// trigger.
    public func usableTriggerLevel(_ volts: Double) -> Double {
        let margin = abs(spanVolts) * 0.02
        let low = min(lowestVolts, highestVolts) + margin
        let high = max(lowestVolts, highestVolts) - margin
        guard low < high else { return screenCentreVolts }
        return min(max(volts, low), high)
    }
}
