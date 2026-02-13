//
//  GraysonEmployeeWhitelist.swift
//  MediaDash
//
//  Manages whitelist of verified Grayson Music Group employee emails
//  Emails are added when users authenticate with Gmail using @graysonmusicgroup.com accounts
//

import Foundation

/// Service for managing whitelist of verified Grayson Music Group employee emails
@MainActor
class GraysonEmployeeWhitelist {
    static let shared = GraysonEmployeeWhitelist()
    
    private let whitelistKey = "grayson_employee_whitelist"
    
    /// Get all whitelisted emails
    var whitelistedEmails: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: whitelistKey),
                  let emails = try? JSONDecoder().decode(Set<String>.self, from: data) else {
                return Set<String>()
            }
            return emails
        }
    }
    
    private init() {}
    
    /// Add an email to the whitelist (only if it's a @graysonmusicgroup.com email)
    func addEmail(_ email: String) -> Bool {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Only allow @graysonmusicgroup.com emails
        guard normalizedEmail.hasSuffix("@graysonmusicgroup.com") else {
            print("⚠️ GraysonEmployeeWhitelist: Cannot add non-Grayson email: \(email)")
            return false
        }
        
        var currentWhitelist = whitelistedEmails
        let (inserted, _) = currentWhitelist.insert(normalizedEmail)
        
        if let data = try? JSONEncoder().encode(currentWhitelist) {
            UserDefaults.standard.set(data, forKey: whitelistKey)
            #if DEBUG
            if inserted { print("✅ GraysonEmployeeWhitelist: Added \(normalizedEmail) to whitelist") }
            #endif
            return true
        }
        
        return false
    }
    
    /// Remove an email from the whitelist
    func removeEmail(_ email: String) {
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var currentWhitelist = whitelistedEmails
        currentWhitelist.remove(normalizedEmail)
        
        if let data = try? JSONEncoder().encode(currentWhitelist) {
            UserDefaults.standard.set(data, forKey: whitelistKey)
            print("✅ GraysonEmployeeWhitelist: Removed \(normalizedEmail) from whitelist")
        }
    }
    
    /// Check if an email is whitelisted
    func isWhitelisted(_ email: String?) -> Bool {
        guard let email = email else { return false }
        let normalizedEmail = email.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return whitelistedEmails.contains(normalizedEmail)
    }
    
    /// Get count of whitelisted emails
    var count: Int {
        whitelistedEmails.count
    }
    
    /// Clear the entire whitelist (admin use only)
    func clear() {
        UserDefaults.standard.removeObject(forKey: whitelistKey)
        print("✅ GraysonEmployeeWhitelist: Cleared whitelist")
    }
}

