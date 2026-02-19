import SwiftUI
import AppKit

/// Minimal authenticated root for Producer role.
/// Same layout as media: sidebar + main content, Settings overlay top-right.
struct ProducerRootView: View {
    @ObservedObject var sessionManager: SessionManager
    let profile: WorkspaceProfile

    @StateObject private var settingsManager: SettingsManager
    @StateObject private var asanaCacheManager = AsanaCacheManager()
    @State private var showSettingsSheet = false
    @State private var showAirtableTablePicker = false

    init(sessionManager: SessionManager, profile: WorkspaceProfile) {
        self.sessionManager = sessionManager
        self.profile = profile
        _settingsManager = StateObject(wrappedValue: SettingsManager(settings: profile.settings))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                ProducerSidebarView(
                    profile: profile,
                    sessionManager: sessionManager,
                    asanaCacheManager: asanaCacheManager,
                    showSettingsSheet: $showSettingsSheet,
                    showAirtableTablePicker: $showAirtableTablePicker
                )
                .environmentObject(settingsManager)

                ProducerView()
                    .environmentObject(settingsManager)
                    .environmentObject(sessionManager)
                    .environmentObject(asanaCacheManager)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                settingsManager.currentSettings = profile.settings
                configureProducerCache()
            }
            .onChange(of: settingsManager.currentSettings) { _, newSettings in
                sessionManager.updateProfile(settings: newSettings)
                configureProducerCache()
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

            // Same as media: Settings button top-right
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
    }

    private func configureProducerCache() {
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

// MARK: - Producer Sidebar (thin icon rail: status, profile — logo lives on staging area)

struct ProducerSidebarView: View {
    let profile: WorkspaceProfile
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var asanaCacheManager: AsanaCacheManager
    @Binding var showSettingsSheet: Bool
    @Binding var showAirtableTablePicker: Bool
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

            IconRailButton(
                icon: "tablecells",
                label: "Airtable",
                badge: nil,
                isActive: showAirtableTablePicker
            ) {
                showAirtableTablePicker.toggle()
            }
            .popover(isPresented: $showAirtableTablePicker, arrowEdge: .leading) {
                ProducerAirtableTablePickerSheet(isPresented: $showAirtableTablePicker)
                    .environmentObject(settingsManager)
            }

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

// MARK: - Producer Airtable Table Picker (rail sheet)

private struct ProducerAirtableTablePickerSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var airtableService = AirtableService()

    @State private var isLoading = false
    @State private var loadError: String?
    @State private var tables: [AirtableTableInfo] = []

    private var settings: AppSettings { settingsManager.currentSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Airtable table")
                .font(.headline)

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.9)
                    Text("Loading tables…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if let err = loadError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }

            if !tables.isEmpty {
                Picker("", selection: Binding(
                    get: { settings.airtableTableID ?? "" },
                    set: { newValue in
                        guard !newValue.isEmpty else { return }
                        var s = settingsManager.currentSettings
                        s.airtableTableID = newValue
                        settingsManager.currentSettings = s
                        isPresented = false
                    }
                )) {
                    ForEach(tables) { t in
                        Text(t.name).tag(t.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else {
                Text("No tables loaded. Set your Airtable Base ID and API key in Settings, then try again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Button("Reload") {
                    Task { await loadTables() }
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 320, height: 200)
        .onAppear {
            Task { await loadTables() }
        }
    }

    private func loadTables() async {
        let baseID = settings.airtableBaseID ?? ""
        guard !baseID.isEmpty else {
            await MainActor.run {
                loadError = "Airtable Base ID is not set."
                tables = []
                isLoading = false
            }
            return
        }

        await MainActor.run {
            isLoading = true
            loadError = nil
        }

        let result = await airtableService.fetchTablesInBase(baseID: baseID)
        await MainActor.run {
            tables = result
            isLoading = false
            if result.isEmpty {
                loadError = "Couldn’t load tables. Confirm your Airtable API key has access to this base."
            }
        }
    }
}

#Preview {
    ProducerRootView(
        sessionManager: SessionManager(),
        profile: WorkspaceProfile.local(name: "Producer")
    )
}

