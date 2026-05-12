//
// UserDefaults+Centered.swift
// Centered
//
// Typed accessors for every preference key the app persists.
// All raw key strings live here — nowhere else in the codebase.
//
// Security — excludedBundleIDs integrity protection:
//   The exclusion list is stored in UserDefaults (a world-readable/writable plist).
//   To detect out-of-process tampering, an HMAC-SHA256 of the serialised list is
//   stored alongside it in the macOS Keychain under the app's bundle ID.
//   On read, the HMAC is recomputed and compared; a mismatch fails closed (returns []).
//   On write, a fresh HMAC is computed and saved to the Keychain.
//
//   Keychain item attributes:
//     service  = Bundle.main.bundleIdentifier ?? "Centered"
//     account  = "excludedBundleIDsHMAC"
//     data     = 32-byte HMAC-SHA256 tag
//

import Foundation
import Security
import CryptoKit

extension UserDefaults {

    // MARK: - Keys

    private enum Key {
        static let selectedScreenName = "selectedScreenName"
        static let centerActiveHotKey = "centerActiveHotKey"
        static let centerAllHotKey    = "centerAllHotKey"
        static let excludedBundleIDs  = "excludedBundleIDs"
    }

    // MARK: - Screen

    var selectedScreenName: String? {
        get { string(forKey: Key.selectedScreenName) }
        set { set(newValue, forKey: Key.selectedScreenName) }
    }

    // MARK: - Hotkeys

    var centerActiveBinding: HotKeyBinding {
        get {
            guard let dict = dictionary(forKey: Key.centerActiveHotKey),
                  let b    = HotKeyBinding(dictionary: dict)
            else { return .centerActive }
            return b
        }
        set { set(newValue.dictionaryRepresentation, forKey: Key.centerActiveHotKey) }
    }

    var centerAllBinding: HotKeyBinding {
        get {
            guard let dict = dictionary(forKey: Key.centerAllHotKey),
                  let b    = HotKeyBinding(dictionary: dict)
            else { return .centerAll }
            return b
        }
        set { set(newValue.dictionaryRepresentation, forKey: Key.centerAllHotKey) }
    }

    // MARK: - Exclusion list (HMAC-integrity-protected)

    /// Bundle IDs of apps that should never be auto-centered.
    /// Reads fail closed (return []) if the stored HMAC is missing or invalid.
    var excludedBundleIDs: Set<String> {
        get {
            let raw = Set(stringArray(forKey: Key.excludedBundleIDs) ?? [])
            guard ExclusionHMAC.verify(raw) else {
                // Tampered or first-run with no HMAC yet — fail closed.
                // If this is genuinely first-run, the setter will write a
                // fresh HMAC next time the user saves the exclusion list.
                return []
            }
            return raw
        }
        set {
            set(Array(newValue), forKey: Key.excludedBundleIDs)
            ExclusionHMAC.store(newValue)
        }
    }
}

// MARK: - HMAC helpers

/// Computes and verifies a Keychain-backed HMAC-SHA256 tag over the
/// serialised exclusion list so that out-of-process plist tampering is detected.
private enum ExclusionHMAC {

    private static let service = Bundle.main.bundleIdentifier ?? "Centered"
    private static let account = "excludedBundleIDsHMAC"

    // MARK: Canonical serialisation

    /// Deterministic serialisation: sorted, newline-joined UTF-8.
    private static func serialise(_ ids: Set<String>) -> Data {
        ids.sorted().joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: HMAC key — stored in Keychain, generated on first use

    private static func hmacKey() -> SymmetricKey {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      "excludedBundleIDsKey",
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let keyData = result as? Data, keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }
        // Generate a new 256-bit key and persist it.
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        let add: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    "excludedBundleIDsKey",
            kSecValueData:      keyData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(add as CFDictionary, nil)
        return newKey
    }

    // MARK: Tag storage — Keychain

    private static func loadTag() -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else { return nil }
        return result as? Data
    }

    private static func saveTag(_ tag: Data) {
        let attrs: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service,
            kSecAttrAccount:    account,
            kSecValueData:      tag,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        // Try update first; add if not found.
        let update: [CFString: Any] = [kSecValueData: tag]
        let query:  [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    // MARK: Public API

    static func store(_ ids: Set<String>) {
        let key  = hmacKey()
        let data = serialise(ids)
        let tag  = HMAC<SHA256>.authenticationCode(for: data, using: key)
        saveTag(Data(tag))
    }

    /// Returns true if the stored tag matches a freshly computed tag.
    /// Returns false if no tag exists (first run) or if the data was tampered.
    static func verify(_ ids: Set<String>) -> Bool {
        guard let storedTag = loadTag() else {
            // No tag stored yet — treat as valid on genuine first run
            // (empty set, no plist entry) or invalid if a list already exists.
            return ids.isEmpty
        }
        let key  = hmacKey()
        let data = serialise(ids)
        guard let mac = try? HMAC<SHA256>.authenticationCode(for: data, using: key) as HMAC<SHA256>.MAC else {
            return false
        }
        return storedTag == Data(mac)
    }
}
