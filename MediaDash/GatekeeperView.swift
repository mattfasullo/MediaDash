import SwiftUI
import AppKit

struct GatekeeperView: View {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var onboardingSettingsManager = SettingsManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                // Show onboarding for first-time users
                OnboardingView(
                    hasCompletedOnboarding: $hasCompletedOnboarding,
                    settingsManager: onboardingSettingsManager
                )
            } else {
                // Normal app flow
                switch sessionManager.authenticationState {
                case .loggedOut:
                    LoginView(sessionManager: sessionManager)

                case .loggedIn(let profile):
                    AuthenticatedRootView(
                        sessionManager: sessionManager,
                        profile: profile
                    )
                }
            }
        }
        .onAppear {
            // Ensure window is configured when view appears
            DispatchQueue.main.async {
                if let window = NSApplication.shared.windows.first {
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.styleMask.insert(.fullSizeContentView)
                    window.toolbar = nil
                    window.invalidateShadow()
                }
            }
        }
    }
}

// MARK: - Authenticated Root View

struct AuthenticatedRootView: View {
    @ObservedObject var sessionManager: SessionManager
    let profile: WorkspaceProfile

    @StateObject private var settingsManager: SettingsManager
    @StateObject private var metadataManager: DocketMetadataManager
    @StateObject private var manager: MediaManager
    @StateObject private var emailScanningService: EmailScanningService
    @StateObject private var notificationCenter = NotificationCenter()

    init(sessionManager: SessionManager, profile: WorkspaceProfile) {
        self.sessionManager = sessionManager
        self.profile = profile

        // Initialize with the profile's settings
        let settings = SettingsManager(settings: profile.settings)
        let metadata = DocketMetadataManager(settings: profile.settings)
        let mediaManager = MediaManager(settingsManager: settings, metadataManager: metadata)

        _settingsManager = StateObject(wrappedValue: settings)
        _metadataManager = StateObject(wrappedValue: metadata)
        _manager = StateObject(wrappedValue: mediaManager)
        
        // Initialize notification center
        let notificationCenter = NotificationCenter()
        _notificationCenter = StateObject(wrappedValue: notificationCenter)
        
        // Initialize email scanning service
        let gmailService = GmailService()
        let parser = EmailDocketParser()
        let emailService = EmailScanningService(gmailService: gmailService, parser: parser)
        emailService.mediaManager = mediaManager
        emailService.settingsManager = settings
        emailService.notificationCenter = notificationCenter
        _emailScanningService = StateObject(wrappedValue: emailService)
    }

    var body: some View {
        ContentView()
            .environmentObject(settingsManager)
            .environmentObject(metadataManager)
            .environmentObject(manager)
            .environmentObject(sessionManager)
            .environmentObject(emailScanningService)
            .environmentObject(notificationCenter)
            .onAppear {
                // Sync settings manager with profile settings
                settingsManager.currentSettings = profile.settings
                
                // Update email scanning service references
                emailScanningService.mediaManager = manager
                emailScanningService.settingsManager = settingsManager
                
                // Start email scanning if enabled and authenticated
                if settingsManager.currentSettings.gmailEnabled {
                    // Restore tokens from Keychain
                    if let accessToken = KeychainService.retrieve(key: "gmail_access_token"), !accessToken.isEmpty {
                        // Restore refresh token if available
                        let refreshToken = KeychainService.retrieve(key: "gmail_refresh_token")
                        print("GmailService: Restoring tokens on app launch")
                        print("  - Access token: \(accessToken.prefix(20))...")
                        print("  - Refresh token: \(refreshToken != nil ? "\(refreshToken!.prefix(20))..." : "nil")")
                        emailScanningService.gmailService.setAccessToken(accessToken, refreshToken: refreshToken)
                        
                        // Start scanning - token will auto-refresh if expired
                        emailScanningService.startScanning()
                    } else {
                        print("GmailService: No access token found in Keychain")
                    }
                }
            }
            .onChange(of: settingsManager.currentSettings) { _, newSettings in
                // Update the profile when settings change
                sessionManager.updateProfile(settings: newSettings)
                
                // Update email scanning service settings
                emailScanningService.settingsManager = settingsManager
                
                // Start/stop scanning based on settings
                if newSettings.gmailEnabled {
                    if let accessToken = KeychainService.retrieve(key: "gmail_access_token"), !accessToken.isEmpty {
                        // Restore refresh token if available
                        let refreshToken = KeychainService.retrieve(key: "gmail_refresh_token")
                        emailScanningService.gmailService.setAccessToken(accessToken, refreshToken: refreshToken)
                        if !emailScanningService.isEnabled {
                            emailScanningService.startScanning()
                        }
                    }
                } else {
                    emailScanningService.stopScanning()
                }
            }
    }
}

// MARK: - Preview

#Preview {
    GatekeeperView()
}
