import Foundation

/// The spectrum's own words for the two settings a sweep is made of.
///
/// A sweep is a time on screen and a number of points. Read as a spectrum, the
/// time on screen is the resolution — a bin is one over it — and the points
/// spread across that time set the sample rate, half of which is the highest
/// frequency the record holds. Span and resolution are those same two settings
/// said the other way round, so going back to the scope shows exactly the
/// record the spectrum was made from.
///
/// The record lengths offered are powers of two, which is also what the
/// transform trims a record to, so the resolution chosen is the bin width got.
extension ScopeSettings {
    /// One bin of the spectrum this sweep gives.
    public var spectrumResolution: Double {
        Self.resolution(secondsPerDivision: secondsPerDivision)
    }

    public static func resolution(secondsPerDivision: Double) -> Double {
        1 / (secondsPerDivision * Double(horizontalDivisions))
    }

    /// Spans in a 1–2–5 sequence, up to half the fastest rate the converter
    /// reaches with this many channels.
    public static func spectrumSpans(capabilities: DeviceCapabilities, channels: Int) -> [Double] {
        let top = 0.5 / capabilities.minimumSamplePeriod(channels: max(channels, 1))
        var spans: [Double] = []
        var decade = 10.0
        while decade <= top {
            for multiplier in [1.0, 2.0, 5.0] where decade * multiplier <= top {
                spans.append(decade * multiplier)
            }
            decade *= 10
        }
        return spans
    }

    /// The shortest record that reaches `span` at `resolution`, or nil when
    /// none can: the longest one does not get there, or getting there would
    /// mean sampling faster than the converter goes.
    public static func spectrumRecord(span: Double, resolution: Double, lengths: [Int],
                                      capabilities: DeviceCapabilities, channels: Int) -> Int? {
        let fastest = 1 / capabilities.minimumSamplePeriod(channels: max(channels, 1))
        return lengths.sorted().first { length in
            let rate = Double(length) * resolution
            return length <= capabilities.analogMaxRecord
                && rate / 2 >= span * (1 - 1e-9)
                && rate <= fastest * (1 + 1e-9)
        }
    }

    /// Sets the span, and the record that reaches it at the current resolution.
    /// Nil is everything the record holds, and leaves the record alone.
    public mutating func setSpectrumSpan(_ span: Double?, lengths: [Int],
                                         capabilities: DeviceCapabilities, channels: Int) {
        spectrum.spanHz = span
        guard let span,
              let record = Self.spectrumRecord(span: span, resolution: spectrumResolution,
                                               lengths: lengths, capabilities: capabilities,
                                               channels: channels) else { return }
        recordLength = record
    }

    /// Sets the resolution by the time on screen that gives it, and keeps the
    /// span by choosing the record again.
    public mutating func setSpectrumResolution(secondsPerDivision: Double, lengths: [Int],
                                               capabilities: DeviceCapabilities, channels: Int) {
        self.secondsPerDivision = secondsPerDivision
        guard let span = spectrum.spanHz,
              let record = Self.spectrumRecord(span: span, resolution: spectrumResolution,
                                               lengths: lengths, capabilities: capabilities,
                                               channels: channels) else { return }
        recordLength = record
    }
}
