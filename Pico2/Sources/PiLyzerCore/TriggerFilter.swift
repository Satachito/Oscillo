import Foundation

/// Mirrors the firmware's trigger-only, one-pole filter. The sample record
/// retains the original ADC codes, including their steps and noise.
struct TriggerFilter {
    private let alpha: Int64
    private(set) var remaining: Int
    private var value: Int64?

    init(cutoffHz: Int, samplePeriod: Double) {
        let exponent = 2 * Double.pi * Double(cutoffHz) * samplePeriod
        alpha = cutoffHz == 0 ? 0 : Int64((-expm1(-exponent) * Double(1 << 30)).rounded())
        remaining = cutoffHz == 0 ? 0 : Int(ceil(5 / exponent))
    }

    mutating func sample(_ code: UInt16) -> Int {
        guard alpha != 0 else { return Int(code) }
        let target = Int64(code) * 65536
        if let previous = value {
            value = previous + (target - previous) * alpha / (1 << 30)
        } else {
            value = target
        }
        remaining = max(remaining - 1, 0)
        return Int((value! + 32768) / 65536)
    }
}
