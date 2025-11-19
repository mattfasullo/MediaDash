import Foundation
import SwiftUI
import Combine

// MARK: - Settings Model

struct AppSettings: Codable, Equatable {
    var profileName: String

    // Path Settings
    var serverBasePath: String
    var sessionsBasePath: String

    // Folder Naming
    var workPictureFolderName: String
    var prepFolderName: String
    var yearPrefix: String // e.g., "GM_"

    // Date Format
    var dateFormat: String // e.g., "MMMd.yy"

    // File Categories
    var pictureExtensions: [String]
    var musicExtensions: [String]
    var aafOmfExtensions: [String]

    // Category Folder Names
    var pictureFolderName: String
    var musicFolderName: String
    var aafOmfFolderName: String
    var otherFolderName: String

    // Folder Format Settings
    var workPicNumberFormat: String // e.g., "%02d" for "01", "02", etc.
    var prepFolderFormat: String // e.g., "{docket}_PREP_{date}"

    // Search Settings
    var enableFuzzySearch: Bool

    static var `default`: AppSettings {
        AppSettings(
            profileName: "Default",
            serverBasePath: "/Volumes/Grayson Assets/GM",
            sessionsBasePath: "/Volumes/Grayson Assets/SESSIONS",
            workPictureFolderName: "WORK PICTURE",
            prepFolderName: "SESSION PREP",
            yearPrefix: "GM_",
            dateFormat: "MMMd.yy",
            pictureExtensions: ["mp4", "mov", "avi", "mxf", "prores", "m4v"],
            musicExtensions: ["wav", "mp3", "aiff", "aif", "flac", "m4a", "aac"],
            aafOmfExtensions: ["aaf", "omf"],
            pictureFolderName: "PICTURE",
            musicFolderName: "MUSIC",
            aafOmfFolderName: "AAF-OMF",
            otherFolderName: "OTHER",
            workPicNumberFormat: "%02d",
            prepFolderFormat: "{docket}_PREP_{date}",
            enableFuzzySearch: true
        )
    }
}

// MARK: - Settings Manager

@MainActor
class SettingsManager: ObservableObject {
    @Published var currentSettings: AppSettings
    @Published var availableProfiles: [String] = []

    private let userDefaults = UserDefaults.standard
    private let currentProfileKey = "currentProfile"
    private let profilesKey = "savedProfiles"

    init() {
        // Load current profile name
        let profileName = userDefaults.string(forKey: currentProfileKey) ?? "Default"

        // Load available profiles
        if let profilesData = userDefaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData) {
            self.availableProfiles = Array(profiles.keys).sorted()
            self.currentSettings = profiles[profileName] ?? .default
        } else {
            // First launch - create default profile
            self.currentSettings = .default
            self.availableProfiles = ["Default"]
            saveProfile(settings: .default, name: "Default")
        }
    }

    func saveCurrentProfile() {
        saveProfile(settings: currentSettings, name: currentSettings.profileName)
    }

    func saveProfile(settings: AppSettings, name: String) {
        var profiles = loadAllProfiles()
        profiles[name] = settings

        if let encoded = try? JSONEncoder().encode(profiles) {
            userDefaults.set(encoded, forKey: profilesKey)
            availableProfiles = Array(profiles.keys).sorted()
        }
    }

    func loadProfile(name: String) {
        let profiles = loadAllProfiles()
        if let profile = profiles[name] {
            currentSettings = profile
            userDefaults.set(name, forKey: currentProfileKey)
        }
    }

    func deleteProfile(name: String) {
        guard name != "Default" else { return } // Can't delete default

        var profiles = loadAllProfiles()
        profiles.removeValue(forKey: name)

        if let encoded = try? JSONEncoder().encode(profiles) {
            userDefaults.set(encoded, forKey: profilesKey)
            availableProfiles = Array(profiles.keys).sorted()

            // If we deleted the current profile, switch to default
            if currentSettings.profileName == name {
                loadProfile(name: "Default")
            }
        }
    }

    func duplicateProfile(name: String, newName: String) {
        let profiles = loadAllProfiles()
        if var profile = profiles[name] {
            profile.profileName = newName
            saveProfile(settings: profile, name: newName)
        }
    }

    private func loadAllProfiles() -> [String: AppSettings] {
        guard let profilesData = userDefaults.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData) else {
            return ["Default": .default]
        }
        return profiles
    }

    func resetToDefaults() {
        currentSettings = .default
        saveCurrentProfile()
    }
}
