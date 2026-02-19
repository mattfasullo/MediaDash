import Foundation
import SwiftUI
import Combine

// MARK: - Profile Model

struct WorkspaceProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var username: String? // Username/email for user identification
    var settings: AppSettings
    var createdAt: Date
    var lastAccessedAt: Date
    var isLocal: Bool // Whether this is a local-only workspace (not synced)

    init(id: UUID = UUID(), name: String, username: String? = nil, settings: AppSettings, isLocal: Bool = false) {
        self.id = id
        self.name = name
        self.username = username
        self.settings = settings
        self.createdAt = Date()
        self.lastAccessedAt = Date()
        self.isLocal = isLocal
    }

    // Create a user workspace that syncs to shared storage
    static func user(username: String, settings: AppSettings? = nil) -> WorkspaceProfile {
        // Use provided settings or load from shared storage, or fall back to defaults
        let userSettings = settings ?? AppSettings.default
        
        // Apply Grayson Music defaults if not already set
        var finalSettings = userSettings
        if finalSettings.serverBasePath == AppSettings.default.serverBasePath {
            finalSettings.sessionsBasePath = "/Volumes/Grayson Assets/SESSIONS"
            finalSettings.serverBasePath = "/Volumes/Grayson Assets/GM"
            finalSettings.workPictureFolderName = "WORK PICTURE"
            finalSettings.prepFolderName = "SESSION PREP"
            finalSettings.yearPrefix = "GM_"
        }
        
        return WorkspaceProfile(
            name: username,
            username: username,
            settings: finalSettings,
            isLocal: false
        )
    }

    // Create a local workspace with default settings (not synced)
    static func local(name: String) -> WorkspaceProfile {
        return WorkspaceProfile(
            name: name,
            username: nil,
            settings: AppSettings.default,
            isLocal: true
        )
    }
}

// MARK: - Authentication State

enum AuthenticationState: Equatable {
    case loggedOut
    case loggedIn(WorkspaceProfile)

    var isLoggedIn: Bool {
        if case .loggedIn = self {
            return true
        }
        return false
    }

    var profile: WorkspaceProfile? {
        if case .loggedIn(let profile) = self {
            return profile
        }
        return nil
    }
}

// MARK: - Session Manager

@MainActor
class SessionManager: ObservableObject {
    @Published var authenticationState: AuthenticationState = .loggedOut
    @Published var syncStatus: SyncStatus = .unknown
    @Published var lastSyncError: String?
    @Published var settingsConflict: SettingsConflict? // Conflict detected during sync

    private let lastProfileIDKey = "lastActiveProfileID"
    private let lastUsernameKey = "lastActiveUsername"
    private let profilesKey = "workspaceProfiles"
    
    enum SyncStatus {
        case synced              // Settings successfully synced to shared storage
        case localOnly           // Using local settings (shared storage unavailable)
        case syncing             // Currently syncing
        case syncFailed(String)  // Sync failed with error message
        case conflict(SettingsConflict) // Conflict detected
        case unknown             // Status not yet determined
    }
    
    struct SettingsConflict {
        let localModified: Date
        let sharedModified: Date
        let resolution: ConflictResolution
        
        enum ConflictResolution {
            case usedLocal      // Used local settings (local was newer)
            case usedShared     // Used shared settings (shared was newer)
            case merged         // Merged both (future enhancement)
        }
    }

    init() {
        Task { @MainActor in
            await Task.yield()
            loadLastSession()
        }
    }

    // Load the last active session from UserDefaults
    private func loadLastSession() {
        guard let profileIDString = UserDefaults.standard.string(forKey: lastProfileIDKey),
              let profileID = UUID(uuidString: profileIDString),
              var profile = loadProfile(id: profileID) else {
            authenticationState = .loggedOut
            syncStatus = .unknown
            return
        }

        // Set initial state with local profile (will update if shared settings are found)
        profile.lastAccessedAt = Date()
        saveProfile(profile)
        authenticationState = .loggedIn(profile)
        syncStatus = .localOnly // Start with local, will update if sync succeeds
        print("SessionManager: Restored session for '\(profile.name)'")

        // If this is a user profile (not local), try to reload settings from shared storage
        // This ensures settings sync when app starts if they were updated on another machine
        if !profile.isLocal, let username = profile.username {
            Task {
                await Task.yield()
                await MainActor.run {
                    syncStatus = .syncing
                }
                let localModified = profile.lastAccessedAt
                
                if let (sharedSettings, sharedModified) = await loadSettingsFromSharedStorage(username: username) {
                    await Task.yield()
                    await MainActor.run {
                        // Check for conflicts: if both exist and are different
                        let settingsAreDifferent = profile.settings != sharedSettings
                        let timeDifference = abs(sharedModified.timeIntervalSince(localModified))
                        
                        if settingsAreDifferent && timeDifference > 1.0 {
                            // Conflict detected - settings differ and timestamps are far apart
                            let conflict: SettingsConflict
                            
                            if sharedModified > localModified {
                                // Shared is newer - use shared settings
                                conflict = SettingsConflict(
                                    localModified: localModified,
                                    sharedModified: sharedModified,
                                    resolution: .usedShared
                                )
                                var updatedProfile = profile
                                updatedProfile.settings = sharedSettings
                                updatedProfile.lastAccessedAt = Date()
                                saveProfile(updatedProfile)
                                authenticationState = .loggedIn(updatedProfile)
                                settingsConflict = conflict
                                syncStatus = .conflict(conflict)
                                print("SessionManager: Conflict resolved - used shared settings (newer: \(sharedModified) vs \(localModified))")
                            } else {
                                // Local is newer - keep local and sync it
                                conflict = SettingsConflict(
                                    localModified: localModified,
                                    sharedModified: sharedModified,
                                    resolution: .usedLocal
                                )
                                // Keep local settings, but sync them to shared storage
                                settingsConflict = conflict
                                syncStatus = .conflict(conflict)
                                Task {
                                    let saved = await saveSettingsToSharedStorage(profile: profile)
                                    await Task.yield()
                                    await MainActor.run {
                                        if saved {
                                            syncStatus = .synced
                                            settingsConflict = nil
                                        }
                                    }
                                }
                                print("SessionManager: Conflict resolved - kept local settings (newer: \(localModified) vs \(sharedModified)), syncing to shared")
                            }
                        } else if settingsAreDifferent {
                            // Settings differ but timestamps are very close (< 1 second) - likely a race condition
                            // Prefer shared to be safe (someone else might have just updated)
                            var updatedProfile = profile
                            updatedProfile.settings = sharedSettings
                            updatedProfile.lastAccessedAt = Date()
                            saveProfile(updatedProfile)
                            authenticationState = .loggedIn(updatedProfile)
                            syncStatus = .synced
                            print("SessionManager: Settings differ but timestamps close - using shared settings")
                        } else {
                            // Settings are the same, just update timestamp
        var updatedProfile = profile
        updatedProfile.lastAccessedAt = Date()
        saveProfile(updatedProfile)
                            syncStatus = .synced
                            print("SessionManager: Settings in sync, no changes needed")
                        }
                        
                        lastSyncError = nil
                    }
                } else {
                    await Task.yield()
                    await MainActor.run {
                        // Check if shared storage is configured but unavailable
                        if let sharedCacheURL = profile.settings.sharedCacheURL, !sharedCacheURL.isEmpty {
                            syncStatus = .localOnly
                            lastSyncError = "Shared storage unavailable. Using local settings."
                        } else {
                            syncStatus = .localOnly
                            lastSyncError = nil
                        }
                        print("SessionManager: No shared settings found for '\(username)', using local settings")
                    }
                }
            }
        } else {
            // Local workspace - no sync needed
            syncStatus = .localOnly
            lastSyncError = nil
        }
    }

    // Log in with username (loads settings from shared storage)
    func loginWithUsername(_ username: String, initialUserRole: UserRole? = nil) async {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanUsername.isEmpty else { return }
        
        syncStatus = .syncing
        lastSyncError = nil
        
        // Try to load settings from shared storage
        var loadedSettings: AppSettings? = nil
        var usingSharedStorage = false
        
        if let (sharedSettings, _) = await loadSettingsFromSharedStorage(username: cleanUsername) {
            loadedSettings = sharedSettings
            usingSharedStorage = true
            syncStatus = .synced
            print("SessionManager: Loaded settings from shared storage for '\(cleanUsername)'")
        } else {
            // Check if shared storage is configured but unavailable
            let defaultSettings = AppSettings.default
            if let sharedCacheURL = defaultSettings.sharedCacheURL, !sharedCacheURL.isEmpty {
                // Shared storage is configured but unavailable
                syncStatus = .localOnly
                lastSyncError = "Shared storage unavailable. Using local settings. Changes will sync when connection is restored."
                print("SessionManager: Shared storage configured but unavailable for '\(cleanUsername)'")
            } else {
                // No shared storage configured
                syncStatus = .localOnly
                print("SessionManager: No shared storage configured, using local settings")
            }
        }
        
        // Create user profile with loaded or default settings; when initialUserRole is provided, always apply it so the sign-in uses the chosen type
        var settingsToUse: AppSettings
        if let loaded = loadedSettings {
            settingsToUse = loaded
        } else {
            settingsToUse = AppSettings.default
        }
        if let role = initialUserRole {
            settingsToUse.userRole = role
        }
        let profile = WorkspaceProfile.user(username: cleanUsername, settings: settingsToUse)
        login(with: profile)
        
        // Try to save to shared storage (will fail gracefully if unavailable)
        if let sharedCacheURL = profile.settings.sharedCacheURL, !sharedCacheURL.isEmpty {
            let saved = await saveSettingsToSharedStorage(profile: profile)
            if !saved && !usingSharedStorage {
                // Failed to save and we didn't load from shared storage
                syncStatus = .syncFailed("Cannot connect to shared storage")
            } else if saved {
                syncStatus = .synced
            }
        }
    }

    // Create a local workspace (not synced); optional userRole sets account type (media vs producer)
    func createLocalWorkspace(name: String, userRole: UserRole? = nil) {
        var settings = AppSettings.default
        if let role = userRole {
            settings.userRole = role
        }
        let profile = WorkspaceProfile(
            name: name,
            username: nil,
            settings: settings,
            isLocal: true
        )
        login(with: profile)
    }

    // Log in with a profile
    func login(with profile: WorkspaceProfile) {
        var updatedProfile = profile
        updatedProfile.lastAccessedAt = Date()

        saveProfile(updatedProfile)
        UserDefaults.standard.set(updatedProfile.id.uuidString, forKey: lastProfileIDKey)
        if let username = updatedProfile.username {
            UserDefaults.standard.set(username, forKey: lastUsernameKey)
        }

        authenticationState = .loggedIn(updatedProfile)
        print("SessionManager: Logged in to workspace '\(profile.name)'")
    }

    // Log out
    func logout() {
        // Save current settings to shared storage before logging out
        if case .loggedIn(let profile) = authenticationState, !profile.isLocal, profile.username != nil {
            Task {
                await saveSettingsToSharedStorage(profile: profile)
            }
        }
        
        UserDefaults.standard.removeObject(forKey: lastProfileIDKey)
        UserDefaults.standard.removeObject(forKey: lastUsernameKey)
        authenticationState = .loggedOut
        print("SessionManager: Logged out")
    }

    // Update the current profile's settings
    func updateProfile(settings: AppSettings) {
        guard case .loggedIn(var profile) = authenticationState else { return }

        profile.settings = settings
        profile.lastAccessedAt = Date()

        // Always save locally first (works offline)
        saveProfile(profile)
        authenticationState = .loggedIn(profile)
        
        // Try to save to shared storage if this is a synced user profile
        if !profile.isLocal, profile.username != nil {
            syncStatus = .syncing
            Task {
                let saved = await saveSettingsToSharedStorage(profile: profile)
                await MainActor.run {
                    if saved {
                        syncStatus = .synced
                        lastSyncError = nil
                    } else {
                        // Check if shared storage is configured
                        if let sharedCacheURL = profile.settings.sharedCacheURL, !sharedCacheURL.isEmpty {
                            syncStatus = .syncFailed("Shared storage unavailable. Settings saved locally and will sync when connection is restored.")
                        } else {
                            syncStatus = .localOnly
                        }
                    }
                }
            }
        }
    }

    // MARK: - Profile Persistence

    private func saveProfile(_ profile: WorkspaceProfile) {
        var profiles = loadAllProfiles()
        profiles[profile.id] = profile

        if let encoded = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(encoded, forKey: profilesKey)
        }
    }

    private func loadProfile(id: UUID) -> WorkspaceProfile? {
        let profiles = loadAllProfiles()
        return profiles[id]
    }

    private func loadAllProfiles() -> [UUID: WorkspaceProfile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([UUID: WorkspaceProfile].self, from: data) else {
            return [:]
        }
        return profiles
    }
    
    /// Get all user profiles (non-local, synced profiles)
    func getAllUserProfiles() -> [WorkspaceProfile] {
        let allProfiles = loadAllProfiles()
        return allProfiles.values
            .filter { !$0.isLocal && $0.username != nil }
            .sorted { $0.lastAccessedAt > $1.lastAccessedAt } // Most recently used first
    }
    
    /// Check if server is connected (shared storage is available)
    func isServerConnected() -> Bool {
        let defaultSettings = AppSettings.default
        guard let sharedCacheURL = defaultSettings.sharedCacheURL, !sharedCacheURL.isEmpty else {
            return false
        }
        return FileManager.default.fileExists(atPath: sharedCacheURL)
    }
    
    /// Get list of usernames from server (users who have settings files on shared storage)
    func getServerUsers() async -> [String] {
        let defaultSettings = AppSettings.default
        guard let sharedCacheURL = defaultSettings.sharedCacheURL, !sharedCacheURL.isEmpty else {
            return []
        }
        
        let cacheBaseURL = URL(fileURLWithPath: sharedCacheURL)
        let settingsDirURL = cacheBaseURL.appendingPathComponent("MediaDash_Settings")
        
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: settingsDirURL.path) else {
            return []
        }
        
        do {
            let files = try fileManager.contentsOfDirectory(at: settingsDirURL, includingPropertiesForKeys: nil)
            let usernames = files
                .filter { $0.pathExtension == "json" }
                .map { $0.deletingPathExtension().lastPathComponent }
                .sorted()
            return usernames
        } catch {
            print("SessionManager: Failed to list server users: \(error.localizedDescription)")
            return []
        }
    }
    
    /// Delete a profile (both local and from server if possible)
    /// Can also delete a server-only user by username (even if no local profile exists)
    func deleteProfile(_ profile: WorkspaceProfile) async -> Bool {
        // Remove from local storage if it exists
        var profiles = loadAllProfiles()
        profiles.removeValue(forKey: profile.id)
        
        if let encoded = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(encoded, forKey: profilesKey)
        }
        
        // Try to delete from server if it's a synced profile
        if !profile.isLocal, let username = profile.username {
            await deleteServerUser(username: username)
        }
        
        // If we deleted the current profile, log out
        if case .loggedIn(let currentProfile) = authenticationState, currentProfile.id == profile.id {
            logout()
        }
        
        return true
    }
    
    /// Delete a user from the server by username (even if no local profile exists)
    func deleteServerUser(username: String) async {
        let defaultSettings = AppSettings.default
        guard let sharedCacheURL = defaultSettings.sharedCacheURL, !sharedCacheURL.isEmpty else {
            return
        }
        
        let cacheBaseURL = URL(fileURLWithPath: sharedCacheURL)
        let settingsDirURL = cacheBaseURL.appendingPathComponent("MediaDash_Settings")
        let settingsFile = settingsDirURL.appendingPathComponent("\(username).json")
        
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: settingsFile.path) {
            do {
                try fileManager.removeItem(at: settingsFile)
                print("SessionManager: Deleted user from server: \(username)")
            } catch {
                print("SessionManager: Failed to delete user from server: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Shared Storage Settings Sync
    
    /// Load settings from shared storage for a user
    /// - Returns: Tuple of (settings, fileModificationDate) or nil if unavailable
    private func loadSettingsFromSharedStorage(username: String) async -> (AppSettings, Date)? {
        // First, try to get shared cache URL from default settings
        let defaultSettings = AppSettings.default
        guard let sharedCacheURL = defaultSettings.sharedCacheURL, !sharedCacheURL.isEmpty else {
            print("SessionManager: No shared cache URL configured")
            return nil
        }
        
        // Use MediaDash_Cache as base directory, with Settings as subdirectory
        let cacheBaseURL = URL(fileURLWithPath: sharedCacheURL)
        let settingsDirURL = cacheBaseURL.appendingPathComponent("MediaDash_Settings")
        let settingsFile = settingsDirURL.appendingPathComponent("\(username).json")
        
        // Check if settings directory exists, create if needed
        let fileManager = FileManager.default
        let settingsURL = settingsFile
        
        guard fileManager.fileExists(atPath: settingsFile.path) else {
            print("SessionManager: Settings file not found at \(settingsFile)")
            return nil
        }
        
        do {
            // Get file modification date
            let attributes = try fileManager.attributesOfItem(atPath: settingsFile.path)
            let modificationDate = attributes[FileAttributeKey.modificationDate] as? Date ?? Date()
            
            let data = try Data(contentsOf: settingsURL)
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            print("SessionManager: Successfully loaded settings from \(settingsFile) (modified: \(modificationDate))")
            return (settings, modificationDate)
        } catch {
            print("SessionManager: Failed to load settings from shared storage: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Get local settings file modification date
    private func getLocalSettingsModificationDate(username: String) -> Date? {
        // Get the profile's last accessed date as a proxy for when local settings were last modified
        // We could also check UserDefaults modification, but lastAccessedAt is close enough
        guard case .loggedIn(let profile) = authenticationState,
              profile.username == username else {
            return nil
        }
        return profile.lastAccessedAt
    }
    
    /// Safely create a directory, handling the case where a file with the same name exists
    /// If a file exists, it will be renamed with a .old extension before creating the directory
    private func safeCreateDirectory(at url: URL, fileManager: FileManager) throws {
        let path = url.path
        
        // Check if path exists
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        
        if exists {
            if isDirectory.boolValue {
                // Already a directory, nothing to do
                return
            } else {
                // It's a file - rename it to avoid conflict
                let backupURL = url.appendingPathExtension("old")
                print("SessionManager: Found file where directory expected at \(path), renaming to \(backupURL.path)")
                
                // Remove old backup if it exists
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.removeItem(at: backupURL)
                }
                
                // Rename the file
                try fileManager.moveItem(at: url, to: backupURL)
            }
        }
        
        // Now create the directory
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
    
    /// Save settings to shared storage for a user
    /// - Returns: true if successful, false if failed (e.g., server unavailable)
    private func saveSettingsToSharedStorage(profile: WorkspaceProfile) async -> Bool {
        guard let username = profile.username else {
            print("SessionManager: Cannot save to shared storage - no username")
            return false
        }
        
        guard let sharedCacheURL = profile.settings.sharedCacheURL, !sharedCacheURL.isEmpty else {
            print("SessionManager: No shared cache URL configured, skipping sync")
            return false
        }
        
        // Use MediaDash_Cache as base directory, with Settings as subdirectory
        let cacheBaseURL = URL(fileURLWithPath: sharedCacheURL)
        let settingsDirURL = cacheBaseURL.appendingPathComponent("MediaDash_Settings")
        let settingsFile = settingsDirURL.appendingPathComponent("\(username).json")
        
        let fileManager = FileManager.default
        let settingsURL = settingsFile
        
        // Check if the base path exists (server mounted)
        guard fileManager.fileExists(atPath: sharedCacheURL) else {
            print("SessionManager: Shared storage path not available: \(sharedCacheURL)")
            return false
        }
        
        // Create settings directory if it doesn't exist (safely handle file conflicts)
        do {
            try safeCreateDirectory(at: settingsDirURL, fileManager: fileManager)
        } catch {
            print("SessionManager: Failed to create settings directory: \(error.localizedDescription)")
            return false
        }
        
        // Save settings to file
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile.settings)
            try data.write(to: settingsURL)
            print("SessionManager: Successfully saved settings to \(settingsFile)")
            return true
        } catch {
            print("SessionManager: Failed to save settings to shared storage: \(error.localizedDescription)")
            return false
        }
    }
}
