import Foundation
import Combine
import SwiftUI

/// Service for detecting new dockets from Asana projects that don't yet exist in Work Picture or Simian.
/// Only considers projects created within the last 2 weeks.
@MainActor
class AsanaDocketScanningService: ObservableObject {
    @Published var isScanning = false
    @Published var lastScanTime: Date?
    @Published var lastError: String?
    @Published var scanResultMessage: String?

    weak var settingsManager: SettingsManager?
    weak var notificationCenter: NotificationCenter?
    weak var mediaManager: MediaManager?
    weak var asanaCacheManager: AsanaCacheManager?
    var simianService: SimianService?

    private let twoWeeksInterval: TimeInterval = 14 * 24 * 60 * 60

    /// Scan Asana projects for new dockets created in the last 2 weeks that don't exist in Work Picture or Simian.
    func scanForNewDockets() async {
        guard !isScanning else { return }

        guard let settings = settingsManager?.currentSettings else {
            lastError = "Settings not available"
            return
        }

        guard let cacheManager = asanaCacheManager else {
            lastError = "Asana cache not available"
            return
        }

        guard cacheManager.service.isAuthenticated else {
            lastError = "Asana is not authenticated"
            return
        }

        // Resolve workspace: use Settings if set, otherwise fetch workspaces via OAuth and use the first (same as rest of app).
        let workspaceID: String
        let raw = settings.asanaWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty {
            workspaceID = raw
        } else {
            do {
                let workspaces = try await cacheManager.service.fetchWorkspaces()
                guard let first = workspaces.first else {
                    lastError = "No Asana workspaces found"
                    return
                }
                workspaceID = first.gid
            } catch {
                lastError = "Could not load workspaces: \(error.localizedDescription)"
                return
            }
        }

        isScanning = true
        lastError = nil
        scanResultMessage = nil

        defer { isScanning = false }

        do {
            let projects = try await cacheManager.service.fetchProjects(workspaceID: workspaceID)
            let cutoffDate = Date().addingTimeInterval(-twoWeeksInterval)

            let recentProjects = projects.filter { project in
                guard let createdAtStr = project.created_at else { return false }
                guard let createdAt = parseAsanaTimestamp(createdAtStr) else { return false }
                return createdAt >= cutoffDate
            }

            // Check Work Picture existence and build a set of docket numbers in Simian
            let simianDocketNumbers = await fetchSimianDocketNumbers()
            let config = AppConfig(settings: settings)

            var newDocketsFound = 0

            for project in recentProjects {
                guard let docketNumber = extractDocketNumber(from: project.name) else {
                    continue
                }

                let jobName = extractJobName(from: project.name, docketNumber: docketNumber)

                // Skip if notification already exists for this docket
                if notificationAlreadyExists(docketNumber: docketNumber, jobName: jobName) {
                    continue
                }

                let docketFolderName = "\(docketNumber)_\(jobName)"
                let existsInWorkPicture = config.findDocketYear(docket: docketFolderName) != nil
                let existsInSimian = simianDocketNumbers.contains(where: { $0.localizedCaseInsensitiveContains(docketNumber) })

                if !existsInWorkPicture && !existsInSimian {
                    let notification = Notification(
                        type: .newDocket,
                        title: "New Docket from Asana",
                        message: "Docket \(docketNumber): \(jobName)",
                        docketNumber: docketNumber,
                        jobName: jobName,
                        sourceEmail: project.owner?.name ?? "Asana"
                    )
                    notificationCenter?.add(notification)
                    newDocketsFound += 1
                }
            }

            lastScanTime = Date()

            if newDocketsFound > 0 {
                scanResultMessage = "Found \(newDocketsFound) new docket\(newDocketsFound == 1 ? "" : "s")"
            } else {
                scanResultMessage = "No new dockets found"
            }

            print("📋 [AsanaDocketScanner] Scanned \(recentProjects.count) recent projects, found \(newDocketsFound) new dockets")

        } catch {
            lastError = "Asana scan failed: \(error.localizedDescription)"
            print("❌ [AsanaDocketScanner] Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func notificationAlreadyExists(docketNumber: String, jobName: String) -> Bool {
        guard let center = notificationCenter else { return false }
        return center.notifications.contains { existing in
            existing.type == .newDocket &&
            existing.docketNumber == docketNumber
        }
    }

    private func fetchSimianDocketNumbers() async -> [String] {
        guard let simian = simianService,
              settingsManager?.currentSettings.simianEnabled == true else {
            return []
        }
        do {
            let projects = try await simian.getProjectList()
            return projects.map { $0.name }
        } catch {
            print("⚠️ [AsanaDocketScanner] Could not fetch Simian projects: \(error.localizedDescription)")
            return []
        }
    }

    private func extractDocketNumber(from name: String) -> String? {
        let pattern = #"\d{5}(?:-[A-Z]{1,3})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range, in: name) else {
            return nil
        }
        return String(name[range])
    }

    private func extractJobName(from name: String, docketNumber: String) -> String {
        var cleaned = name

        // Remove the docket number portion (e.g., "26042-US Some Job Name" → "Some Job Name")
        if let range = cleaned.range(of: docketNumber) {
            cleaned = String(cleaned[range.upperBound...])
        }

        // Remove common separators at the start
        cleaned = cleaned.replacingOccurrences(of: #"^[\s\-–_:]+"#, with: "", options: .regularExpression)

        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    private func parseAsanaTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
}
