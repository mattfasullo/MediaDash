import SwiftUI

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

                // Sessions Base Path
                VStack(alignment: .leading, spacing: 4) {
                    Text("ProTools Sessions Storage")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Where your ProTools sessions are stored for searching")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("Example: /Volumes/Server/SESSIONS", text: binding(for: \.sessionsBasePath))
                            .textFieldStyle(.roundedBorder)
                        Button(action: { browseFolderFor(\.sessionsBasePath) }) {
                            Image(systemName: "folder")
                        }
                        .help("Browse for folder")
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
