import Foundation
import AppKit
import Combine
import AVFoundation

// --- CONFIGURATION (Strictly Non-Isolated) ---
struct AppConfig: Sendable {
    let settings: AppSettings
    
    /// Centralized folder naming and date formatting service
    nonisolated var namingService: FolderNamingService {
        FolderNamingService(settings: settings)
    }

    nonisolated init(settings: AppSettings) {
        self.settings = settings
    }

    /// Ensure the year folder structure exists, creating it if needed
    nonisolated func ensureYearFolderStructure() throws {
        let year = Calendar.current.component(.year, from: Date())
        let serverBase = URL(fileURLWithPath: settings.serverBasePath)
        let yearFolder = serverBase.appendingPathComponent("\(settings.yearPrefix)\(year)")
        
        let fm = FileManager.default
        
        // Check if server base exists
        guard fm.fileExists(atPath: serverBase.path) else {
            throw AppError.fileSystem(.directoryNotFound(serverBase.path))
        }
        
        // Create year folder if it doesn't exist
        if !fm.fileExists(atPath: yearFolder.path) {
            try fm.createDirectory(at: yearFolder, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Define all required subfolders for the year
        let subfolders = [
            "\(year)_DATA BACKUPS",
            "\(year)_MUSIC DEMOS",
            "\(year)_MUSIC LAYUPS",
            "\(year)_\(settings.prepFolderName)",  // SESSION PREP
            "\(year)_SFX INTERNAL",
            "\(year)_WORK PICTURE"  // This might be different from workPictureFolderName, but we'll create both
        ]
        
        // Create all subfolders
        for subfolder in subfolders {
            let subfolderPath = yearFolder.appendingPathComponent(subfolder)
            if !fm.fileExists(atPath: subfolderPath.path) {
                try fm.createDirectory(at: subfolderPath, withIntermediateDirectories: true, attributes: nil)
            }
        }
        
        // Also ensure the work picture folder exists (in case the folder name differs)
        let workPicPath = yearFolder.appendingPathComponent("\(year)_\(settings.workPictureFolderName)")
        if !fm.fileExists(atPath: workPicPath.path) {
            try fm.createDirectory(at: workPicPath, withIntermediateDirectories: true, attributes: nil)
        }
    }

    nonisolated func getPaths() -> (workPic: URL, prep: URL) {
        let year = Calendar.current.component(.year, from: Date())
        let serverRoot = URL(fileURLWithPath: settings.serverBasePath)
            .appendingPathComponent("\(settings.yearPrefix)\(year)")
        let wp = serverRoot.appendingPathComponent("\(year)_\(settings.workPictureFolderName)")
        let prep = serverRoot.appendingPathComponent("\(year)_\(settings.prepFolderName)")
        
        // Ensure year folder structure exists (create if needed)
        do {
            try ensureYearFolderStructure()
        } catch {
            // Log error but don't fail - let the caller handle missing folders
        }
        
        return (wp, prep)
    }
    
    /// Get the work picture path for a specific year
    nonisolated func getWorkPicPath(for year: Int) -> URL {
        let serverRoot = URL(fileURLWithPath: settings.serverBasePath)
            .appendingPathComponent("\(settings.yearPrefix)\(year)")
        return serverRoot.appendingPathComponent("\(year)_\(settings.workPictureFolderName)")
    }

    /// Root URL for Music Demos for a given year (e.g. …/GM_2026/2026_MUSIC DEMOS).
    nonisolated func getMusicDemosRoot(for year: Int) -> URL {
        let serverRoot = URL(fileURLWithPath: settings.serverBasePath)
            .appendingPathComponent("\(settings.yearPrefix)\(year)")
        return serverRoot.appendingPathComponent("\(year)_MUSIC DEMOS")
    }

    /// Build prep folder name using format string from settings
    /// Uses FolderNamingService for consistent formatting
    nonisolated func prepFolderName(docket: String, date: Date) -> String {
        return namingService.prepFolderName(docket: docket, date: date)
    }

    /// Date part only for demos folder name (now uses standard format)
    nonisolated func demosDatePartFormat() -> String {
        return namingService.demosDatePartFormat()
    }

    /// Date folder name for demos (e.g. 01_Feb09.26). When creating new: prefix is sequence (01, 02, 03…), then date part.
    nonisolated func demosDateFolderName(for date: Date) -> String {
        // For backward compatibility, use sequence 01 if no existing folders
        return namingService.demosDateFolderName(sequenceNumber: 1, date: date)
    }

    /// Next demos date folder name for a docket: next sequence number (01, 02, 03…) + "_" + date part (e.g. Feb09.26).
    nonisolated func nextDemosDateFolderName(docketPath: URL, date: Date) -> String {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: docketPath, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return namingService.demosDateFolderName(sequenceNumber: 1, date: date)
        }
        var maxSeq = 0
        for url in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent
            if let underscoreIdx = name.firstIndex(of: "_") {
                let prefix = String(name[..<underscoreIdx])
                if let n = Int(prefix), n > 0 { maxSeq = max(maxSeq, n) }
            }
        }
        let nextSeq = maxSeq + 1
        return namingService.demosDateFolderName(sequenceNumber: nextSeq, date: date)
    }

    /// URL for the demos date folder for a docket (e.g. …/2026_MUSIC DEMOS/26014_Coors/01_Feb.9.26).
    /// Prefers an existing date folder in the docket; only creates a new one when none exist, using next sequence (01, 02, 03…).
    nonisolated func getOrCreateDemosDateFolder(docketFolderName: String, date: Date) throws -> URL {
        try ensureYearFolderStructure()
        let year = Calendar.current.component(.year, from: date)
        let root = getMusicDemosRoot(for: year)
        let docketPath = root.appendingPathComponent(docketFolderName)
        let fm = FileManager.default
        if !fm.fileExists(atPath: docketPath.path) {
            try fm.createDirectory(at: docketPath, withIntermediateDirectories: true, attributes: nil)
        }
        // See if the docket already has any date folders (e.g. 01_Feb.9.26) – use the most recent one instead of creating
        if let existingSubdirs = try? fm.contentsOfDirectory(at: docketPath, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            let dateFolders = existingSubdirs.filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            if !dateFolders.isEmpty {
                let best = dateFolders.max(by: { a, b in
                    let tA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let tB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return tA < tB
                })
                if let use = best { return use }
            }
        }
        // No existing date folder – create one with next sequence number (01, 02, 03…) + date part
        let dateName = nextDemosDateFolderName(docketPath: docketPath, date: date)
        let datePath = docketPath.appendingPathComponent(dateName)
        if !fm.fileExists(atPath: datePath.path) {
            try fm.createDirectory(at: datePath, withIntermediateDirectories: true, attributes: nil)
        }
        return datePath
    }
    
    /// Find which year a docket folder exists in (searches across all years)
    nonisolated func findDocketYear(docket: String) -> Int? {
        let fm = FileManager.default
        let serverBase = URL(fileURLWithPath: settings.serverBasePath)
        
        // Check if server base exists
        guard fm.fileExists(atPath: serverBase.path) else {
            return nil
        }
        
        // Get all year folders
        guard let yearFolders = try? fm.contentsOfDirectory(at: serverBase, includingPropertiesForKeys: nil) else {
            return nil
        }
        
        // Search through each year folder
        for yearFolder in yearFolders where yearFolder.lastPathComponent.hasPrefix(settings.yearPrefix) {
            // Extract year from folder name (e.g., "GM_2025" -> 2025)
            let yearString = yearFolder.lastPathComponent.replacingOccurrences(of: settings.yearPrefix, with: "")
            guard let year = Int(yearString) else {
                continue
            }
            
            // Check if docket exists in this year's work picture folder
            let workPicPath = yearFolder.appendingPathComponent("\(year)_\(settings.workPictureFolderName)")
            let docketPath = workPicPath.appendingPathComponent(docket)
            
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: docketPath.path, isDirectory: &isDir) && isDir.boolValue {
                // #region agent log
                do {
                    let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "AppConfig.findDocketYear", "message": "findDocketYear FOUND", "data": ["docket": docket, "year": year, "docketPath": docketPath.path, "serverBase": settings.serverBasePath], "sessionId": "debug-session", "hypothesisId": "H1"]
                    let d = try JSONSerialization.data(withJSONObject: payload)
                    let line = String(data: d, encoding: .utf8)! + "\n"
                    let path = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug.log"
                    let url = URL(fileURLWithPath: path)
                    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
                    if let stream = OutputStream(url: url, append: true) {
                        stream.open()
                        _ = line.data(using: .utf8)!.withUnsafeBytes { stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: line.utf8.count) }
                        stream.close()
                    }
                } catch {}
                // #endregion
                return year
            }
        }
        
        return nil
    }

    nonisolated var sessionsBasePath: String {
        settings.sessionsBasePath
    }
}

enum JobType: String, Sendable, CaseIterable {
    case workPicture = "Work Picture"
    case prep = "Prep"
    case both = "Both"
}

enum FileCompletionState: Sendable {
    case none           // Not started
    case workPicDone    // Work Picture complete (for Both mode)
    case prepDone       // Prep complete (for Both mode)
    case complete       // Fully complete
}

struct FileItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileCount: Int // For directories, counts files recursively; for files, always 1
    let fileSize: Int64? // File size in bytes (nil for directories)

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = exists && isDir.boolValue

        if self.isDirectory {
            self.fileCount = Self.countFilesRecursively(in: url)
            self.fileSize = nil
        } else {
            self.fileCount = 1
            // Get file size
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int64 {
                self.fileSize = size
            } else {
                self.fileSize = nil
            }
        }
    }
    
    /// Display name (file name without extension for readability, or folder name)
    var displayName: String {
        if isDirectory {
            return name
        } else {
            // Return name without extension if it has one
            let baseName = url.deletingPathExtension().lastPathComponent
            return baseName.isEmpty ? name : baseName
        }
    }
    
    /// Formatted file size string (e.g., "1.2 MB", "350 KB")
    var formattedSize: String? {
        guard let size = fileSize else { return nil }
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    private static func countFilesRecursively(in directory: URL, maxFiles: Int = 10000) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let fileURL as URL in enumerator {
            // Bail early if we've counted enough files to prevent UI freeze
            if count >= maxFiles {
                return count
            }
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
               let isRegularFile = resourceValues.isRegularFile,
               isRegularFile {
                count += 1
            }
        }
        return count
    }

    /// Calculate total size of all files in a directory recursively
    static func calculateDirectorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               let isRegularFile = resourceValues.isRegularFile,
               isRegularFile,
               let fileSize = resourceValues.fileSize {
                totalSize += Int64(fileSize)
            }
        }
        return totalSize
    }
}

struct SearchResults: Sendable {
    let exactMatches: [String]
    let fuzzyMatches: [String]
}

// --- PURE LOGIC ---
enum MediaLogic {
    // Fuzzy matching helpers
    nonisolated static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1 = Array(s1)
        let s2 = Array(s2)
        var dist = [[Int]](repeating: [Int](repeating: 0, count: s2.count + 1), count: s1.count + 1)

        for i in 0...s1.count { dist[i][0] = i }
        for j in 0...s2.count { dist[0][j] = j }

        for i in 1...s1.count {
            for j in 1...s2.count {
                if s1[i-1] == s2[j-1] {
                    dist[i][j] = dist[i-1][j-1]
                } else {
                    dist[i][j] = min(dist[i-1][j], dist[i][j-1], dist[i-1][j-1]) + 1
                }
            }
        }

        return dist[s1.count][s2.count]
    }

    nonisolated static func fuzzyMatch(searchTerm: String, target: String, maxDistance: Int = 3) -> Bool {
        let search = searchTerm.lowercased()
        let targetLower = target.lowercased()

        // Exact substring match
        if targetLower.contains(search) { return true }

        // Remove spaces and compare
        let searchNoSpaces = search.replacingOccurrences(of: " ", with: "")
        let targetNoSpaces = targetLower.replacingOccurrences(of: " ", with: "")

        if targetNoSpaces.contains(searchNoSpaces) { return true }

        // Split target into words and check fuzzy match on each
        let words = targetLower.split(separator: " ").map { String($0) }
        for word in words {
            // More lenient length check - allow bigger differences
            let minLength = max(3, search.count - maxDistance - 1)
            if word.count >= minLength &&
               levenshteinDistance(search, word) <= maxDistance {
                return true
            }
            // Also check without spaces in the word
            let wordNoSpaces = word.replacingOccurrences(of: " ", with: "")
            if wordNoSpaces.count >= max(3, searchNoSpaces.count - maxDistance - 1) &&
               levenshteinDistance(searchNoSpaces, wordNoSpaces) <= maxDistance {
                return true
            }
        }

        // Also try matching against the entire target path (not just words)
        // This helps catch matches where words are concatenated differently
        if targetNoSpaces.count >= max(3, searchNoSpaces.count - maxDistance - 1) &&
           levenshteinDistance(searchNoSpaces, targetNoSpaces) <= maxDistance {
            return true
        }

        return false
    }

    nonisolated static func scanDockets(config: AppConfig, jobType: JobType = .workPicture) -> [String] {
        var results: [String] = []
        let fm = FileManager.default
        let serverBase = URL(fileURLWithPath: config.settings.serverBasePath)
        let yearPrefix = config.settings.yearPrefix
        
        // Check if server base exists
        guard fm.fileExists(atPath: serverBase.path) else {
            print("Error scanning dockets: Server base path does not exist: \(serverBase.path)")
            return results
        }
        
        // Work Picture: return full folder names (not just docket numbers), sorted by most recently modified
        if jobType == .workPicture {
            let workPictureFolderName = config.settings.workPictureFolderName
            var docketDates: [String: Date] = [:]
            
            // Get all year folders
            guard let yearFolders = try? fm.contentsOfDirectory(at: serverBase, includingPropertiesForKeys: nil) else {
                return results
            }
            
            // Scan each year folder
            for yearFolder in yearFolders where yearFolder.lastPathComponent.hasPrefix(yearPrefix) {
                let yearString = yearFolder.lastPathComponent.replacingOccurrences(of: yearPrefix, with: "")
                let workPicPath = yearFolder.appendingPathComponent("\(yearString)_\(workPictureFolderName)")
                
                // Check if this year's work picture folder exists
                guard fm.fileExists(atPath: workPicPath.path) else {
                    continue
                }
                
                // Scan docket folders in this year's work picture
                do {
                    let items = try fm.contentsOfDirectory(at: workPicPath, includingPropertiesForKeys: [.contentModificationDateKey])
                    for item in items {
                        if item.hasDirectoryPath && !item.lastPathComponent.hasPrefix(".") {
                            let folderName = item.lastPathComponent
                            let modDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                            if let existing = docketDates[folderName] {
                                if modDate > existing {
                                    docketDates[folderName] = modDate
                                }
                            } else {
                                docketDates[folderName] = modDate
                            }
                        }
                    }
                } catch {
                    // Continue to next year if this one fails
                    continue
                }
            }
            
            // Sort by most recently modified (newest first)
            results = docketDates
                .sorted { $0.value > $1.value }
                .map { $0.key }
        } else {
            // For prep mode, scan current year only (prep folders are year-specific)
            let paths = config.getPaths()
            let base = paths.prep
            
            guard fm.fileExists(atPath: base.path) else {
                return results
            }
            
            do {
                let items = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])
                for item in items {
                if item.hasDirectoryPath && !item.lastPathComponent.hasPrefix(".") {
                        // Prep folders are named like "12345_PREP_Dec4.24"
                        // Extract just "12345" part
                        let folderName = item.lastPathComponent
                        if let docketNumber = folderName.split(separator: "_").first {
                            let docketStr = String(docketNumber)
                            if !results.contains(docketStr) {
                                results.append(docketStr)
                            }
                    }
                }
            }
        } catch {
                print("Error scanning prep dockets: \(error.localizedDescription)")
            }
        }
        
        return results
    }
    
    nonisolated static func buildIndex(config: AppConfig, folder: SearchFolder = .sessions) -> [String] {
        var index: [String] = []
        let fm = FileManager.default

        switch folder {
        case .sessions:
            let base = URL(fileURLWithPath: config.sessionsBasePath)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: base.path, isDirectory: &isDir) {
                do {
                    let contents = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                    let years = contents.filter {
                        $0.lastPathComponent.uppercased().contains("_PROTOOLS SESSIONS") ||
                        $0.lastPathComponent.uppercased().contains("PROTOOLS")
                    }
                    for year in years {
                        if let sessions = try? fm.contentsOfDirectory(at: year, includingPropertiesForKeys: nil) {
                            for sess in sessions {
                                if sess.hasDirectoryPath && !sess.lastPathComponent.hasPrefix(".") {
                                    index.append(sess.path)
                                }
                            }
                        }
                    }
                } catch {
                    print("Error building session index: \(error.localizedDescription)")
                }
            }

        case .workPicture:
            // Dynamically find all Work Picture folders across years
            let serverBase = URL(fileURLWithPath: config.settings.serverBasePath)
            let yearPrefix = config.settings.yearPrefix
            let workPictureFolderName = config.settings.workPictureFolderName
            
            if let yearFolders = try? fm.contentsOfDirectory(at: serverBase, includingPropertiesForKeys: nil) {
                for yearFolder in yearFolders where yearFolder.lastPathComponent.hasPrefix(yearPrefix) {
                    // Extract year from folder name (e.g., "GM_2024" -> "2024")
                    let yearString = yearFolder.lastPathComponent.replacingOccurrences(of: yearPrefix, with: "")
                    let workPicPath = yearFolder.appendingPathComponent("\(yearString)_\(workPictureFolderName)")
                    if fm.fileExists(atPath: workPicPath.path) {
                        if let sessions = try? fm.contentsOfDirectory(at: workPicPath, includingPropertiesForKeys: nil) {
                            for sess in sessions {
                                if sess.hasDirectoryPath && !sess.lastPathComponent.hasPrefix(".") {
                                    index.append(sess.path)
                                }
                            }
                        }
                    }
                }
            }

        case .mediaPostings:
            let baseMedia = URL(fileURLWithPath: "/Volumes/Grayson Assets/MEDIA/MEDIA POSTINGS")
            if fm.fileExists(atPath: baseMedia.path) {
                if let yearFolders = try? fm.contentsOfDirectory(at: baseMedia, includingPropertiesForKeys: nil) {
                    for yearFolder in yearFolders {
                        if yearFolder.hasDirectoryPath && !yearFolder.lastPathComponent.hasPrefix(".") {
                            // Index folders within each year folder
                            if let sessions = try? fm.contentsOfDirectory(at: yearFolder, includingPropertiesForKeys: nil) {
                                for sess in sessions {
                                    if sess.hasDirectoryPath && !sess.lastPathComponent.hasPrefix(".") {
                                        index.append(sess.path)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return index
    }
    
    nonisolated static func getAllFiles(at url: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                if let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    for item in contents {
                        results.append(contentsOf: getAllFiles(at: item))
                    }
                }
            } else {
                results.append(url)
            }
        }
        return results
    }

    nonisolated static func applyPrepChecklistAssignments(
        session: PrepChecklistSession,
        root: URL,
        stagedFiles: [FileItem]
    ) {
        let fileById = Dictionary(uniqueKeysWithValues: stagedFiles.map { ($0.id, $0) })
        let checklistRoot = root.appendingPathComponent("CHECKLIST")
        let fm = FileManager.default

        if !fm.fileExists(atPath: checklistRoot.path) {
            try? fm.createDirectory(at: checklistRoot, withIntermediateDirectories: true)
        }

        for item in session.items {
            let assigned = item.assignedFileIds.compactMap { fileById[$0] }
            guard !assigned.isEmpty else { continue }

            let folderName = sanitizeChecklistFolderName(item.title)
            let itemFolder = checklistRoot.appendingPathComponent(folderName)
            if !fm.fileExists(atPath: itemFolder.path) {
                try? fm.createDirectory(at: itemFolder, withIntermediateDirectories: true)
            }

            for file in assigned {
                let flatFiles = getAllFiles(at: file.url)
                for flatFile in flatFiles {
                    let destFile = itemFolder.appendingPathComponent(flatFile.lastPathComponent)
                    if fm.fileExists(atPath: destFile.path) {
                        continue
                    }
                    try? fm.copyItem(at: flatFile, to: destFile)
                }
            }
        }
    }

    private nonisolated static func sanitizeChecklistFolderName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        var sanitized = name.components(separatedBy: invalid).joined(separator: "_")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty {
            sanitized = "ChecklistItem"
        }
        if sanitized.count > 80 {
            sanitized = String(sanitized.prefix(80))
        }
        return sanitized
    }

    // MARK: - Prep Summary Generation

    /// Get video duration in seconds
    nonisolated static func getVideoDuration(_ url: URL) async -> TimeInterval? {
        let asset = AVAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        guard duration.isValid && !duration.isIndefinite else { return nil }
        return CMTimeGetSeconds(duration)
    }

    /// Format duration as :SS or M:SS or MM:SS
    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        // Round to nearest standard duration
        let roundedSeconds = roundToStandardDuration(seconds)
        let totalSeconds = Int(roundedSeconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60

        if minutes == 0 {
            return String(format: ":%02d", secs)
        } else if minutes < 60 {
            return String(format: "%d:%02d", minutes, secs)
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
    }

    /// Round duration to nearest standard value (:06, :15, :20, :30, 1:00, etc.)
    nonisolated static func roundToStandardDuration(_ seconds: TimeInterval) -> TimeInterval {
        let standardDurations: [TimeInterval] = [
            6, 15, 20, 30,      // Under 1 minute
            60, 90, 120, 150,   // 1:00 to 2:30
            180, 210, 240, 270, // 3:00 to 4:30
            300, 330, 360, 390, // 5:00 to 6:30
            420, 450, 480, 510, // 7:00 to 8:30
            540, 570, 600       // 9:00 to 10:00
        ]

        // For durations over 10 minutes, round to nearest 30 seconds
        if seconds > 600 {
            return (seconds / 30).rounded() * 30
        }

        // Find closest standard duration
        var closestDuration = standardDurations[0]
        var smallestDiff = abs(seconds - closestDuration)

        for duration in standardDurations {
            let diff = abs(seconds - duration)
            if diff < smallestDiff {
                smallestDiff = diff
                closestDuration = duration
            }
        }

        return closestDuration
    }

    /// Check if filename contains stem keywords
    nonisolated static func isStemFile(_ filename: String) -> Bool {
        let stemKeywords = ["vocal", "instrumental", "drum", "percussion", "bass", "guitar",
                           "piano", "strings", "brass", "synth", "pad", "lead", "stem"]
        let lowercased = filename.lowercased()
        return stemKeywords.contains { lowercased.contains($0) }
    }

    /// Extract track name from stem filename (remove stem keyword suffix)
    nonisolated static func extractTrackName(_ filename: String) -> String {
        let stemKeywords = ["vocal", "instrumental", "drum", "percussion", "bass", "guitar",
                           "piano", "strings", "brass", "synth", "pad", "lead", "stem"]
        var name = (filename as NSString).deletingPathExtension
        let lowercased = name.lowercased()

        // Remove stem keywords from the end
        for keyword in stemKeywords {
            if lowercased.hasSuffix(keyword) {
                name = String(name.dropLast(keyword.count)).trimmingCharacters(in: .whitespaces)
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
                break
            }
        }
        return name
    }

    /// Generate prep summary text
    nonisolated static func generatePrepSummary(docket: String, jobName: String, prepFolderPath: String, config: AppConfig) async -> String {
        let fm = FileManager.default
        let prepURL = URL(fileURLWithPath: prepFolderPath)
        var summary = "\(docket) - \(jobName)\n\n"

        guard fm.fileExists(atPath: prepFolderPath) else {
            return summary + "Prep folder not found."
        }

        // PICTURE
        let picturePath = prepURL.appendingPathComponent(config.settings.pictureFolderName)
        if fm.fileExists(atPath: picturePath.path) {
            // Exclude z_unconverted folder and its contents from video count
            let unconvertedPath = picturePath.appendingPathComponent("z_unconverted")
            let videoFiles = (try? fm.contentsOfDirectory(at: picturePath, includingPropertiesForKeys: nil))?.filter {
                // Exclude directories (like z_unconverted) and files in z_unconverted
                !$0.hasDirectoryPath && 
                config.settings.pictureExtensions.contains($0.pathExtension.lowercased()) &&
                !$0.path.hasPrefix(unconvertedPath.path)
            } ?? []

            if !videoFiles.isEmpty {
                var durationGroups: [String: Int] = [:]
                // Process videos with limited concurrency (max 3 at a time) to avoid overwhelming the system
                await withTaskGroup(of: (String, Int)?.self) { group in
                    for video in videoFiles {
                        group.addTask {
                            guard let duration = await getVideoDuration(video) else { return nil }
                            let formatted = formatDuration(duration)
                            return (formatted, 1)
                        }
                    }
                    
                    // Collect results as they complete
                    for await result in group {
                        if let (formatted, count) = result {
                            durationGroups[formatted, default: 0] += count
                        }
                    }
                }

                let durationText = durationGroups.sorted { $0.key < $1.key }
                    .map { "\($0.value) x \($0.key)" }
                    .joined(separator: ", ")

                summary += "PICTURE - \(durationText) prepped\n"
            }
        }

        // OMF/AAF
        let aafOmfPath = prepURL.appendingPathComponent(config.settings.aafOmfFolderName)
        if fm.fileExists(atPath: aafOmfPath.path) {
            let aafOmfFiles = (try? fm.contentsOfDirectory(at: aafOmfPath, includingPropertiesForKeys: nil))?.filter {
                config.settings.aafOmfExtensions.contains($0.pathExtension.lowercased())
            } ?? []

            if !aafOmfFiles.isEmpty {
                var types: [String] = []
                if aafOmfFiles.contains(where: { $0.pathExtension.lowercased() == "aaf" }) {
                    types.append("AAF")
                }
                if aafOmfFiles.contains(where: { $0.pathExtension.lowercased() == "omf" }) {
                    types.append("OMF")
                }
                let typeText = types.isEmpty ? "AAF/OMF" : types.joined(separator: "/")
                summary += "\(typeText) - Tested & prepped\n"
            }
        }

        // MUSIC
        let musicPath = prepURL.appendingPathComponent(config.settings.musicFolderName)
        if fm.fileExists(atPath: musicPath.path) {
            let musicFiles = (try? fm.contentsOfDirectory(at: musicPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.filter {
                !$0.hasDirectoryPath && config.settings.musicExtensions.contains($0.pathExtension.lowercased())
            } ?? []

            if !musicFiles.isEmpty {
                summary += "MUSIC\n"
                for file in musicFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = (file.lastPathComponent as NSString).deletingPathExtension
                    summary += "  - \(name) prepped\n"
                }
            }

            // Check for stems folders
            let folders = (try? fm.contentsOfDirectory(at: musicPath, includingPropertiesForKeys: nil))?.filter {
                $0.hasDirectoryPath && $0.lastPathComponent.uppercased().contains("STEM")
            } ?? []

            if !folders.isEmpty {
                for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    summary += "  - \(folder.lastPathComponent) prepped\n"
                }
            }
        }

        // SFX
        let sfxPath = prepURL.appendingPathComponent("SFX")
        if fm.fileExists(atPath: sfxPath.path) {
            let ptxFiles = (try? fm.contentsOfDirectory(at: sfxPath, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension.lowercased() == "ptx"
            } ?? []

            if !ptxFiles.isEmpty {
                summary += "SFX - Prepped (ProTools session found)\n"
            }
        }

        // OTHER
        let otherPath = prepURL.appendingPathComponent(config.settings.otherFolderName)
        if fm.fileExists(atPath: otherPath.path) {
            let otherFiles = (try? fm.contentsOfDirectory(at: otherPath, includingPropertiesForKeys: nil))?.filter {
                !$0.hasDirectoryPath
            } ?? []

            if !otherFiles.isEmpty {
                summary += "OTHER - \(otherFiles.count) file(s) prepped\n"
            }
        }

        // CHECKLIST (when user assigned files to checklist items from session description)
        let checklistPath = prepURL.appendingPathComponent("CHECKLIST")
        if fm.fileExists(atPath: checklistPath.path) {
            let itemDirs = (try? fm.contentsOfDirectory(at: checklistPath, includingPropertiesForKeys: nil))?.filter {
                $0.hasDirectoryPath
            } ?? []
            for dir in itemDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
                    !$0.hasDirectoryPath
                } ?? []
                if !files.isEmpty {
                    summary += "\n\(dir.lastPathComponent):\n"
                    for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        summary += "  - \(file.lastPathComponent)\n"
                    }
                }
            }
        }

        return summary.trimmingCharacters(in: .newlines)
    }
}

@MainActor
class MediaManager: ObservableObject {
    @Published var selectedFiles: [FileItem] = []
    @Published var dockets: [String] = []
    @Published var statusMessage: String = "Ready"
    @Published var isProcessing: Bool = false
    @Published var cancelRequested: Bool = false
    @Published var progress: Double = 0
    @Published var fileProgress: [UUID: Double] = [:] // Per-file progress tracking
    @Published var fileCompletionState: [UUID: FileCompletionState] = [:] // Per-file completion state
    @Published var isIndexing: Bool = false // Computed from indexingFolders
    @Published var isScanningDockets: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var indexingFolders: Set<SearchFolder> = [] // Track which folders are being indexed
    @Published var prepSummary: String = ""
    @Published var showPrepSummary: Bool = false
    @Published var connectionWarning: String? = nil
    @Published var showConnectionWarning: Bool = false
    @Published var isConverting: Bool = false
    @Published var conversionProgress: [UUID: Double] = [:] // Per-file conversion progress
    @Published var showConvertVideosPrompt: Bool = false
    @Published var pendingPrepConversion: (root: URL, videoFiles: [(url: URL, sourceId: UUID)], docket: String)?
    @Published var pendingPrepChecklistSession: PrepChecklistSession?
    /// Per-file destination folder overrides for prep (e.g. from calendar prep). Key = FileItem.id; value = folder name. Nil = no overrides.
    var pendingPrepFileOverrides: [UUID: String]?
    /// When set (e.g. from calendar prep with flattened files), used to resolve checklist assigned file IDs. Otherwise uses staged files only.
    var pendingPrepAllFileItemsForChecklist: [FileItem]?

    private var cachedSessions: [String] = [] // Legacy - for backward compatibility
    var folderCaches: [SearchFolder: [String]] = [:] // New cache system - internal for validation
    var config: AppConfig // Internal for DocketSearchView access
    private var prepFolderWatcher: DispatchSourceFileSystemObject?
    private var currentPrepFolder: String?
    private var metadataManager: DocketMetadataManager
    var videoConverter: VideoConverterManager?
    var omfAafValidator: OMFAAFValidatorManager?
    @Published var showOMFAAFValidator: Bool = false
    @Published var omfAafFileToValidate: URL?
    private var conversionMonitoringTask: Task<Void, Never>? // Track conversion monitoring task for cleanup
    private var prepSummaryRegenerationTask: Task<Void, Never>? // Track prep summary regeneration to cancel previous ones
    private var prepSummaryRegenerationWorkItem: DispatchWorkItem? // For debouncing watcher events

    init(settingsManager: SettingsManager, metadataManager: DocketMetadataManager) {
        self.config = AppConfig(settings: settingsManager.currentSettings)
        self.metadataManager = metadataManager

        // Directory connection status is now shown via status indicators in the sidebar
        // No need to show popup on launch

        // Start docket scanning (async, non-blocking)
        refreshDockets()
        
        // Build session index during startup (essential for smooth UX)
        buildSessionIndex()

        // Initialize video converter
        self.videoConverter = VideoConverterManager()
        
        // Initialize OMF/AAF validator
        self.omfAafValidator = OMFAAFValidatorManager()
    }
    
    func updateConfig(settings: AppSettings) {
        let oldSettings = self.config.settings
        self.config = AppConfig(settings: settings)
        
        // Only refresh dockets and indexes if path-related settings changed
        // Don't refresh if only theme or other non-path settings changed
        let pathSettingsChanged = 
            oldSettings.serverBasePath != settings.serverBasePath ||
            oldSettings.sessionsBasePath != settings.sessionsBasePath ||
            oldSettings.yearPrefix != settings.yearPrefix ||
            oldSettings.workPictureFolderName != settings.workPictureFolderName ||
            oldSettings.prepFolderName != settings.prepFolderName
        
        if pathSettingsChanged {
            refreshDockets()
            buildSessionIndex()
        }
    }

    // MARK: - Directory Connection Checking

    /// Check if required directories are accessible based on operation type
    func checkDirectoryAccess(for operation: String) -> Bool {
        let fm = FileManager.default
        
        // Check if server is connected (both work picture/prep and sessions are on the same Grayson server)
        let serverBase = config.settings.serverBasePath
        let sessionsBase = config.settings.sessionsBasePath
        let serverConnected = fm.fileExists(atPath: serverBase)
        let sessionsConnected = fm.fileExists(atPath: sessionsBase)
        
        // Determine what operations need what paths
        let needsServerPath = operation.contains("Work Picture") || operation.contains("Prep") || operation.contains("Both")
        let needsSessionsPath = operation.contains("Search") || operation.contains("Index")
        
        // If either required path is missing, show warning
        if (needsServerPath && !serverConnected) || (needsSessionsPath && !sessionsConnected) {
            connectionWarning = "Not connected to Grayson server.\n\nPlease connect to the server and try again."
            showConnectionWarning = true
            return false
        }

        return true
    }

    /// Check general directory access (for startup checks)
    func checkAllDirectoryAccess() {
        let fm = FileManager.default

        let serverBase = config.settings.serverBasePath
        let sessionsBase = config.settings.sessionsBasePath
        let serverConnected = fm.fileExists(atPath: serverBase)
        let sessionsConnected = fm.fileExists(atPath: sessionsBase)

        // Since both paths are on the same Grayson server, report as a single connection issue
        if !serverConnected || !sessionsConnected {
            connectionWarning = "Not connected to Grayson server.\n\nSome features may not work until the server is connected.\n\nYou can update paths in Settings if needed."
            showConnectionWarning = true
        }
    }

    /// Check if server directory is connected
    func isServerDirectoryConnected() -> Bool {
        let fm = FileManager.default
        let serverBase = config.settings.serverBasePath
        return fm.fileExists(atPath: serverBase)
    }
    
    /// Check if sessions directory is connected
    func isSessionsDirectoryConnected() -> Bool {
        let fm = FileManager.default
        let sessionsBase = config.settings.sessionsBasePath
        return fm.fileExists(atPath: sessionsBase)
    }

    func refreshDockets() {
        guard !isScanningDockets else { return }
        isScanningDockets = true
        let currentConfig = self.config
        
        // Check if the server path exists before scanning
        let paths = currentConfig.getPaths()
        let fm = FileManager.default
        
        // Try to ensure year folder structure exists (create if needed)
        var foldersCreated = false
        do {
            let yearFolderExistedBefore = {
                let year = Calendar.current.component(.year, from: Date())
                let serverRoot = URL(fileURLWithPath: currentConfig.settings.serverBasePath)
                    .appendingPathComponent("\(currentConfig.settings.yearPrefix)\(year)")
                return FileManager.default.fileExists(atPath: serverRoot.path)
            }()
            
            try currentConfig.ensureYearFolderStructure()
            
            // If folder didn't exist before but does now, we created it - invalidate search cache
            let yearFolderExistsAfter = {
                let year = Calendar.current.component(.year, from: Date())
                let serverRoot = URL(fileURLWithPath: currentConfig.settings.serverBasePath)
                    .appendingPathComponent("\(currentConfig.settings.yearPrefix)\(year)")
                return FileManager.default.fileExists(atPath: serverRoot.path)
            }()
            
            if !yearFolderExistedBefore && yearFolderExistsAfter {
                foldersCreated = true
            }
        } catch {
            // If we can't create the folder structure, continue to check
        }
        
        // If we created folders, invalidate the workPicture search cache so it rebuilds
        if foldersCreated {
            folderCaches[.workPicture] = nil
            // Trigger rebuild of workPicture index
            buildSessionIndex(folder: .workPicture)
        }
        
        // Also check if cache is stale (empty but folders now exist) - rebuild if needed
        let workPicExists = fm.fileExists(atPath: paths.workPic.path)
        if workPicExists {
            let cachedWorkPic = folderCaches[.workPicture] ?? []
            // If cache is empty but folder exists, it's stale - rebuild
            if cachedWorkPic.isEmpty && !indexingFolders.contains(.workPicture) {
                folderCaches[.workPicture] = nil
                buildSessionIndex(folder: .workPicture)
            }
        }
        
        if !workPicExists {
            Task { @MainActor in
                self.isScanningDockets = false
                self.dockets = []
                self.connectionWarning = "Work Picture folder not found:\n\n\(paths.workPic.path)\n\nPlease check your settings:\n• Server Base Path: \(currentConfig.settings.serverBasePath)\n• Year Prefix: \(currentConfig.settings.yearPrefix)\n• Work Picture Folder Name: \(currentConfig.settings.workPictureFolderName)\n\nMake sure the server is connected and the paths are correct in Settings."
                self.showConnectionWarning = true
            }
            return
        }
        
        Task.detached {
            let dockets = MediaLogic.scanDockets(config: currentConfig)
            
            await MainActor.run {
                self.dockets = dockets
                self.isScanningDockets = false
                
                // If no dockets found and path exists, it might be empty (which is OK)
                // But if path doesn't exist, we already showed the warning above
            }
        }
    }
    
    func buildSessionIndex(folder: SearchFolder = .sessions) {
        // Skip if this folder is already being indexed or is already cached
        guard !indexingFolders.contains(folder) && folderCaches[folder] == nil else {
            return
        }

        indexingFolders.insert(folder)
        isIndexing = !indexingFolders.isEmpty

        let currentConfig = self.config
        Task.detached(priority: .userInitiated) {
            let index = MediaLogic.buildIndex(config: currentConfig, folder: folder)
            
            await MainActor.run {
                self.folderCaches[folder] = index
                // Also update legacy cache if it's sessions folder
                if folder == .sessions {
                    self.cachedSessions = index
                }
                self.indexingFolders.remove(folder)
                self.isIndexing = !self.indexingFolders.isEmpty

                // Log the result for debugging
                print("\(folder.displayName): Indexed \(index.count) items")
            }
        }
    }

    // Index all folders at once
    func buildAllFolderIndexes() {
        for folder in SearchFolder.allCases {
            buildSessionIndex(folder: folder)
        }
    }

    func searchSessions(term: String, folder: SearchFolder = .sessions) async -> SearchResults {
        // Build index for this folder if not cached (but don't wait if already indexing)
        if folderCaches[folder] == nil && !indexingFolders.contains(folder) {
            buildSessionIndex(folder: folder)
        }
        
        // If indexing is in progress, wait a bit for it to complete (max 2 seconds)
        if indexingFolders.contains(folder) {
            var attempts = 0
            while indexingFolders.contains(folder) && attempts < 20 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                attempts += 1
            }
        }
        
        if term.isEmpty { return SearchResults(exactMatches: [], fuzzyMatches: []) }

        let currentCache = folderCaches[folder] ?? []
        let fuzzyEnabled = config.settings.enableFuzzySearch
        return await Task.detached(priority: .userInitiated) {
            let lower = term.localizedLowercase
            let searchWords = lower.split(separator: " ").map(String.init)

            // 1. Exact matches - check if all words are present (in any order)
            let exactMatches = currentCache.filter { path in
                let pathLower = path.lowercased()
                // If single word or exact phrase match, use contains
                if searchWords.count == 1 || pathLower.contains(lower) {
                    return pathLower.contains(lower)
                }
                // For multiple words, check if ALL words are present (in any order)
                return searchWords.allSatisfy { word in
                    pathLower.contains(word)
                }
            }

            // 2. Fuzzy matches - catch typos and spacing differences (if enabled)
            let fuzzyMatches: [String]
            if fuzzyEnabled {
                fuzzyMatches = currentCache.filter { path in
                    // Skip if already in exact matches
                    if exactMatches.contains(path) { return false }
                    // Use fuzzy matching on the path (maxDistance: 3 for lenient matching)
                    return MediaLogic.fuzzyMatch(searchTerm: term, target: path)
                }
            } else {
                fuzzyMatches = []
            }

            // Sort both lists
            let sortedExact = exactMatches.prefix(150).sorted { pathA, pathB in
                let nsPathA = pathA as NSString
                let nsPathB = pathB as NSString

                let parentA = nsPathA.deletingLastPathComponent as NSString
                let parentB = nsPathB.deletingLastPathComponent as NSString

                let folderA = parentA.lastPathComponent
                let folderB = parentB.lastPathComponent

                if folderA != folderB {
                    return folderA > folderB
                }
                return nsPathA.lastPathComponent < nsPathB.lastPathComponent
            }

            let sortedFuzzy = fuzzyMatches.prefix(50).sorted { pathA, pathB in
                let nsPathA = pathA as NSString
                let nsPathB = pathB as NSString

                let parentA = nsPathA.deletingLastPathComponent as NSString
                let parentB = nsPathB.deletingLastPathComponent as NSString

                let folderA = parentA.lastPathComponent
                let folderB = parentB.lastPathComponent

                if folderA != folderB {
                    return folderA > folderB
                }
                return nsPathA.lastPathComponent < nsPathB.lastPathComponent
            }

            return SearchResults(
                exactMatches: Array(sortedExact),
                fuzzyMatches: Array(sortedFuzzy)
            )
        }.value
    }
    
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK {
                let items = panel.urls.map { FileItem(url: $0) }
                let currentIDs = Set(self.selectedFiles.map { $0.url })
                let new = items.filter { !currentIDs.contains($0.url) }
                self.selectedFiles.append(contentsOf: new)
            }
        }
    }
    
    func checkForOMFAAFFiles(in urls: [URL]) {
        let aafOmfExtensions = ["aaf", "omf"]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if aafOmfExtensions.contains(ext) && !url.hasDirectoryPath {
                // Found an AAF/OMF file, show validator
                omfAafFileToValidate = url
                showOMFAAFValidator = true
                break // Only show validator for the first AAF/OMF file found
            }
        }
    }
    
    func clearFiles() {
        selectedFiles.removeAll()
        // Clean up progress tracking when files are cleared
        fileProgress.removeAll()
        fileCompletionState.removeAll()
        conversionProgress.removeAll()
    }

    func removeFile(withId id: UUID) {
        selectedFiles.removeAll { $0.id == id }
        // Also clean up any progress tracking for this file
        fileProgress.removeValue(forKey: id)
        fileCompletionState.removeValue(forKey: id)
        conversionProgress.removeValue(forKey: id)
    }

    func cancelProcessing() {
        cancelRequested = true
        statusMessage = "Cancelling..."
        
        // Cancel any ongoing conversion monitoring
        conversionMonitoringTask?.cancel()
        conversionMonitoringTask = nil
        isConverting = false
        
        // Clear progress dictionaries to prevent memory buildup
        fileProgress.removeAll()
        fileCompletionState.removeAll()
        conversionProgress.removeAll()
    }
    
    func runJob(type: JobType, docket: String, wpDate: Date, prepDate: Date) {
        if selectedFiles.isEmpty {
            if type == .prep || type == .both {
                errorMessage = "No files staged.\n\nAdd files in the Staging area before starting Prep."
                showError = true
                return
            }
            pickFiles()
            return
        }

        // Check directory access before starting
        if !checkDirectoryAccess(for: type.rawValue) {
            return
        }

        cancelRequested = false
        isProcessing = true; progress = 0; statusMessage = "Starting..."
        fileProgress.removeAll() // Clear any previous progress
        fileCompletionState.removeAll() // Clear completion states
        let files = selectedFiles
        let checklistSession = (type == .prep || type == .both) ? pendingPrepChecklistSession : nil
        let checklistAssignedFileIds = checklistSession?.allAssignedFileIds ?? []
        let prepFileOverrides = (type == .prep || type == .both) ? pendingPrepFileOverrides : nil
        let allFileItemsForChecklist = (type == .prep || type == .both) ? pendingPrepAllFileItemsForChecklist : nil
        if type == .prep || type == .both {
            pendingPrepChecklistSession = nil
            pendingPrepFileOverrides = nil
            pendingPrepAllFileItemsForChecklist = nil
        }
        let currentConfig = self.config

        // Calculate total bytes for all files
        let totalBytes: Int64 = files.reduce(0) { sum, file in
            if file.isDirectory {
                // For directories, sum up all files recursively
                return sum + FileItem.calculateDirectorySize(at: file.url)
            } else {
                return sum + (file.fileSize ?? 0)
            }
        }
        // For "both" mode, files are copied twice
        let adjustedTotalBytes = type == .both ? totalBytes * 2 : totalBytes

        // Start floating progress indicator
        let progressOperation: ProgressOperation = {
            switch type {
            case .workPicture: return .filing(docket: docket)
            case .prep: return .prepping(docket: docket)
            case .both: return .filingAndPrepping(docket: docket)
            }
        }()
        FloatingProgressManager.shared.startOperation(progressOperation, totalFiles: files.count * (type == .both ? 2 : 1), totalBytes: adjustedTotalBytes)

        print("🚀 [DEBUG] Starting file operation: \(type), files: \(files.count), totalBytes: \(adjustedTotalBytes)")
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let paths = currentConfig.getPaths()
            let total = Double(files.count * (type == .both ? 2 : 1))
            var currentStep = 0.0
            var cumulativeBytesCopied: Int64 = 0

            var failedFiles: [String] = []
            var workPictureDestinationFolder: URL? = nil

            if type == .workPicture || type == .both {
                await MainActor.run {
                    self.statusMessage = "Filing..."
                    FloatingProgressManager.shared.updateProgress(0, message: "Filing...")
                }
                
                // Verify work picture parent directory exists before creating folders
                guard fm.fileExists(atPath: paths.workPic.path) else {
                    await MainActor.run {
                        self.errorMessage = "Work Picture folder path does not exist:\n\(paths.workPic.path)\n\nPlease check your settings:\n• Server Base Path: \(currentConfig.settings.serverBasePath)\n• Year Prefix: \(currentConfig.settings.yearPrefix)\n• Work Picture Folder Name: \(currentConfig.settings.workPictureFolderName)\n\nMake sure the server is connected and the paths are correct in Settings."
                        self.showError = true
                        self.isProcessing = false
                        FloatingProgressManager.shared.hide()
                    }
                    return
                }
                
                // Find which year the docket folder exists in (searches across all years)
                let docketYear = currentConfig.findDocketYear(docket: docket)
                let workPicPath: URL
                if let year = docketYear {
                    // Use the year where the docket was found
                    workPicPath = currentConfig.getWorkPicPath(for: year)
                } else {
                    // Fall back to current year if not found
                    workPicPath = paths.workPic
                }
                
                // Verify docket folder exists before creating date subfolders
                let base = workPicPath.appendingPathComponent(docket)
                guard fm.fileExists(atPath: base.path) else {
                    await MainActor.run {
                        self.errorMessage = "Docket folder does not exist:\n\(base.path)\n\nPlease create the docket folder first or check that the docket name is correct."
                        self.showError = true
                        self.isProcessing = false
                        FloatingProgressManager.shared.hide()
                    }
                    return
                }
                
                // Use FolderNamingService for consistent work picture folder naming
                let destFolder = self.getNextFolder(base: base, date: wpDate, config: currentConfig)
                workPictureDestinationFolder = destFolder
                
                // Check if folder already exists, if not create it
                if !fm.fileExists(atPath: destFolder.path) {
                do {
                        try fm.createDirectory(at: destFolder, withIntermediateDirectories: false)
                } catch {
                    await MainActor.run {
                            self.errorMessage = "Failed to create work picture folder: \(error.localizedDescription)\n\nPath: \(destFolder.path)"
                        self.showError = true
                        self.isProcessing = false
                    }
                    return
                    }
                }

                for f in files {
                    let shouldCancel = await MainActor.run { self.cancelRequested }
                    if shouldCancel {
                        break
                    }

                    // Mark file as starting
                    await MainActor.run { self.fileProgress[f.id] = 0.0 }

                    let dest = destFolder.appendingPathComponent(f.name)
                    let fileSize = f.fileSize ?? 0
                    let bytesBeforeThisFile = cumulativeBytesCopied

                    // Skip if file already exists, otherwise copy it
                    if fm.fileExists(atPath: dest.path) {
                        // File already exists, skip it but don't count as failed
                        print("Skipping existing file: \(f.name)")
                        // Still count bytes for skipped files to keep progress accurate
                        cumulativeBytesCopied += fileSize
                    } else {
                        // Use progress-aware copy for large files
                        let baseProgress = currentStep / total
                        let progressPerFile = 1.0 / total

                        let copySuccess = self.copyItemWithProgress(from: f.url, to: dest) { bytesWritten, fileTotalBytes in
                            let filePortionComplete = Double(bytesWritten) / Double(fileTotalBytes)
                            let adjustedProgress = baseProgress + (progressPerFile * filePortionComplete)
                            let currentTotalBytes = bytesBeforeThisFile + bytesWritten

                            // Use DispatchQueue.main.async instead of Task to avoid task accumulation
                            DispatchQueue.main.async { [weak self] in
                                guard let self = self else { return }
                                self.fileProgress[f.id] = filePortionComplete
                                self.progress = min(adjustedProgress, 1.0)
                                FloatingProgressManager.shared.updateProgress(adjustedProgress, currentFile: f.name)
                                FloatingProgressManager.shared.updateBytes(copied: currentTotalBytes)
                            }
                        }

                        if copySuccess {
                            cumulativeBytesCopied += fileSize
                        } else {
                            failedFiles.append(f.name)
                        }
                    }

                    // Mark file as complete
                    currentStep += 1
                    let p = currentStep / total
                    await MainActor.run {
                        self.fileProgress[f.id] = 1.0
                        self.progress = p

                        // Update completion state
                        if type == .both {
                            self.fileCompletionState[f.id] = .workPicDone
                        } else {
                            self.fileCompletionState[f.id] = .complete
                        }
                    }
                }
            }
            
            var prepDestinationFolder: URL? = nil

            if type == .prep || type == .both {
                await MainActor.run {
                    self.statusMessage = "Prepping..."
                    FloatingProgressManager.shared.updateProgress(self.progress, message: "Prepping...")
                }
                
                // Verify prep parent directory exists before creating folders
                guard fm.fileExists(atPath: paths.prep.path) else {
                    await MainActor.run {
                        self.errorMessage = "Prep folder path does not exist:\n\(paths.prep.path)\n\nPlease check your settings:\n• Server Base Path: \(currentConfig.settings.serverBasePath)\n• Year Prefix: \(currentConfig.settings.yearPrefix)\n• Prep Folder Name: \(currentConfig.settings.prepFolderName)\n\nMake sure the server is connected and the paths are correct in Settings."
                        self.showError = true
                        self.isProcessing = false
                        FloatingProgressManager.shared.hide()
                    }
                    return
                }
                
                // Use FolderNamingService for consistent prep folder naming
                let folder = currentConfig.prepFolderName(docket: docket, date: prepDate)
                let root = paths.prep.appendingPathComponent(folder)
                prepDestinationFolder = root
                
                // Check if prep folder already exists, if not create it
                // If it exists, we'll use the existing folder and skip duplicate files
                if !fm.fileExists(atPath: root.path) {
                do {
                        try fm.createDirectory(at: root, withIntermediateDirectories: false)
                } catch {
                    await MainActor.run {
                            self.errorMessage = "Failed to create prep folder: \(error.localizedDescription)\n\nPath: \(root.path)"
                        self.showError = true
                        self.isProcessing = false
                    }
                    return
                    }
                }

                // Build map of flat files to their source FileItem
                var flats: [(url: URL, sourceId: UUID)] = []
                var fileToFlatCount: [UUID: Int] = [:]
                for f in files {
                    let flatFiles = MediaLogic.getAllFiles(at: f.url)
                    fileToFlatCount[f.id] = flatFiles.count
                    for flatFile in flatFiles {
                        flats.append((flatFile, f.id))
                    }
                }

                // Check for video files and ask about conversion
                let videoExtensions = ["mp4", "mov", "avi", "mxf", "m4v", "prores"]
                let videoFiles = flats.filter { videoExtensions.contains($0.url.pathExtension.lowercased()) }
                var willConvertVideos = false

                if !videoFiles.isEmpty {
                    // Store pending conversion info and show prompt
                    await MainActor.run {
                        self.pendingPrepConversion = (root: root, videoFiles: videoFiles, docket: docket)
                        self.showConvertVideosPrompt = true
                    }

                    // Wait for user response
                    var waiting = true
                    while waiting {
                        waiting = await MainActor.run { self.showConvertVideosPrompt }
                        if waiting {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                    
                    // Check if user chose to convert (converter will be set up if yes)
                    willConvertVideos = await MainActor.run { self.pendingPrepConversion != nil }
                }

                // Initialize progress for all files
                await MainActor.run {
                    for f in files {
                        self.fileProgress[f.id] = 0.0
                    }
                }

                // Track completion per source file
                var completedPerFile: [UUID: Int] = [:]
                for f in files {
                    completedPerFile[f.id] = 0
                }

                for (flatFile, sourceId) in flats {
                    let shouldCancel = await MainActor.run { self.cancelRequested }
                    if shouldCancel {
                        break
                    }

                    // Skip video files if we're converting them - they'll go to z_unconverted instead
                    let isVideoFile = videoExtensions.contains(flatFile.pathExtension.lowercased())
                    if isVideoFile && willConvertVideos {
                        // Skip copying video files - they'll be handled by convertPrepVideos
                        continue
                    }

                    // Files assigned to description-line checklist go only to CHECKLIST, not to format folders
                    if checklistAssignedFileIds.contains(sourceId) {
                        currentStep += 1
                        completedPerFile[sourceId, default: 0] += 1
                        let p = currentStep / total
                        let fileP = Double(completedPerFile[sourceId]!) / Double(fileToFlatCount[sourceId]!)
                        await MainActor.run {
                            self.fileProgress[sourceId] = fileP
                            self.progress = p
                            if fileP >= 1.0 {
                                if type == .both {
                                    if self.fileCompletionState[sourceId] == .workPicDone { self.fileCompletionState[sourceId] = .complete }
                                    else { self.fileCompletionState[sourceId] = .prepDone }
                                } else { self.fileCompletionState[sourceId] = .complete }
                            }
                        }
                        continue
                    }

                    let cat: String? = {
                        if let overrides = prepFileOverrides, let folder = overrides[sourceId], !folder.isEmpty {
                            return folder
                        }
                        return self.getPrepCategory(flatFile, config: currentConfig)
                    }()
                    guard let cat = cat else {
                        currentStep += 1
                        completedPerFile[sourceId, default: 0] += 1
                        let p = currentStep / total
                        let fileP = Double(completedPerFile[sourceId]!) / Double(fileToFlatCount[sourceId]!)
                        await MainActor.run {
                            self.fileProgress[sourceId] = fileP
                            self.progress = p
                            if fileP >= 1.0 {
                                if type == .both {
                                    if self.fileCompletionState[sourceId] == .workPicDone { self.fileCompletionState[sourceId] = .complete }
                                    else { self.fileCompletionState[sourceId] = .prepDone }
                                } else { self.fileCompletionState[sourceId] = .complete }
                            }
                        }
                        continue
                    }
                    let dir = root.appendingPathComponent(cat)
                    
                    // Create category directory if it doesn't exist
                    if !fm.fileExists(atPath: dir.path) {
                    do {
                            try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                    } catch {
                        print("Error creating category directory \(cat): \(error.localizedDescription)")
                            failedFiles.append(flatFile.lastPathComponent)
                            continue
                        }
                    }
                    
                    let destFile = dir.appendingPathComponent(flatFile.lastPathComponent)

                    // Get file size for byte tracking
                    let flatFileSize: Int64 = {
                        if let attrs = try? fm.attributesOfItem(atPath: flatFile.path),
                           let size = attrs[.size] as? Int64 {
                            return size
                        }
                        return 0
                    }()
                    let bytesBeforeThisFile = cumulativeBytesCopied

                    // Skip if file already exists, otherwise copy it
                    if fm.fileExists(atPath: destFile.path) {
                        // File already exists, skip it but don't count as failed
                        print("Skipping existing file: \(flatFile.lastPathComponent)")
                        // Still count bytes for skipped files to keep progress accurate
                        cumulativeBytesCopied += flatFileSize
                    } else {
                        // Use progress-aware copy for large files
                        // This provides smooth progress updates during long file copies
                        let baseProgress = currentStep / total
                        let progressPerFile = 1.0 / total
                        // Note: fileToFlatCount[sourceId] is available for future use if needed for per-source progress tracking

                        let currentFileName = flatFile.lastPathComponent
                        let copySuccess = self.copyItemWithProgress(from: flatFile, to: destFile) { bytesWritten, fileTotalBytes in
                            // Calculate sub-file progress (0.0 to 1.0 within this file's portion)
                            let filePortionComplete = Double(bytesWritten) / Double(fileTotalBytes)
                            let adjustedProgress = baseProgress + (progressPerFile * filePortionComplete)
                            let currentTotalBytes = bytesBeforeThisFile + bytesWritten

                            // Update UI on main thread - use DispatchQueue.main.async instead of Task to avoid task accumulation
                            DispatchQueue.main.async { [weak self] in
                                guard let self = self else { return }
                                self.progress = min(adjustedProgress, 1.0)
                                FloatingProgressManager.shared.updateProgress(adjustedProgress, currentFile: currentFileName)
                                FloatingProgressManager.shared.updateBytes(copied: currentTotalBytes)
                            }
                        }

                        if copySuccess {
                            cumulativeBytesCopied += flatFileSize
                        } else {
                            failedFiles.append(flatFile.lastPathComponent)
                        }
                    }

                    // Update progress for source file
                    completedPerFile[sourceId, default: 0] += 1
                    currentStep += 1
                    let p = currentStep / total
                    let fileP = Double(completedPerFile[sourceId]!) / Double(fileToFlatCount[sourceId]!)

                    await MainActor.run {
                        self.fileProgress[sourceId] = fileP
                        self.progress = p

                        // If this file is complete, update completion state
                        if fileP >= 1.0 {
                            if type == .both {
                                // Check if work picture was already done
                                if self.fileCompletionState[sourceId] == .workPicDone {
                                    self.fileCompletionState[sourceId] = .complete
                                } else {
                                    self.fileCompletionState[sourceId] = .prepDone
                                }
                            } else {
                                self.fileCompletionState[sourceId] = .complete
                            }
                        }
                    }
                }

                if (currentConfig.settings.createPrepChecklistFolder ?? true),
                   let session = checklistSession, session.docket == docket {
                    let filesForChecklist = allFileItemsForChecklist ?? files
                    MediaLogic.applyPrepChecklistAssignments(session: session, root: root, stagedFiles: filesForChecklist)
                }

                // Organize stems and generate summary
                if type == .prep || type == .both {
                    print("📁 [DEBUG] Starting stem organization and summary generation")
                    await MainActor.run { self.statusMessage = "Organizing stems..." }
                    // Run organizeStems in background to avoid blocking
                    await Task.detached(priority: .utility) {
                        print("📁 [DEBUG] Organizing stems in background task")
                        self.organizeStems(in: root, config: currentConfig)
                        print("✅ [DEBUG] Stem organization completed")
                    }.value

                    // Get job name for summary
                    let jobName = await MainActor.run { self.getJobName(for: docket) }

                    print("📊 [DEBUG] Generating prep summary...")
                    await MainActor.run { self.statusMessage = "Generating prep summary..." }
                    let summary = await MediaLogic.generatePrepSummary(
                        docket: docket,
                        jobName: jobName,
                        prepFolderPath: root.path,
                        config: currentConfig
                    )
                    print("✅ [DEBUG] Prep summary generated")

                    // Save summary to file
                    let summaryFile = root.appendingPathComponent("\(docket)_Prep_Summary.txt")
                    try? summary.write(to: summaryFile, atomically: true, encoding: .utf8)

                    // Update UI and setup file watching (but delay watcher setup to avoid firing during final operations)
                    await MainActor.run {
                        self.prepSummary = summary
                        self.showPrepSummary = true
                        self.currentPrepFolder = root.path
                        
                        print("⏰ [DEBUG] Scheduling prep folder watcher setup in 2 seconds (to avoid firing during final operations)")
                        // Delay watcher setup to avoid immediate firing from final file operations
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                            print("⏰ [DEBUG] Setting up prep folder watcher now (2 second delay elapsed)")
                            self?.setupPrepFolderWatcher(path: root.path, docket: docket)
                        }
                    }
                }
            }

            // Capture failedFiles and folders before entering MainActor context
            let finalFailedFiles = failedFiles
            let prepFolderToOpen = prepDestinationFolder
            let workPictureFolderToOpen = workPictureDestinationFolder
            let jobType = type // Capture type for use in MainActor context

            let wasCancelled = await self.cancelRequested

            await MainActor.run {
                if wasCancelled {
                    print("🛑 [DEBUG] File operation cancelled")
                    self.isProcessing = false
                    self.statusMessage = "Cancelled"
                    FloatingProgressManager.shared.cancel()
                    // Ensure cleanup on cancel
                    self.fileProgress.removeAll()
                    self.fileCompletionState.removeAll()
                    return
                }
                
                print("✅ [DEBUG] File operation completed. isProcessing: \(self.isProcessing) -> false")
                self.isProcessing = false
                
                if finalFailedFiles.isEmpty {
                    self.statusMessage = "Done!"
                    FloatingProgressManager.shared.complete(message: "Done!")
                    NSSound(named: "Glass")?.play()

                    // Open folders if settings are enabled
                    if jobType == .prep || jobType == .both {
                        if let prepFolder = prepFolderToOpen, self.config.settings.openPrepFolderWhenDone {
                            NSWorkspace.shared.open(prepFolder)
                        }
                    }
                    if jobType == .workPicture || jobType == .both {
                        if let wpFolder = workPictureFolderToOpen, self.config.settings.openWorkPictureFolderWhenDone {
                            NSWorkspace.shared.open(wpFolder)
                        }
                    }
                } else {
                    self.statusMessage = "Completed with \(finalFailedFiles.count) error(s)"
                    self.errorMessage = "Failed to copy these files:\n\(finalFailedFiles.joined(separator: "\n"))"
                    self.showError = true
                    FloatingProgressManager.shared.complete(message: "Completed with errors")
                }
                
                // Clean up progress dictionaries after operation completes
                // Keep fileProgress for a short time in case UI needs to show final state
                // But clear old entries that are no longer relevant
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    print("🧹 [DEBUG] Cleaning up progress dictionaries")
                    self?.fileProgress.removeAll()
                    self?.fileCompletionState.removeAll()
                }
            }
        }
    }
    
    // Date formatting now handled by FolderNamingService
    // Use config.namingService.formatDate() instead
    
    nonisolated private func getNextFolder(base: URL, date: Date, config: AppConfig) -> URL {
        let fm = FileManager.default
        var sequenceNumber = 1

        // Get all items in the base directory
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return base.appendingPathComponent(config.namingService.workPictureFolderName(sequenceNumber: sequenceNumber, date: date))
        }

        // Filter for directories that match the numbered date pattern: NN_anydate
        // We look at ALL numbered folders to find the highest number, regardless of date
        let numberedFolders = items.filter { item in
            // Only check directories
            guard let isDirectory = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDirectory == true else {
                return false
            }
            let name = item.lastPathComponent
            // Match pattern: digits followed by underscore (e.g., "01_", "02_", "15_")
            guard let underscoreIndex = name.firstIndex(of: "_") else {
                return false
            }
            let prefix = String(name[..<underscoreIndex])
            // Verify the prefix is a number
            return Int(prefix) != nil
        }

        // Extract numbers from folder names (format: "01_date" -> 1)
        let nums = numberedFolders.compactMap { item -> Int? in
            let name = item.lastPathComponent
            // Extract the number prefix before the underscore
            if let underscoreIndex = name.firstIndex(of: "_") {
                let prefix = String(name[..<underscoreIndex])
                return Int(prefix)
            }
            return nil
        }

        // Find the highest number and increment
        if let max = nums.max(), max >= 1 {
            sequenceNumber = max + 1
        }

        return base.appendingPathComponent(config.namingService.workPictureFolderName(sequenceNumber: sequenceNumber, date: date))
    }
    
    // Helper to normalize date strings for comparison (handles both old and new formats)
    nonisolated private func normalizeDateString(_ dateStr: String) -> String {
        // Convert "Dec02.25" to "Dec2.25" for comparison
        // This handles matching old folders with new format
        if let dotIndex = dateStr.firstIndex(of: ".") {
            let monthDay = String(dateStr[..<dotIndex])
            let year = String(dateStr[dateStr.index(after: dotIndex)...])
            
            // Extract month (first 3 letters) and day (rest)
            if monthDay.count > 3 {
                let month = String(monthDay.prefix(3))
                let dayStr = String(monthDay.dropFirst(3))
                // Remove leading zero from day if present
                let day = dayStr.hasPrefix("0") && dayStr.count > 1 ? String(dayStr.dropFirst()) : dayStr
                return "\(month)\(day).\(year)"
            }
        }
        return dateStr
    }
    
    nonisolated private func getCategory(_ u: URL, config: AppConfig) -> String {
        let e = u.pathExtension.lowercased()
        if config.settings.pictureExtensions.contains(e) { return config.settings.pictureFolderName }
        if config.settings.musicExtensions.contains(e) { return config.settings.musicFolderName }
        if config.settings.aafOmfExtensions.contains(e) { return config.settings.aafOmfFolderName }
        return config.settings.otherFolderName
    }

    /// Resolves the prep folder for a file: if the natural category is disabled, uses OTHER if enabled, else nil (skip).
    nonisolated private func getPrepCategory(_ u: URL, config: AppConfig) -> String? {
        let cat = getCategory(u, config: config)
        let s = config.settings
        func create(_ name: String) -> Bool {
            if name == s.pictureFolderName { return s.createPrepPictureFolder ?? true }
            if name == s.musicFolderName { return s.createPrepMusicFolder ?? true }
            if name == s.aafOmfFolderName { return s.createPrepAafOmfFolder ?? true }
            if name == s.otherFolderName { return s.createPrepOtherFolder ?? true }
            return true
        }
        if create(cat) { return cat }
        if (s.createPrepOtherFolder ?? true) { return s.otherFolderName }
        return nil
    }
    
    nonisolated private func copyItem(from: URL, to: URL) -> Bool {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: to.path) {
                try fm.removeItem(at: to)
            }
            try fm.copyItem(at: from, to: to)
            return true
        } catch {
            print("Error copying file from \(from.path) to \(to.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Copy a file with progress reporting for large files
    /// Returns (success, bytesWritten) - bytesWritten is used to update progress during copy
    /// Includes timeout protection to prevent hanging on slow/stuck file operations
    nonisolated private func copyItemWithProgress(
        from: URL,
        to: URL,
        progressHandler: @escaping (Int64, Int64) -> Void,  // (bytesWritten, totalBytes)
        timeoutSeconds: TimeInterval = 300.0  // 5 minutes default timeout
    ) -> Bool {
        let fm = FileManager.default

        // Get file size for progress calculation
        guard let attributes = try? fm.attributesOfItem(atPath: from.path),
              let fileSize = attributes[.size] as? Int64 else {
            // Fall back to regular copy if we can't get file size
            return copyItem(from: from, to: to)
        }

        // For small files (< 50MB), use regular copy - faster and simpler
        let smallFileThreshold: Int64 = 50 * 1024 * 1024
        if fileSize < smallFileThreshold {
            return copyItem(from: from, to: to)
        }

        // For large files, use streaming copy with progress updates
        do {
            if fm.fileExists(atPath: to.path) {
                try fm.removeItem(at: to)
            }

            // Create destination file
            fm.createFile(atPath: to.path, contents: nil, attributes: nil)

            guard let inputStream = InputStream(url: from),
                  let outputStream = OutputStream(url: to, append: false) else {
                return copyItem(from: from, to: to)
            }

            inputStream.open()
            outputStream.open()

            defer {
                inputStream.close()
                outputStream.close()
            }

            // Use 1MB buffer for efficient copying
            let bufferSize = 1024 * 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            var totalBytesWritten: Int64 = 0
            var lastProgressUpdate = Date()
            let startTime = Date()
            var lastByteCount: Int64 = 0
            var lastByteCountTime = Date()

            while inputStream.hasBytesAvailable {
                // Check for overall timeout
                let elapsed = Date().timeIntervalSince(startTime)
                if elapsed > timeoutSeconds {
                    print("Error: File copy timed out after \(timeoutSeconds) seconds")
                    try? fm.removeItem(at: to)
                    return false
                }
                
                // Check for stall (no progress for 30 seconds indicates a stuck operation)
                let timeSinceLastProgress = Date().timeIntervalSince(lastByteCountTime)
                if timeSinceLastProgress > 30.0 && totalBytesWritten == lastByteCount && totalBytesWritten > 0 {
                    print("Error: File copy stalled (no progress for 30 seconds)")
                    try? fm.removeItem(at: to)
                    return false
                }

                let bytesRead = inputStream.read(&buffer, maxLength: bufferSize)
                if bytesRead < 0 {
                    // Read error
                    try? fm.removeItem(at: to)
                    return false
                }
                if bytesRead == 0 {
                    break
                }

                var bytesWritten = 0
                while bytesWritten < bytesRead {
                    // Use withUnsafeBufferPointer for safe pointer arithmetic
                    let writeResult = buffer.withUnsafeBufferPointer { bufferPtr in
                        guard let baseAddress = bufferPtr.baseAddress else { return -1 }
                        return outputStream.write(baseAddress + bytesWritten, maxLength: bytesRead - bytesWritten)
                    }
                    if writeResult < 0 {
                        // Write error
                        try? fm.removeItem(at: to)
                        return false
                    }
                    bytesWritten += writeResult
                }

                totalBytesWritten += Int64(bytesWritten)
                
                // Track progress for stall detection
                if totalBytesWritten > lastByteCount {
                    lastByteCount = totalBytesWritten
                    lastByteCountTime = Date()
                }

                // Update progress every 100ms to avoid too many UI updates
                let now = Date()
                if now.timeIntervalSince(lastProgressUpdate) >= 0.1 {
                    progressHandler(totalBytesWritten, fileSize)
                    lastProgressUpdate = now
                }
            }

            // Final progress update
            progressHandler(fileSize, fileSize)
            return true
        } catch {
            print("Error copying file with progress from \(from.path) to \(to.path): \(error.localizedDescription)")
            return copyItem(from: from, to: to)
        }
    }

    // MARK: - Prep Summary Helpers

    /// Organize stem files into dedicated folders
    nonisolated private func organizeStems(in prepFolder: URL, config: AppConfig) {
        let fm = FileManager.default
        let musicFolder = prepFolder.appendingPathComponent(config.settings.musicFolderName)

        guard fm.fileExists(atPath: musicFolder.path) else { return }

        // Get all music files
        guard let musicFiles = try? fm.contentsOfDirectory(at: musicFolder, includingPropertiesForKeys: nil) else { return }

        let audioFiles = musicFiles.filter {
            !$0.hasDirectoryPath && config.settings.musicExtensions.contains($0.pathExtension.lowercased())
        }

        // Group stems by track name
        var stemGroups: [String: [URL]] = [:]

        for file in audioFiles {
            if MediaLogic.isStemFile(file.lastPathComponent) {
                let trackName = MediaLogic.extractTrackName(file.lastPathComponent)
                stemGroups[trackName, default: []].append(file)
            }
        }

        // Move each stem group into its own folder
        for (trackName, stems) in stemGroups where stems.count > 1 {
            let stemFolder = musicFolder.appendingPathComponent("\(trackName) STEMS")
            try? fm.createDirectory(at: stemFolder, withIntermediateDirectories: true)

            for stem in stems {
                let destination = stemFolder.appendingPathComponent(stem.lastPathComponent)
                try? fm.moveItem(at: stem, to: destination)
            }
        }
    }

    /// Get job name from docket metadata (docket may be full folder name e.g. "12345_Job Name" or just "12345")
    func getJobName(for docket: String) -> String {
        // Try exact match first
        for (_, metadata) in metadataManager.metadata {
            if metadata.docketNumber == docket && !metadata.jobName.isEmpty {
                return metadata.jobName
            }
        }
        // Try leading docket number from folder name (e.g. "12345_Job Name" or "12345_PREP_Date")
        let docketNumber = docket.split(separator: "_").first.map(String.init) ?? docket
        if docketNumber != docket {
            for (_, metadata) in metadataManager.metadata {
                if metadata.docketNumber == docketNumber && !metadata.jobName.isEmpty {
                    return metadata.jobName
                }
            }
        }
        return docket
    }

    /// Setup file system monitoring for prep folder
    func setupPrepFolderWatcher(path: String, docket: String) {
        print("🔍 [DEBUG] Setting up prep folder watcher for: \(path)")
        
        // Stop existing watcher
        prepFolderWatcher?.cancel()
        prepFolderWatcher = nil
        
        // Cancel any pending regeneration
        prepSummaryRegenerationWorkItem?.cancel()
        prepSummaryRegenerationWorkItem = nil

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("⚠️ [DEBUG] Failed to open file descriptor for watcher: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility) // Lower priority to avoid interfering with file operations
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            print("🔍 [DEBUG] Prep folder watcher fired for: \(path), isProcessing: \(self.isProcessing)")
            
            // Cancel previous debounce work item
            self.prepSummaryRegenerationWorkItem?.cancel()
            
            // Create new debounced work item with longer delay to avoid firing during active file operations
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Only regenerate if we're not currently processing files
                if self.isProcessing {
                    print("⏸️ [DEBUG] Skipping summary regeneration - still processing files")
                    return
                }
                print("🔄 [DEBUG] Executing debounced summary regeneration for: \(path)")
                self.regeneratePrepSummary(path: path, docket: docket)
            }
            
            self.prepSummaryRegenerationWorkItem = workItem
            
            // Debounce with 3 second delay to avoid firing during active file operations
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: workItem)
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        prepFolderWatcher = source
        print("✅ [DEBUG] Prep folder watcher started successfully")
    }

    /// Regenerate prep summary
    func regeneratePrepSummary(path: String, docket: String) {
        // Cancel any existing regeneration task to prevent accumulation
        if prepSummaryRegenerationTask != nil {
            print("🛑 [DEBUG] Cancelling previous prep summary regeneration task")
            prepSummaryRegenerationTask?.cancel()
        }
        
        print("🚀 [DEBUG] Starting prep summary regeneration for: \(path)")
        prepSummaryRegenerationTask = Task { [weak self] in
            guard let self = self else {
                print("⚠️ [DEBUG] Summary regeneration task: self is nil")
                return
            }
            
            // Check if task was cancelled
            guard !Task.isCancelled else {
                print("🛑 [DEBUG] Summary regeneration task cancelled immediately")
                return
            }
            
            let jobName = await MainActor.run { self.getJobName(for: docket) }
            
            // Check again after getting job name
            guard !Task.isCancelled else {
                print("🛑 [DEBUG] Summary regeneration task cancelled after getting job name")
                return
            }
            
            print("📊 [DEBUG] Generating prep summary...")
            let summary = await MediaLogic.generatePrepSummary(
                docket: docket,
                jobName: jobName,
                prepFolderPath: path,
                config: self.config
            )

            // Final cancellation check
            guard !Task.isCancelled else {
                print("🛑 [DEBUG] Summary regeneration task cancelled after generating summary")
                return
            }

            // Save updated summary
            let summaryFile = URL(fileURLWithPath: path).appendingPathComponent("\(docket)_Prep_Summary.txt")
            try? summary.write(to: summaryFile, atomically: true, encoding: .utf8)

            // Update UI only if not cancelled
            guard !Task.isCancelled else {
                print("🛑 [DEBUG] Summary regeneration task cancelled before UI update")
                return
            }
            
            await MainActor.run {
                self.prepSummary = summary
            }
            print("✅ [DEBUG] Prep summary regeneration completed successfully")
        }
    }

    // MARK: - Video Conversion

    /// Start background video conversion
    func startVideoConversion(aspectRatio: AspectRatio, outputDirectory: URL) async {
        guard let converter = videoConverter else { return }

        // Cancel any existing monitoring task
        conversionMonitoringTask?.cancel()
        conversionMonitoringTask = nil

        // Get video files from staging area
        let videoExtensions = ["mp4", "mov", "avi", "mxf", "m4v", "prores"]
        let videoFiles = selectedFiles.filter { item in
            !item.isDirectory && videoExtensions.contains(item.url.pathExtension.lowercased())
        }

        guard !videoFiles.isEmpty else { return }

        // Add files to converter
        converter.addFiles(
            urls: videoFiles.map { $0.url },
            format: .proResProxy,
            aspectRatio: aspectRatio,
            outputDirectory: outputDirectory
        )

        // Start conversion and monitor progress
        isConverting = true

        // Monitor conversion progress in parallel with proper cleanup
        conversionMonitoringTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled && self.isConverting {
                // Update progress for each job
                for job in converter.jobs {
                    // Find matching file item by URL
                    if let fileItem = self.selectedFiles.first(where: { $0.url == job.sourceURL }) {
                        self.conversionProgress[fileItem.id] = job.progress
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
        }

        // Start the actual conversion
        await converter.startConversion()

        // Mark conversion as complete and cleanup
        isConverting = false
        conversionMonitoringTask?.cancel()
        conversionMonitoringTask = nil

        // Clear progress
        conversionProgress.removeAll()
    }

    /// Get video files from staging area
    func getVideoFiles() -> [FileItem] {
        let videoExtensions = ["mp4", "mov", "avi", "mxf", "m4v", "prores"]
        return selectedFiles.filter { item in
            !item.isDirectory && videoExtensions.contains(item.url.pathExtension.lowercased())
        }
    }

    /// Convert videos during prep and move originals to z_unconverted
    func convertPrepVideos() async {
        guard let pending = pendingPrepConversion,
              let converter = videoConverter else {
            showConvertVideosPrompt = false
            return
        }

        let fm = FileManager.default
        let pictureFolder = pending.root.appendingPathComponent(config.settings.pictureFolderName)
        let unconvertedFolder = pictureFolder.appendingPathComponent("z_unconverted")

        // Create z_unconverted folder
        try? fm.createDirectory(at: unconvertedFolder, withIntermediateDirectories: true)

        statusMessage = "Moving originals to z_unconverted..."

        // Copy video files directly to z_unconverted (they should have been skipped during prep)
        for (videoURL, _) in pending.videoFiles {
            let filename = videoURL.lastPathComponent
            let unconvertedPath = unconvertedFolder.appendingPathComponent(filename)

            // Copy source directly to z_unconverted (should not be in picture folder)
            if !fm.fileExists(atPath: unconvertedPath.path) {
                try? fm.copyItem(at: videoURL, to: unconvertedPath)
            }
            
            // If file somehow ended up in picture folder, remove it
            let picturePath = pictureFolder.appendingPathComponent(filename)
            if fm.fileExists(atPath: picturePath.path) {
                try? fm.removeItem(at: picturePath)
            }

            // Add source file to converter to create ProRes version in PICTURE folder
            // For prep: Always 1920x1080, ProRes Proxy, 23.976fps, keep original filename
            converter.addFiles(
                urls: [videoURL],
                format: .proResProxy,
                aspectRatio: .sixteenNine, // Always 16:9 (1920x1080) for prep
                outputDirectory: pictureFolder,
                keepOriginalName: true // Keep original filename during prep
            )
        }

        statusMessage = "Converting videos to ProRes..."

        // Start conversion
        showConvertVideosPrompt = false
        pendingPrepConversion = nil

        await converter.startConversion()

        statusMessage = "Conversion complete"
    }

    /// Skip video conversion during prep
    func skipPrepVideoConversion() {
        showConvertVideosPrompt = false
        pendingPrepConversion = nil
    }
    
    deinit {
        // Clean up resources when MediaManager is deallocated
        prepFolderWatcher?.cancel()
        prepFolderWatcher = nil
        conversionMonitoringTask?.cancel()
        conversionMonitoringTask = nil
        prepSummaryRegenerationTask?.cancel()
        prepSummaryRegenerationTask = nil
        prepSummaryRegenerationWorkItem?.cancel()
        prepSummaryRegenerationWorkItem = nil
    }
}
