//
// UserDefaults+Centered.swift
// Centered
//
// Typed accessors for every preference key the app persists.
// All raw key strings live here — nowhere else in the codebase.
//

import Foundation

extension UserDefaults {

    // MARK: - Keys

    private enum Key {
        static let selectedScreenName = "selectedScreenName"
        static let centerActiveHotKey = "centerActiveHotKey"
        static let centerAllHotKey    = "centerAllHotKey"
        static let excludedBundleIDs  = "excludedBundleIDs"
    }

    // MARK: - Screen

    /// `localizedName` of the user's preferred screen; `nil` if never set.
    var selectedScreenName: String? {
        get { string(forKey: Key.selectedScreenName) }
        set { set(newValue, forKey: Key.selectedScreenName) }
    }

    // MARK: - Hotkeys

    /// Binding for "Center Active Window". Falls back to ⌘⌥C if absent.
    var centerActiveBinding: HotKeyBinding {
        get {
            guard let dict = dictionary(forKey: Key.centerActiveHotKey),
                  let b    = HotKeyBinding(dictionary: dict)
            else { return .centerActive }
            return b
        }
        set { set(newValue.dictionaryRepresentation, forKey: Key.centerActiveHotKey) }
    }

    /// Binding for "Center All Windows". Falls back to ⌘⇧C if absent.
    var centerAllBinding: HotKeyBinding {
        get {
            guard let dict = dictionary(forKey: Key.centerAllHotKey),
                  let b    = HotKeyBinding(dictionary: dict)
            else { return .centerAll }
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
