import Foundation

/// How wide each of a converter's codes is, from how often each one comes up.
///
/// Put a smooth sweep on the input and take a great many conversions: a code
/// that stands for a wide slice of voltage is landed on more often than its
/// neighbours, a narrow one less often, and a missing one never. The sweep
/// need not be a straight ramp — the curve of a resistor and a capacitor will
/// do — because each code is set against the median of the codes around it.
/// The median follows the sweep's own density, and one wide code among the
/// neighbours does not move it.
public struct CodeDensity: Equatable, Sendable {
    /// The first code measured; `widths[0]` is its width.
    public var firstCode: Int
    /// Each code's width as a multiple of its neighbours': 1 on an even converter.
    public var widths: [Double]

    public init(firstCode: Int, widths: [Double]) {
        self.firstCode = firstCode
        self.widths = widths
    }

    /// `histogram[code]` is how many conversions gave that code. `codes` is
    /// the stretch to measure, which has to leave `neighbours` codes clear at
    /// either end of the histogram.
    public static func of(histogram: [Int], codes: Range<Int>, neighbours: Int = 40) -> CodeDensity {
        let measured = codes.clamped(to: neighbours..<max(histogram.count - neighbours, neighbours))
        let widths = measured.map { code -> Double in
            var around = Array(histogram[(code - neighbours)..<code])
            around += histogram[(code + 1)...(code + neighbours)]
            around.sort()
            // An even number of them, so the median is between the middle two.
            let median = Double(around[neighbours - 1] + around[neighbours]) / 2
            return median > 0 ? Double(histogram[code]) / median : 0
        }
        return CodeDensity(firstCode: measured.lowerBound, widths: widths)
    }

    /// The same codes measured on several sweeps, averaged.
    public static func mean(_ runs: [CodeDensity]) -> CodeDensity? {
        guard let first = runs.first,
              runs.allSatisfy({ $0.firstCode == first.firstCode && $0.widths.count == first.widths.count })
        else { return nil }
        let widths = first.widths.indices.map { index in
            runs.reduce(0) { $0 + $1.widths[index] } / Double(runs.count)
        }
        return CodeDensity(firstCode: first.firstCode, widths: widths)
    }

    /// How far the sweeps are from their mean, as a multiple of a neighbour's
    /// width: what the figures are good to.
    public static func scatter(_ runs: [CodeDensity]) -> Double? {
        guard let mean = mean(runs), !mean.widths.isEmpty else { return nil }
        let squares = runs.reduce(0.0) { total, run in
            total + zip(run.widths, mean.widths).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        }
        return (squares / Double(runs.count * mean.widths.count)).squareRoot()
    }

    public var codes: Range<Int> { firstCode..<(firstCode + widths.count) }

    public func width(of code: Int) -> Double? {
        codes.contains(code) ? widths[code - firstCode] : nil
    }

    public func codes(where test: (Double) -> Bool) -> [Int] {
        widths.indices.filter { test(widths[$0]) }.map { $0 + firstCode }
    }

    /// The median width of the codes picked out, nil if there are none.
    public func typicalWidth(where test: (Int) -> Bool) -> Double? {
        let picked = codes.filter(test).map { widths[$0 - firstCode] }.sorted()
        guard !picked.isEmpty else { return nil }
        return picked[picked.count / 2]
    }

    /// Differential nonlinearity in LSB: the widths scaled so that the mean
    /// code is one LSB wide, less one. A neighbour is a little over one LSB
    /// on a converter with many narrow codes, which is why this is not simply
    /// the width less one.
    public var differential: [Double] {
        let total = widths.reduce(0, +)
        guard total > 0 else { return widths.map { _ in 0 } }
        let scale = Double(widths.count) / total
        return widths.map { $0 * scale - 1 }
    }

    public var rmsDifferential: Double {
        let errors = differential
        guard !errors.isEmpty else { return 0 }
        return (errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)).squareRoot()
    }

    /// Integral nonlinearity in LSB over the codes measured: how far the
    /// running sum of the differential strays, below and above.
    public var line: ClosedRange<Double> {
        var sum = 0.0, low = 0.0, high = 0.0
        for error in differential {
            sum += error
            low = min(low, sum)
            high = max(high, sum)
        }
        return low...high
    }
}
