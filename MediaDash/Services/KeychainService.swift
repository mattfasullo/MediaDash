import Foundation
import Security
import LocalAuthentication

/// Service for securely storing and retrieving sensitive data in macOS Keychain
@MainActor
class KeychainService {
    private static let serviceName = "com.mediadash.keychain"
    
    /// Store a string value in the keychain
    @discardableResult
    static func store(key: String, value: String) -> Bool {
        // Delete any existing item first
        delete(key: key)
        
        guard let data = value.data(using: .utf8) else {
            return false
        }
        
        // Create authentication context that suppresses UI
        let authContext = LAContext()
        authContext.interactionNotAllowed = true
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // Allow access without prompting after first unlock
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            // Suppress authentication UI when possible
            kSecUseAuthenticationContext as String: authContext
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Retrieve a string value from the keychain
    /// Automatically migrates existing items to use new accessibility attributes
    static func retrieve(key: String) -> String? {
        // Create authentication context that suppresses UI
        let authContext = LAContext()
        authContext.interactionNotAllowed = true
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Suppress authentication UI when possible
            kSecUseAuthenticationContext as String: authContext
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Migrate existing item: delete and recreate with new attributes
        // This ensures existing users get the fix on first access after update
        migrateItemIfNeeded(key: key, value: value)
        
        return value
    }
    
    /// Migrate an existing keychain item to use new accessibility attributes
    /// This prevents password prompts after app updates
    private static func migrateItemIfNeeded(key: String, value: String) {
        // Check if item exists with old attributes by trying to retrieve attributes
        let checkQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var attributes: AnyObject?
        let checkStatus = SecItemCopyMatching(checkQuery as CFDictionary, &attributes)
        
        // If item exists, check if it has the new accessibility attribute
        if checkStatus == errSecSuccess,
           let attrs = attributes as? [String: Any],
           attrs[kSecAttrAccessible as String] == nil {
            // Item exists but doesn't have new attributes - migrate it
            // Delete and recreate with new attributes
            delete(key: key)
            _ = store(key: key, value: value)
        }
    }
    
    /// Delete a value from the keychain
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    
    /// Check if a key exists in the keychain
    static func exists(key: String) -> Bool {
        return retrieve(key: key) != nil
    }
    
    /// Migrate all existing keychain items to use new accessibility attributes
    /// Call this once on app launch to migrate all items at once
    static func migrateAllExistingItems() {
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
            
            // CodeMind
            "codemind_api_key",
            "codemind_gemini_api_key",
            "codemind_grok_api_key",
            "codemind_shared_gemini_key",
            "codemind_shared_grok_key",
            "codemind_shared_claude_key",
            "codemind_shared_openai_key"
        ]
        
        // Migrate each key if it exists
        for key in knownKeys {
            if let value = retrieve(key: key) {
                // retrieve() already triggers migration, but we ensure it happens
                _ = store(key: key, value: value)
            }
        }
    }
}

