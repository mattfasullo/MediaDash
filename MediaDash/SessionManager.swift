import Foundation
import SwiftUI
import Combine

// MARK: - Profile Model

struct WorkspaceProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var settings: AppSettings
    var createdAt: Date
    var lastAccessedAt: Date

    init(id: UUID = UUID(), name: String, settings: AppSettings) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = Date()
        self.lastAccessedAt = Date()
    }

    // Preset for Grayson Music workspace
    static func graysonMusic() -> WorkspaceProfile {
        var settings = AppSettings.default
        settings.sessionsBasePath = "/Volumes/Grayson Assets/SESSIONS"
        settings.serverBasePath = "/Volumes/Grayson Assets"

        return WorkspaceProfile(
            name: "Grayson Music",
            settings: settings
        )
    }

    // Create a local workspace with default settings
    static func local(name: String) -> WorkspaceProfile {
        return WorkspaceProfile(
            name: name,
            settings: AppSettings.default
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

    private let lastProfileIDKey = "lastActiveProfileID"
    private let profilesKey = "workspaceProfiles"

    init() {
        loadLastSession()
    }

    // Load the last active session from UserDefaults
    private func loadLastSession() {
        guard let profileIDString = UserDefaults.standard.string(forKey: lastProfileIDKey),
              let profileID = UUID(uuidString: profileIDString),
              let profile = loadProfile(id: profileID) else {
            authenticationState = .loggedOut
            return
        }

        var updatedProfile = profile
        updatedProfile.lastAccessedAt = Date()
        saveProfile(updatedProfile)

        authenticationState = .loggedIn(updatedProfile)
        print("SessionManager: Restored session for workspace '\(profile.name)'")
    }

    // Authenticate with cloud workspace (simulated)
    func authenticateCloud(username: String, password: String) -> Bool {
        // Simulated cloud authentication
        if username.lowercased() == "graysonmusic" && password == "gr@ys00n" {
            let profile = WorkspaceProfile.graysonMusic()
            login(with: profile)
            return true
        }
        return false
    }

    // Create a local workspace
    func createLocalWorkspace(name: String) {
        let profile = WorkspaceProfile.local(name: name)
        login(with: profile)
    }

    // Log in with a profile
    func login(with profile: WorkspaceProfile) {
        var updatedProfile = profile
        updatedProfile.lastAccessedAt = Date()

        saveProfile(updatedProfile)
        UserDefaults.standard.set(updatedProfile.id.uuidString, forKey: lastProfileIDKey)

        authenticationState = .loggedIn(updatedProfile)
        print("SessionManager: Logged in to workspace '\(profile.name)'")
    }

    // Log out
    func logout() {
        UserDefaults.standard.removeObject(forKey: lastProfileIDKey)
        authenticationState = .loggedOut
        print("SessionManager: Logged out")
    }

    // Update the current profile's settings
    func updateProfile(settings: AppSettings) {
        guard case .loggedIn(var profile) = authenticationState else { return }

        profile.settings = settings
        profile.lastAccessedAt = Date()

        saveProfile(profile)
        authenticationState = .loggedIn(profile)
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
}
