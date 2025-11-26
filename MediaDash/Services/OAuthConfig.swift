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
    // TODO: Replace with your actual Asana OAuth credentials
    // Get them from: https://app.asana.com/0/my-apps
    static let asanaClientID = "YOUR_ASANA_CLIENT_ID_HERE"
    static let asanaClientSecret = "YOUR_ASANA_CLIENT_SECRET_HERE"
    
    // MARK: - Gmail OAuth Credentials
    // TODO: Replace with your actual Gmail OAuth credentials
    // Get them from: https://console.cloud.google.com/apis/credentials
    static let gmailClientID = "YOUR_GMAIL_CLIENT_ID_HERE"
    static let gmailClientSecret = "YOUR_GMAIL_CLIENT_SECRET_HERE"
    
    // MARK: - Validation
    
    static var isAsanaConfigured: Bool {
        return !asanaClientID.isEmpty && 
               asanaClientID != "YOUR_ASANA_CLIENT_ID_HERE" &&
               !asanaClientSecret.isEmpty &&
               asanaClientSecret != "YOUR_ASANA_CLIENT_SECRET_HERE"
    }
    
    static var isGmailConfigured: Bool {
        return !gmailClientID.isEmpty &&
               gmailClientID != "YOUR_GMAIL_CLIENT_ID_HERE" &&
               !gmailClientSecret.isEmpty &&
               gmailClientSecret != "YOUR_GMAIL_CLIENT_SECRET_HERE"
    }
}

