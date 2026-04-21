// KeychainHelper.swift
// Minimal Keychain wrapper for storing sensitive strings (server API key,
// server URL override). All methods are synchronous and main-actor safe
// because the underlying Security APIs are thread-safe.
//
// Why Keychain instead of UserDefaults / AppStorage?
// - UserDefaults is an unencrypted plist backed by the sandbox container.
//   Anyone with filesystem access (a jailbroken device, a stolen Mac with
//   the simulator, certain backup tools) can read it. Keychain items are
//   encrypted at rest with hardware-backed keys and survive reinstalls.
// - Even for a shared-dev X-API-Key, UserDefaults is a bad habit to get
//   into. When we eventually add real user auth / session tokens, the
//   same helper handles those without changing call sites.
//
// We intentionally do NOT share the Keychain across devices via iCloud.
// If you want cross-device key sync, add `.kSecAttrSynchronizable: true`.

import Foundation
import Security

enum KeychainHelper {
    /// Stable service identifier. Using the bundle id would be more
    /// convention-aligned, but it's unstable when the app is run in the
    /// simulator under different schemes, so we hard-code.
    private static let service = "com.lifting.app"

    // Well-known key names. Exposed as static constants so callers don't
    // spell them wrong and so future migrations (e.g. renaming) are easy.
    static let apiKeyKey = "lifting.apiKey"
    static let serverURLKey = "lifting.serverURL"

    // Auth session storage. Both keys are set together by AuthManager
    // after a successful Sign in with Apple / Google exchange and cleared
    // together on sign-out.
    static let authTokenKey = "lifting.authToken"
    static let authUserIDKey = "lifting.authUserID"
    static let authExpiresAtKey = "lifting.authExpiresAt"

    // MARK: Read / Write / Delete

    /// Fetch a previously-stored string, or nil if the key is absent.
    static func read(key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Store or update a string under `key`. Empty strings are treated
    /// the same as nil (the entry is removed), which matches how UI
    /// TextField clearing behaves.
    @discardableResult
    static func write(_ value: String, forKey key: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return delete(key: key)
        }
        let data = Data(trimmed.utf8)
        let query = baseQuery(key: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        // Try update first; fall back to add if the item doesn't exist.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Helpers

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
