//
// UserDefaults+Centered.swift
// Centered
//
// Typed accessors for every preference key the app persists.
// Using a dedicated extension avoids stringly-typed key literals scattered
// across the codebase.
//

import Foundation

extension UserDefaults {

    private enum Key {
        static let selectedScreenName  = "selectedScreenName"
        static let centerActiveHotKey  = "centerActiveHotKey"
        static let centerAllHotKey     = "centerAllHotKey"
        static let excludedBundleIDs   = "excludedBundleIDs"
    }

    // MARK: - Screen

    /// The `localizedName` of the user's preferred screen, or `nil` if never set.
    var selectedScreenName: String? {
        get { string(forKey: Key.selectedScreenName) }
        set { set(newValue, forKey: Key.selectedScreenName) }
    }

    // MARK: - Hotkeys

    /// Binding for "Center Active Window". Defaults to ⌘⌥C.
    var centerActiveBinding: HotKeyBinding {
        get {
            guard let dict = dictionary(forKey: Key.centerActiveHotKey),
                  let b    = HotKeyBinding(dictionary: dict) else { return .centerActive }
            return b
        }
        set { set(newValue.dictionaryRepresentation, forKey: Key.centerActiveHotKey) }
    }

    /// Binding for "Center All Windows". Defaults to ⌘⇧C.
    var centerAllBinding: HotKeyBinding {
        get {
            guard let dict = dictionary(forKey: Key.centerAllHotKey),
                  let b    = HotKeyBinding(dictionary: dict) else { return .centerAll }
            return b
        }
        set { set(newValue.dictionaryRepresentation, forKey: Key.centerAllHotKey) }
    }

    // MARK: - Exclusion list

    /// Bundle IDs of apps that should never be auto-centered.
    var excludedBundleIDs: Set<String> {
        get { Set(stringArray(forKey: Key.excludedBundleIDs) ?? []) }
        set { set(Array(newValue), forKey: Key.excludedBundleIDs) }
    }
}
