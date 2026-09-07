import DPScopeCore
import Foundation

/// Front-panel state that survives a relaunch, the way a bench instrument
/// remembers where you left its knobs.
enum Preferences {
    private static let defaults = UserDefaults.standard
    private static let settingsKey = "scopeSettings"
    private static let displayModeKey = "displayMode"
    private static let measurementsKey = "showMeasurements"
    private static let sourceKey = "deviceSource"

    static func loadSettings() -> ScopeSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(ScopeSettings.self, from: data)
        else { return ScopeSettings() }
        return settings
    }

    static func save(_ settings: ScopeSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    static var displayMode: DisplayMode {
        get {
            defaults.string(forKey: displayModeKey).flatMap(DisplayMode.init(rawValue:)) ?? .time
        }
        set { defaults.set(newValue.rawValue, forKey: displayModeKey) }
    }

    /// The source the app was last connected to, so it comes back to the same
    /// instrument next launch.
    static var deviceSource: DeviceSource? {
        get {
            guard let data = defaults.data(forKey: sourceKey) else { return nil }
            return try? JSONDecoder().decode(DeviceSource.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                defaults.removeObject(forKey: sourceKey)
                return
            }
            defaults.set(data, forKey: sourceKey)
        }
    }

    static var showMeasurements: Bool {
        get { defaults.object(forKey: measurementsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: measurementsKey) }
    }
}
