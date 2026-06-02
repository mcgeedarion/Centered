import Foundation

protocol Settings {
    var selectedScreenName: String? { get set }
    var centerActiveBinding: HotKeyBinding { get set }
    var centerAllBinding: HotKeyBinding { get set }
    var excludedBundleIDs: Set<String> { get set }
}

struct DefaultSettings: Settings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedScreenName: String? {
        get {
            guard let name = defaults.selectedScreenName,
                  !name.isEmpty,
                  name.count <= 256
            else { return nil }
            return name
        }
        set { defaults.selectedScreenName = newValue }
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
}
