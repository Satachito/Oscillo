import Foundation
import PiLyzerCore

/// The front panel comes back the way it was left.
enum Preferences {
    private static let settingsKey = "PiLyzer.settings.v1"
    private static let sourceKey = "PiLyzer.source.v1"

    /// Record lengths the panel offers. A power of two is what the transform
    /// wants, so a stored value from an older build is snapped onto the list
    /// rather than leaving the picker showing nothing.
    static let recordLengths = [512, 1024, 2048, 4096, 8192, 16384]
    static let logicRecordLengths = [1024, 4096, 8192, 16384, 32768, 65536]

    static func load() -> ScopeSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              var settings = try? JSONDecoder().decode(ScopeSettings.self, from: data) else {
            return ScopeSettings()
        }
        settings.recordLength = nearest(settings.recordLength, in: recordLengths)
        settings.logic.recordLength = nearest(settings.logic.recordLength, in: logicRecordLengths)
        return settings
    }

    private static func nearest(_ value: Int, in options: [Int]) -> Int {
        options.min { abs($0 - value) < abs($1 - value) } ?? value
    }

    static func save(_ settings: ScopeSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    static func loadSource() -> DeviceSource? {
        guard let data = UserDefaults.standard.data(forKey: sourceKey) else { return nil }
        return try? JSONDecoder().decode(DeviceSource.self, from: data)
    }

    static func save(source: DeviceSource) {
        guard let data = try? JSONEncoder().encode(source) else { return }
        UserDefaults.standard.set(data, forKey: sourceKey)
    }
}
