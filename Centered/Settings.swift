import Foundation

// MARK: - Settings Protocol

protocol Settings {
    var selectedScreenName: String? { get set }
    var centerActiveBinding: HotKeyBinding { get set }
    var centerAllBinding: HotKeyBinding { get set }
    var excludedBundleIDs: Set<String> { get set }
    var isAutoCenteringPaused: Bool { get set }
    var centersOnWindowScreen: Bool { get set }
    var animationStyle: WindowAnimationStyle { get set }

    /// Reset all settings to their default values for testing purposes.
    mutating func reset()
}

// MARK: - Default Settings Implementation

struct DefaultSettings: Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func isValidScreenName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 256
    }

    var selectedScreenName: String? {
        get {
            guard let name = defaults.selectedScreenName,
                  isValidScreenName(name)
            else { return nil }
            return name
        }
        set {
            guard let name = newValue, isValidScreenName(name) else {
                defaults.selectedScreenName = nil
                return
            }
            defaults.selectedScreenName = name
        }
    }

    var centerActiveBinding: HotKeyBinding {
        get { defaults.centerActiveBinding }
        set { defaults.centerActiveBinding = newValue }
    }

    var centerAllBinding: HotKeyBinding {
        get { defaults.centerAllBinding }
        set { defaults.centerAllBinding = newValue }
    }

    var excludedBundleIDs: Set<String> {
        get { defaults.excludedBundleIDs }
        set { defaults.excludedBundleIDs = newValue }
    }

    var isAutoCenteringPaused: Bool {
        get { defaults.isAutoCenteringPaused }
        set { defaults.isAutoCenteringPaused = newValue }
    }

    var centersOnWindowScreen: Bool {
        get { defaults.centersOnWindowScreen }
        set { defaults.centersOnWindowScreen = newValue }
    }

    var animationStyle: WindowAnimationStyle {
        get { defaults.animationStyle }
        set { defaults.animationStyle = newValue }
    }

    mutating func reset() {
        defaults.removeObject(forKey: UserDefaults.Key.selectedScreenName)
        defaults.removeObject(forKey: UserDefaults.Key.centerActiveHotKey)
        defaults.removeObject(forKey: UserDefaults.Key.centerAllHotKey)
        defaults.removeObject(forKey: UserDefaults.Key.excludedBundleIDs)
        defaults.removeObject(forKey: UserDefaults.Key.isAutoCenteringPaused)
        defaults.removeObject(forKey: UserDefaults.Key.centersOnWindowScreen)
        defaults.removeObject(forKey: UserDefaults.Key.animationStyle)
        defaults.removeLegacyCenteredSettings()
        ExclusionHMAC.resetStoredTag()
    }
}
