//
// UserDefaults+Centered.swift
// Centered
//
// Typed accessors for every preference key the app persists.
// All raw key strings live here — nowhere else in the codebase.
//
// Security — excludedBundleIDs integrity protection:
//   An HMAC-SHA256 tag over the serialised exclusion list is stored in the
//   Keychain. Reads fail closed (return []) on tag mismatch or absence.
//
//   Keychain item: service = bundle ID, account = "excludedBundleIDsHMAC"
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

    // MARK: - Exclusion list

    /// Reads fail closed (returns []) if the Keychain HMAC is missing or invalid.
    var excludedBundleIDs: Set<String> {
        get {
            let raw = Set(stringArray(forKey: Key.excludedBundleIDs) ?? [])
            guard ExclusionHMAC.verify(raw) else { return [] }
            return raw
        }
        set {
            set(Array(newValue), forKey: Key.excludedBundleIDs)
            ExclusionHMAC.store(newValue)
        }
    }
}

// MARK: - HMAC helpers

private enum ExclusionHMAC {

    private static let service = Bundle.main.bundleIdentifier ?? "Centered"
    private static let account = "excludedBundleIDsHMAC"

    /// Deterministic serialisation: sorted, newline-joined UTF-8.
    private static func serialise(_ ids: Set<String>) -> Data {
        ids.sorted().joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: HMAC key

    /// Returns the persisted 256-bit key, generating and storing one on first use.
    private static func hmacKey() -> SymmetricKey {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "excludedBundleIDsKey",
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let keyData = result as? Data, keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }
        let newKey  = SymmetricKey(size: .bits256)
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

    // MARK: Tag storage

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
        let update: [CFString: Any] = [kSecValueData: tag]
        let query:  [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            let attrs: [CFString: Any] = [
                kSecClass:          kSecClassGenericPassword,
                kSecAttrService:    service,
                kSecAttrAccount:    account,
                kSecValueData:      tag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ]
            SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    // MARK: Public API

    static func store(_ ids: Set<String>) {
        let tag = HMAC<SHA256>.authenticationCode(for: serialise(ids), using: hmacKey())
        saveTag(Data(tag))
    }

    /// Returns false if no tag exists or if the stored tag does not match.
    static func verify(_ ids: Set<String>) -> Bool {
        guard let storedTag = loadTag() else { return ids.isEmpty }
        guard let mac = try? HMAC<SHA256>.authenticationCode(for: serialise(ids), using: hmacKey()) as HMAC<SHA256>.MAC
        else { return false }
        return storedTag == Data(mac)
    }
}
