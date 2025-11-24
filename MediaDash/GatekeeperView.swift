import SwiftUI
import AppKit

struct GatekeeperView: View {
    @StateObject private var sessionManager = SessionManager()

    var body: some View {
        Group {
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
    }

    var body: some View {
        ContentView()
            .environmentObject(settingsManager)
            .environmentObject(metadataManager)
            .environmentObject(manager)
            .environmentObject(sessionManager)
            .onAppear {
                // Sync settings manager with profile settings
                settingsManager.currentSettings = profile.settings
            }
            .onChange(of: settingsManager.currentSettings) { _, newSettings in
                // Update the profile when settings change
                sessionManager.updateProfile(settings: newSettings)
            }
    }
}

// MARK: - Preview

#Preview {
    GatekeeperView()
}
