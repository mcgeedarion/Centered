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
        /// The `localizedName` of the last screen the user selected.
        static let selectedScreenName = "selectedScreenName"
    }

    /// The `localizedName` of the user's preferred screen, or `nil` if never set.
    var selectedScreenName: String? {
        get { string(forKey: Key.selectedScreenName) }
        set { set(newValue, forKey: Key.selectedScreenName) }
    }
}
