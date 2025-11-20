import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @Binding var isPresented: Bool

    @State private var settings: AppSettings
    @State private var showNewProfileSheet = false
    @State private var showDeleteAlert = false
    @State private var profileToDelete: String?
    @State private var hasUnsavedChanges = false

    init(settingsManager: SettingsManager, isPresented: Binding<Bool>) {
        self.settingsManager = settingsManager
        self._isPresented = isPresented
        self._settings = State(initialValue: settingsManager.currentSettings)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Profile Management
                    ProfileSection(
                        settings: $settings,
                        settingsManager: settingsManager,
                        showNewProfileSheet: $showNewProfileSheet,
                        showDeleteAlert: $showDeleteAlert,
                        profileToDelete: $profileToDelete,
                        hasUnsavedChanges: $hasUnsavedChanges
                    )

                    Divider()

                    // Theme Selection
                    ThemeSelectionSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)

                    Divider()

                    // Path Settings
                    PathSettingsSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)

                    Divider()

                    // Folder Naming
                    FolderNamingSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)

                    Divider()

                    // File Categories
                    FileCategoriesSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)

                    Divider()

                    // Advanced Settings
                    AdvancedSettingsSection(settings: $settings, hasUnsavedChanges: $hasUnsavedChanges)
                }
                .padding()
            }

            Divider()

            // Footer with Save/Reset buttons
            HStack {
                Button("Reset to Defaults") {
                    settings = .default
                    hasUnsavedChanges = true
                }

                Spacer()

                if hasUnsavedChanges {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Button("Save") {
                    settingsManager.currentSettings = settings
                    settingsManager.saveCurrentProfile()
                    hasUnsavedChanges = false
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 700, height: 600)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile")
                .font(.headline)

            HStack {
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
                        Image(systemName: "chevron.down")
                    }
                    .frame(width: 200, alignment: .leading)
                }
                .menuStyle(BorderedButtonMenuStyle())

                Button(action: { showNewProfileSheet = true }) {
                    Image(systemName: "plus")
                }
                .help("New Profile")

                if settings.profileName != "Default" {
                    Button(action: {
                        profileToDelete = settings.profileName
                        showDeleteAlert = true
                    }) {
                        Image(systemName: "trash")
                    }
                    .help("Delete Profile")
                }
            }

            Text("Save different configurations for different workflows")
                .font(.caption)
                .foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 15) {
            Text("Storage Locations")
                .font(.headline)

            Text("Tell MediaDash where your files are stored")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                // Server Base Path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Work Picture & Prep Storage")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Where dockets and prep folders are stored")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("Example: /Volumes/Server/GM", text: binding(for: \.serverBasePath))
                            .textFieldStyle(.roundedBorder)
                        Button(action: { browseFolderFor(\.serverBasePath) }) {
                            Image(systemName: "folder")
                        }
                        .help("Browse for folder")
                    }
                }

                Divider()

                // Job Info Source
                VStack(alignment: .leading, spacing: 4) {
                    Text("Job Info Source")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Choose where to load job information from")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { settings.docketSource },
                        set: {
                            settings.docketSource = $0
                            hasUnsavedChanges = true
                        }
                    )) {
                        Text("CSV File").tag(DocketSource.csv)
                        Text("Server Path (Sessions)").tag(DocketSource.server)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Divider()

                // Sessions Base Path (for server-based docket lookup)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ProTools Sessions Storage")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(settings.docketSource == .server ? .primary : .secondary)
                    Text(settings.docketSource == .server ?
                         "Scan this folder for docket information" :
                         "Not used when CSV source is selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("Example: /Volumes/Server/SESSIONS", text: binding(for: \.sessionsBasePath))
                            .textFieldStyle(.roundedBorder)
                            .disabled(settings.docketSource != .server)
                        Button(action: { browseFolderFor(\.sessionsBasePath) }) {
                            Image(systemName: "folder")
                        }
                        .disabled(settings.docketSource != .server)
                        .help("Browse for folder")
                    }
                }

                Divider()

                // Docket Metadata CSV Import
                VStack(alignment: .leading, spacing: 4) {
                    Text("Docket Metadata")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(settings.docketSource == .csv ? .primary : .secondary)
                    Text(settings.docketSource == .csv ?
                         "Import a CSV file with docket metadata (Producer, Director, etc.)" :
                         "Not used when Server Path is selected")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: { importCSVFile() }) {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("Import CSV File")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.docketSource != .csv)
                        .help("Select a CSV file to import. It will be copied to ~/Documents/MediaDash/")

                        if showImportSuccess {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text(importMessage)
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }

                        if showImportError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                                Text(importMessage)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        // CSV Status Display
                        if csvExists {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text.fill")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                                Text(csvStatus)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        } else if settings.docketSource == .csv {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.badge.ellipsis")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("No CSV file imported yet")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            .padding(.top, 4)
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

// MARK: - Folder Naming Section

struct FolderNamingSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Folder Organization")
                .font(.headline)

            Text("Customize how folders are named and organized")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                // Work Picture Folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("Work Picture Folder")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("The main folder name for work pictures (usually \"WORK PICTURE\")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("WORK PICTURE", text: binding(for: \.workPictureFolderName))
                        .textFieldStyle(.roundedBorder)
                }

                // Prep Folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prep Folder")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("The main folder name for session prep (usually \"SESSION PREP\")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("SESSION PREP", text: binding(for: \.prepFolderName))
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                // Year Prefix
                VStack(alignment: .leading, spacing: 4) {
                    Text("Year Folder Prefix")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Prefix added to year folders (like \"GM_2025\")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("GM_", text: binding(for: \.yearPrefix))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("→ Creates folders like: \(settings.yearPrefix)\(Calendar.current.component(.year, from: Date()))")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }

                // Date Format
                VStack(alignment: .leading, spacing: 4) {
                    Text("Date Format")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("How dates appear in folder names")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("MMMd.yy", text: binding(for: \.dateFormat))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Text("→ Today would be: \(exampleDate)")
                            .font(.caption)
                            .foregroundColor(.blue)
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
}

// MARK: - File Categories Section

struct FileCategoriesSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("File Organization")
                .font(.headline)

            Text("MediaDash automatically sorts files into folders based on their type")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
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

                VStack(alignment: .leading, spacing: 4) {
                    Text("Everything Else")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Files that don't match any category go here")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Folder Name:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                    TextField("PICTURE", text: $folderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }

                HStack {
                    Text("File Types:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                    TextField("mp4, mov, avi", text: $extensions)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Advanced Settings Section

struct AdvancedSettingsSection: View {
    @Binding var settings: AppSettings
    @Binding var hasUnsavedChanges: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Advanced Options")
                .font(.headline)

            Text("Fine-tune how MediaDash creates folders and searches")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                // Folder Templates
                VStack(alignment: .leading, spacing: 4) {
                    Text("Folder Naming Templates")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Customize how MediaDash names new folders")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Prep Folders:")
                                .font(.caption)
                                .frame(width: 120, alignment: .leading)
                            TextField("{docket}_PREP_{date}", text: binding(for: \.prepFolderFormat))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            Text("{docket} and {date} will be replaced")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }

                        HStack {
                            Text("Work Picture:")
                                .font(.caption)
                                .frame(width: 120, alignment: .leading)
                            TextField("%02d", text: binding(for: \.workPicNumberFormat))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("Creates: 01, 02, 03...")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.top, 4)
                }

                Divider()

                // Search Options
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search Behavior")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Toggle(isOn: Binding(
                        get: { settings.enableFuzzySearch },
                        set: {
                            settings.enableFuzzySearch = $0
                            hasUnsavedChanges = true
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Smart Search")
                                .font(.callout)
                            Text("Finds results even with typos and spacing differences")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    // Default Search Folder
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Search Folder")
                            .font(.callout)
                            .padding(.top, 8)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Folder Selection Behavior")
                            .font(.callout)
                            .padding(.top, 8)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick Search (Typing)")
                            .font(.callout)
                            .padding(.top, 8)
                        Text("What opens when you start typing")
                            .font(.caption)
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

                // Date/Business Day Options
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prep Date Calculation")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text("File date is always today. Configure how prep date is calculated:")
                        .font(.caption)
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
                                .font(.callout)
                            Text("If next day is Saturday or Sunday, skip to Monday")
                                .font(.caption)
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
                                .font(.callout)
                            Text("If next day is a holiday on Thu/Fri, skip to Tuesday")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
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
        VStack(alignment: .leading, spacing: 15) {
            Text("Appearance")
                .font(.headline)

            Text("Choose your preferred visual theme")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Theme")
                    .font(.subheadline)
                    .fontWeight(.medium)

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
                .frame(width: 200)

                // Theme description
                Text(themeDescription(for: settings.appTheme))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func themeDescription(for theme: AppTheme) -> String {
        switch theme {
        case .modern:
            return "Clean, professional interface with subtle colors"
        case .windows95:
            return "Nostalgic gray interface with beveled buttons"
        case .windowsXP:
            return "Blue and green with that classic Fisher-Price look"
        case .macos1996:
            return "Platinum appearance with the classic Mac aesthetic"
        case .retro:
            return "Classic MS-DOS with cyan text on blue background"
        case .cursed:
            return "⚠️ A chaotic assault on good taste and usability"
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
