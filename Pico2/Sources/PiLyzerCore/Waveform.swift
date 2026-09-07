import Foundation

public struct ChannelTrace: Equatable, Sendable, Identifiable {
    public var index: Int
    /// Volts at the probe tip.
    public var samples: [Double]
    /// True when the record touched the ends of the converter's range, where
    /// the signal on screen is a flattened copy of the real one and no amount
    /// of calibration brings it back.
    public var clipped: Bool
    /// What software AC coupling took out, in volts. Zero when it is off. The
    /// samples are no longer absolute once this is non-zero, so anything drawn
    /// against them — the trigger level, above all — has to be shifted by the
    /// same amount.
    public var removedMean: Double

    public var id: Int { index }

    public init(index: Int, samples: [Double], clipped: Bool = false, removedMean: Double = 0) {
        self.index = index
        self.samples = samples
        self.clipped = clipped
        self.removedMean = removedMean
    }
}

public struct ScopeFrame: Equatable, Sendable {
    public var traces: [ChannelTrace]
    public var samplePeriod: Double
    public var triggerIndex: Int
    public var triggered: Bool
    public var timestamp: Date

    public init(traces: [ChannelTrace] = [], samplePeriod: Double = 0,
                triggerIndex: Int = 0, triggered: Bool = false, timestamp: Date = Date()) {
        self.traces = traces
        self.samplePeriod = samplePeriod
        self.triggerIndex = triggerIndex
        self.triggered = triggered
        self.timestamp = timestamp
    }

    public var sampleCount: Int { traces.first?.samples.count ?? 0 }
    public var duration: Double { samplePeriod * Double(sampleCount) }
    public var isEmpty: Bool { sampleCount == 0 }

    public func trace(_ index: Int) -> ChannelTrace? { traces.first { $0.index == index } }

    /// Time of a sample relative to the trigger, which is where the time axis
    /// has its zero.
    public func time(at sample: Int) -> Double {
        Double(sample - triggerIndex) * samplePeriod
    }
}

public struct LogicFrame: Equatable, Sendable {
    public var samples: [UInt8]
    public var samplePeriod: Double
    public var triggerIndex: Int
    public var triggered: Bool
    public var channelCount: Int
    public var timestamp: Date

    public init(samples: [UInt8] = [], samplePeriod: Double = 0, triggerIndex: Int = 0,
                triggered: Bool = false, channelCount: Int = 8, timestamp: Date = Date()) {
        self.samples = samples
        self.samplePeriod = samplePeriod
        self.triggerIndex = triggerIndex
        self.triggered = triggered
        self.channelCount = channelCount
        self.timestamp = timestamp
    }

    public var isEmpty: Bool { samples.isEmpty }
    public var duration: Double { samplePeriod * Double(samples.count) }

    public func level(_ channel: Int, at index: Int) -> Bool {
        guard index >= 0, index < samples.count else { return false }
        return samples[index] & (1 << UInt8(channel)) != 0
    }

    public func time(at sample: Int) -> Double { Double(sample - triggerIndex) * samplePeriod }
}

/// What the readouts under the screen show.
public struct Measurements: Equatable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var peakToPeak: Double
    public var mean: Double
    public var rms: Double
    /// RMS with the mean removed — the AC part on its own.
    public var acRMS: Double
    public var frequency: Double?
    public var period: Double?
    public var dutyCycle: Double?
    public var riseTime: Double?
    public var fallTime: Double?

    public static let empty = Measurements(minimum: 0, maximum: 0, peakToPeak: 0, mean: 0,
                                           rms: 0, acRMS: 0)

    /// Measures one trace. Every timing figure comes from crossings of the
    /// half-way level with hysteresis, so noise around the crossing does not
    /// invent extra edges.
    public static func of(_ samples: [Double], samplePeriod: Double) -> Measurements {
        guard !samples.isEmpty else { return .empty }

        var minimum = samples[0], maximum = samples[0], total = 0.0, square = 0.0
        for value in samples {
            minimum = Swift.min(minimum, value)
            maximum = Swift.max(maximum, value)
            total += value
            square += value * value
        }
        let count = Double(samples.count)
        let mean = total / count
        let rms = (square / count).squareRoot()
        let variance = Swift.max(square / count - mean * mean, 0)

        var result = Measurements(minimum: minimum, maximum: maximum,
                                  peakToPeak: maximum - minimum, mean: mean,
                                  rms: rms, acRMS: variance.squareRoot())

        let amplitude = maximum - minimum
        guard amplitude > 1e-9, samplePeriod > 0 else { return result }

        let middle = (maximum + minimum) / 2
        let guard_ = amplitude * 0.05
        var risingCrossings: [Double] = []
        var fallingCrossings: [Double] = []
        var above = samples[0] > middle

        for index in 1..<samples.count {
            let value = samples[index]
            if !above, value > middle + guard_ {
                above = true
                risingCrossings.append(interpolatedCrossing(samples, index, middle))
            } else if above, value < middle - guard_ {
                above = false
                fallingCrossings.append(interpolatedCrossing(samples, index, middle))
            }
        }

        // A short record may hold only one crossing of one polarity, so the
        // period comes from whichever edge was seen at least twice.
        let periodEdges = risingCrossings.count >= 2 ? risingCrossings : fallingCrossings
        if periodEdges.count >= 2 {
            let span = periodEdges[periodEdges.count - 1] - periodEdges[0]
            let period = span / Double(periodEdges.count - 1) * samplePeriod
            if period > 0 {
                result.period = period
                result.frequency = 1 / period
            }
        }

        if let first = risingCrossings.first, let period = result.period,
           let fall = fallingCrossings.first(where: { $0 > first }) {
            let high = (fall - first) * samplePeriod
            result.dutyCycle = Swift.min(Swift.max(high / period, 0), 1)
        }

        result.riseTime = transitionTime(samples, minimum: minimum, maximum: maximum,
                                         samplePeriod: samplePeriod, rising: true)
        result.fallTime = transitionTime(samples, minimum: minimum, maximum: maximum,
                                         samplePeriod: samplePeriod, rising: false)
        return result
    }

    /// Where between two samples the level was actually crossed.
    private static func interpolatedCrossing(_ samples: [Double], _ index: Int, _ level: Double) -> Double {
        let previous = samples[index - 1]
        let current = samples[index]
        let step = current - previous
        guard abs(step) > 1e-15 else { return Double(index) }
        return Double(index - 1) + (level - previous) / step
    }

    private static func transitionTime(_ samples: [Double], minimum: Double, maximum: Double,
                                       samplePeriod: Double, rising: Bool) -> Double? {
        let amplitude = maximum - minimum
        guard amplitude > 1e-9 else { return nil }
        let low = minimum + amplitude * 0.1
        let high = minimum + amplitude * 0.9

        var lowIndex: Double?
        for index in 1..<samples.count {
            let previous = samples[index - 1], current = samples[index]
            if rising {
                if previous < low, current >= low { lowIndex = interpolatedCrossing(samples, index, low) }
                if let start = lowIndex, previous < high, current >= high {
                    return (interpolatedCrossing(samples, index, high) - start) * samplePeriod
                }
            } else {
                if previous > high, current <= high { lowIndex = interpolatedCrossing(samples, index, high) }
                if let start = lowIndex, previous > low, current <= low {
                    return (interpolatedCrossing(samples, index, low) - start) * samplePeriod
                }
            }
        }
        return nil
    }
}
