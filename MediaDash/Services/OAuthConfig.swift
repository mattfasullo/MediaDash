import Foundation

/// OAuth configuration for Asana and Gmail integrations
/// 
/// **IMPORTANT**: Replace the placeholder values below with your actual OAuth credentials:
/// 1. For Asana: Create an app at https://app.asana.com/0/my-apps
/// 2. For Gmail: Create OAuth credentials in Google Cloud Console
/// 
/// These credentials are safe to hardcode - they're meant to be embedded in apps.
/// Each user will still authenticate with their own account.
struct OAuthConfig {
    // MARK: - Asana OAuth Credentials
    // Configured for Grayson organization
    static let asanaClientID = "1212059930309267"
    static let asanaClientSecret = "34e7d1f8261eaac6f95f4d38ae4b07ac"
    
    // MARK: - Gmail OAuth Credentials
    // TODO: Replace with your actual Gmail OAuth credentials
    // Get them from: https://console.cloud.google.com/apis/credentials
    static let gmailClientID = "281310450512-nkqqosoq2i1cm8j80ln2b79m3398674d.apps.googleusercontent.com"
    static let gmailClientSecret = "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"
    
    // MARK: - Validation
    
    static var isAsanaConfigured: Bool {
        return !asanaClientID.isEmpty && 
               asanaClientID != "YOUR_ASANA_CLIENT_ID_HERE" &&
               !asanaClientSecret.isEmpty &&
               asanaClientSecret != "YOUR_ASANA_CLIENT_SECRET_HERE"
    }
    
    static var isGmailConfigured: Bool {
        // Trim whitespace and check
        let clientID = gmailClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = gmailClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let isConfigured = !clientID.isEmpty &&
               clientID != "YOUR_GMAIL_CLIENT_ID_HERE" &&
               !clientSecret.isEmpty &&
               clientSecret != "YOUR_GMAIL_CLIENT_SECRET_HERE"
        
        // Debug logging (only in debug builds)
        #if DEBUG
        if !isConfigured {
            print("⚠️ OAuthConfig Debug - Gmail not configured:")
            print("  gmailClientID.isEmpty: \(clientID.isEmpty)")
            print("  gmailClientID == 'YOUR_GMAIL_CLIENT_ID_HERE': \(clientID == "YOUR_GMAIL_CLIENT_ID_HERE")")
            print("  gmailClientID length: \(clientID.count)")
            if !clientID.isEmpty && clientID.count < 50 {
                print("  gmailClientID value: \(clientID)")
            }
            print("  gmailClientSecret.isEmpty: \(clientSecret.isEmpty)")
            print("  gmailClientSecret == 'YOUR_GMAIL_CLIENT_SECRET_HERE': \(clientSecret == "YOUR_GMAIL_CLIENT_SECRET_HERE")")
            print("  gmailClientSecret length: \(clientSecret.count)")
        }
        #endif
        
        return isConfigured
    }
}

