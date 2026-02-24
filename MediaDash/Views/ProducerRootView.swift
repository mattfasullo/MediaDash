import SwiftUI
import AppKit

extension Foundation.Notification.Name {
    static let producerOpenRecentProject = Foundation.Notification.Name("ProducerOpenRecentProject")
}

/// Minimal authenticated root for Producer role.
/// Same layout as media: sidebar + main content, Settings overlay top-right.
struct ProducerRootView: View {
    @ObservedObject var sessionManager: SessionManager
    let profile: WorkspaceProfile

    @StateObject private var settingsManager: SettingsManager
    @StateObject private var asanaCacheManager = AsanaCacheManager()
    @StateObject private var simianService = SimianService()
    @State private var showSettingsSheet = false
    @State private var showRecentHistory = false
    @State private var showAirtableTablePicker = false
    @State private var showServicesSetupPrompt = false
    @State private var hasEvaluatedServicesPrompt = false

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
                    showRecentHistory: $showRecentHistory,
                    showAirtableTablePicker: $showAirtableTablePicker
                ) { recent in
                    showRecentHistory = false
                    Foundation.NotificationCenter.default.post(
                        name: .producerOpenRecentProject,
                        object: nil,
                        userInfo: [
                            "projectGid": recent.projectGid,
                            "fullName": recent.fullName,
                            "docketNumber": recent.docketNumber ?? "",
                            "jobName": recent.jobName ?? ""
                        ]
                    )
                }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    evaluateServicesPromptIfNeeded()
                }
            }
            .onChange(of: sessionManager.authenticationState) { _, newState in
                // Clean up cache manager if user logs out
                if case .loggedOut = newState {
                    asanaCacheManager.shutdown()
                }
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
        .sheet(isPresented: $showServicesSetupPrompt) {
            let (gmail, asana, simian) = ServicesSetupPromptBuilder.buildStatus(
                settings: settingsManager.currentSettings,
                simianService: simianService
            )
            ServicesSetupPromptSheet(
                isPresented: $showServicesSetupPrompt,
                onOpenSettings: {
                    Foundation.NotificationCenter.default.post(
                        name: Foundation.Notification.Name("OpenSettings"),
                        object: nil
                    )
                },
                gmailStatus: gmail,
                asanaStatus: asana,
                simianStatus: simian
            )
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

        // Keep Simian service config in sync so setup prompt can accurately detect connection state.
        if s.simianEnabled,
           let baseURL = s.simianAPIBaseURL,
           !baseURL.isEmpty {
            simianService.setBaseURL(baseURL)
            if let username = s.simianUsername,
               let password = s.simianPassword {
                simianService.setCredentials(username: username, password: password)
            }
        }
    }

    private func evaluateServicesPromptIfNeeded() {
        guard !hasEvaluatedServicesPrompt else { return }
        hasEvaluatedServicesPrompt = true

        let dontShowAgain = UserDefaults.standard.bool(forKey: "servicesPromptDontShowAgain")
        if ServicesSetupPromptBuilder.shouldShowPrompt(
            settings: settingsManager.currentSettings,
            simianService: simianService,
            dontShowAgain: dontShowAgain,
            isProducer: true
        ) {
            showServicesSetupPrompt = true
        }
    }
}

// MARK: - Producer Sidebar (thin icon rail: status, profile — logo lives on staging area)

struct ProducerSidebarView: View {
    let profile: WorkspaceProfile
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var asanaCacheManager: AsanaCacheManager
    @Binding var showSettingsSheet: Bool
    @Binding var showRecentHistory: Bool
    @Binding var showAirtableTablePicker: Bool
    let onSelectRecentProject: (ProducerRecentProject) -> Void
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
            
            IconRailButton(
                icon: "clock.arrow.circlepath",
                label: "Recent",
                badge: nil,
                isActive: showRecentHistory
            ) {
                showRecentHistory.toggle()
            }
            .popover(isPresented: $showRecentHistory, arrowEdge: .leading) {
                ProducerRecentHistorySheet(
                    isPresented: $showRecentHistory,
                    onSelectRecentProject: onSelectRecentProject
                )
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

private struct ProducerRecentHistorySheet: View {
    @Binding var isPresented: Bool
    let onSelectRecentProject: (ProducerRecentProject) -> Void
    @EnvironmentObject var settingsManager: SettingsManager
    
    private var recentProjects: [ProducerRecentProject] {
        (settingsManager.currentSettings.producerRecentProjects ?? [])
            .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent projects")
                .font(.headline)
            
            if recentProjects.isEmpty {
                Text("No recent projects yet. Open a project and it will appear here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(recentProjects) { entry in
                    Button {
                        onSelectRecentProject(entry)
                        isPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.fullName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                            Text(secondaryLine(for: entry))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .scrollContentBackground(.visible)
            }
        }
        .padding(14)
        .frame(width: 340, height: 300)
    }
    
    private func secondaryLine(for entry: ProducerRecentProject) -> String {
        let docket = entry.docketNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let job = entry.jobName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: String
        if !docket.isEmpty && !job.isEmpty {
            base = "\(docket) · \(job)"
        } else if !docket.isEmpty {
            base = docket
        } else if !job.isEmpty {
            base = job
        } else {
            base = "Project"
        }
        return "\(base) · \(formatRelativeDate(entry.lastOpenedAt))"
    }
    
    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    ProducerRootView(
        sessionManager: SessionManager(),
        profile: WorkspaceProfile.local(name: "Producer")
    )
}
