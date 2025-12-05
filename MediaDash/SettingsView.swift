import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings Card

struct SettingsCard<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

// MARK: - Hoverable Icon Button

struct HoverableIconButton: View {
    let icon: String
    let action: () -> Void
    let helpText: String?
    @State private var isHovered = false
    
    init(icon: String, action: @escaping () -> Void, helpText: String? = nil) {
        self.icon = icon
        self.action = action
        self.helpText = helpText
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundColor(isHovered ? .primary : .secondary)
                .scaleEffect(isHovered ? 1.15 : 1.0)
                .padding(4)
                .background(isHovered ? Color.gray.opacity(0.15) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(helpText ?? "")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Expandable Settings Header

struct ExpandableSettingsHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    
    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Window Mode Card

struct WindowModeCard: View {
    let mode: WindowMode
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
                        .frame(width: 80, height: 56)
                    
                    Image(systemName: mode.icon)
                        .font(.system(size: 24))
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }
                
                // Text
                VStack(spacing: 3) {
                    Text(mode.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isSelected ? .accentColor : .primary)
                    
                    Text(mode.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 140, height: 120)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : (isHovered ? Color.gray.opacity(0.3) : Color.clear), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @EnvironmentObject var sessionManager: SessionManager
    @Binding var isPresented: Bool

    @State private var settings: AppSettings
    @State private var showNewProfileSheet = false
    @State private var showDeleteAlert = false
    @State private var profileToDelete: String?
    @State private var hasUnsavedChanges = false
    @StateObject private var oauthService = OAuthService()
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var showManualCodeEntry = false
    @State private var manualAuthCode = ""
    @State private var manualAuthURL: URL?
    @State private var manualAuthState = ""

    init(settingsManager: SettingsManager, isPresented: Binding<Bool>) {
        self.settingsManager = settingsManager
        self._isPresented = isPresented
        self._settings = State(initialValue: settingsManager.currentSettings)
    }
    
    private func connectToAsana() {
        guard OAuthConfig.isAsanaConfigured else {
            connectionError = "Asana OAuth credentials not configured. Please update OAuthConfig.swift with your credentials."
            return
        }
        
        isConnecting = true
        connectionError = nil
        
        Task {
            do {
                // Try localhost first
                let token = try await oauthService.authenticateAsana(useOutOfBand: false)
                
                // Store the access token
                oauthService.storeTokens(accessToken: token.accessToken, refreshToken: token.refreshToken, for: "asana")
                
                await MainActor.run {
                    isConnecting = false
                    print("Asana OAuth successful! Token stored.")
                }
            } catch OAuthError.manualCodeRequired(let state, let authURL) {
                // Fall back to manual code entry
                await MainActor.run {
                    isConnecting = false
                    manualAuthState = state
                    manualAuthURL = authURL
                    showManualCodeEntry = true
                    // Open browser
                    NSWorkspace.shared.open(authURL)
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    // Check if it's a redirect URI error
                    if error.localizedDescription.contains("redirect_uri") {
                        connectionError = "Redirect URI error. Please add 'http://localhost:8080/callback' to your Asana app's redirect URLs, or use manual code entry."
                        // Offer to try out-of-band flow
                        Task {
                            do {
                                let token = try await oauthService.authenticateAsana(useOutOfBand: true)
                                oauthService.storeTokens(accessToken: token.accessToken, refreshToken: token.refreshToken, for: "asana")
                                await MainActor.run {
                                    isConnecting = false
                                    print("Asana OAuth successful! Token stored.")
                                }
                            } catch OAuthError.manualCodeRequired(let state, let authURL) {
                                await MainActor.run {
                                    manualAuthState = state
                                    manualAuthURL = authURL
                                    showManualCodeEntry = true
                                    NSWorkspace.shared.open(authURL)
                                }
                            } catch {
                                await MainActor.run {
                                    connectionError = error.localizedDescription
                                }
                            }
                        }
                    } else {
                        connectionError = error.localizedDescription
                    }
                    print("Asana OAuth failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func submitManualCode() {
        guard !manualAuthCode.isEmpty else {
            return
        }
        
        isConnecting = true
        connectionError = nil
        
        Task {
            do {
                let token = try await oauthService.exchangeCodeForTokenManually(
                    code: manualAuthCode.trimmingCharacters(in: .whitespaces)
                )
                
                oauthService.storeTokens(accessToken: token.accessToken, refreshToken: token.refreshToken, for: "asana")
                
                await MainActor.run {
                    isConnecting = false
                    showManualCodeEntry = false
                    manualAuthCode = ""
                    print("Asana OAuth successful! Token stored.")
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectionError = error.localizedDescription
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))

                Spacer()

                Button(action: {
                    isPresented = false
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help("Close Settings")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(nsColor: .controlBackgroundColor))

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Profile Management
                    ProfileSection(
                        settings: $settings,
                        settingsManager: settingsManager,
                        sessionManager: sessionManager,
                        showNewProfileSheet: $showNewProfileSheet,
                        showDeleteAlert: $showDeleteAlert,
                        profileToDelete: $profileToDelete,
                        hasUnsavedChanges: $hasUnsavedChanges
                    )

                    // Theme Selection
                    ThemeSelectionSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)

                    // Path Settings
                    PathSettingsSection(
                        settings: $settings,
                        hasUnsavedChanges: $hasUnsavedChanges
                    )
                    
                    // Asana Integration (only shown when Asana is selected)
                    if settings.docketSource == .asana {
                        AsanaIntegrationSection(
                            settings: $settings,
                            hasUnsavedChanges: $hasUnsavedChanges,
                            oauthService: oauthService,
                            isConnecting: $isConnecting,
                            connectionError: $connectionError
                        )
                    }

                    // Gmail Integration Section
                    GmailIntegrationSection(
                        settings: $settings,
                        hasUnsavedChanges: $hasUnsavedChanges,
                        oauthService: oauthService
                    )

                    // CodeMind AI Integration Section
                    CodeMindIntegrationSection(
                        settings: $settings,
                        hasUnsavedChanges: $hasUnsavedChanges
                    )

                    // Simian Integration Section
                    SimianIntegrationSection(
                        settings: $settings,
                        hasUnsavedChanges: $hasUnsavedChanges
                    )

                        // CSV Column Mapping (only shown when CSV is selected)
                        if settings.docketSource == .csv {
                            CSVColumnMappingSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)
                        }

                    // General Options (Search, Workflow, etc.)
                    GeneralOptionsSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)
                    
                    // Work Culture Enhancements
                    WorkCultureEnhancementsSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }

            // Footer with Save/Reset buttons
            VStack(spacing: 0) {
                Divider()
                HStack {
                    // Version number
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("Version \(version)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if hasUnsavedChanges {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("Unsaved changes")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                        }
                    }

                    Button("Reset to Defaults") {
                        settings = .default
                        hasUnsavedChanges = true
                    }
                    .buttonStyle(.bordered)

                    Button("Save") {
                        settingsManager.currentSettings = settings
                        settingsManager.saveCurrentProfile()
                        hasUnsavedChanges = false
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUnsavedChanges)
                    .help(hasUnsavedChanges ? "Save changes (Cmd+S)" : "No changes to save")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: 600, height: 500)
        .sheet(isPresented: $showNewProfileSheet) {
            NewProfileView(
                settingsManager: settingsManager,
                currentSettings: settings,
                isPresented: $showNewProfileSheet
            )
        }
        .alert("Delete Profile", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    settingsManager.deleteProfile(name: profile)
                }
            }
        } message: {
            if let profile = profileToDelete {
                Text("Are you sure you want to delete the '\(profile)' profile?")
            }
        }
    }
}

// MARK: - Profile Section

struct ProfileSection: View {
    @Binding var settings: AppSettings
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var sessionManager: SessionManager
    @Binding var showNewProfileSheet: Bool
    @Binding var showDeleteAlert: Bool
    @Binding var profileToDelete: String?
    @Binding var hasUnsavedChanges: Bool
    
    private var currentWorkspaceProfile: WorkspaceProfile? {
        if case .loggedIn(let profile) = sessionManager.authenticationState {
            return profile
        }
        return nil
    }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "person.circle")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                    Text("Profile")
                        .font(.system(size: 18, weight: .semibold))
                }

                // Workspace Profile Info (if logged in)
                if let workspaceProfile = currentWorkspaceProfile {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: workspaceProfile.isLocal ? "desktopcomputer" : "cloud.fill")
                                .foregroundColor(workspaceProfile.isLocal ? .orange : .blue)
                                .font(.system(size: 12))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspaceProfile.name)
                                    .font(.system(size: 13, weight: .medium))
                                
                                if let username = workspaceProfile.username {
                                    Text(username)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Spacer()
                            
                            // Sync Status
                            syncStatusBadge
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        
                        // Last accessed info
                        if !workspaceProfile.isLocal {
                            HStack {
                                Image(systemName: "clock")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                Text("Last accessed: \(formatDate(workspaceProfile.lastAccessedAt))")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 4)
                        }
                    }
                    .padding(.bottom, 8)
                    
                    Divider()
                        .padding(.vertical, 4)
                }

                // Mode Selector (Media, Producer, Engineer, Admin)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mode")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Menu {
                        // Media Mode - Enabled
                        Button {
                            // Media mode is active, no action needed
                        } label: {
                            HStack {
                                Text("Media")
                                Spacer()
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        
                        Divider()
                        
                        // Producer Mode - Disabled
                        Button {
                            // Coming soon
                        } label: {
                            HStack {
                                Text("Producer")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("Coming Soon")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(true)
                        
                        // Engineer Mode - Disabled
                        Button {
                            // Coming soon
                        } label: {
                            HStack {
                                Text("Engineer")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("Coming Soon")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(true)
                        
                        // Admin Mode - Disabled
                        Button {
                            // Coming soon
                        } label: {
                            HStack {
                                Text("Admin")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("Coming Soon")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .disabled(true)
                    } label: {
                        HStack {
                            Text("Media")
                                .foregroundColor(.primary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                    }
                    .menuStyle(.borderlessButton)
                    
                    Text("Each mode has different layouts and core features")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var syncStatusBadge: some View {
        Group {
            switch sessionManager.syncStatus {
            case .synced:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                    Text("Synced")
                        .font(.system(size: 10))
                }
                .foregroundColor(.green)
            case .localOnly:
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 10))
                    Text("Local")
                        .font(.system(size: 10))
                }
                .foregroundColor(.orange)
            case .syncing:
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                    Text("Syncing")
                        .font(.system(size: 10))
                }
                .foregroundColor(.blue)
            case .syncFailed:
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Failed")
                        .font(.system(size: 10))
                }
                .foregroundColor(.red)
            case .conflict:
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                    Text("Conflict")
                        .font(.system(size: 10))
                }
                .foregroundColor(.yellow)
            case .unknown:
                EmptyView()
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Path Settings Section

struct PathSettingsSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool
    @State private var showImportSuccess = false
    @State private var showImportError = false
    @State private var importMessage = ""
    @State private var csvStatus = ""
    @State private var csvExists = false
    @State private var showAdvancedSettings = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                    Text("Storage Locations")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("Tell MediaDash where your files are stored")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 20) {
                // Server Connection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server Connection")
                        .font(.system(size: 14, weight: .medium))
                    Text("Network server IP or hostname (e.g., 192.168.200.200 or smb://192.168.200.200)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("Example: 192.168.200.200", text: Binding(
                        get: { settings.serverConnectionURL ?? "" },
                        set: { settings.serverConnectionURL = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                
                // Server Base Path
                VStack(alignment: .leading, spacing: 8) {
                    Text("Work Picture & Prep Storage")
                        .font(.system(size: 14, weight: .medium))
                    Text("Where dockets and prep folders are stored")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        TextField("Example: /Volumes/Server/GM", text: binding(for: \.serverBasePath))
                            .textFieldStyle(.roundedBorder)
                        Button(action: { browseFolderFor(\.serverBasePath) }) {
                            Image(systemName: "folder")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.bordered)
                        .help("Browse for folder")
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                // Job Info Source
                // TEMPORARILY DISABLED FOR ASANA DEBUGGING - Only Asana is available
                VStack(alignment: .leading, spacing: 8) {
                    Text("Job Info Source")
                        .font(.system(size: 14, weight: .medium))
                    Text("Currently using Asana only (CSV and Server disabled for debugging)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    // Force Asana selection
                    HStack {
                        Text("Asana")
                            .foregroundColor(.primary)
                            .font(.system(size: 13))
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
                    // Hidden picker that always returns Asana
                    Picker("", selection: Binding(
                        get: { DocketSource.asana },
                        set: { _ in }
                    )) {
                        Text("Asana").tag(DocketSource.asana)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .hidden()
                    .frame(height: 0)
                }
                .onAppear {
                    // Force Asana selection on appear
                    if settings.docketSource != .asana {
                        settings.docketSource = .asana
                        hasUnsavedChanges = true
                    }
                }


                // Sessions Base Path (only shown when Server is selected)
                if settings.docketSource == .server {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ProTools Sessions Storage")
                            .font(.system(size: 14, weight: .medium))
                        Text("Scan this folder for docket information")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("Example: /Volumes/Server/SESSIONS", text: binding(for: \.sessionsBasePath))
                                .textFieldStyle(.roundedBorder)
                            Button(action: { browseFolderFor(\.sessionsBasePath) }) {
                                Image(systemName: "folder")
                                    .foregroundColor(.blue)
                            }
                            .buttonStyle(.bordered)
                            .help("Browse for folder")
                        }
                    }
                }

                // Docket Metadata CSV Import (only shown when CSV is selected)
                if settings.docketSource == .csv {
                    Divider()
                        .padding(.vertical, 4)

                    // Docket Metadata CSV Import
                    VStack(alignment: .leading, spacing: 8) {
                    Text("Docket Metadata")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(settings.docketSource == .csv ? .primary : .secondary)
                    Text(settings.docketSource == .csv ?
                         "Import a CSV file with docket metadata (Producer, Director, etc.)" :
                         "Not used when Server Path is selected")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Button(action: { importCSVFile() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.down")
                                Text("Import CSV File")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.docketSource != .csv)
                        .help("Select a CSV file to import. It will be copied to ~/Documents/MediaDash/")

                        if showImportSuccess {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 12))
                                Text(importMessage)
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                            .padding(.top, 4)
                        }

                        if showImportError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 12))
                                Text(importMessage)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                            .padding(.top, 4)
                        }

                        // CSV Status Display
                        if csvExists {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 12))
                                Text(csvStatus)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        } else if settings.docketSource == .csv {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.badge.ellipsis")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 12))
                                Text("No CSV file imported yet")
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                            }
                            .padding(.top, 4)
                        }
                    }
                    }
                }
                
                // Advanced Settings Disclosure
                Divider()
                    .padding(.vertical, 8)
                
                ExpandableSettingsHeader(title: "Folder & File Organization", isExpanded: $showAdvancedSettings)
                
                if showAdvancedSettings {
                    VStack(alignment: .leading, spacing: 16) {
                        // Work Picture Folder
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Work Picture Folder")
                                .font(.system(size: 14, weight: .medium))
                            Text("The main folder name for work pictures (usually \"WORK PICTURE\")")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                TextField("WORK PICTURE", text: binding(for: \.workPictureFolderName))
                                    .textFieldStyle(.roundedBorder)
                                Button(action: { browseForFolderName(\.workPictureFolderName, basePath: settings.serverBasePath) }) {
                                    Image(systemName: "folder")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.bordered)
                                .help("Browse to select folder")
                            }
                        }
                        
                        // Prep Folder
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Prep Folder")
                                .font(.system(size: 14, weight: .medium))
                            Text("The main folder name for session prep (usually \"SESSION PREP\")")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                TextField("SESSION PREP", text: binding(for: \.prepFolderName))
                                    .textFieldStyle(.roundedBorder)
                                Button(action: { browseForFolderName(\.prepFolderName, basePath: settings.serverBasePath) }) {
                                    Image(systemName: "folder")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.bordered)
                                .help("Browse to select folder")
                            }
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // Year Prefix
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Year Folder Prefix")
                                .font(.system(size: 14, weight: .medium))
                            Text("Prefix added to year folders (like \"GM_2025\")")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                TextField("GM_", text: binding(for: \.yearPrefix))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                Text("→ Creates folders like: \(settings.yearPrefix)\(Calendar.current.component(.year, from: Date()))")
                                    .font(.system(size: 12))
                                    .foregroundColor(.blue)
                            }
                        }
                        
                        // Date Format
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Date Format")
                                .font(.system(size: 14, weight: .medium))
                            Text("How dates appear in folder names")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                TextField("MMMd.yy", text: binding(for: \.dateFormat))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                Text("→ Today would be: \(exampleDate)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.blue)
                            }
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        // File Categories
                        Text("File Organization")
                            .font(.system(size: 14, weight: .medium))
                        Text("MediaDash automatically sorts files into folders based on their type")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            InlineCategoryRow(
                                icon: "photo",
                                title: "Video Files",
                                folderName: binding(for: \.pictureFolderName),
                                extensions: bindingArray(for: \.pictureExtensions),
                                description: "Files like .mp4, .mov, .avi",
                                hasUnsavedChanges: $hasUnsavedChanges
                            )
                            
                            InlineCategoryRow(
                                icon: "music.note",
                                title: "Audio Files",
                                folderName: binding(for: \.musicFolderName),
                                extensions: bindingArray(for: \.musicExtensions),
                                description: "Files like .wav, .mp3, .aiff",
                                hasUnsavedChanges: $hasUnsavedChanges
                            )
                            
                            InlineCategoryRow(
                                icon: "doc",
                                title: "Project Files",
                                folderName: binding(for: \.aafOmfFolderName),
                                extensions: bindingArray(for: \.aafOmfExtensions),
                                description: "ProTools files like .aaf, .omf",
                                hasUnsavedChanges: $hasUnsavedChanges
                            )
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Everything Else")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Files that don't match any category go here")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .foregroundColor(.gray)
                                        .frame(width: 20)
                                    TextField("OTHER", text: binding(for: \.otherFolderName))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 150)
                                }
                            }
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.top, 8)
                }
                }
            }
        }
        .onAppear {
            checkCSVStatus()
        }
    }
    
    private var exampleDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = settings.dateFormat
        return formatter.string(from: Date())
    }
    
    private func bindingArray(for keyPath: WritableKeyPath<AppSettings, [String]>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath].joined(separator: ", ") },
            set: {
                settings[keyPath: keyPath] = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                hasUnsavedChanges = true
            }
        )
    }

    private func binding(for keyPath: WritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                hasUnsavedChanges = true
            }
        )
    }

    private func browseFolderFor(_ keyPath: WritableKeyPath<AppSettings, String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select folder location"

        if panel.runModal() == .OK, let url = panel.url {
            settings[keyPath: keyPath] = url.path
            hasUnsavedChanges = true
        }
    }

    private func browseForFolderName(_ keyPath: WritableKeyPath<AppSettings, String>, basePath: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select folder to get its name"
        
        // Set initial directory to the base path if it exists
        if FileManager.default.fileExists(atPath: basePath) {
            panel.directoryURL = URL(fileURLWithPath: basePath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            // Extract just the folder name from the selected path
            let folderName = url.lastPathComponent
            settings[keyPath: keyPath] = folderName
            hasUnsavedChanges = true
        }
    }

    private func checkCSVStatus() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mediaDashFolder = documentsPath.appendingPathComponent("MediaDash")
        let destinationURL = mediaDashFolder.appendingPathComponent("docket_metadata.csv")

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            csvExists = true
            if let content = try? String(contentsOf: destinationURL, encoding: .utf8) {
                let lineCount = content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
                csvStatus = "CSV imported: \(lineCount) rows"
            } else {
                csvStatus = "CSV file exists but cannot be read"
            }
        } else {
            csvExists = false
            csvStatus = ""
        }
    }

    private func importCSVFile() {
        // Reset messages
        showImportSuccess = false
        showImportError = false

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Select CSV file to import"

        if panel.runModal() == .OK, let sourceURL = panel.url {
            // Define destination
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let mediaDashFolder = documentsPath.appendingPathComponent("MediaDash")
            let destinationURL = mediaDashFolder.appendingPathComponent("docket_metadata.csv")

            do {
                // Create MediaDash folder if needed
                try FileManager.default.createDirectory(at: mediaDashFolder, withIntermediateDirectories: true)

                // Remove existing file if it exists
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }

                // Copy the file
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

                // Verify the file exists and is readable
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    let content = try? String(contentsOf: destinationURL, encoding: .utf8)
                    let lineCount = content?.components(separatedBy: .newlines).filter { !$0.isEmpty }.count ?? 0

                    print("CSV imported successfully from \(sourceURL.path)")
                    print("CSV copied to \(destinationURL.path)")
                    print("CSV file has \(lineCount) lines (including header)")

                    // Show success message
                    showImportSuccess = true
                    importMessage = "Imported successfully (\(lineCount) rows)"

                    // Update status
                    checkCSVStatus()

                    // Auto-hide after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        showImportSuccess = false
                    }
                }
            } catch {
                print("Error importing CSV: \(error)")
                showImportError = true
                importMessage = "Failed to import: \(error.localizedDescription)"

                // Auto-hide after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    showImportError = false
                }
            }
        }
    }
}

// MARK: - Asana Integration Section

struct AsanaIntegrationSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool
    @StateObject var oauthService: OAuthService
    @Binding var isConnecting: Bool
    @Binding var connectionError: String?
    
    @StateObject private var cacheManager = AsanaCacheManager()
    @State private var showManualCodeEntry = false
    @State private var manualAuthCode = ""
    @State private var manualAuthURL: URL?
    @State private var manualAuthState = ""
    @State private var showCacheDetails = false
    @State private var showAdvancedSettings = false
    @State private var showForceSyncConfirmation = false
    @State private var isForceSyncing = false
    @State private var forceSyncError: String?
    @State private var forceSyncSuccess = false
    
    private func connectToAsana() {
        guard OAuthConfig.isAsanaConfigured else {
            connectionError = "Asana OAuth credentials not configured. Please update OAuthConfig.swift with your credentials."
            return
        }
        
        isConnecting = true
        connectionError = nil
        
        Task {
            do {
                // Try localhost first
                let token = try await oauthService.authenticateAsana(useOutOfBand: false)
                
                // Store the access token
                oauthService.storeTokens(accessToken: token.accessToken, refreshToken: token.refreshToken, for: "asana")
                
                await MainActor.run {
                    isConnecting = false
                    print("Asana OAuth successful! Token stored.")
                }
            } catch OAuthError.manualCodeRequired(let state, let authURL) {
                // Fall back to manual code entry
                await MainActor.run {
                    isConnecting = false
                    manualAuthState = state
                    manualAuthURL = authURL
                    showManualCodeEntry = true
                    // Open browser
                    NSWorkspace.shared.open(authURL)
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    // Check if it's a redirect URI error
                    if error.localizedDescription.contains("redirect_uri") {
                        connectionError = "Redirect URI error. Trying manual code entry..."
                        // Try out-of-band flow
                        Task {
                            do {
                                let token = try await oauthService.authenticateAsana(useOutOfBand: true)
                                oauthService.storeTokens(accessToken: token.accessToken, refreshToken: token.refreshToken, for: "asana")
                                await MainActor.run {
                                    isConnecting = false
                                    print("Asana OAuth successful! Token stored.")
                                }
                            } catch OAuthError.manualCodeRequired(let state, let authURL) {
                                await MainActor.run {
                                    manualAuthState = state
                                    manualAuthURL = authURL
                                    showManualCodeEntry = true
                                    NSWorkspace.shared.open(authURL)
                                }
                            } catch {
                                await MainActor.run {
                                    connectionError = error.localizedDescription
                                }
                            }
                        }
                    } else {
                        connectionError = error.localizedDescription
                    }
                    print("Asana OAuth failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func submitManualCode() {
        guard !manualAuthCode.isEmpty else {
            return
        }
        
        isConnecting = true
        connectionError = nil
        
        Task {
            do {
                let token = try await oauthService.exchangeCodeForTokenManually(
                    code: manualAuthCode.trimmingCharacters(in: .whitespaces)
                )
                
                oauthService.storeTokens(accessToken: token.accessToken, refreshToken: token.refreshToken, for: "asana")
                
                await MainActor.run {
                    isConnecting = false
                    showManualCodeEntry = false
                    manualAuthCode = ""
                    print("Asana OAuth successful! Token stored.")
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectionError = error.localizedDescription
                }
            }
        }
    }
    
    private var isConnected: Bool {
        SharedKeychainService.getAsanaAccessToken() != nil
    }
    
    private func disconnectAsana() {
        KeychainService.delete(key: "asana_access_token")
        KeychainService.delete(key: "asana_refresh_token")
        oauthService.clearToken(for: "asana")
        print("Asana disconnected.")
    }
    
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "link")
                        .foregroundColor(.blue)
                        .font(.system(size: 16))
                    Text("Asana Integration")
                        .font(.system(size: 16, weight: .semibold))
                }
                
                Text("Fetch dockets and job names from Asana")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 12) {
                    // Connection Status and Actions
                    HStack(spacing: 12) {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Connecting...")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        } else if isConnected {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 14))
                                Text("Connected")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        } else {
                            Button("Connect to Asana") {
                                connectToAsana()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!OAuthConfig.isAsanaConfigured)
                        }
                        
                        if isConnected {
                            Spacer()
                            Button("Disconnect") {
                                disconnectAsana()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    
                    // Error Messages
                    if let error = connectionError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                    
                    // Config Warning
                    if !OAuthConfig.isAsanaConfigured && !isConnected {
                        Text("OAuth credentials not configured")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    
                    // Advanced Settings Disclosure
                    Divider()
                        .padding(.vertical, 8)
                    
                    ExpandableSettingsHeader(title: "Advanced Options", isExpanded: $showAdvancedSettings)
                    
                    if showAdvancedSettings {
                        VStack(alignment: .leading, spacing: 12) {
                            // Workspace ID
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Workspace ID (optional)")
                                    .font(.system(size: 13))
                                TextField("Leave empty to search all workspaces", text: Binding(
                                    get: { settings.asanaWorkspaceID ?? "" },
                                    set: {
                                        settings.asanaWorkspaceID = $0.isEmpty ? nil : $0
                                        hasUnsavedChanges = true
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                            
                            // Project ID
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Project ID (optional)")
                                    .font(.system(size: 13))
                                TextField("Leave empty to search all projects", text: Binding(
                                    get: { settings.asanaProjectID ?? "" },
                                    set: {
                                        settings.asanaProjectID = $0.isEmpty ? nil : $0
                                        hasUnsavedChanges = true
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            // Custom Fields
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Custom Fields (optional)")
                                    .font(.system(size: 13))
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Docket Field Name")
                                            .font(.system(size: 11))
                                        TextField("e.g., Docket Number", text: Binding(
                                            get: { settings.asanaDocketField ?? "" },
                                            set: {
                                                settings.asanaDocketField = $0.isEmpty ? nil : $0
                                                hasUnsavedChanges = true
                                            }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Job Name Field Name")
                                            .font(.system(size: 11))
                                        TextField("e.g., Job Name", text: Binding(
                                            get: { settings.asanaJobNameField ?? "" },
                                            set: {
                                                settings.asanaJobNameField = $0.isEmpty ? nil : $0
                                                hasUnsavedChanges = true
                                            }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                }
                                Text("If not specified, will parse from task names (e.g., '12345_Job Name')")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            // Shared Cache
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Shared Cache (Optional)")
                                    .font(.system(size: 13))
                                
                                Toggle("Use Shared Cache", isOn: Binding(
                                    get: { settings.useSharedCache },
                                    set: {
                                        settings.useSharedCache = $0
                                        hasUnsavedChanges = true
                                    }
                                ))
                                .font(.system(size: 12))
                                
                                if settings.useSharedCache {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Shared Cache URL")
                                            .font(.system(size: 11))
                                        TextField("file:///Volumes/Server/cache.json or /path/to/cache.json", text: Binding(
                                            get: { settings.sharedCacheURL ?? "" },
                                            set: {
                                                settings.sharedCacheURL = $0.isEmpty ? nil : $0
                                                hasUnsavedChanges = true
                                            }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        Text("Enter a file path (e.g., /Volumes/Server/MediaDash/cache.json) or HTTP URL. MediaDash will read from this shared cache file instead of syncing with Asana directly. Falls back to local sync if unavailable.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.leading, 20)
                                }
                            }
                            
                            Divider()
                                .padding(.vertical, 4)
                            
                            // Force Full Sync
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Cache Maintenance")
                                    .font(.system(size: 13))
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) {
                                        Button {
                                            showForceSyncConfirmation = true
                                        } label: {
                                            HStack(spacing: 6) {
                                                if isForceSyncing {
                                                    ProgressView()
                                                        .scaleEffect(0.7)
                                                        .frame(width: 14, height: 14)
                                                } else {
                                                    Image(systemName: "arrow.triangle.2.circlepath")
                                                        .font(.system(size: 12))
                                                }
                                                Text(isForceSyncing ? "Syncing..." : "Force Full Sync")
                                                    .font(.system(size: 12))
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.orange)
                                        .disabled(isForceSyncing || !isConnected)
                                        
                                        if forceSyncSuccess {
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.green)
                                                Text("Sync complete!")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.green)
                                            }
                                        }
                                    }
                                    
                                    if let error = forceSyncError {
                                        Text(error)
                                            .font(.system(size: 10))
                                            .foregroundColor(.red)
                                    }
                                    
                                    Text("Clears local cache and fetches all data directly from Asana. Use this if you suspect data is out of sync or corrupted.")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.leading, 16)
                        .padding(.top, 8)
                    }
                }
            }
        }
        .sheet(isPresented: $showManualCodeEntry) {
            VStack(spacing: 20) {
                Text("Manual Authorization")
                    .font(.system(size: 16, weight: .semibold))
                
                if let url = manualAuthURL {
                    Text("Copy the authorization code from your browser:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    Button("Open Browser") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                TextField("Enter authorization code", text: $manualAuthCode)
                    .textFieldStyle(.roundedBorder)
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        showManualCodeEntry = false
                        manualAuthCode = ""
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Submit") {
                        submitManualCode()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualAuthCode.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 400)
        }
        .alert("Force Full Sync", isPresented: $showForceSyncConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Start Sync", role: .destructive) {
                performForceSync()
            }
        } message: {
            Text("This will clear your local cache and fetch all data directly from Asana. This operation may take several minutes depending on the size of your workspace.\n\nThis bypasses the shared cache and goes directly to the Asana API.")
        }
    }
    
    private func performForceSync() {
        isForceSyncing = true
        forceSyncError = nil
        forceSyncSuccess = false
        
        Task {
            do {
                try await cacheManager.forceFullSync(
                    workspaceID: settings.asanaWorkspaceID,
                    projectID: settings.asanaProjectID,
                    docketField: settings.asanaDocketField,
                    jobNameField: settings.asanaJobNameField
                )
                
                await MainActor.run {
                    isForceSyncing = false
                    forceSyncSuccess = true
                    
                    // Auto-hide success message after 5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        forceSyncSuccess = false
                    }
                }
            } catch {
                await MainActor.run {
                    isForceSyncing = false
                    forceSyncError = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Gmail Integration Section

struct GmailIntegrationSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool
    @StateObject var oauthService: OAuthService
    
    @StateObject private var gmailService = GmailService()
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var showManualCodeEntry = false
    @State private var manualAuthCode = ""
    @State private var manualAuthURL: URL?
    @State private var manualAuthState = ""
    @State private var isTestingConnection = false
    @State private var testResult: String?
    @State private var testError: String?
    @State private var connectedEmail: String?
    @State private var isLoadingEmail = false
    @State private var hasAuthenticated = false
    @State private var showAdvancedSettings = false
    
    private func connectToGmail() {
        guard OAuthConfig.isGmailConfigured else {
            connectionError = "Gmail OAuth credentials not configured. Please update OAuthConfig.swift with your credentials."
            return
        }
        
        isConnecting = true
        connectionError = nil
        
        Task {
            do {
                let token = try await oauthService.authenticateGmail(useOutOfBand: false)
                
                oauthService.storeToken(token.accessToken, for: "gmail")
                // Store both access token and refresh token
                gmailService.setAccessToken(token.accessToken, refreshToken: token.refreshToken)
                
                // Fetch user's email address
                do {
                    let email = try await gmailService.getUserEmail()
                    await MainActor.run {
                        connectedEmail = email
                        hasAuthenticated = true // Mark as authenticated
                        // Store in UserDefaults for persistence
                        UserDefaults.standard.set(email, forKey: "gmail_connected_email")
                        
                        // Add to Grayson employee whitelist if it's a Grayson email
                        if email.lowercased().hasSuffix("@graysonmusicgroup.com") {
                            _ = GraysonEmployeeWhitelist.shared.addEmail(email)
                            print("✅ Added \(email) to Grayson employee whitelist")
                        }
                    }
                } catch {
                    print("Failed to fetch user email: \(error.localizedDescription)")
                }
                
                await MainActor.run {
                    isConnecting = false
                    hasAuthenticated = true // Mark as authenticated even if email fetch fails
                    print("Gmail OAuth successful! Token stored.")
                    print("Debug: hasUnsavedChanges = \(hasUnsavedChanges) after Gmail connection")
                }
            } catch OAuthError.manualCodeRequired(let state, let authURL) {
                await MainActor.run {
                    isConnecting = false
                    manualAuthState = state
                    manualAuthURL = authURL
                    showManualCodeEntry = true
                    NSWorkspace.shared.open(authURL)
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectionError = error.localizedDescription
                    print("Gmail OAuth failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func submitManualCode() {
        guard !manualAuthCode.isEmpty else { return }
        
        isConnecting = true
        connectionError = nil
        
        Task {
            do {
                let token = try await oauthService.exchangeCodeForGmailTokenManually(
                    code: manualAuthCode.trimmingCharacters(in: .whitespaces)
                )
                
                oauthService.storeToken(token.accessToken, for: "gmail")
                // Store both access token and refresh token
                gmailService.setAccessToken(token.accessToken, refreshToken: token.refreshToken)
                
                // Fetch user's email address
                do {
                    let email = try await gmailService.getUserEmail()
                    await MainActor.run {
                        connectedEmail = email
                        hasAuthenticated = true // Mark as authenticated
                        // Store in UserDefaults for persistence
                        UserDefaults.standard.set(email, forKey: "gmail_connected_email")
                        
                        // Add to Grayson employee whitelist if it's a Grayson email
                        if email.lowercased().hasSuffix("@graysonmusicgroup.com") {
                            _ = GraysonEmployeeWhitelist.shared.addEmail(email)
                            print("✅ Added \(email) to Grayson employee whitelist")
                        }
                    }
                } catch {
                    print("Failed to fetch user email: \(error.localizedDescription)")
                }
                
                await MainActor.run {
                    isConnecting = false
                    showManualCodeEntry = false
                    manualAuthCode = ""
                    hasAuthenticated = true // Mark as authenticated even if email fetch fails
                    print("Gmail OAuth successful! Token stored.")
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectionError = error.localizedDescription
                }
            }
        }
    }
    
    private func loadConnectedEmail() async {
        guard gmailService.isAuthenticated else { return }
        
        await MainActor.run {
            isLoadingEmail = true
        }
        
        do {
            let email = try await gmailService.getUserEmail()
            await MainActor.run {
                connectedEmail = email
                UserDefaults.standard.set(email, forKey: "gmail_connected_email")
                
                // Add to Grayson employee whitelist if it's a Grayson email
                if email.lowercased().hasSuffix("@graysonmusicgroup.com") {
                    _ = GraysonEmployeeWhitelist.shared.addEmail(email)
                    print("✅ Added \(email) to Grayson employee whitelist")
                }
                
                isLoadingEmail = false
            }
        } catch {
            await MainActor.run {
                isLoadingEmail = false
                print("Failed to load connected email: \(error.localizedDescription)")
            }
        }
    }
    
    private func disconnectGmail() {
        gmailService.clearAccessToken()
        connectedEmail = nil
        hasAuthenticated = false
        UserDefaults.standard.removeObject(forKey: "gmail_connected_email")
        print("Gmail disconnected. User can reconnect by clicking 'Connect to Gmail'.")
    }
    
    private func testGmailConnection() {
        guard gmailService.isAuthenticated else {
            testError = "Not connected to Gmail. Please connect first."
            testResult = nil
            // Clear connected status if authentication fails
            connectedEmail = nil
            UserDefaults.standard.removeObject(forKey: "gmail_connected_email")
            return
        }
        
        isTestingConnection = true
        testResult = nil
        testError = nil
        
        Task {
            do {
                // Build query from search terms
                let baseQuery: String
                if !settings.gmailSearchTerms.isEmpty {
                    // Build OR query for each term, trying both label and subject
                    let queryParts = settings.gmailSearchTerms.filter { !$0.isEmpty }.flatMap { term in
                        [
                            "label:\"\(term)\"",
                            "subject:\"\(term)\""
                        ]
                    }
                    baseQuery = queryParts.isEmpty ? "label:\"New Docket\"" : "(\(queryParts.joined(separator: " OR ")))"
                } else if !settings.gmailQuery.isEmpty {
                    baseQuery = settings.gmailQuery
                } else {
                    baseQuery = "label:\"New Docket\""
                }
                
                let query = "\(baseQuery) is:unread"
                
                // Fetch a few emails to test the connection
                let messageRefs = try await gmailService.fetchEmails(query: query, maxResults: 5)
                
                if messageRefs.isEmpty {
                    await MainActor.run {
                        testResult = "Connection successful! No emails found matching query: \(query)"
                        testError = nil
                        isTestingConnection = false
                    }
                } else {
                    // Get full details of first email
                    let firstMessage = try await gmailService.getEmail(messageId: messageRefs.first!.id)
                    
                    await MainActor.run {
                        let subject = firstMessage.subject ?? "No subject"
                        let from = firstMessage.from ?? "Unknown sender"
                        testResult = "Connection successful! Found \(messageRefs.count) email(s).\n\nSample email:\nFrom: \(from)\nSubject: \(subject)"
                        testError = nil
                        isTestingConnection = false
                    }
                }
            } catch {
                await MainActor.run {
                    testError = "Connection test failed: \(error.localizedDescription)"
                    testResult = nil
                    isTestingConnection = false
                    
                    // If authentication error, clear the token and connected status
                    if error.localizedDescription.contains("authentication") || 
                       error.localizedDescription.contains("401") ||
                       error.localizedDescription.contains("not authenticated") {
                        gmailService.clearAccessToken()
                        connectedEmail = nil
                        hasAuthenticated = false // Clear authentication status
                        UserDefaults.standard.removeObject(forKey: "gmail_connected_email")
                    }
                }
            }
        }
    }
    
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "envelope")
                        .foregroundColor(.red)
                        .font(.system(size: 16))
                    Text("Gmail Integration")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.gmailEnabled },
                        set: {
                            settings.gmailEnabled = $0
                            hasUnsavedChanges = true
                        }
                    ))
                    .labelsHidden()
                }
                
                Text("Automatically scan emails for new dockets")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                if settings.gmailEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        // Connection Status and Actions
                        HStack(spacing: 12) {
                            if isConnecting {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Connecting...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            } else if hasAuthenticated && gmailService.isAuthenticated {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 14))
                                    Text("Connected")
                                        .font(.system(size: 12))
                                        .foregroundColor(.green)
                                    if let email = connectedEmail {
                                        Text("• \(email)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            } else {
                                Button("Connect to Gmail") {
                                    connectToGmail()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(!OAuthConfig.isGmailConfigured)
                            }
                            
                            if hasAuthenticated && gmailService.isAuthenticated {
                                Spacer()
                                HStack(spacing: 8) {
                                    if isTestingConnection {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                        Text("Testing...")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    } else {
                                        Button("Test") {
                                            testGmailConnection()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        
                                        Button("Disconnect") {
                                            disconnectGmail()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                        
                        // Error Messages
                        if let error = connectionError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                        }
                        
                        if let testError = testError {
                            Text(testError)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                        }
                        
                        if let testResult = testResult {
                            Text(testResult)
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                                .textSelection(.enabled)
                        }
                        
                        // Config Warning
                        if !OAuthConfig.isGmailConfigured && !gmailService.isAuthenticated {
                            Text("OAuth credentials not configured")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        
                        // Advanced Settings Disclosure
                        Divider()
                            .padding(.vertical, 8)
                        
                        ExpandableSettingsHeader(title: "Advanced Options", isExpanded: $showAdvancedSettings)
                        
                        if showAdvancedSettings {
                            VStack(alignment: .leading, spacing: 12) {
                                // Search Terms
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Search Terms / Labels")
                                        .font(.system(size: 13))
                                    
                                    Text("Add terms or labels to search for in email subjects, labels, and body text (case-insensitive)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(settings.gmailSearchTerms.indices, id: \.self) { index in
                                            HStack(spacing: 8) {
                                                TextField("Search term", text: Binding(
                                                    get: { settings.gmailSearchTerms[index] },
                                                    set: {
                                                        settings.gmailSearchTerms[index] = $0
                                                        hasUnsavedChanges = true
                                                    }
                                                ))
                                                .textFieldStyle(.roundedBorder)
                                                
                                                Button(action: {
                                                    settings.gmailSearchTerms.remove(at: index)
                                                    hasUnsavedChanges = true
                                                }) {
                                                    Image(systemName: "minus.circle.fill")
                                                        .foregroundColor(.red)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        
                                        Button(action: {
                                            settings.gmailSearchTerms.append("")
                                            hasUnsavedChanges = true
                                        }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus.circle.fill")
                                                Text("Add Search Term")
                                            }
                                            .font(.system(size: 12))
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                
                                // Polling Interval
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Scan Interval (seconds)")
                                        .font(.system(size: 13))
                                    
                                    TextField("300", value: Binding(
                                        get: { settings.gmailPollInterval },
                                        set: {
                                            settings.gmailPollInterval = max(60, $0)
                                            hasUnsavedChanges = true
                                        }
                                    ), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)
                                    
                                    Text("How often to check for new emails (minimum: 60 seconds)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                
                                Divider()
                                    .padding(.vertical, 8)
                                
                                // Company Media Email Section
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Company Media Email")
                                        .font(.system(size: 13, weight: .medium))
                                    
                                    Text("Emails sent to this address containing file hosting links will appear in a separate 'File Deliveries' section")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    
                                    TextField("media@graysonmusicgroup.com", text: Binding(
                                        get: { settings.companyMediaEmail },
                                        set: {
                                            settings.companyMediaEmail = $0
                                            hasUnsavedChanges = true
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }
                                
                                Divider()
                                    .padding(.vertical, 8)
                                
                                // Media Team & Grabbed Indicator Section
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Media Team & Grabbed Indicator")
                                        .font(.system(size: 13, weight: .medium))
                                    
                                    Text("Configure which team members can 'grab' media file threads and what qualifies as a media-file-delivery thread")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    
                                    // Media Team Emails
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Media Team Emails")
                                            .font(.system(size: 12))
                                        
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(settings.mediaTeamEmails.indices, id: \.self) { index in
                                                HStack(spacing: 8) {
                                                    TextField("email@example.com", text: Binding(
                                                        get: { settings.mediaTeamEmails[index] },
                                                        set: {
                                                            settings.mediaTeamEmails[index] = $0
                                                            hasUnsavedChanges = true
                                                        }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    
                                                    Button(action: {
                                                        settings.mediaTeamEmails.remove(at: index)
                                                        hasUnsavedChanges = true
                                                    }) {
                                                        Image(systemName: "minus.circle.fill")
                                                            .foregroundColor(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            
                                            Button(action: {
                                                settings.mediaTeamEmails.append("")
                                                hasUnsavedChanges = true
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "plus.circle.fill")
                                                    Text("Add Team Member")
                                                }
                                                .font(.system(size: 12))
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    // Subject Patterns
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Subject Patterns (Keywords)")
                                            .font(.system(size: 12))
                                        
                                        Text("Threads with these keywords in the subject qualify as media-file-delivery")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(settings.grabbedSubjectPatterns.indices, id: \.self) { index in
                                                HStack(spacing: 8) {
                                                    TextField("FILE DELIVERY", text: Binding(
                                                        get: { settings.grabbedSubjectPatterns[index] },
                                                        set: {
                                                            settings.grabbedSubjectPatterns[index] = $0
                                                            hasUnsavedChanges = true
                                                        }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    
                                                    Button(action: {
                                                        settings.grabbedSubjectPatterns.remove(at: index)
                                                        hasUnsavedChanges = true
                                                    }) {
                                                        Image(systemName: "minus.circle.fill")
                                                            .foregroundColor(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            
                                            Button(action: {
                                                settings.grabbedSubjectPatterns.append("")
                                                hasUnsavedChanges = true
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "plus.circle.fill")
                                                    Text("Add Pattern")
                                                }
                                                .font(.system(size: 12))
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    // Subject Exclusions
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Subject Exclusions")
                                            .font(.system(size: 12))
                                        
                                        Text("Threads with these keywords in the subject will NOT qualify as media-file-delivery")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(settings.grabbedSubjectExclusions.indices, id: \.self) { index in
                                                HStack(spacing: 8) {
                                                    TextField("SESSION CHECKLIST", text: Binding(
                                                        get: { settings.grabbedSubjectExclusions[index] },
                                                        set: {
                                                            settings.grabbedSubjectExclusions[index] = $0
                                                            hasUnsavedChanges = true
                                                        }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    
                                                    Button(action: {
                                                        settings.grabbedSubjectExclusions.remove(at: index)
                                                        hasUnsavedChanges = true
                                                    }) {
                                                        Image(systemName: "minus.circle.fill")
                                                            .foregroundColor(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            
                                            Button(action: {
                                                settings.grabbedSubjectExclusions.append("")
                                                hasUnsavedChanges = true
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "plus.circle.fill")
                                                    Text("Add Exclusion")
                                                }
                                                .font(.system(size: 12))
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    // Attachment Types
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Attachment Types")
                                            .font(.system(size: 12))
                                        
                                        Text("File extensions that qualify as media files (comma-separated or one per line)")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(settings.grabbedAttachmentTypes.indices, id: \.self) { index in
                                                HStack(spacing: 8) {
                                                    TextField("wav", text: Binding(
                                                        get: { settings.grabbedAttachmentTypes[index] },
                                                        set: {
                                                            settings.grabbedAttachmentTypes[index] = $0
                                                            hasUnsavedChanges = true
                                                        }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    
                                                    Button(action: {
                                                        settings.grabbedAttachmentTypes.remove(at: index)
                                                        hasUnsavedChanges = true
                                                    }) {
                                                        Image(systemName: "minus.circle.fill")
                                                            .foregroundColor(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            
                                            Button(action: {
                                                settings.grabbedAttachmentTypes.append("")
                                                hasUnsavedChanges = true
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "plus.circle.fill")
                                                    Text("Add Type")
                                                }
                                                .font(.system(size: 12))
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    // File Hosting Whitelist (Primary Method)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("File Hosting Whitelist")
                                            .font(.system(size: 12, weight: .semibold))
                                        
                                        Text("Primary method: Only links from these domains qualify as file delivery. Review platforms (simian.me, disco.ac) are automatically excluded.")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(settings.grabbedFileHostingWhitelist.indices, id: \.self) { index in
                                                HStack(spacing: 8) {
                                                    TextField("drive.google.com", text: Binding(
                                                        get: { settings.grabbedFileHostingWhitelist[index] },
                                                        set: {
                                                            settings.grabbedFileHostingWhitelist[index] = $0
                                                            hasUnsavedChanges = true
                                                        }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    
                                                    Button(action: {
                                                        settings.grabbedFileHostingWhitelist.remove(at: index)
                                                        hasUnsavedChanges = true
                                                    }) {
                                                        Image(systemName: "minus.circle.fill")
                                                            .foregroundColor(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            
                                            Button(action: {
                                                settings.grabbedFileHostingWhitelist.append("")
                                                hasUnsavedChanges = true
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "plus.circle.fill")
                                                    Text("Add Domain")
                                                }
                                                .font(.system(size: 12))
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    // Body Exclusions
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Body Exclusions")
                                            .font(.system(size: 12))
                                        
                                        Text("Threads with these keywords in the body will NOT qualify as media-file-delivery")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(settings.grabbedBodyExclusions.indices, id: \.self) { index in
                                                HStack(spacing: 8) {
                                                    TextField("check out", text: Binding(
                                                        get: { settings.grabbedBodyExclusions[index] },
                                                        set: {
                                                            settings.grabbedBodyExclusions[index] = $0
                                                            hasUnsavedChanges = true
                                                        }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    
                                                    Button(action: {
                                                        settings.grabbedBodyExclusions.remove(at: index)
                                                        hasUnsavedChanges = true
                                                    }) {
                                                        Image(systemName: "minus.circle.fill")
                                                            .foregroundColor(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            
                                            Button(action: {
                                                settings.grabbedBodyExclusions.append("")
                                                hasUnsavedChanges = true
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "plus.circle.fill")
                                                    Text("Add Exclusion")
                                                }
                                                .font(.system(size: 12))
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                    
                                    Divider()
                                        .padding(.vertical, 4)
                                    
                                    // Sender Whitelist
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Approved Senders")
                                            .font(.system(size: 12))
                                        
                                        Text("Threads from these senders qualify as media-file-delivery")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        
                                        VStack(alignment: .leading, spacing: 6) {
                                            ForEach(settings.grabbedSenderWhitelist.indices, id: \.self) { index in
                                                HStack(spacing: 8) {
                                                    TextField("client@example.com", text: Binding(
                                                        get: { settings.grabbedSenderWhitelist[index] },
                                                        set: {
                                                            settings.grabbedSenderWhitelist[index] = $0
                                                            hasUnsavedChanges = true
                                                        }
                                                    ))
                                                    .textFieldStyle(.roundedBorder)
                                                    
                                                    Button(action: {
                                                        settings.grabbedSenderWhitelist.remove(at: index)
                                                        hasUnsavedChanges = true
                                                    }) {
                                                        Image(systemName: "minus.circle.fill")
                                                            .foregroundColor(.red)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            
                                            Button(action: {
                                                settings.grabbedSenderWhitelist.append("")
                                                hasUnsavedChanges = true
                                            }) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "plus.circle.fill")
                                                    Text("Add Sender")
                                                }
                                                .font(.system(size: 12))
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                            .padding(.leading, 16)
                            .padding(.top, 8)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showManualCodeEntry) {
            VStack(spacing: 20) {
                Text("Manual Authorization")
                    .font(.system(size: 16, weight: .semibold))
                
                if let url = manualAuthURL {
                    Text("Copy the authorization code from your browser:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    Button("Open Browser") {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                TextField("Enter authorization code", text: $manualAuthCode)
                    .textFieldStyle(.roundedBorder)
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        showManualCodeEntry = false
                        manualAuthCode = ""
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Submit") {
                        submitManualCode()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualAuthCode.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 400)
        }
        .onAppear {
            // Restore connection state from Keychain when settings view appears
            if let accessToken = SharedKeychainService.getGmailAccessToken(), !accessToken.isEmpty {
                // Restore refresh token if available
                let refreshToken = SharedKeychainService.getGmailRefreshToken()
                gmailService.setAccessToken(accessToken, refreshToken: refreshToken)
                hasAuthenticated = true
                
                // Restore connected email from UserDefaults if available
                if let savedEmail = UserDefaults.standard.string(forKey: "gmail_connected_email") {
                    connectedEmail = savedEmail
                } else {
                    // Load email if not cached
                    Task {
                        await loadConnectedEmail()
                    }
                }
            } else {
                // No token found, ensure state is cleared
                hasAuthenticated = false
                connectedEmail = nil
            }
        }
        .task {
            // Load email if authenticated but not yet loaded
            if gmailService.isAuthenticated && connectedEmail == nil {
                await loadConnectedEmail()
            }
        }
    }
}


// MARK: - CodeMind AI Integration Section

struct CodeMindIntegrationSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool
    
    @State private var apiKey: String = ""
    @State private var provider: String = "gemini"
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testError: String?
    @State private var isInitialized = false
    @State private var showAdvancedSettings = false
    
    private let keychainKey = "codemind_api_key"
    private let isGraysonEmployee = SharedKeychainService.isCurrentUserGraysonEmployee()
    private let hasSharedKeys = CodeMindConfig.hasSharedKeysConfigured()
    
    private func saveAPIKey() {
        if apiKey.isEmpty {
            // Clear from Keychain (provider-specific key)
            let keychainKeyForProvider: String
            switch provider {
            case "grok":
                keychainKeyForProvider = "codemind_grok_api_key"
            default:
                keychainKeyForProvider = "codemind_gemini_api_key"
            }
            KeychainService.delete(key: keychainKeyForProvider)
            // Also clear legacy key if exists
            KeychainService.delete(key: keychainKey)

            settings.codeMindAPIKey = nil // Just a flag, not the actual key
            settings.codeMindProvider = nil
            UserDefaults.standard.removeObject(forKey: "codemind_provider")
            isInitialized = false
        } else {
            // Store in Keychain using provider-specific key
            let keychainKeyForProvider: String
            switch provider {
            case "grok":
                keychainKeyForProvider = "codemind_grok_api_key"
            case "groq":
                keychainKeyForProvider = "codemind_groq_api_key"
            default:
                keychainKeyForProvider = "codemind_gemini_api_key"
            }
            if KeychainService.store(key: keychainKeyForProvider, value: apiKey) {
                // Store flag and provider in settings (not the actual key)
                settings.codeMindAPIKey = "***" // Flag that key exists, but not the actual key
                settings.codeMindProvider = provider
                // Also store provider preference in UserDefaults for quick access
                UserDefaults.standard.set(provider, forKey: "codemind_provider")
                isInitialized = true
                print("CodeMind \(provider) API key saved to Keychain")
            } else {
                testError = "Failed to save API key to Keychain"
            }
        }
        hasUnsavedChanges = true
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        testError = nil
        
        Task {
            do {
                // Get the actual key that will be used (shared or personal)
                let testKey: String?
                if !apiKey.isEmpty {
                    // Use personal key if provided
                    testKey = apiKey
                } else {
                    // Use shared key or personal key from Keychain
                    testKey = CodeMindConfig.getAPIKey(for: provider)
                }
                
                guard let key = testKey else {
                    let providerName = provider == "grok" ? "Grok" : "Gemini"
                    await MainActor.run {
                        testError = "No \(providerName) API key found. Please enter a personal key or ensure shared keys are configured."
                        testResult = nil
                        isTesting = false
                    }
                    return
                }
                
                // Determine which key source is being used
                let keySource: String
                if !apiKey.isEmpty {
                    keySource = "personal"
                } else if isGraysonEmployee {
                    let hasSharedKey: Bool
                    switch provider {
                    case "grok":
                        hasSharedKey = SharedKeychainService.hasSharedKey(.codemindGrok)
                    default:
                        hasSharedKey = SharedKeychainService.hasSharedKey(.codemindGemini)
                    }
                    keySource = hasSharedKey ? "shared team key" : "personal key from Keychain"
                } else {
                    keySource = "personal key from Keychain"
                }

                // Initialize CodeMind
                let classifier = CodeMindEmailClassifier()
                try await classifier.initialize(apiKey: key, provider: provider)
                
                // Make a simple test query to verify the API actually works
                let classificationResult = try await classifier.classifyNewDocketEmail(
                    subject: "Test Email",
                    body: "This is a test email to verify CodeMind is working correctly.",
                    from: "test@example.com"
                )
                
                await MainActor.run {
                    self.testResult = "✅ Connection successful! CodeMind is working with your \(keySource).\n\nTest classification: \(classificationResult.classification.isNewDocket ? "Detected as new docket" : "Not a docket email")"
                    self.testError = nil
                    self.isTesting = false
                    self.isInitialized = true
                }
            } catch {
                // Log the error for debugging
                CodeMindLogger.shared.log(.error, "Connection test failed", category: .general, metadata: [
                    "error": error.localizedDescription,
                    "errorType": String(describing: type(of: error)),
                    "provider": provider,
                    "fullError": "\(error)"
                ])
                
                await MainActor.run {
                    let errorMessage: String
                    if let codeMindError = error as? CodeMindError {
                        switch codeMindError {
                        case .notConfigured(let msg):
                            errorMessage = "Configuration error: \(msg)"
                        case .notInitialized:
                            errorMessage = "CodeMind not initialized. Please check your API key."
                        default:
                            errorMessage = "Connection failed: \(codeMindError.localizedDescription)"
                        }
                    } else {
                        // Check for JSON decoding errors (common with invalid API keys)
                        let errorDescription = error.localizedDescription
                        let providerName = provider == "grok" ? "Grok" : "Gemini"
                        if errorDescription.contains("couldn't be read") || 
                           errorDescription.contains("isn't in the correct format") ||
                           errorDescription.contains("DecodingError") ||
                           errorDescription.contains("dataCorrupted") {
                            errorMessage = "Invalid API response format. This usually means:\n• The \(providerName) API key is invalid or expired\n• The \(providerName) API service is temporarily unavailable\n\nPlease verify your \(providerName) API key is correct."
                        } else {
                            errorMessage = "Connection failed: \(errorDescription)"
                        }
                    }
                    
                    self.testError = errorMessage
                    self.testResult = nil
                    self.isTesting = false
                    self.isInitialized = false
                }
            }
        }
    }
    
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundColor(.blue)
                        .font(.system(size: 16))
                    Text("CodeMind AI")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                
                Text("AI-powered email classification for better docket and file delivery detection")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                Divider()
                
                // Provider Selection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Provider")
                            .font(.system(size: 13, weight: .medium))
                        
                        Spacer()
                        
                        Button(action: testConnection) {
                            if isTesting {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Testing...")
                                        .font(.system(size: 11))
                                }
                            } else {
                                Text("Test Connection")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isTesting)
                        .help("Test CodeMind connection and API key")
                    }
                    
                    // Provider dropdown
                    Picker("AI Provider", selection: $provider) {
                        Text("Gemini").tag("gemini")
                        Text("Grok (xAI)").tag("grok")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    .onChange(of: provider) { _, newProvider in
                        settings.codeMindProvider = newProvider
                        UserDefaults.standard.set(newProvider, forKey: "codemind_provider")
                        // Clear API key field when switching providers
                        apiKey = ""
                        isInitialized = false
                        hasUnsavedChanges = true
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: provider == "grok" ? "sparkles" : "sparkles")
                            .foregroundColor(.blue)
                            .font(.system(size: 12))
                        Text("Powered by \(provider == "grok" ? "Grok (xAI)" : "Gemini")")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                // Show status for Grayson employees with shared keys
                if isGraysonEmployee {
                    if hasSharedKeys {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Using shared team key automatically")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        // Check if shared key exists for selected provider
                        let sharedKeyForProvider = provider == "grok" 
                            ? SharedKeychainService.hasSharedKey(.codemindGrok)
                            : SharedKeychainService.hasSharedKey(.codemindGemini)
                        
                        if !sharedKeyForProvider {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.orange)
                                Text("No shared \(provider == "grok" ? "Grok" : "Gemini") key configured. Set one up below or use a personal key.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
                // Advanced Settings (Personal API Key) - Only show if:
                // 1. Not a Grayson employee (they use shared keys), OR
                // 2. Grayson employee wants to override with personal key
                VStack(alignment: .leading, spacing: 8) {
                    Button(action: {
                        showAdvancedSettings.toggle()
                    }) {
                        HStack {
                            Text("Advanced Settings")
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Image(systemName: showAdvancedSettings ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    
                    if showAdvancedSettings {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Personal API Key (Optional)")
                                .font(.system(size: 12, weight: .medium))
                            
                            if isGraysonEmployee {
                                Text("You're using shared team keys. Set a personal key here to override.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 8) {
                                SecureField("Enter personal API key (stored securely in Keychain)", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: apiKey) { _, _ in
                                        saveAPIKey()
                                    }
                                
                                Button(action: testConnection) {
                                    if isTesting {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else {
                                        Text("Test")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isTesting)
                            }
                            
                            Text("Get your API key from:")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            
                            if provider == "grok" {
                                Link("Get your Grok API key from xAI Console", destination: URL(string: "https://console.x.ai/")!)
                                    .font(.system(size: 11))
                            } else {
                                Link("Get your Gemini API key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                                    .font(.system(size: 11))
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.top, 4)
                    }
                }
                
                // Status
                if let result = testResult {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(result)
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                    .padding(.vertical, 4)
                }
                
                if let error = testError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
                    .padding(.vertical, 4)
                }
                
                if isInitialized {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                        Text("CodeMind is active and will enhance email classification")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text("What CodeMind does:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("• Understands context better than pattern matching")
                        Text("• Learns from your email patterns over time")
                        Text("• Extracts docket numbers and job names more accurately")
                        Text("• Identifies file delivery emails with better precision")
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                .padding(.top, 4)
                
                Divider()
                
                // Activity Overlay Settings
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "circle.hexagongrid.fill")
                            .foregroundColor(.purple)
                        Text("Activity Overlay")
                            .font(.system(size: 13, weight: .medium))
                    }
                    
                    Text("Show a floating bubble that displays CodeMind activity in real-time")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Toggle("Enable Activity Bubble", isOn: Binding(
                        get: { settings.codeMindOverlayEnabled },
                        set: { newValue in
                            settings.codeMindOverlayEnabled = newValue
                            CodeMindActivityManager.shared.setEnabled(newValue)
                            hasUnsavedChanges = true
                        }
                    ))
                    .toggleStyle(.switch)
                    
                    if settings.codeMindOverlayEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Detail Level")
                                .font(.system(size: 12, weight: .medium))
                            
                            Picker("Detail Level", selection: Binding(
                                get: { settings.codeMindOverlayDetailLevel },
                                set: { newValue in
                                    settings.codeMindOverlayDetailLevel = newValue
                                    if let level = ActivityDetailLevel(rawValue: newValue) {
                                        CodeMindActivityManager.shared.setDetailLevel(level)
                                    }
                                    hasUnsavedChanges = true
                                }
                            )) {
                                Text("Minimal - Subtle pulse indicator").tag("minimal")
                                Text("Medium - Brief activity summaries").tag("medium")
                                Text("Detailed - Full activity stream").tag("detailed")
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                        }
                        .padding(.leading, 12)
                        
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard")
                                .foregroundColor(.secondary)
                            Text("Toggle with ⌘⇧O")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Divider()
                
                // Review Threshold Settings
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Review Threshold")
                            .font(.system(size: 13, weight: .medium))
                    }
                    
                    Text("Notifications with confidence below this threshold will go to 'For Review' for manual approval")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Threshold: \(Int(settings.codeMindReviewThreshold * 100))%")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            // Reset to default button
                            Button("Reset to 97%") {
                                settings.codeMindReviewThreshold = 0.97
                                hasUnsavedChanges = true
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        }
                        
                        Slider(
                            value: Binding(
                                get: { settings.codeMindReviewThreshold },
                                set: { newValue in
                                    settings.codeMindReviewThreshold = newValue
                                    hasUnsavedChanges = true
                                }
                            ),
                            in: 0.5...1.0,
                            step: 0.01
                        )
                        
                        HStack {
                            Text("50%")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("97% (Recommended)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("100%")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        
                        // Confidence indicator
                        HStack(spacing: 4) {
                            let thresholdPercent = Int(settings.codeMindReviewThreshold * 100)
                            let color: Color = thresholdPercent >= 95 ? .green : thresholdPercent >= 80 ? .orange : .red
                            Circle()
                                .fill(color)
                                .frame(width: 8, height: 8)
                            Text(thresholdPercent >= 95 ? "Strict - Most notifications will be reviewed" : 
                                 thresholdPercent >= 80 ? "Moderate - Some notifications will be reviewed" : 
                                 "Lenient - Few notifications will be reviewed")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.leading, 12)
                }
                
                // Shared Key Section (for Grayson Music Group employees only)
                if SharedKeychainService.isCurrentUserGraysonEmployee() {
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "building.2")
                                .foregroundColor(.blue)
                            Text("Shared Team Keys (Grayson Music Group)")
                                .font(.system(size: 13, weight: .medium))
                        }
                        
                        Text("Set shared keys that all Grayson Music Group employees can use automatically")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        
                        SharedKeySetupView()
                    }
                }
            }
        }
        .onAppear {
            // Load provider preference first
            if let storedProvider = settings.codeMindProvider {
                provider = storedProvider
            } else if let userDefaultsProvider = UserDefaults.standard.string(forKey: "codemind_provider") {
                provider = userDefaultsProvider
            } else {
                // Use default provider from shared config
                provider = CodeMindConfig.getDefaultProvider()
            }
            
            // Load API key from Keychain (provider-specific or legacy)
            let keychainKeyForProvider: String
            switch provider {
            case "grok":
                keychainKeyForProvider = "codemind_grok_api_key"
            default:
                keychainKeyForProvider = "codemind_gemini_api_key"
            }
            if let storedKey = KeychainService.retrieve(key: keychainKeyForProvider) {
                apiKey = storedKey
                isInitialized = true
            } else if let legacyKey = KeychainService.retrieve(key: keychainKey) {
                // Check for legacy key
                apiKey = legacyKey
                isInitialized = true
            } else if isGraysonEmployee && hasSharedKeys {
                // For Grayson employees with shared keys, check if CodeMind is working
                // by trying to get a key (which will use shared key)
                if CodeMindConfig.getAPIKey(for: provider) != nil {
                    isInitialized = true
                }
            }
        }
    }
}

// MARK: - Shared Key Setup View (Grayson Employees Only)

struct SharedKeySetupView: View {
    // CodeMind keys
    @State private var sharedClaudeKey: String = ""
    @State private var sharedOpenAIKey: String = ""
    @State private var sharedGeminiKey: String = ""
    @State private var sharedGrokKey: String = ""

    // Gmail keys
    @State private var sharedGmailAccessToken: String = ""
    @State private var sharedGmailRefreshToken: String = ""
    
    // Asana keys
    @State private var sharedAsanaAccessToken: String = ""
    
    @State private var isSaving = false
    @State private var saveResult: String?
    @State private var saveError: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // CodeMind Section
            VStack(alignment: .leading, spacing: 8) {
                Text("CodeMind AI")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 6) {
                    KeyField(label: "Gemini API Key", value: $sharedGeminiKey) {
                        saveSharedKey(sharedGeminiKey, for: .codemindGemini, name: "Gemini")
                    }

                    KeyField(label: "Grok API Key", value: $sharedGrokKey) {
                        saveSharedKey(sharedGrokKey, for: .codemindGrok, name: "Grok")
                    }
                }
            }
            
            Divider()
            
            // Gmail Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Gmail")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 6) {
                    KeyField(label: "Access Token", value: $sharedGmailAccessToken) {
                        saveSharedKey(sharedGmailAccessToken, for: .gmailAccessToken, name: "Gmail Access Token")
                    }
                    
                    KeyField(label: "Refresh Token", value: $sharedGmailRefreshToken) {
                        saveSharedKey(sharedGmailRefreshToken, for: .gmailRefreshToken, name: "Gmail Refresh Token")
                    }
                }
            }
            
            Divider()
            
            // Asana Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Asana")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                KeyField(label: "Access Token", value: $sharedAsanaAccessToken) {
                    saveSharedKey(sharedAsanaAccessToken, for: .asanaAccessToken, name: "Asana Access Token")
                }
            }
            
            // Status messages
            if let result = saveResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
            }
            
            if let error = saveError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }
            
            if hasAnySharedKeys() {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                    Text("Shared keys are configured. All Grayson employees will use them automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private func hasAnySharedKeys() -> Bool {
        return SharedKeychainService.hasSharedKey(.codemindGemini)
            || SharedKeychainService.hasSharedKey(.gmailAccessToken)
            || SharedKeychainService.hasSharedKey(.gmailRefreshToken)
            || SharedKeychainService.hasSharedKey(.asanaAccessToken)
    }
    
    private func saveSharedKey(_ key: String, for sharedKey: SharedKeychainService.SharedKey, name: String) {
        guard !key.isEmpty else { return }
        
        isSaving = true
        saveResult = nil
        saveError = nil
        
        if SharedKeychainService.setSharedKey(key, for: sharedKey) {
            saveResult = "✅ Shared \(name) saved successfully!"
            saveError = nil
            
            // Clear the field after successful save
            switch sharedKey {
            case .codemindGemini: sharedGeminiKey = ""
            case .gmailAccessToken: sharedGmailAccessToken = ""
            case .gmailRefreshToken: sharedGmailRefreshToken = ""
            case .asanaAccessToken: sharedAsanaAccessToken = ""
            default:
                break
            }
        } else {
            saveError = "Failed to save shared key. Make sure you're logged in with a @graysonmusicgroup.com email."
            saveResult = nil
        }
        
        isSaving = false
    }
}

// MARK: - Key Field Component

struct KeyField: View {
    let label: String
    @Binding var value: String
    let onSave: () -> Void
    
    @State private var isSaving = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                SecureField("Enter shared \(label.lowercased())", text: $value)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    onSave()
                }
                .buttonStyle(.bordered)
                .disabled(value.isEmpty || isSaving)
            }
        }
    }
}

// MARK: - Simian Integration Section

struct SimianIntegrationSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool
    
    @StateObject private var simianService = SimianService()
    @State private var webhookURL: String = ""
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testError: String?
    @State private var showAdvancedSettings = false
    
    private func testWebhook() {
        guard simianService.isConfigured else {
            testError = "Webhook URL not configured"
            testResult = nil
            return
        }
        
        isTesting = true
        testResult = nil
        testError = nil
        
        Task {
            do {
                try await simianService.createJob(
                    docketNumber: "TEST",
                    jobName: "Test Job",
                    projectManager: nil, // Test doesn't need a specific project manager
                    projectTemplate: settings.simianProjectTemplate
                )
                
                await MainActor.run {
                    testResult = "Webhook test successful! Check your Zapier Zap to confirm it received the test."
                    testError = nil
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testError = error.localizedDescription
                    testResult = nil
                    isTesting = false
                }
            }
        }
    }
    
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "link.circle")
                        .foregroundColor(.purple)
                        .font(.system(size: 16))
                    Text("Simian Integration")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { settings.simianEnabled },
                        set: {
                            settings.simianEnabled = $0
                            hasUnsavedChanges = true
                        }
                    ))
                    .labelsHidden()
                }
                
                Text("Create Simian projects automatically from notifications")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                if settings.simianEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        // Status
                        if simianService.isConfigured {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 14))
                                Text("Configured")
                                    .font(.system(size: 12))
                                    .foregroundColor(.green)
                            }
                        } else {
                            Text("Webhook URL required (configure in Advanced Settings)")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                        
                        // Test Button
                        if simianService.isConfigured {
                            HStack(spacing: 12) {
                                if isTesting {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Testing...")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                } else {
                                    Button("Test") {
                                        testWebhook()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        
                        // Test Results
                        if let testError = testError {
                            Text(testError)
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                        }
                        
                        if let testResult = testResult {
                            Text(testResult)
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                                .textSelection(.enabled)
                        }
                        
                        // Advanced Settings Disclosure
                        Divider()
                            .padding(.vertical, 8)
                        
                        ExpandableSettingsHeader(title: "Advanced Options", isExpanded: $showAdvancedSettings)
                        
                        if showAdvancedSettings {
                            VStack(alignment: .leading, spacing: 12) {
                                // Webhook URL
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Zapier Webhook URL")
                                        .font(.system(size: 13))
                                    
                                    TextField("https://hooks.zapier.com/hooks/catch/...", text: Binding(
                                        get: { settings.simianWebhookURL ?? "" },
                                        set: {
                                            settings.simianWebhookURL = $0.isEmpty ? nil : $0
                                            hasUnsavedChanges = true
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    
                                    Text("Get this URL from your Zapier Zap: Webhook by Zapier (Catch Hook) → Simian (Create Project)")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                
                                // Project Template
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Project Template")
                                        .font(.system(size: 13))
                                    
                                    TextField("Enter project template name or ID", text: Binding(
                                        get: { settings.simianProjectTemplate ?? "" },
                                        set: {
                                            settings.simianProjectTemplate = $0.isEmpty ? nil : $0
                                            hasUnsavedChanges = true
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    
                                    Text("The project template to use when creating Simian projects")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.leading, 16)
                            .padding(.top, 8)
                        }
                    }
                }
            }
        }
        .onAppear {
            updateWebhookURL()
        }
        .onChange(of: settings.simianWebhookURL) { _, _ in
            updateWebhookURL()
        }
    }
    
    private func updateWebhookURL() {
        webhookURL = settings.simianWebhookURL ?? ""
        if !webhookURL.isEmpty {
            simianService.setWebhookURL(webhookURL)
        } else {
            simianService.clearWebhookURL()
        }
    }
}

// MARK: - Cache Visualization View

struct CacheVisualizationView: View {
    @ObservedObject var cacheManager: AsanaCacheManager
    let settings: AppSettings
    @Binding var showCacheDetails: Bool
    @State private var showClearCacheAlert = false
    
    private var cachedDockets: [DocketInfo] {
        cacheManager.loadCachedDockets()
    }
    
    private var cacheSize: String {
        cacheManager.getCacheSize() ?? "Unknown"
    }
    
    private var lastSync: Date? {
        cacheManager.lastSyncDate
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cache Status")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Button(showCacheDetails ? "Hide Details" : "Show Details") {
                    showCacheDetails.toggle()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "externaldrive.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 12))
                    Text("\(cachedDockets.count) dockets cached")
                        .font(.system(size: 12))
                }
                
                HStack {
                    Image(systemName: "doc.text.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    Text("Cache size: \(cacheSize)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                if let lastSync = lastSync {
                    HStack {
                        Image(systemName: "clock.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                        Text("Last synced: \(formatDate(lastSync))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                        Text("No cache found")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }
                }
                
                if showCacheDetails && !cachedDockets.isEmpty {
                    Divider()
                        .padding(.vertical, 4)
                    
                    Text("Sample Dockets (first 10):")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(cachedDockets.prefix(10)) { docket in
                                HStack(spacing: 8) {
                                    Text(docket.number)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.blue)
                                        .frame(width: 60, alignment: .leading)
                                    Text(docket.jobName)
                                        .font(.system(size: 10))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if let updatedAt = docket.updatedAt {
                                        Text(formatDate(updatedAt))
                                            .font(.system(size: 9))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
                
                HStack(spacing: 8) {
                    Button("Sync Cache") {
                        syncCache()
                    }
                    .buttonStyle(.bordered)
                    .disabled(cacheManager.isSyncing || KeychainService.retrieve(key: "asana_access_token") == nil)
                    
                    if cacheManager.isSyncing {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Syncing with Asana...")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            Text("This may take several minutes depending on the number of projects and tasks.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.8))
                                .italic()
                        }
                    }
                    
                    Button("Clear Cache") {
                        showClearCacheAlert = true
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.red)
                    .alert("Clear Cache?", isPresented: $showClearCacheAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Clear", role: .destructive) {
                            clearCache()
                        }
                    } message: {
                        Text("This will delete all cached Asana data. You'll need to sync with Asana again, which may take several minutes depending on the number of projects and tasks in your workspace.")
                    }
                    
                    if let error = cacheManager.syncError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func syncCache() {
        guard let token = KeychainService.retrieve(key: "asana_access_token"), !token.isEmpty else {
            cacheManager.syncError = "Not connected to Asana"
            return
        }
        
        Task {
            do {
                try await cacheManager.syncWithAsana(
                    workspaceID: settings.asanaWorkspaceID,
                    projectID: settings.asanaProjectID,
                    docketField: settings.asanaDocketField,
                    jobNameField: settings.asanaJobNameField,
                    sharedCacheURL: settings.sharedCacheURL,
                    useSharedCache: settings.useSharedCache
                )
            } catch {
                await MainActor.run {
                    cacheManager.syncError = error.localizedDescription
                }
            }
        }
    }
    
    private func clearCache() {
        cacheManager.clearCache()
        cacheManager.syncError = nil
    }
}


// MARK: - File Category Row

struct InlineCategoryRow: View {
    let icon: String
    let title: String
    @Binding var folderName: String
    @Binding var extensions: String
    let description: String
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .frame(width: 20)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }

            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("Folder:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("PICTURE", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                HStack(spacing: 6) {
                    Text("Types:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("mp4, mov, avi", text: $extensions)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(6)
    }
}

// MARK: - General Options Section

struct GeneralOptionsSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool
    @State private var showAdvancedSettings = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                    Text("General Options")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("Search, workflow, and date preferences")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    // Workflow Options
                    Toggle(isOn: Binding(
                        get: { settings.openPrepFolderWhenDone },
                        set: {
                            settings.openPrepFolderWhenDone = $0
                            hasUnsavedChanges = true
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open Prep Folder When Done")
                                .font(.system(size: 13))
                            Text("Automatically opens the prep folder in Finder after prep completes")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    // Advanced Settings Disclosure
                    Divider()
                        .padding(.vertical, 4)
                    
                    ExpandableSettingsHeader(title: "Advanced Options", isExpanded: $showAdvancedSettings)
                    
                    if showAdvancedSettings {
                VStack(alignment: .leading, spacing: 16) {
                    // Folder Templates
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Folder Naming Templates")
                            .font(.system(size: 14, weight: .medium))
                        Text("Customize how MediaDash names new folders")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text("Prep Folders:")
                                    .font(.system(size: 12))
                                    .frame(width: 120, alignment: .leading)
                                TextField("{docket}_PREP_{date}", text: binding(for: \.prepFolderFormat))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                Text("{docket} and {date} will be replaced")
                                    .font(.system(size: 12))
                                    .foregroundColor(.blue)
                            }

                            HStack(spacing: 8) {
                                Text("Work Picture:")
                                    .font(.system(size: 12))
                                    .frame(width: 120, alignment: .leading)
                                TextField("%02d", text: binding(for: \.workPicNumberFormat))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                                Text("Creates: 01, 02, 03...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.top, 4)
                    }

                    Divider()
                        .padding(.vertical, 4)
                    
                    // Debug Features Toggle
                    Toggle(isOn: Binding(
                        get: { settings.showDebugFeatures },
                        set: {
                            settings.showDebugFeatures = $0
                            hasUnsavedChanges = true
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show Debug Features")
                                .font(.system(size: 13))
                            Text("Show test notification, debug scan, and cache viewer buttons in notification center")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    // Browser Preference
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Browser for Email Links")
                            .font(.system(size: 14, weight: .medium))
                        
                        Picker("Browser", selection: Binding(
                            get: { settings.defaultBrowser },
                            set: {
                                settings.defaultBrowser = $0
                                hasUnsavedChanges = true
                            }
                        )) {
                            ForEach(BrowserPreference.allCases, id: \.self) { browser in
                                Text(browser.displayName).tag(browser)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                        
                        Text("Choose which browser to use when opening email links from notifications")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Search Options
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Search Behavior")
                            .font(.system(size: 14, weight: .medium))

                        Toggle(isOn: Binding(
                            get: { settings.enableFuzzySearch },
                            set: {
                                settings.enableFuzzySearch = $0
                                hasUnsavedChanges = true
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Smart Search")
                                    .font(.system(size: 13))
                                Text("Finds results even with typos and spacing differences")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        // Default Search Folder
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Default Search Folder")
                                .font(.system(size: 13))
                                .padding(.top, 4)
                            Picker("", selection: Binding(
                                get: { settings.defaultSearchFolder },
                                set: {
                                    settings.defaultSearchFolder = $0
                                    hasUnsavedChanges = true
                                }
                            )) {
                                ForEach(SearchFolder.allCases, id: \.self) { folder in
                                    Text(folder.displayName).tag(folder)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        // Search Folder Preference
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Folder Selection Behavior")
                                .font(.system(size: 13))
                                .padding(.top, 4)
                            Picker("", selection: Binding(
                                get: { settings.searchFolderPreference },
                                set: {
                                    settings.searchFolderPreference = $0
                                    hasUnsavedChanges = true
                                }
                            )) {
                                Text(SearchFolderPreference.rememberLast.rawValue).tag(SearchFolderPreference.rememberLast)
                                Text(SearchFolderPreference.alwaysUseDefault.rawValue).tag(SearchFolderPreference.alwaysUseDefault)
                            }
                            .pickerStyle(.segmented)
                        }

                        // Default Quick Search
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Quick Search (Typing)")
                                .font(.system(size: 13))
                                .padding(.top, 4)
                            Text("What opens when you start typing")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Picker("", selection: Binding(
                                get: { settings.defaultQuickSearch },
                                set: {
                                    settings.defaultQuickSearch = $0
                                    hasUnsavedChanges = true
                                }
                            )) {
                                Text("Search").tag(DefaultQuickSearch.search)
                                Text("Job Info").tag(DefaultQuickSearch.jobInfo)
                            }
                            .pickerStyle(.segmented)
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Date/Business Day Options
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Prep Date Calculation")
                            .font(.system(size: 14, weight: .medium))

                        Text("File date is always today. Configure how prep date is calculated:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 4)

                        Toggle(isOn: Binding(
                            get: { settings.skipWeekends },
                            set: {
                                settings.skipWeekends = $0
                                hasUnsavedChanges = true
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Skip Weekends")
                                    .font(.system(size: 13))
                                Text("If next day is Saturday or Sunday, skip to Monday")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        Toggle(isOn: Binding(
                            get: { settings.skipHolidays },
                            set: {
                                settings.skipHolidays = $0
                                hasUnsavedChanges = true
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Skip Canadian Holidays")
                                    .font(.system(size: 13))
                                Text("If next day is a holiday on Thu/Fri, skip to Tuesday")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                        }
                        .padding(.leading, 16)
                        .padding(.top, 8)
                    }
                }
            }
        }
    }

    private func binding(for keyPath: WritableKeyPath<AppSettings, String>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                hasUnsavedChanges = true
            }
        )
    }
}

// MARK: - Theme Selection Section

struct ThemeSelectionSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "paintbrush")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                    Text("Appearance")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("Choose your preferred visual theme")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    // Appearance (Light/Dark Mode)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Appearance")
                            .font(.system(size: 14, weight: .medium))

                        Picker("", selection: Binding(
                            get: { settings.appearance },
                            set: {
                                settings.appearance = $0
                                hasUnsavedChanges = true
                            }
                        )) {
                            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    // Theme
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Theme")
                            .font(.system(size: 14, weight: .medium))

                        Picker("", selection: Binding(
                            get: { settings.appTheme },
                            set: {
                                settings.appTheme = $0
                                hasUnsavedChanges = true
                            }
                        )) {
                            ForEach(AppTheme.allCases, id: \.self) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 250)

                        // Theme description
                        Text(themeDescription(for: settings.appTheme))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    // Window Mode
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.split.3x1")
                                .font(.system(size: 14))
                                .foregroundColor(.accentColor)
                            Text("Window Mode")
                                .font(.system(size: 14, weight: .medium))
                        }
                        
                        Text("Choose between a compact phone-like interface or a full dashboard experience")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        // Window Mode Cards
                        HStack(spacing: 12) {
                            WindowModeCard(
                                mode: .compact,
                                isSelected: settings.windowMode == .compact,
                                onSelect: {
                                    if settings.windowMode != .compact {
                                        settings.windowMode = .compact
                                        hasUnsavedChanges = true
                                    }
                                }
                            )
                            
                            WindowModeCard(
                                mode: .dashboard,
                                isSelected: settings.windowMode == .dashboard,
                                onSelect: {
                                    if settings.windowMode != .dashboard {
                                        settings.windowMode = .dashboard
                                        hasUnsavedChanges = true
                                    }
                                }
                            )
                        }
                        .padding(.top, 4)
                        
                        // Note about restart
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            Text("Changes take effect after saving and restarting the app")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
    }

    private func themeDescription(for theme: AppTheme) -> String {
        switch theme {
        case .modern:
            return "Clean, professional interface with subtle colors"
        case .retroDesktop:
            return "Nostalgic retro desktop OS aesthetic with bold colors and window-based interface (Beta)"
        }
    }
}

// MARK: - New Profile View

struct NewProfileView: View {
    @ObservedObject var settingsManager: SettingsManager
    let currentSettings: AppSettings
    @Binding var isPresented: Bool
    @State private var profileName = ""
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("New Profile")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Profile Name:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Enter profile name", text: $profileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }

            if showError {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    createProfile()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func createProfile() {
        let name = profileName.trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty else {
            errorMessage = "Profile name cannot be empty"
            showError = true
            return
        }

        if settingsManager.availableProfiles.contains(name) {
            errorMessage = "A profile with this name already exists"
            showError = true
            return
        }

        var newSettings = currentSettings
        newSettings.profileName = name
        settingsManager.saveProfile(settings: newSettings, name: name)
        settingsManager.loadProfile(name: name)
        isPresented = false
    }
}

// MARK: - CSV Column Mapping Section

struct CSVColumnMappingSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "tablecells")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                    Text("CSV Column Names")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("Configure which column names to read from your job database CSV")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Essential Columns")
                        .font(.system(size: 14, weight: .medium))
                        .padding(.top, 4)

                    columnField("Docket:", keyPath: \.csvDocketColumn, placeholder: "Docket")
                    columnField("Project Title:", keyPath: \.csvProjectTitleColumn, placeholder: "Licensor/Project Title")
                    columnField("Client:", keyPath: \.csvClientColumn, placeholder: "Client")
                    columnField("Producer:", keyPath: \.csvProducerColumn, placeholder: "Grayson Producer")
                    columnField("Status:", keyPath: \.csvStatusColumn, placeholder: "STATUS")
                    columnField("License Total:", keyPath: \.csvLicenseTotalColumn, placeholder: "Music License Totals")
                    columnField("Currency:", keyPath: \.csvCurrencyColumn, placeholder: "Currency")

                    Divider()
                        .padding(.vertical, 4)

                    Text("Optional Columns")
                        .font(.system(size: 14, weight: .medium))

                    columnField("Agency:", keyPath: \.csvAgencyColumn, placeholder: "Agency")
                    columnField("Agency Producer:", keyPath: \.csvAgencyProducerColumn, placeholder: "Agency Producer / Supervisor")
                    columnField("Music Type:", keyPath: \.csvMusicTypeColumn, placeholder: "Music Type")
                    columnField("Track:", keyPath: \.csvTrackColumn, placeholder: "Track")
                    columnField("Media:", keyPath: \.csvMediaColumn, placeholder: "Media")
                }
            }
        }
    }

    @ViewBuilder
    private func columnField(_ label: String, keyPath: WritableKeyPath<AppSettings, String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 130, alignment: .leading)
            TextField(placeholder, text: Binding(
                get: { settings[keyPath: keyPath] },
                set: {
                    settings[keyPath: keyPath] = $0
                    hasUnsavedChanges = true
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)
        }
    }
}

// MARK: - Work Culture Enhancements Section

struct WorkCultureEnhancementsSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                        .font(.system(size: 18))
                    Text("Work Culture Enhancements")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("Fun features to enhance your workflow experience")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    // Cursed Image Grabbed Replies
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { settings.enableCursedImageReplies },
                            set: {
                                settings.enableCursedImageReplies = $0
                                hasUnsavedChanges = true
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cursed Image Grabbed Replies")
                                    .font(.system(size: 13))
                                Text("Instead of sending 'Grabbed' text, send a random image from a Reddit subreddit (NSFW subreddits are automatically excluded)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        
                        if settings.enableCursedImageReplies {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Subreddit Name")
                                    .font(.system(size: 11))
                                
                                TextField("cursedimages", text: Binding(
                                    get: { settings.cursedImageSubreddit },
                                    set: {
                                        settings.cursedImageSubreddit = $0
                                        hasUnsavedChanges = true
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                
                                Text("Enter subreddit name without 'r/' prefix (e.g., 'cursedimages', 'blursedimages')")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 16)
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

