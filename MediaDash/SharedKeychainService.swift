//
//  SharedKeychainService.swift
//  MediaDash
//
//  Shared Keychain service for Grayson Music Group employees
//  Provides automatic access to shared team keys stored in Keychain
//

import Foundation

/// Service for managing shared team keys in Keychain
/// All shared keys are only accessible to authenticated @graysonmusicgroup.com users
struct SharedKeychainService {
    /// Allowed email domain for shared key access
    static let allowedEmailDomain = "graysonmusicgroup.com"
    
    // MARK: - Key Names
    
    /// Keychain key names for shared team keys
    /// Pattern: {service}_shared_{key_type}
    enum SharedKey {
        // CodeMind
        case codemindClaude
        case codemindOpenAI
        case codemindGemini
        case codemindGrok

        // Gmail
        case gmailAccessToken
        case gmailRefreshToken

        // Asana
        case asanaAccessToken
        case asanaRefreshToken

        var keychainKey: String {
            switch self {
            case .codemindClaude: return "codemind_shared_claude_key"
            case .codemindOpenAI: return "codemind_shared_openai_key"
            case .codemindGemini: return "codemind_shared_gemini_key"
            case .codemindGrok: return "codemind_shared_grok_key"
            case .gmailAccessToken: return "gmail_shared_access_token"
            case .gmailRefreshToken: return "gmail_shared_refresh_token"
            case .asanaAccessToken: return "asana_shared_access_token"
            case .asanaRefreshToken: return "asana_shared_refresh_token"
            }
        }
    }
    
    // MARK: - Authentication Check
    
    /// Check if the given email/username is from Grayson Music Group
    static func isGraysonMusicGroupUser(_ emailOrUsername: String?) -> Bool {
        guard let email = emailOrUsername?.lowercased() else { return false }
        // hasSuffix already covers all cases where the email contains the domain at the end
        return email.hasSuffix("@\(allowedEmailDomain)")
    }
    
    /// Get the current authenticated user's email/username
    static func getCurrentUserEmail() -> String? {
        // Check UserDefaults for the last active username
        if let username = UserDefaults.standard.string(forKey: "lastActiveUsername") {
            return username
        }
        return nil
    }
    
    /// Check if current user is authenticated as a Grayson Music Group employee
    /// Now uses whitelist of verified Gmail-authenticated emails
    static func isCurrentUserGraysonEmployee() -> Bool {
        let currentUser = getCurrentUserEmail()
        
        // First check whitelist (most secure - only Gmail-authenticated emails)
        if GraysonEmployeeWhitelist.shared.isWhitelisted(currentUser) {
            return true
        }
        
        // Fallback to domain check for backward compatibility
        // (but this should eventually be removed)
        return isGraysonMusicGroupUser(currentUser)
    }
    
    // MARK: - Shared Key Management
    
    /// Get a shared key from Keychain (only for Grayson employees)
    /// Falls back to personal key if shared key doesn't exist
    static func getKey(shared: SharedKey, personalKey: String) -> String? {
        // #region agent log
        let logData: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "D",
            "location": "SharedKeychainService.swift:getKey",
            "message": "SharedKeychainService.getKey called",
            "data": [
                "sharedKey": shared.keychainKey,
                "personalKey": personalKey,
                "isGraysonEmployee": isCurrentUserGraysonEmployee(),
                "timestamp": Date().timeIntervalSince1970
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
        // #endregion
        // First try shared key (only if Grayson employee)
        if isCurrentUserGraysonEmployee() {
            if let sharedKey = KeychainService.retrieve(key: shared.keychainKey) {
                return sharedKey
            }
        }
        
        // Fall back to personal key
        return KeychainService.retrieve(key: personalKey)
    }
    
    /// Store a shared key in Keychain (admin use only - Grayson employees)
    static func setSharedKey(_ key: String, for sharedKey: SharedKey) -> Bool {
        guard isCurrentUserGraysonEmployee() else {
            print("⚠️ Only Grayson Music Group employees can set shared keys")
            return false
        }
        
        // Store in Keychain using the exact same method as other keys
        if KeychainService.store(key: sharedKey.keychainKey, value: key) {
            print("✅ Shared \(sharedKey.keychainKey) saved to Keychain")
            return true
        } else {
            print("❌ Failed to save shared \(sharedKey.keychainKey) to Keychain")
            return false
        }
    }
    
    /// Check if a shared key exists in Keychain
    static func hasSharedKey(_ sharedKey: SharedKey) -> Bool {
        guard isCurrentUserGraysonEmployee() else { return false }
        return KeychainService.retrieve(key: sharedKey.keychainKey) != nil
    }
    
    // MARK: - Convenience Methods for Specific Services
    
    /// Get Gmail access token (shared or personal)
    static func getGmailAccessToken() -> String? {
        return getKey(shared: .gmailAccessToken, personalKey: "gmail_access_token")
    }
    
    /// Get Gmail refresh token (shared or personal)
    static func getGmailRefreshToken() -> String? {
        return getKey(shared: .gmailRefreshToken, personalKey: "gmail_refresh_token")
    }
    
    /// Get Asana access token (shared or personal)
    static func getAsanaAccessToken() -> String? {
        return getKey(shared: .asanaAccessToken, personalKey: "asana_access_token")
    }
    
    /// Get Asana refresh token (shared or personal)
    static func getAsanaRefreshToken() -> String? {
        return getKey(shared: .asanaRefreshToken, personalKey: "asana_refresh_token")
    }
    
    /// Get CodeMind API key for a provider (shared or personal)
    /// Supports Gemini and Grok
    static func getCodeMindAPIKey(for provider: String) -> String? {
        let providerLower = provider.lowercased()

        switch providerLower {
        case "gemini":
            return getKey(shared: .codemindGemini, personalKey: "codemind_gemini_api_key")
        case "grok":
            return getKey(shared: .codemindGrok, personalKey: "codemind_grok_api_key")
        default:
            return nil
        }
    }
}

