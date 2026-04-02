import Foundation
import Security

/// Service for securely storing and retrieving sensitive data in macOS Keychain.
///
/// Credentials are stored in a **single** generic-password item (JSON blob) under
/// `com.mediadash.keychain` / `mediadash_credentials_blob_v1` to minimize keychain
/// password prompts. On first launch after upgrade, legacy per-key items are read
/// once, merged into the blob, then removed.
@MainActor
class KeychainService {
    private static let serviceName = "com.mediadash.keychain"

    /// Run once per session; must run from `applicationWillFinishLaunching` before UI.
    private static var launchMigrationRan = false

    /// When `false`, `blobSecrets` is authoritative; when `true`, legacy per-account items are used.
    private static var useLegacyRuntime = false

    /// In-memory cache of blob contents (nil = not loaded yet for blob mode).
    private static var blobSecrets: [String: String]?

    // MARK: - Launch migration

    /// Migrates legacy per-key items into a single blob, or loads an existing blob.
    /// Call once at startup before any other KeychainService API.
    static func migrateCredentialsToBlobIfNeededAtLaunch() {
        guard !launchMigrationRan else { return }
        launchMigrationRan = true

        if blobItemExists() {
            if loadBlobFromKeychainIntoCache() {
                useLegacyRuntime = false
                return
            }
            #if DEBUG
            print("KeychainService: Blob item present but unreadable; using legacy per-key storage.")
            #endif
            useLegacyRuntime = true
            return
        }

        var collected: [String: String] = [:]
        for key in KeychainCredentialsBlob.allCredentialKeyNames {
            if let value = legacyRetrieveSecure(account: key) {
                collected[key] = value
            }
        }

        guard persistBlobSecretsToKeychain(collected) else {
            #if DEBUG
            print("KeychainService: Could not write credentials blob; using legacy per-key storage until next launch.")
            #endif
            useLegacyRuntime = true
            blobSecrets = nil
            return
        }

        // Verify read-back before deleting legacy items.
        blobSecrets = nil
        guard loadBlobFromKeychainIntoCache(), blobSecrets == collected else {
            #if DEBUG
            print("KeychainService: Blob verification failed; leaving legacy items intact.")
            #endif
            useLegacyRuntime = true
            blobSecrets = nil
            return
        }

        for key in KeychainCredentialsBlob.allCredentialKeyNames {
            legacyDeleteSecure(account: key)
        }

        useLegacyRuntime = false
    }

    /// Store a string value in the keychain (or blob).
    @discardableResult
    static func store(key: String, value: String) -> Bool {
        guard value.data(using: .utf8) != nil else {
            return false
        }

        if useLegacyRuntime {
            return legacyStore(account: key, value: value)
        }

        if blobSecrets == nil {
            guard loadBlobFromKeychainIntoCache() else {
                return false
            }
        }
        var next = blobSecrets ?? [:]
        next[key] = value
        return persistBlobSecretsToKeychain(next)
    }

    /// Retrieve a string value from the keychain (or blob).
    static func retrieve(key: String) -> String? {
        if useLegacyRuntime {
            return legacyRetrieveSecure(account: key)
        }
        if blobSecrets == nil {
            _ = loadBlobFromKeychainIntoCache()
        }
        return blobSecrets?[key]
    }

    /// Delete a value from the keychain (or blob).
    static func delete(key: String) {
        if useLegacyRuntime {
            legacyDeleteSecure(account: key)
            return
        }
        if blobSecrets == nil {
            guard loadBlobFromKeychainIntoCache() else { return }
        }
        var next = blobSecrets ?? [:]
        next.removeValue(forKey: key)
        _ = persistBlobSecretsToKeychain(next)
    }

    /// Check if a key exists in the keychain (or blob).
    static func exists(key: String) -> Bool {
        retrieve(key: key) != nil
    }

    // MARK: - Blob

    private static func blobItemExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: KeychainCredentialsBlob.blobAccountName,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }

    @discardableResult
    private static func loadBlobFromKeychainIntoCache() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: KeychainCredentialsBlob.blobAccountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let payload = KeychainCredentialsBlob.decode(data) else {
            return false
        }
        blobSecrets = payload.secrets
        return true
    }

    @discardableResult
    private static func persistBlobSecretsToKeychain(_ secrets: [String: String]) -> Bool {
        let payload = KeychainCredentialsBlob.makePayload(secrets: secrets)
        guard let data = KeychainCredentialsBlob.encode(payload) else {
            return false
        }

        let account = KeychainCredentialsBlob.blobAccountName
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        if blobItemExists() {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrSynchronizable as String: false
            ]
            let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            if status == errSecSuccess {
                blobSecrets = secrets
                return true
            }
            return false
        }

        var addQuery: [String: Any] = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            blobSecrets = secrets
            return true
        }
        return false
    }

    // MARK: - Legacy per-account storage

    private static func legacyRetrieveSecure(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func legacyDeleteSecure(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    @discardableResult
    private static func legacyStore(account: String, value: String) -> Bool {
        legacyDeleteSecure(account: account)
        guard let data = value.data(using: .utf8) else {
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
