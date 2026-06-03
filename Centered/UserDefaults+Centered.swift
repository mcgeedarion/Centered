import Foundation
import Security
import CryptoKit
import os.log

extension UserDefaults {

    private enum Key {
        static let selectedScreenName = "selectedScreenName"
        static let centerActiveHotKey = "centerActiveHotKey"
        static let centerAllHotKey    = "centerAllHotKey"
        static let excludedBundleIDs  = "excludedBundleIDs"
    }

    var selectedScreenName: String? {
        get { string(forKey: Key.selectedScreenName) }
        set { set(newValue, forKey: Key.selectedScreenName) }
    }

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

    /// Stores and verifies excluded bundle IDs using Keychain HMAC.
    /// Returns an empty set if verification fails (data integrity check).
    /// Reads fail closed (returns []) if the Keychain HMAC is missing or invalid.
    var excludedBundleIDs: Set<String> {
        get {
            var result: Set<String> = []
            ExclusionHMAC.hmacQueue.sync {
                let raw = Set(stringArray(forKey: Key.excludedBundleIDs) ?? [])
                if ExclusionHMAC.verify(raw) {
                    result = raw
                } else if !raw.isEmpty {
                    os_log("Excluded bundle IDs verification failed - returning empty set", 
                           log: .default, type: .error)
                }
            }
            return result
        }
        set {
            ExclusionHMAC.hmacQueue.async(flags: .barrier) { [weak self] in
                self?.set(Array(newValue), forKey: Key.excludedBundleIDs)
                ExclusionHMAC.store(newValue)
            }
        }
    }
}

private enum ExclusionHMAC {

    private static let service = Bundle.main.bundleIdentifier ?? "Centered"
    private static let account = "excludedBundleIDsHMAC"
    private static let keyAccount = "excludedBundleIDsKey"
    
    /// Thread-safe queue for Keychain and HMAC operations
    static let hmacQueue = DispatchQueue(
        label: "com.centered.hmac",
        attributes: .concurrent
    )

    /// Deterministic serialisation: sorted, newline-joined UTF-8.
    private static func serialise(_ ids: Set<String>) -> Data {
        ids.sorted().joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    /// Returns the persisted 256-bit key, generating and storing one on first use.
    /// Thread-safe and handles Keychain errors gracefully.
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
        
        // Check if valid key exists
        let keyExists = status == errSecSuccess && (result as? Data)?.count == 32
        if keyExists, let keyData = result as? Data {
            return SymmetricKey(data: keyData)
        }

        // Generate new key
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        
        // Store new key in Keychain
        let storeStatus = if status == errSecSuccess {
            // Update existing (corrupted) entry
            let lookup: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: keyAccount,
            ]
            let update: [CFString: Any] = [kSecValueData: keyData]
            SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        } else {
            // Create new entry
            let attrs: [CFString: Any] = [
                kSecClass:          kSecClassGenericPassword,
                kSecAttrService:    service,
                kSecAttrAccount:    keyAccount,
                kSecValueData:      keyData,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            ]
            SecItemAdd(attrs as CFDictionary, nil)
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

    /// Returns false if no tag exists or if the stored tag does not match.
    /// Logs errors for debugging purposes.
    static func verify(_ ids: Set<String>) -> Bool {
        guard let storedTag = loadTag() else { 
            return ids.isEmpty
        }
        
        do {
            let mac = try HMAC<SHA256>.authenticationCode(
                for: serialise(ids),
                using: hmacKey()
            ) as HMAC<SHA256>.MAC
            return storedTag == Data(mac)
        } catch {
            os_log("Failed to compute HMAC: %{public}@", 
                   log: .default, type: .error, error.localizedDescription)
            return false
        }
    }
}
