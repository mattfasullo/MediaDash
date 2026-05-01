import Foundation

/// Tracks Simian project IDs the user opened in MediaDash, newest-first, per workspace profile (`WorkspaceProfile.id`).
enum SimianRecentProjectsStore {
    private static let defaults = UserDefaults.standard
    private static let keyPrefix = "simianRecentOpenedProjectIds"
    private static let maxStored = 100

    private static func storageKey(profileId: UUID) -> String {
        "\(keyPrefix).\(profileId.uuidString)"
    }

    static func orderedIds(for profileId: UUID) -> [String] {
        defaults.stringArray(forKey: storageKey(profileId: profileId)) ?? []
    }

    static func recordOpen(profileId: UUID, projectId: String) {
        guard !projectId.isEmpty else { return }
        var ids = orderedIds(for: profileId)
        ids.removeAll { $0 == projectId }
        ids.insert(projectId, at: 0)
        if ids.count > maxStored {
            ids = Array(ids.prefix(maxStored))
        }
        defaults.set(ids, forKey: storageKey(profileId: profileId))
    }
}
