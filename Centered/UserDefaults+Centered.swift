import Foundation
import Security
import CryptoKit
import os.log

extension UserDefaults {

    enum Key {
        static let selectedScreenName    = "selectedScreenName"
        static let selectedScreenID      = "selectedScreenID"
        static let centerActiveHotKey    = "centerActiveHotKey"
        static let centerAllHotKey       = "centerAllHotKey"
        static let excludedBundleIDs     = "excludedBundleIDs"
        static let isAutoCenteringPaused = "isAutoCenteringPaused"
        static let centersOnWindowScreen = "centersOnWindowScreen"
        static let animationStyle        = "animationStyle"

        static let legacyCenterActiveBinding = "centerActiveBinding"
        static let legacyCenterAllBinding    = "centerAllBinding"
    }

    var selectedScreenID: UInt32? {
        get {
            guard let number = object(forKey: Key.selectedScreenID) as? NSNumber else { return nil }
            return UInt32(exactly: number.uint64Value)
        }
        set { set(newValue.map { NSNumber(value: $0) }, forKey: Key.selectedScreenID) }
    }

    var selectedScreenName: String? {
        get { string(forKey: Key.selectedScreenName) }
        set { set(newValue, forKey: Key.selectedScreenName) }
    }

    var centerActiveBinding: HotKeyBinding {
        get {
            persistedHotKeyBinding(
                currentKey: Key.centerActiveHotKey,
                legacyKey: Key.legacyCenterActiveBinding,
                defaultBinding: .centerActive
            )
        }
        set { setHotKeyBinding(newValue, forKey: Key.centerActiveHotKey) }
    }

    var centerAllBinding: HotKeyBinding {
        get {
            persistedHotKeyBinding(
                currentKey: Key.centerAllHotKey,
                legacyKey: Key.legacyCenterAllBinding,
                defaultBinding: .centerAll
            )
        }
        set { setHotKeyBinding(newValue, forKey: Key.centerAllHotKey) }
    }

    /// Stores and verifies excluded bundle IDs using a Keychain-backed HMAC.
    /// Reads fail closed when non-empty persisted data is missing a matching tag.
    var excludedBundleIDs: Set<String> {
        get {
            ExclusionHMAC.hmacQueue.sync {
                let raw = Set(stringArray(forKey: Key.excludedBundleIDs) ?? [])
                guard raw.allSatisfy(ExclusionHMAC.isValidBundleID) else {
                    if !raw.isEmpty {
                        os_log("Excluded bundle IDs contain invalid values - returning empty set",
                               log: .default, type: .error)
                    }
                    return []
                }
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
                let validIDs = Set(newValue.filter(ExclusionHMAC.isValidBundleID))
                guard ExclusionHMAC.store(validIDs) else {
                    os_log("Excluded bundle IDs were not updated because Keychain persistence failed", log: .default, type: .error)
                    return
                }
                set(Array(validIDs.sorted()), forKey: Key.excludedBundleIDs)
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

    private func persistedHotKeyBinding(
        currentKey: String,
        legacyKey: String,
        defaultBinding: HotKeyBinding
    ) -> HotKeyBinding {
        if let dict = dictionary(forKey: currentKey),
           let binding = HotKeyBinding(dictionary: dict) {
            return binding
        }
        if let migrated = migratedHotKeyBinding(forKey: legacyKey) {
            setHotKeyBinding(migrated, forKey: currentKey)
            removeObject(forKey: legacyKey)
            return migrated
        }
        return defaultBinding
    }

    private func setHotKeyBinding(_ binding: HotKeyBinding, forKey key: String) {
        set(binding.dictionaryRepresentation, forKey: key)
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

    static func isValidBundleID(_ id: String) -> Bool {
        AppleScriptCenterer.isValidBundleID(id)
    }

    private static func serialise(_ ids: Set<String>) -> Data {
        let payload = ids.sorted().map { "\($0.utf8.count):\($0)" }.joined(separator: "\n")
        return payload.data(using: .utf8) ?? Data()
    }

    private static func legacySerialise(_ ids: Set<String>) -> Data {
        ids.sorted().joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    /// Never rotate an existing key after a transient Keychain failure. Doing so
    /// would make every previously persisted exclusion tag unverifiable.
    private static func hmacKey() -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let keyData = result as? Data, keyData.count == 32 else {
                os_log("Keychain HMAC key has invalid data", log: .default, type: .error)
                return nil
            }
            return SymmetricKey(data: keyData)
        }
        guard status == errSecItemNotFound else {
            os_log("Failed to load HMAC key: %d", log: .default, type: .error, status)
            return nil
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: keyAccount,
            kSecValueData: keyData,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let storeStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard storeStatus == errSecSuccess else {
            os_log("Failed to create HMAC key: %d", log: .default, type: .error, storeStatus)
            return nil
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

    @discardableResult
    private static func saveTag(_ tag: Data) -> Bool {
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
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let addStatus = SecItemAdd(attrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                os_log("Failed to add HMAC tag: %d", log: .default, type: .error, addStatus)
                return false
            }
            return true
        } else if updateStatus != errSecSuccess {
            os_log("Failed to update HMAC tag: %d", log: .default, type: .error, updateStatus)
            return false
        }
        return true
    }

    @discardableResult
    static func store(_ ids: Set<String>) -> Bool {
        guard let key = hmacKey() else { return false }
        let tag = HMAC<SHA256>.authenticationCode(for: serialise(ids), using: key)
        return saveTag(Data(tag))
    }

    static func verify(_ ids: Set<String>) -> Bool {
        guard ids.allSatisfy(isValidBundleID), let key = hmacKey() else { return false }
        guard let storedTag = loadTag() else {
            return ids.isEmpty
        }

        if HMAC<SHA256>.isValidAuthenticationCode(storedTag, authenticating: serialise(ids), using: key) {
            return true
        }

        if HMAC<SHA256>.isValidAuthenticationCode(storedTag, authenticating: legacySerialise(ids), using: key) {
            store(ids)
            return true
        }

        return false
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
