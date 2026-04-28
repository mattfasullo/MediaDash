import Foundation
import SwiftUI
import AppKit

/// Minimal shell for the Tools account type: sidebar + tools hub (no full media stack).
struct ToolsRootView: View {
    @ObservedObject var sessionManager: SessionManager
    let profile: WorkspaceProfile

    @StateObject private var settingsManager: SettingsManager
    @StateObject private var metadataManager: DocketMetadataManager
    @StateObject private var mediaManager: MediaManager
    @StateObject private var asanaCacheManager = AsanaCacheManager()
    @State private var showSettingsSheet = false

    init(sessionManager: SessionManager, profile: WorkspaceProfile) {
        self.sessionManager = sessionManager
        self.profile = profile
        let settings = SettingsManager(settings: profile.settings)
        let metadata = DocketMetadataManager(settings: profile.settings)
        _settingsManager = StateObject(wrappedValue: settings)
        _metadataManager = StateObject(wrappedValue: metadata)
        _mediaManager = StateObject(wrappedValue: MediaManager(settingsManager: settings, metadataManager: metadata))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                ToolsSidebarView(
                    profile: profile,
                    sessionManager: sessionManager,
                    asanaCacheManager: asanaCacheManager,
                    showSettingsSheet: $showSettingsSheet
                )
                .environmentObject(settingsManager)

                MusicDemosLatestToolView()
                    .environmentObject(mediaManager)
                    .environmentObject(settingsManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                settingsManager.currentSettings = SettingsManager.applyDocketConfigDefaults(to: profile.settings)
                configureToolsCache()
            }
            .onChange(of: sessionManager.authenticationState) { _, newState in
                if case .loggedOut = newState {
                    asanaCacheManager.shutdown()
                }
            }
            .onChange(of: settingsManager.currentSettings) { _, newSettings in
                sessionManager.updateProfile(settings: newSettings)
                mediaManager.updateConfig(settings: newSettings)
                configureToolsCache()
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name("OpenSettings"))) { _ in
                SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
            }
            .onChange(of: showSettingsSheet) { _, newValue in
                if newValue {
                    SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
                    showSettingsSheet = false
                }
            }

            Button(action: {
                SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
            }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .padding(.top, 8)
            .padding(.trailing, 8)
            .zIndex(1000)
        }
        .onAppear {
            FinderCommandBridge.shared.clearPending()
        }
    }

    private func configureToolsCache() {
        let s = settingsManager.currentSettings
        asanaCacheManager.updateCacheSettings(
            sharedCacheURL: s.sharedCacheURL,
            useSharedCache: s.useSharedCache,
            serverBasePath: s.serverBasePath,
            serverConnectionURL: s.serverConnectionURL
        )
        asanaCacheManager.updateSyncSettings(
            workspaceID: s.asanaWorkspaceID,
            projectID: s.asanaProjectID,
            docketField: s.asanaDocketField,
            jobNameField: s.asanaJobNameField
        )
    }
}

// MARK: - Sidebar

private struct ToolsSidebarView: View {
    let profile: WorkspaceProfile
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var asanaCacheManager: AsanaCacheManager
    @Binding var showSettingsSheet: Bool
    @EnvironmentObject var settingsManager: SettingsManager

    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }

    var body: some View {
        VStack(spacing: 8) {
            ServerStatusIndicator(
                cacheManager: asanaCacheManager,
                showSettings: $showSettingsSheet
            )
            .frame(width: 28, height: 28)

            Spacer()
            Divider()
                .padding(.horizontal, 8)
            IconRailProfileButton(profile: profile, sessionManager: sessionManager)
        }
        .padding(.vertical, 16)
        .frame(width: 64)
        .background(currentTheme.sidebarBackground)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

#Preview {
    ToolsRootView(sessionManager: SessionManager(), profile: WorkspaceProfile.local(name: "Tools"))
}
