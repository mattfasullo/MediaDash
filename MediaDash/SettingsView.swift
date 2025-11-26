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

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @Binding var isPresented: Bool

    @State private var settings: AppSettings
    @State private var showNewProfileSheet = false
    @State private var showDeleteAlert = false
    @State private var profileToDelete: String?
    @State private var hasUnsavedChanges = false
    @StateObject private var oauthService = OAuthService()
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var showAdvancedSettings = false
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
                oauthService.storeToken(token.accessToken, for: "asana")
                
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
                                oauthService.storeToken(token.accessToken, for: "asana")
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
                
                oauthService.storeToken(token.accessToken, for: "asana")
                
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

                    // Simian Integration Section
                    SimianIntegrationSection(
                        settings: $settings,
                        hasUnsavedChanges: $hasUnsavedChanges
                    )

                    // Advanced Settings Toggle
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "gearshape.2")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 16))
                                Text("Advanced Settings")
                                    .font(.system(size: 16, weight: .medium))
                                Spacer()
                                Toggle("", isOn: $showAdvancedSettings)
                                    .labelsHidden()
                            }
                            Text("Show technical and customization options")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }

                    if showAdvancedSettings {
                        // Folder Naming
                        FolderNamingSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)

                        // File Categories
                        FileCategoriesSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)

                        // CSV Column Mapping (only shown when CSV is selected)
                        if settings.docketSource == .csv {
                            CSVColumnMappingSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)
                        }

                        // Advanced Settings
                        AdvancedSettingsSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges, settingsManager: settingsManager)
                    }
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
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: 720, height: 650)
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
    @Binding var showNewProfileSheet: Bool
    @Binding var showDeleteAlert: Bool
    @Binding var profileToDelete: String?
    @Binding var hasUnsavedChanges: Bool

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

                HStack(spacing: 12) {
                    Menu {
                        ForEach(settingsManager.availableProfiles, id: \.self) { profile in
                            Button(profile) {
                                settingsManager.loadProfile(name: profile)
                                settings = settingsManager.currentSettings
                                hasUnsavedChanges = false
                            }
                        }
                    } label: {
                        HStack {
                            Text(settings.profileName)
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

                    Button(action: { showNewProfileSheet = true }) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .help("New Profile")

                    if settings.profileName != "Default" {
                        Button(action: {
                            profileToDelete = settings.profileName
                            showDeleteAlert = true
                        }) {
                            Image(systemName: "trash.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 20))
                        }
                        .buttonStyle(.plain)
                        .help("Delete Profile")
                    }
                }

                Text("Save different configurations for different workflows")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
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
                }
            }
        }
        .onAppear {
            checkCSVStatus()
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
                oauthService.storeToken(token.accessToken, for: "asana")
                
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
                                oauthService.storeToken(token.accessToken, for: "asana")
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
                
                oauthService.storeToken(token.accessToken, for: "asana")
                
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
        KeychainService.retrieve(key: "asana_access_token") != nil
    }
    
    private func disconnectAsana() {
        KeychainService.delete(key: "asana_access_token")
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
                    }
                } catch {
                    print("Failed to fetch user email: \(error.localizedDescription)")
                }
                
                await MainActor.run {
                    isConnecting = false
                    hasAuthenticated = true // Mark as authenticated even if email fetch fails
                    print("Gmail OAuth successful! Token stored.")
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
        .task {
            if gmailService.isAuthenticated && connectedEmail == nil {
                await loadConnectedEmail()
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
                try await simianService.createJob(docketNumber: "TEST", jobName: "Test Job")
                
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

// MARK: - Folder Naming Section

struct FolderNamingSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "folder.badge.gear")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                    Text("Folder Organization")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("Customize how folders are named and organized")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

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
            }
        }
        }
    }
    
    private var exampleDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = settings.dateFormat
        return formatter.string(from: Date())
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
}

// MARK: - File Categories Section

struct FileCategoriesSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                    Text("File Organization")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("MediaDash automatically sorts files into folders based on their type")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    CategoryRow(
                        icon: "photo",
                        title: "Video Files",
                        folderName: binding(for: \.pictureFolderName),
                        extensions: bindingArray(for: \.pictureExtensions),
                        description: "Files like .mp4, .mov, .avi",
                        hasUnsavedChanges: $hasUnsavedChanges
                    )

                    CategoryRow(
                        icon: "music.note",
                        title: "Audio Files",
                        folderName: binding(for: \.musicFolderName),
                        extensions: bindingArray(for: \.musicExtensions),
                        description: "Files like .wav, .mp3, .aiff",
                        hasUnsavedChanges: $hasUnsavedChanges
                    )

                    CategoryRow(
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

    private func bindingArray(for keyPath: WritableKeyPath<AppSettings, [String]>) -> Binding<String> {
        Binding(
            get: { settings[keyPath: keyPath].joined(separator: ", ") },
            set: {
                settings[keyPath: keyPath] = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                hasUnsavedChanges = true
            }
        )
    }
}

struct CategoryRow: View {
    let icon: String
    let title: String
    @Binding var folderName: String
    @Binding var extensions: String
    let description: String
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .frame(width: 20)
                    .font(.system(size: 16))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
            }

            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Folder Name:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .leading)
                    TextField("PICTURE", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }

                HStack {
                    Text("File Types:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .leading)
                    TextField("mp4, mov, avi", text: $extensions)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - Advanced Settings Section

struct AdvancedSettingsSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                    Text("Advanced Options")
                        .font(.system(size: 18, weight: .semibold))
                }

                Text("Fine-tune how MediaDash creates folders and searches")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

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

                    Divider()
                        .padding(.vertical, 4)

                    // Workflow Options
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Workflow")
                            .font(.system(size: 14, weight: .medium))

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
                    }

                    // Gmail Advanced Settings
                    if settings.gmailEnabled {
                        Divider()
                            .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Gmail Integration")
                                .font(.system(size: 14, weight: .medium))
                            
                            // Search Terms
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Search Terms / Labels")
                                    .font(.system(size: 13))
                                
                                Text("Add terms or labels to search for in email subjects and labels (case-insensitive)")
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
                        }
                    }
                    
                    // Asana Advanced Settings
                    if settings.docketSource == .asana {
                        Divider()
                            .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Asana Integration")
                                .font(.system(size: 14, weight: .medium))
                            
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
                        }
                    }
                    
                    // Simian Advanced Settings
                    if settings.simianEnabled {
                        Divider()
                            .padding(.vertical, 4)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Simian Integration")
                                .font(.system(size: 14, weight: .medium))
                            
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
                        }
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

                VStack(alignment: .leading, spacing: 10) {
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

