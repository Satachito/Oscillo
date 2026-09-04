import Foundation

/// One acquisition result, already converted to volts.
public struct ScopeFrame: Sendable, Equatable {
    public var channel1: [Double]
    public var channel2: [Double]
    /// Seconds between consecutive samples.
    public var sampleInterval: Double
    public var mode: AcquisitionMode
    /// False when the sweep was returned by an auto-trigger timeout.
    public var isTriggered: Bool
    /// Set when a channel's samples reached the converter's limits, so the
    /// trace on screen is a clipped copy of the real signal.
    public var channel1Clipped: Bool
    public var channel2Clipped: Bool
    public var timestamp: Date

    public init(
        channel1: [Double] = [],
        channel2: [Double] = [],
        sampleInterval: Double = 1,
        mode: AcquisitionMode = .scope,
        isTriggered: Bool = true,
        channel1Clipped: Bool = false,
        channel2Clipped: Bool = false,
        timestamp: Date = Date()
    ) {
        self.channel1 = channel1
        self.channel2 = channel2
        self.sampleInterval = sampleInterval
        self.mode = mode
        self.isTriggered = isTriggered
        self.channel1Clipped = channel1Clipped
        self.channel2Clipped = channel2Clipped
        self.timestamp = timestamp
    }

    public func isClipped(_ channel: Int) -> Bool {
        channel == 0 ? channel1Clipped : channel2Clipped
    }

    public var isEmpty: Bool { channel1.isEmpty && channel2.isEmpty }

    public var duration: Double {
        Double(max(channel1.count, channel2.count)) * sampleInterval
    }

    public func samples(for channel: Int) -> [Double] {
        channel == 0 ? channel1 : channel2
    }
}

/// Summary statistics shown under the display.
public struct ChannelStatistics: Sendable, Equatable {
    public var minimum: Double
    public var maximum: Double
    public var mean: Double
    public var rms: Double

    public var peakToPeak: Double { maximum - minimum }

    public init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        var lowest = samples[0]
        var highest = samples[0]
        var total = 0.0
        var totalSquares = 0.0
        for value in samples {
            lowest = Swift.min(lowest, value)
            highest = Swift.max(highest, value)
            total += value
            totalSquares += value * value
        }
        minimum = lowest
        maximum = highest
        mean = total / Double(samples.count)
        rms = (totalSquares / Double(samples.count)).squareRoot()
    }
}

/// Fundamental frequency of a trace, from the times it crosses its own midpoint.
///
/// Interpolating each crossing and measuring from the first to the last keeps
/// the estimate far better than the sample interval alone would allow. Returns
/// nil when the trace does not cross often enough to be sure — a flat line, a
/// signal slower than the sweep, or noise around the midpoint.
public func estimateFrequency(_ samples: [Double], sampleInterval: Double) -> Double? {
    guard samples.count > 8, sampleInterval > 0 else { return nil }

    var lowest = samples[0]
    var highest = samples[0]
    for value in samples {
        lowest = Swift.min(lowest, value)
        highest = Swift.max(highest, value)
    }
    let amplitude = highest - lowest
    guard amplitude > 0 else { return nil }
    let middle = (highest + lowest) / 2
    // Hysteresis, so noise riding on the midpoint cannot fake a crossing.
    let band = amplitude * 0.15

    var crossings: [Double] = []
    var armed = false
    for index in 1..<samples.count {
        if samples[index] < middle - band {
            armed = true
        } else if armed, samples[index] >= middle, samples[index - 1] < middle {
            armed = false
            let step = samples[index] - samples[index - 1]
            let fraction = step == 0 ? 0 : (middle - samples[index - 1]) / step
            crossings.append((Double(index - 1) + fraction) * sampleInterval)
        }
    }

    guard crossings.count >= 2 else { return nil }
    let span = crossings[crossings.count - 1] - crossings[0]
    guard span > 0 else { return nil }
    return Double(crossings.count - 1) / span
}

/// Engineering-notation helpers, used by labels and readouts.
public enum Format {
    public static func voltage(_ value: Double) -> String { scaled(value, unit: "V") }
    public static func time(_ value: Double) -> String { scaled(value, unit: "s") }
    public static func frequency(_ value: Double) -> String { scaled(value, unit: "Hz") }

    private static func scaled(_ value: Double, unit: String) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case 0: return "0 \(unit)"
        case ..<1e-9: return String(format: "%.2f p%@", value * 1e12, unit)
        case ..<1e-6: return String(format: "%.2f n%@", value * 1e9, unit)
        case ..<1e-3: return String(format: "%.3g µ%@", value * 1e6, unit)
        case ..<1: return String(format: "%.3g m%@", value * 1e3, unit)
        case ..<1e3: return String(format: "%.3g %@", value, unit)
        case ..<1e6: return String(format: "%.3g k%@", value / 1e3, unit)
        default: return String(format: "%.3g M%@", value / 1e6, unit)
        }
    }
}

/// Splits the interleaved readback buffer into two channels.
public func deinterleave(_ samples: [UInt8]) -> (first: [UInt8], second: [UInt8]) {
    var first: [UInt8] = []
    var second: [UInt8] = []
    first.reserveCapacity(samples.count / 2 + 1)
    second.reserveCapacity(samples.count / 2 + 1)
    for (index, value) in samples.enumerated() {
        if index % 2 == 0 { first.append(value) } else { second.append(value) }
    }
    return (first, second)
}

/// Single-sided magnitude spectrum, in volts, with a Hann window applied.
///
/// The input is zero-padded to the next power of two so the in-place radix-2
/// transform below can be used for any record length.
public func magnitudeSpectrum(
    _ samples: [Double],
    sampleInterval: Double
) -> (frequencies: [Double], magnitudes: [Double]) {
    guard samples.count >= 4, sampleInterval > 0 else { return ([], []) }

    let mean = samples.reduce(0, +) / Double(samples.count)
    var size = 1
    while size < samples.count { size <<= 1 }

    var real = [Double](repeating: 0, count: size)
    var imaginary = [Double](repeating: 0, count: size)
    var windowPower = 0.0
    for index in 0..<samples.count {
        let window = 0.5 * (1 - cos(2 * .pi * Double(index) / Double(samples.count - 1)))
        real[index] = (samples[index] - mean) * window
        windowPower += window
    }
    guard windowPower > 0 else { return ([], []) }

    fastFourierTransform(real: &real, imaginary: &imaginary)

    let binCount = size / 2
    let resolution = 1.0 / (sampleInterval * Double(size))
    var frequencies = [Double](repeating: 0, count: binCount)
    var magnitudes = [Double](repeating: 0, count: binCount)
    for bin in 0..<binCount {
        frequencies[bin] = Double(bin) * resolution
        let amplitude = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
        magnitudes[bin] = 2 * amplitude / windowPower
    }
    return (frequencies, magnitudes)
}

/// In-place iterative radix-2 Cooley–Tukey FFT. `real` and `imaginary` must be
/// the same power-of-two length.
func fastFourierTransform(real: inout [Double], imaginary: inout [Double]) {
    let count = real.count
    precondition(count == imaginary.count && count > 0 && count & (count - 1) == 0)

    // Bit-reversal permutation.
    var target = 0
    for source in 1..<count {
        var bit = count >> 1
        while target & bit != 0 {
            target ^= bit
            bit >>= 1
        }
        target |= bit
        if source < target {
            real.swapAt(source, target)
            imaginary.swapAt(source, target)
        }
    }

    var length = 2
    while length <= count {
        let angle = -2 * Double.pi / Double(length)
        let stepReal = cos(angle)
        let stepImaginary = sin(angle)
        var start = 0
        while start < count {
            var twiddleReal = 1.0
            var twiddleImaginary = 0.0
            for offset in 0..<(length / 2) {
                let a = start + offset
                let b = a + length / 2
                let productReal = twiddleReal * real[b] - twiddleImaginary * imaginary[b]
                let productImaginary = twiddleReal * imaginary[b] + twiddleImaginary * real[b]
                real[b] = real[a] - productReal
                imaginary[b] = imaginary[a] - productImaginary
                real[a] += productReal
                imaginary[a] += productImaginary
                let nextReal = twiddleReal * stepReal - twiddleImaginary * stepImaginary
                twiddleImaginary = twiddleReal * stepImaginary + twiddleImaginary * stepReal
                twiddleReal = nextReal
            }
            start += length
        }
        length <<= 1
    }
}
