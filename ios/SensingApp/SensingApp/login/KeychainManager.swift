//
//  KeychainManager 2.swift
//  SensingApp
//
//  Created by UIUCSpineSurgey on 3/29/26.
//


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
// and the patient's user ID between app launches.
//
// WHY KEYCHAIN (not UserDefaults):
// UserDefaults stores data in plaintext on disk — anyone with
// access to the device's file system can read it. Keychain
// encrypts data at rest using the device's hardware security
// module and ties access to the app's bundle identifier.
// This is the iOS standard for storing credentials and tokens.
//
// STORED KEYS (set by SecureAuthManager):
//   "journey_access_token"  — short-lived JWT for API requests
//   "journey_refresh_token" — long-lived token for silent re-auth
//   "journey_user_id"       — patient's user ID string
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
    //
    // Shared instance — the only way to access KeychainManager.
    // Ensures all Keychain operations go through a single point,
    // making it easy to add logging or error handling later.
    static let shared = KeychainManager()
    // Prevents instantiation from outside this class.
    // All access must go through KeychainManager.shared.
    private init() {}
    // MARK: - Save
    //
    // Stores a Data value in Keychain under the given key.
    // If a value already exists for that key, it is deleted first
    // then re-added — this is the standard upsert pattern for
    // Keychain since SecItemUpdate requires more complex handling.
    //
    // Parameters:
    //   key  — unique string identifier (e.g. "journey_access_token")
    //   data — raw bytes to store (convert strings via Data("x".utf8))
    //
    // Called by SecureAuthManager:
    //   • storeTokens() after successful login
    //   • silentRefresh() after receiving new tokens from server
    func save(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword, // generic password item type
            kSecAttrAccount as String: key,                      // key used to identify the item
            kSecValueData as String:   data                      // the actual data to store
        ]
        // Delete any existing value first — Keychain doesn't allow
        // duplicate entries for the same key, so we remove before adding.
        // SecItemDelete silently does nothing if the key doesn't exist.
        SecItemDelete(query as CFDictionary)
        // Add the new value. Return value is ignored here —
        // if this fails silently, the subsequent read will return nil
        // and SecureAuthManager will handle it by forcing re-login.
        SecItemAdd(query as CFDictionary, nil)
    }
    // MARK: - Read
    //
    // Retrieves a Data value from Keychain by key.
    // Returns nil if the key doesn't exist or the read fails.
    //
    // Parameters:
    //   key — the same string used when saving
    //
    // Returns:
    //   Data? — the stored bytes, or nil if not found
    //
    // Called by SecureAuthManager:
    //   • init() to check if a refresh token exists on app launch
    //   • silentRefresh() to read the stored refresh token
    //   • authenticatedRequest() to read the current access token
    //   • readToken() helper which converts the Data to a String
    func read(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword, // match generic password items
            kSecAttrAccount as String: key,                      // match this specific key
            kSecReturnData as String:  true,                     // return the stored data payload
            kSecMatchLimit as String:  kSecMatchLimitOne         // return at most one result
        ]
        // dataTypeRef will hold the result if the query succeeds
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            // Cast the result to Data and return it
            return dataTypeRef as? Data
        }
        // Key not found or read failed — return nil.
        // Callers treat nil as "not stored" and handle accordingly.
        return nil
    }
    // MARK: - Delete
    //
    // Removes a value from Keychain by key.
    // Silent no-op if the key doesn't exist — safe to call anytime.
    //
    // Parameters:
    //   key — the same string used when saving
    //
    // Called by SecureAuthManager:
    //   • clearTokens() on logout — removes all three token keys
    //   • clearTokens() when silent refresh fails — prevents stale
    //     tokens from being used on next app launch
    //
    // IMPORTANT: After logout, all three keys must be deleted:
    //   "journey_access_token", "journey_refresh_token", "journey_user_id"
    //   This is handled by SecureAuthManager.clearTokens() which calls
    //   delete() once per key.
    func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword, // match generic password items
            kSecAttrAccount as String: key                       // match this specific key
        ]
        // Remove the item. Return value is ignored —
        // if the key didn't exist, SecItemDelete returns errSecItemNotFound
        // which is harmless and expected on a fresh install or after logout.
        SecItemDelete(query as CFDictionary)
    }
}
