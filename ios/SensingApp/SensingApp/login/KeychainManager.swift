

import Foundation
import Security

// ============================================================
// MARK: - KeychainManager Documentation
// ============================================================
//
// PURPOSE:
// Provides a simple interface for securely storing, reading,
// and deleting sensitive data using the iOS Keychain Services API.
// Used exclusively by SecureAuthManager to persist auth tokens
// and the patient's Apple user identifier between app launches.
//
// WHY KEYCHAIN (not UserDefaults):
// UserDefaults stores data in plaintext on disk — anyone with
// access to the device's file system can read it. Keychain
// encrypts data at rest using the device's hardware security
// module and ties access to the app's bundle identifier.
// This is the iOS standard for storing credentials and tokens.
//
// STORED KEYS (set by SecureAuthManager):
//   "journey_access_token"    — short-lived JWT for API requests
//   "journey_refresh_token"   — long-lived token for silent re-auth
//   (The raw Apple user ID is NOT stored — only its one-way hash, in
//    UserDefaults via ParticipantID — so no re-identification key is kept.)
//
// ACCESSIBILITY:
//   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly is used so tokens
//   remain readable after the device is unlocked once — this supports
//   background tasks and silent refresh on app relaunch without
//   requiring the user to unlock the device first. "ThisDeviceOnly"
//   keeps tokens out of encrypted backups, so they never migrate to
//   another device (PHI hardening) — the user re-authenticates instead.
//
// USAGE:
//   KeychainManager.shared.save(key: "my_key", data: Data("value".utf8))
//   let data = KeychainManager.shared.read(key: "my_key")
//   KeychainManager.shared.delete(key: "my_key")
//
// SINGLETON:
// Accessed via KeychainManager.shared — only one instance exists.
// private init() prevents accidental instantiation elsewhere.
//
// THREAD SAFETY:
// Keychain API calls are synchronous and should be called from
// the main thread or a consistent serial queue. SecureAuthManager
// is @MainActor which ensures this is always the case.
//
// ERROR HANDLING:
// This implementation is intentionally simple — failures are silent.
// SecureAuthManager handles missing keys by checking for nil on read.
// Consider adding OSLog logging here if debugging Keychain issues.
// ============================================================

class KeychainManager {

    // MARK: - Singleton
    static let shared = KeychainManager()
    private init() {}

    // MARK: - Save
    //
    // Stores a Data value in Keychain under the given key.
    // If a value already exists for that key, it is deleted first
    // then re-added — standard upsert pattern for Keychain since
    // SecItemUpdate requires more complex handling.
    //
    // kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly ensures the item is
    // readable after the first device unlock (required for background token
    // refresh) while never leaving the device via iCloud or encrypted backups.
    func save(key: String, data: Data) {
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrAccount:    key,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly  // ← background refresh; ThisDeviceOnly = never restored to another device via backup
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - Read
    //
    // Retrieves a Data value from Keychain by key.
    // Returns nil if the key doesn't exist or the read fails.
    func read(key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess {
            return dataTypeRef as? Data
        }
        return nil
    }

    // MARK: - Delete
    //
    // Removes a value from Keychain by key.
    // Silent no-op if the key doesn't exist — safe to call anytime.
    func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
