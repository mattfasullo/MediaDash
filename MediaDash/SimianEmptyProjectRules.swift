//
//  SimianEmptyProjectRules.swift
//  MediaDash
//
//  Pure rules for empty Simian jobs in the archiver (not @MainActor — safe for tests and background use).
//

import Foundation

enum SimianEmptyProjectRules {
    /// Simian lists an empty job as a small shell, usually about 33 KB. At or under 64 KB counts as empty.
    nonisolated static let maxEmptyBytes: Int64 = 64 * 1024

    nonisolated static let unarchivedEmptyDeletionNote = "Empty projects in this list were last accessed more than 3 months ago."

    nonisolated static func isEmpty(reportedSizeBytes: Int64?) -> Bool {
        guard let reportedSizeBytes else { return false }
        return reportedSizeBytes <= maxEmptyBytes
    }

    /// Archived jobs can be deleted as they are today. An empty job can be deleted when its last access is more than 3 months ago.
    nonisolated static func isDeletable(
        isArchived: Bool,
        reportedSizeBytes: Int64?,
        lastAccess: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        if isArchived { return true }
        guard isEmpty(reportedSizeBytes: reportedSizeBytes), let lastAccess else { return false }
        guard let cutoff = calendar.date(byAdding: .month, value: -3, to: now) else { return false }
        return lastAccess < cutoff
    }

    nonisolated static func partitionForArchive(
        _ projects: [SimianProject],
        reportedSizeBytesById: [String: Int64]
    ) -> (toArchive: [SimianProject], skippedEmpty: [SimianProject]) {
        var toArchive: [SimianProject] = []
        var skippedEmpty: [SimianProject] = []
        for project in projects {
            if isEmpty(reportedSizeBytes: reportedSizeBytesById[project.id]) {
                skippedEmpty.append(project)
            } else {
                toArchive.append(project)
            }
        }
        return (toArchive, skippedEmpty)
    }

    /// Highlighted jobs that can be deleted. A click outside the selection deletes only that job, when it qualifies.
    nonisolated static func deletionTargets(
        clicked: SimianProject,
        isClickedSelected: Bool,
        displayedProjects: [SimianProject],
        selectedIds: Set<String>,
        deletableIds: Set<String>
    ) -> [SimianProject] {
        if isClickedSelected {
            return displayedProjects.filter { selectedIds.contains($0.id) && deletableIds.contains($0.id) }
        }
        return deletableIds.contains(clicked.id) ? [clicked] : []
    }

    nonisolated static func nothingToDownloadMessage(skippedEmptyCount: Int) -> String {
        "Skipped \(skippedEmptyCount) empty \(projectWord(skippedEmptyCount)). Nothing to download."
    }

    nonisolated static func appendingSkippedEmpty(_ message: String, count: Int) -> String {
        guard count > 0 else { return message }
        return "\(message) Skipped \(count) empty \(projectWord(count))."
    }

    private nonisolated static func projectWord(_ count: Int) -> String {
        count == 1 ? "project" : "projects"
    }
}

/// Projects that stay on Simian. They are omitted from the archiver list, so they cannot be archived or deleted from here.
enum SimianArchiverExclusions {
    nonisolated static let unarchiveProjectName = "Misc/UNARCHIVE_Delete Every 3 Months"

    nonisolated static func isHidden(_ project: SimianProject) -> Bool {
        hiddenIds.contains(project.id) || hiddenNames.contains(project.name)
    }

    /// 91 and 459 were already hidden. 332 and 348 are the Tom Westin and SizzleReel exceptions.
    private nonisolated static let hiddenIds: Set<String> = ["91", "459", "332", "348"]

    private nonisolated static let hiddenNames: Set<String> = [
        unarchiveProjectName,
        "2xxxx_Tom Westin_Jazz_VN_Do Not Delete",
        "24xxx_SizzleReel"
    ]
}

/// Top-level folders in the permanent UNARCHIVE project. The project stays. A top-level folder uploaded more than 3 months ago is removed, contents included. Nested folders are not checked on their own.
enum SimianUnarchiveCleanup {
    struct Folder {
        let id: String
        let name: String
        let uploadedAt: Date?
    }

    struct DueFolder: Identifiable, Hashable {
        let id: String
        let name: String
        let uploadedAt: Date
    }

    struct RemovalPlan {
        let due: [DueFolder]
        let undatedCount: Int
    }

    nonisolated static func isOlderThanThreeMonths(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let cutoff = calendar.date(byAdding: .month, value: -3, to: now) else { return false }
        return date < cutoff
    }

    /// Stand-in for when a top-level folder was created: the earliest upload date among files directly inside it.
    nonisolated static func createdAt(fromFileUploadDates dates: [Date]) -> Date? {
        dates.min()
    }

    /// Only the folders passed in are considered. Callers pass the project root.
    nonisolated static func removalPlan(_ topLevelFolders: [Folder], now: Date, calendar: Calendar = .current) -> RemovalPlan {
        var due: [DueFolder] = []
        var undatedCount = 0
        for folder in topLevelFolders {
            if let uploadedAt = folder.uploadedAt, isOlderThanThreeMonths(uploadedAt, now: now, calendar: calendar) {
                due.append(DueFolder(id: folder.id, name: folder.name, uploadedAt: uploadedAt))
            } else if folder.uploadedAt == nil {
                undatedCount += 1
            }
        }
        return RemovalPlan(due: due, undatedCount: undatedCount)
    }
}
