import Foundation

/// Minimum size (bytes) for a ZIP to count as archived. Smaller files are likely failed/truncated downloads and are excluded so the project stays "Not archived".
private let kMinValidArchiveSizeBytes: Int64 = 1024 * 1024 // 1 MB

/// Scans GM year folders' DATA BACKUPS for Simian archive ZIPs and reports which project IDs are already archived.
/// Archive filenames follow: `{sanitizedProjectName}_{projectId}.zip`
/// ZIPs smaller than kMinValidArchiveSizeBytes are ignored (incomplete/error downloads).
struct SimianArchiveComparisonService {

    let serverBasePath: String
    let yearPrefix: String

    /// DATA BACKUPS folder name patterns per year (e.g. "2026_DATA BACKUPS", "2024 DATA BACKUPS", "2023_DATA_BACKUPS")
    private func dataBackupsFolderNames(for year: Int) -> [String] {
        [
            "\(year)_DATA BACKUPS",
            "\(year) DATA BACKUPS",
            "\(year)_DATA_BACKUPS"
        ]
    }

    /// Preferred folder name for writing (matches MediaManager / standard).
    private static func preferredDataBackupsFolderName(for year: Int) -> String {
        "\(year)_DATA BACKUPS"
    }

    /// Whether the GM server base path is reachable (volume mounted).
    func isServerAvailable() -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: serverBasePath, isDirectory: &isDir) && isDir.boolValue
    }

    /// DATA BACKUPS folder URL for a given year. Creates year folder and DATA BACKUPS folder if needed. Returns nil if server unavailable or creation fails.
    func dataBackupsURL(for year: Int) -> URL? {
        guard isServerAvailable() else { return nil }
        let base = URL(fileURLWithPath: serverBasePath)
        let yearDir = base.appendingPathComponent("\(yearPrefix)\(year)")
        let folderName = Self.preferredDataBackupsFolderName(for: year)
        let backupsURL = yearDir.appendingPathComponent(folderName)
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: yearDir.path) {
                try fm.createDirectory(at: yearDir, withIntermediateDirectories: true, attributes: nil)
            }
            if !fm.fileExists(atPath: backupsURL.path) {
                try fm.createDirectory(at: backupsURL, withIntermediateDirectories: true, attributes: nil)
            }
            return backupsURL
        } catch {
            return nil
        }
    }

    /// All DATA BACKUPS directory URLs under the GM root (one per year folder that has a DATA BACKUPS).
    func dataBackupsURLs() -> [URL] {
        let base = URL(fileURLWithPath: serverBasePath)
        let fm = FileManager.default
        var result: [URL] = []
        guard let yearDirs = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return result }

        for yearDir in yearDirs {
            let name = yearDir.lastPathComponent
            guard name.hasPrefix(yearPrefix),
                  name.count >= 4,
                  let year = Int(name.suffix(4)),
                  year >= 2000, year <= 2100 else { continue }
            for folderName in dataBackupsFolderNames(for: year) {
                let backupsURL = yearDir.appendingPathComponent(folderName)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: backupsURL.path, isDirectory: &isDir), isDir.boolValue {
                    result.append(backupsURL)
                    break
                }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Scan all DATA BACKUPS folders for Simian ZIPs and return the set of project IDs that have an archive.
    /// ZIPs are named `{sanitizedProjectName}_{projectId}.zip`; we extract the project ID as the suffix after the last `_` before `.zip`.
    func scanArchivedProjectIds() -> (archivedIds: Set<String>, locations: [String: [URL]]) {
        var archivedIds = Set<String>()
        var locations: [String: [URL]] = [:]
        let fm = FileManager.default

        for backupsURL in dataBackupsURLs() {
            guard let contents = try? fm.contentsOfDirectory(
                at: backupsURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for fileURL in contents {
                let name = fileURL.lastPathComponent
                guard name.lowercased().hasSuffix(".zip") else { continue }
                let baseName = String(name.dropLast(4)) // strip .zip
                guard let lastUnderscore = baseName.lastIndex(of: "_") else { continue }
                let projectId = String(baseName[baseName.index(after: lastUnderscore)...])
                guard !projectId.isEmpty, projectId.allSatisfy(\.isNumber) else { continue }

                let fileSize: Int64? = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
                if let size = fileSize, size < kMinValidArchiveSizeBytes {
                    continue // Skip tiny/corrupt archives so project is not marked archived
                }
                archivedIds.insert(projectId)
                locations[projectId, default: []].append(fileURL)
            }
        }
        return (archivedIds, locations)
    }
}
