import Foundation

// MARK: - Property Wrapper for UserDefaults

@propertyWrapper
struct UserDefault<Value: Codable> {
    let key: String
    let defaultValue: Value
    private let userDefaults: UserDefaults
    
    init(_ key: String, defaultValue: Value, userDefaults: UserDefaults = .standard) {
        self.key = key
        self.defaultValue = defaultValue
        self.userDefaults = userDefaults
    }
    
    var wrappedValue: Value {
        get {
            guard let data = userDefaults.data(forKey: key) else { return defaultValue }
            let decoder = JSONDecoder()
            return (try? decoder.decode(Value.self, from: data)) ?? defaultValue
        }
        set {
            let encoder = JSONEncoder()
            if let encoded = try? encoder.encode(newValue) {
                userDefaults.set(encoded, forKey: key)
            }
        }
    }
}

// MARK: - Settings Protocol

protocol Settings {
    var selectedScreenName: String? { get set }
    var centerActiveBinding: HotKeyBinding { get set }
    var centerAllBinding: HotKeyBinding { get set }
    var excludedBundleIDs: Set<String> { get set }
    
    /// Reset all settings to their default values for testing purposes
    mutating func reset()
}

// MARK: - Default Settings Implementation

struct DefaultSettings: Settings {
    private let defaults: UserDefaults
    
    // MARK: - Properties with UserDefault Wrapper
    
    @UserDefault("centerActiveBinding", defaultValue: HotKeyBinding())
    private var _centerActiveBinding: HotKeyBinding
    
    @UserDefault("centerAllBinding", defaultValue: HotKeyBinding())
    private var _centerAllBinding: HotKeyBinding
    
    @UserDefault("excludedBundleIDs", defaultValue: Set<String>())
    private var _excludedBundleIDs: Set<String>
    
    // MARK: - Initialization
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Initialize property wrappers
        self._centerActiveBinding = UserDefault("centerActiveBinding", defaultValue: HotKeyBinding(), userDefaults: defaults)
        self._centerAllBinding = UserDefault("centerAllBinding", defaultValue: HotKeyBinding(), userDefaults: defaults)
        self._excludedBundleIDs = UserDefault("excludedBundleIDs", defaultValue: Set<String>(), userDefaults: defaults)
    }
    
    // MARK: - Validation
    
    private func isValidScreenName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 256
    }
    
    // MARK: - Settings Properties
    
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
        get { _centerActiveBinding }
        set { _centerActiveBinding = newValue }
    }
    
    var centerAllBinding: HotKeyBinding {
        get { _centerAllBinding }
        set { _centerAllBinding = newValue }
    }
    
    var excludedBundleIDs: Set<String> {
        get { _excludedBundleIDs }
        set { _excludedBundleIDs = newValue }
    }
    
    // MARK: - Testability
    
    mutating func reset() {
        selectedScreenName = nil
        centerActiveBinding = HotKeyBinding()
        centerAllBinding = HotKeyBinding()
        excludedBundleIDs = Set<String>()
        
        // Also clear from UserDefaults
        defaults.removeObject(forKey: "selectedScreenName")
        defaults.removeObject(forKey: "centerActiveBinding")
        defaults.removeObject(forKey: "centerAllBinding")
        defaults.removeObject(forKey: "excludedBundleIDs")
    }
}
