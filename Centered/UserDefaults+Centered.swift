import Foundation
import Security
import CryptoKit
import os.log

extension UserDefaults {

    enum Key {
        static let selectedScreenName    = "selectedScreenName"
        static let centerActiveHotKey    = "centerActiveHotKey"
        static let centerAllHotKey       = "centerAllHotKey"
        static let excludedBundleIDs     = "excludedBundleIDs"
        static let isAutoCenteringPaused = "isAutoCenteringPaused"
        static let centersOnWindowScreen = "centersOnWindowScreen"
        static let animationStyle        = "animationStyle"

        // Older builds used Codable blobs with these keys. Keep the names here so
        // migrations and tests do not need to duplicate magic strings.
        static let legacyCenterActiveBinding = "centerActiveBinding"
        static let legacyCenterAllBinding    = "centerAllBinding"
    }

    var selectedScreenName: String? {
        get { string(forKey: Key.selectedScreenName) }
        set { set(newValue, forKey: Key.selectedScreenName) }
    }

    var centerActiveBinding: HotKeyBinding {
        get {
            if let dict = dictionary(forKey: Key.centerActiveHotKey),
               let binding = HotKeyBinding(dictionary: dict) {
                return binding
            }
            if let migrated = migratedHotKeyBinding(forKey: Key.legacyCenterActiveBinding) {
                centerActiveBinding = migrated
                removeObject(forKey: Key.legacyCenterActiveBinding)
                return migrated
            }
            return .centerActive
        }
        set { set(newValue.dictionaryRepresentation, forKey: Key.centerActiveHotKey) }
    }

    var centerAllBinding: HotKeyBinding {
        get {
            if let dict = dictionary(forKey: Key.centerAllHotKey),
               let binding = HotKeyBinding(dictionary: dict) {
                return binding
            }
            if let migrated = migratedHotKeyBinding(forKey: Key.legacyCenterAllBinding) {
                centerAllBinding = migrated
                removeObject(forKey: Key.legacyCenterAllBinding)
                return migrated
            }
            return .centerAll
        }
        set { set(newValue.dictionaryRepresentation, forKey: Key.centerAllHotKey) }
    }

    /// Stores and verifies excluded bundle IDs using a Keychain-backed HMAC.
    /// Reads fail closed when non-empty persisted data is missing a matching tag.
    var excludedBundleIDs: Set<String> {
        get {
            ExclusionHMAC.hmacQueue.sync {
                let raw = Set(stringArray(forKey: Key.excludedBundleIDs) ?? [])
                if ExclusionHMAC.verify(raw) {
                    return raw
                }
                if !raw.isEmpty {
                    os_log("Excluded bundle IDs verification failed - returning empty set",
                           log: .default, type: .error)
                }
                return []
            }
        }
        set {
            ExclusionHMAC.hmacQueue.sync(flags: .barrier) {
                set(Array(newValue.sorted()), forKey: Key.excludedBundleIDs)
                ExclusionHMAC.store(newValue)
            }
        }
    }

    var isAutoCenteringPaused: Bool {
        get { bool(forKey: Key.isAutoCenteringPaused) }
        set { set(newValue, forKey: Key.isAutoCenteringPaused) }
    }

    var centersOnWindowScreen: Bool {
        get {
            guard object(forKey: Key.centersOnWindowScreen) != nil else { return true }
            return bool(forKey: Key.centersOnWindowScreen)
        }
        set { set(newValue, forKey: Key.centersOnWindowScreen) }
    }

    var animationStyle: WindowAnimationStyle {
        get {
            guard let raw = string(forKey: Key.animationStyle),
                  let style = WindowAnimationStyle(rawValue: raw)
            else { return .smooth }
            return style
        }
        set { set(newValue.rawValue, forKey: Key.animationStyle) }
    }

    func removeLegacyCenteredSettings() {
        removeObject(forKey: Key.legacyCenterActiveBinding)
        removeObject(forKey: Key.legacyCenterAllBinding)
    }

    private func migratedHotKeyBinding(forKey key: String) -> HotKeyBinding? {
        guard let data = data(forKey: key),
              let binding = try? JSONDecoder().decode(HotKeyBinding.self, from: data)
        else { return nil }
        return binding
    }
}

enum ExclusionHMAC {

    private static let service = Bundle.main.bundleIdentifier ?? "Centered"
    private static let account = "excludedBundleIDsHMAC"
    private static let keyAccount = "excludedBundleIDsKey"

    /// Thread-safe queue for Keychain and HMAC operations.
    static let hmacQueue = DispatchQueue(
        label: "com.centered.hmac",
        attributes: .concurrent
    )

    private static func serialise(_ ids: Set<String>) -> Data {
        ids.sorted().joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    private static func hmacKey() -> SymmetricKey {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyAccount,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess,
           let keyData = result as? Data,
           keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }

        let storeStatus: OSStatus
        if status == errSecSuccess {
            let lookup: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: keyAccount,
            ]
            let update: [CFString: Any] = [kSecValueData: keyData]
            storeStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        } else {
            let attrs: [CFString: Any] = [
                kSecClass:          kSecClassGenericPassword,
                kSecAttrService:    service,
                kSecAttrAccount:    keyAccount,
                kSecValueData:      keyData,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ]
            storeStatus = SecItemAdd(attrs as CFDictionary, nil)
        }

        if storeStatus != errSecSuccess {
            os_log("Failed to store HMAC key: %d", log: .default, type: .error, storeStatus)
        }

        return newKey
    }

    private static func loadTag() -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess {
            return result as? Data
        } else if status != errSecItemNotFound {
            os_log("Failed to load HMAC tag: %d", log: .default, type: .error, status)
        }
        return nil
    }

    private static func saveTag(_ tag: Data) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [kSecValueData: tag]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            let attrs: [CFString: Any] = [
                kSecClass:          kSecClassGenericPassword,
                kSecAttrService:    service,
                kSecAttrAccount:    account,
                kSecValueData:      tag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let addStatus = SecItemAdd(attrs as CFDictionary, nil)
            if addStatus != errSecSuccess {
                os_log("Failed to add HMAC tag: %d", log: .default, type: .error, addStatus)
            }
        } else if updateStatus != errSecSuccess {
            os_log("Failed to update HMAC tag: %d", log: .default, type: .error, updateStatus)
        }
    }

    static func store(_ ids: Set<String>) {
        let tag = HMAC<SHA256>.authenticationCode(for: serialise(ids), using: hmacKey())
        saveTag(Data(tag))
    }

    static func verify(_ ids: Set<String>) -> Bool {
        guard let storedTag = loadTag() else {
            return ids.isEmpty
        }
        let mac = HMAC<SHA256>.authenticationCode(for: serialise(ids), using: hmacKey())
        return storedTag == Data(mac)
    }

    static func resetStoredTag() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
