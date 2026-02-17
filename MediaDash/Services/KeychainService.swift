import Foundation
import Security

/// Service for securely storing and retrieving sensitive data in macOS Keychain
///
/// Uses kSecAttrAccessibleAfterFirstUnlock to minimize password prompts.
/// Items are stored without strict per-application ACL, allowing any version
/// of the app signed with the same developer certificate to access them.
@MainActor
class KeychainService {
    private static let serviceName = "com.mediadash.keychain"
    
    // Track if migration has been completed this session
    private static var migrationCompleted = false
    
    // #region agent log
    private static func logKeychainOp(_ operation: String, key: String, status: String, hypothesisId: String = "A") {
        let logData: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": hypothesisId,
            "location": "KeychainService.swift",
            "message": "Keychain \(operation)",
            "data": [
                "operation": operation,
                "key": key,
                "status": status,
                "timestamp": Date().timeIntervalSince1970,
                "thread": Thread.current.name ?? "unknown"
            ],
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let json = try? JSONSerialization.data(withJSONObject: logData),
           let jsonString = String(data: json, encoding: .utf8) {
            if let fileHandle = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                fileHandle.seekToEndOfFile()
                fileHandle.write((jsonString + "\n").data(using: .utf8)!)
                fileHandle.closeFile()
            } else {
                try? (jsonString + "\n").write(toFile: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log", atomically: true, encoding: .utf8)
            }
        }
    }
    // #endregion

    /// Store a string value in the keychain
    ///
    /// Uses kSecAttrAccessibleAfterFirstUnlock without a custom SecAccessControl.
    /// This allows the item to be accessed by any version of the app signed with
    /// the same developer certificate, avoiding password prompts after updates.
    @discardableResult
    static func store(key: String, value: String) -> Bool {
        // #region agent log
        logKeychainOp("store_START", key: key, status: "before_delete", hypothesisId: "B")
        // #endregion
        // Delete any existing item first
        delete(key: key)

        guard let data = value.data(using: .utf8) else {
            // #region agent log
            logKeychainOp("store_FAIL", key: key, status: "data_conversion_failed", hypothesisId: "B")
            // #endregion
            return false
        }

        // Use kSecAttrAccessible instead of kSecAttrAccessControl
        // This creates a simpler ACL that allows access without per-build authorization
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // Allow access after first unlock - no additional constraints
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            // Don't sync to iCloud - keep local
            kSecAttrSynchronizable as String: false
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        // #region agent log
        logKeychainOp("store_COMPLETE", key: key, status: status == errSecSuccess ? "success" : "failed_\(status)", hypothesisId: "B")
        // #endregion
        if status != errSecSuccess {
            print("KeychainService: Failed to store key '\(key)': \(status)")
        }
        return status == errSecSuccess
    }
    
    /// Retrieve a string value from the keychain
    /// Automatically migrates existing items to use new access control attributes
    static func retrieve(key: String) -> String? {
        // #region agent log
        logKeychainOp("retrieve_START", key: key, status: "before_query", hypothesisId: "C")
        // #endregion
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // #region agent log
        logKeychainOp("retrieve_COMPLETE", key: key, status: status == errSecSuccess ? "success" : "failed_\(status)", hypothesisId: "C")
        // #endregion

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    /// Check if an item needs migration and migrate it
    /// Returns true if item was migrated
    /// Optimized to minimize keychain operations and password prompts
    private static func migrateItemIfNeeded(key: String) -> Bool {
        // First, try to retrieve the value (this will prompt if old ACL)
        guard let value = retrieve(key: key) else {
            return false
        }

        // Try to update the item's accessibility attribute directly using SecItemUpdate
        // This is more efficient than delete+add and may avoid additional prompts
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        let updateAttributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false
        ]
        
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        
        // If update succeeded, we're done (single operation, minimal prompts)
        if updateStatus == errSecSuccess {
            return true
        }
        
        // If update failed (likely because ACL can't be changed on existing items),
        // fall back to delete+add approach, but skip backup to minimize operations
        // We already have the value, so we can safely delete and re-add
        delete(key: key)
        
        // Store with new access control (this will prompt once for the new item)
        let success = store(key: key, value: value)
        
        return success
    }
    
    /// Delete a value from the keychain
    static func delete(key: String) {
        // #region agent log
        logKeychainOp("delete_START", key: key, status: "before_delete", hypothesisId: "B")
        // #endregion
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        // #region agent log
        logKeychainOp("delete_COMPLETE", key: key, status: status == errSecSuccess ? "success" : "failed_\(status)", hypothesisId: "B")
        // #endregion
    }
    
    /// Check if a key exists in the keychain
    static func exists(key: String) -> Bool {
        return retrieve(key: key) != nil
    }

    /// Migrate all existing keychain items to use new access control attributes
    /// This is called automatically via static initializer when KeychainService is first accessed
    ///
    /// This re-stores all keychain items with access control that doesn't require
    /// per-application authorization, which prevents password prompts after app updates.
    ///
    /// After Sparkle updates, code signature changes cause macOS to treat the new version
    /// as a different app. Migration ensures all items are re-stored with the new signature,
    /// preventing multiple password prompts.
    ///
    /// Note: The first access after an update may still prompt once per item during migration.
    /// After migration completes, subsequent accesses won't prompt.
    static func migrateAllExistingItems() {
        // #region agent log
        logKeychainOp("migration_START", key: "ALL", status: "beginning", hypothesisId: "A")
        // #endregion
        // Only run once per session
        guard !migrationCompleted else {
            // #region agent log
            logKeychainOp("migration_SKIP", key: "ALL", status: "already_completed", hypothesisId: "A")
            // #endregion
            return
        }
        migrationCompleted = true

        // List of known keychain keys used by the app
        let knownKeys = [
            // Gmail
            "gmail_access_token",
            "gmail_refresh_token",
            "gmail_shared_access_token",
            "gmail_shared_refresh_token",

            // Asana
            "asana_access_token",
            "asana_refresh_token",
            "asana_shared_access_token",
            "asana_shared_refresh_token",

            // Simian
            "simian_username",
            "simian_password",
            "simian_shared_username",
            "simian_shared_password"
        ]

        var migratedCount = 0

        // Migrate each key if it exists
        // This will prompt the user for each item that exists with old ACL,
        // but after migration, future updates won't prompt
        for key in knownKeys {
            // #region agent log
            logKeychainOp("migration_ITEM_START", key: key, status: "checking", hypothesisId: "A")
            // #endregion
            if migrateItemIfNeeded(key: key) {
                migratedCount += 1
                // #region agent log
                logKeychainOp("migration_ITEM_SUCCESS", key: key, status: "migrated", hypothesisId: "A")
                // #endregion
            } else {
                // #region agent log
                logKeychainOp("migration_ITEM_SKIP", key: key, status: "not_found_or_failed", hypothesisId: "A")
                // #endregion
            }
        }

        // #region agent log
        logKeychainOp("migration_COMPLETE", key: "ALL", status: "migrated_\(migratedCount)", hypothesisId: "A")
        // #endregion
        if migratedCount > 0 {
            print("KeychainService: Migrated \(migratedCount) keychain items to new access control")
        }
    }

    /// Retrieve and migrate in one operation
    /// This is useful when you need to access an item and want to ensure it gets migrated
    static func retrieveAndMigrate(key: String) -> String? {
        guard let value = retrieve(key: key) else {
            return nil
        }

        // Re-store with new ACL (idempotent - same result if already migrated)
        delete(key: key)
        _ = store(key: key, value: value)

        return value
    }
}

