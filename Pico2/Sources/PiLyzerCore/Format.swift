import Foundation

/// Engineering notation, so a panel never reads "0.000002 s".
public enum Format {
    private static let prefixes: [(exponent: Int, symbol: String)] = [
        (-15, "f"), (-12, "p"), (-9, "n"), (-6, "µ"), (-3, "m"),
        (0, ""), (3, "k"), (6, "M"), (9, "G"),
    ]

    public static func engineering(_ value: Double, unit: String, digits: Int = 3) -> String {
        guard value.isFinite, value != 0 else { return "0 \(unit)" }
        let magnitude = abs(value)
        var chosen = prefixes[5]
        for entry in prefixes where magnitude >= pow(10, Double(entry.exponent)) {
            chosen = entry
        }
        let scaled = value / pow(10, Double(chosen.exponent))
        let decimals = max(0, digits - 1 - Int(floor(log10(abs(scaled)))))
        return String(format: "%.\(min(decimals, 4))f %@%@", scaled, chosen.symbol, unit)
    }

    public static func voltage(_ value: Double) -> String { engineering(value, unit: "V") }
    public static func time(_ value: Double) -> String { engineering(value, unit: "s") }
    public static func frequency(_ value: Double) -> String { engineering(value, unit: "Hz") }
    public static func sampleRate(_ value: Double) -> String { engineering(value, unit: "Sa/s") }

    public static func decibels(_ value: Double) -> String {
        value.isFinite ? String(format: "%.1f dB", value) : "—"
    }

    public static func percent(_ value: Double, digits: Int = 2) -> String {
        String(format: "%.\(digits)f %%", value)
    }
}
