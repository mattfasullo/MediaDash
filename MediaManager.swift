import Foundation
import AppKit
import Combine
import AVFoundation

// --- CONFIGURATION (Strictly Non-Isolated) ---
struct AppConfig: Sendable {
    let settings: AppSettings

    nonisolated init(settings: AppSettings) {
        self.settings = settings
    }

    nonisolated func getPaths() -> (workPic: URL, prep: URL) {
        let year = Calendar.current.component(.year, from: Date())
        let serverRoot = URL(fileURLWithPath: settings.serverBasePath)
            .appendingPathComponent("\(settings.yearPrefix)\(year)")
        let wp = serverRoot.appendingPathComponent("\(year)_\(settings.workPictureFolderName)")
        let prep = serverRoot.appendingPathComponent("\(year)_\(settings.prepFolderName)")
        return (wp, prep)
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

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = exists && isDir.boolValue

        if self.isDirectory {
            self.fileCount = Self.countFilesRecursively(in: url)
        } else {
            self.fileCount = 1
        }
    }

    private static func countFilesRecursively(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
               let isRegularFile = resourceValues.isRegularFile,
               isRegularFile {
                count += 1
            }
        }
        return count
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
        let paths = config.getPaths()
        // For Both mode, show Work Picture folders (we'll check for prep folders later)
        let base = (jobType == .prep) ? paths.prep : paths.workPic
        var results: [String] = []
        do {
            let items = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])
            let sorted = items.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
            for item in sorted {
                if item.hasDirectoryPath && !item.lastPathComponent.hasPrefix(".") {
                    // For prep mode, extract just the docket number from folder name
                    if jobType == .prep {
                        // Prep folders are named like "12345_PREP_Dec4.24"
                        // Extract just "12345" part
                        let folderName = item.lastPathComponent
                        if let docketNumber = folderName.split(separator: "_").first {
                            let docketStr = String(docketNumber)
                            if !results.contains(docketStr) {
                                results.append(docketStr)
                            }
                        }
                    } else {
                        // For work picture, just use the folder name (which is the docket number)
                        results.append(item.lastPathComponent)
                    }
                }
            }
        } catch {
            print("Error scanning dockets: \(error.localizedDescription)")
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
            let baseGM = URL(fileURLWithPath: "/Volumes/Grayson Assets/GM")
            if let yearFolders = try? fm.contentsOfDirectory(at: baseGM, includingPropertiesForKeys: nil) {
                for yearFolder in yearFolders where yearFolder.lastPathComponent.hasPrefix("GM_") {
                    let workPicPath = yearFolder.appendingPathComponent(yearFolder.lastPathComponent.replacingOccurrences(of: "GM_", with: "") + "_WORK PICTURE")
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
        var summary = "\(docket) - \(jobName) Prep\n\n"

        guard fm.fileExists(atPath: prepFolderPath) else {
            return summary + "Prep folder not found."
        }

        // PICTURE
        let picturePath = prepURL.appendingPathComponent(config.settings.pictureFolderName)
        if fm.fileExists(atPath: picturePath.path) {
            let videoFiles = (try? fm.contentsOfDirectory(at: picturePath, includingPropertiesForKeys: nil))?.filter {
                config.settings.pictureExtensions.contains($0.pathExtension.lowercased())
            } ?? []

            if !videoFiles.isEmpty {
                var durationGroups: [String: Int] = [:]
                for video in videoFiles {
                    if let duration = await getVideoDuration(video) {
                        let formatted = formatDuration(duration)
                        durationGroups[formatted, default: 0] += 1
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

    private var cachedSessions: [String] = [] // Legacy - for backward compatibility
    var folderCaches: [SearchFolder: [String]] = [:] // New cache system - internal for validation
    private var finderScript: NSAppleScript?
    var config: AppConfig // Internal for DocketSearchView access
    private var prepFolderWatcher: DispatchSourceFileSystemObject?
    private var currentPrepFolder: String?
    private var metadataManager: DocketMetadataManager
    var videoConverter: VideoConverterManager?

    init(settingsManager: SettingsManager, metadataManager: DocketMetadataManager) {
        self.config = AppConfig(settings: settingsManager.currentSettings)
        self.metadataManager = metadataManager
        let source = """
        tell application "Finder"
            set selectionList to selection
            set pathList to {}
            repeat with i in selectionList
                set end of pathList to POSIX path of (i as alias)
            end repeat
            return pathList
        end tell
        """
        self.finderScript = NSAppleScript(source: source)

        // Check directory access on startup
        checkAllDirectoryAccess()

        refreshDockets()
        buildSessionIndex()
        startFinderLoop()

        // Initialize video converter
        self.videoConverter = VideoConverterManager()
    }
    
    func updateConfig(settings: AppSettings) {
        self.config = AppConfig(settings: settings)
        refreshDockets()
        buildSessionIndex()
    }

    // MARK: - Directory Connection Checking

    /// Check if required directories are accessible based on operation type
    func checkDirectoryAccess(for operation: String) -> Bool {
        let fm = FileManager.default
        var missingPaths: [String] = []

        // Check server base path for work picture and prep operations
        if operation.contains("Work Picture") || operation.contains("Prep") || operation.contains("Both") {
            let serverBase = config.settings.serverBasePath
            if !fm.fileExists(atPath: serverBase) {
                missingPaths.append("Server: \(serverBase)")
            }
        }

        // Check sessions base path for search operations
        if operation.contains("Search") || operation.contains("Index") {
            let sessionsBase = config.settings.sessionsBasePath
            if !fm.fileExists(atPath: sessionsBase) {
                missingPaths.append("Sessions: \(sessionsBase)")
            }
        }

        if !missingPaths.isEmpty {
            connectionWarning = "Required directories not connected:\n\n" + missingPaths.joined(separator: "\n") + "\n\nPlease connect to these directories and try again."
            showConnectionWarning = true
            return false
        }

        return true
    }

    /// Check general directory access (for startup checks)
    func checkAllDirectoryAccess() {
        let fm = FileManager.default
        var warnings: [String] = []

        let serverBase = config.settings.serverBasePath
        if !fm.fileExists(atPath: serverBase) {
            warnings.append("• Server path not connected: \(serverBase)")
        }

        let sessionsBase = config.settings.sessionsBasePath
        if !fm.fileExists(atPath: sessionsBase) {
            warnings.append("• Sessions path not connected: \(sessionsBase)")
        }

        if !warnings.isEmpty {
            connectionWarning = "Some directories are not connected:\n\n" + warnings.joined(separator: "\n") + "\n\nSome features may not work until these directories are connected.\n\nYou can update paths in Settings if needed."
            showConnectionWarning = true
        }
    }

    func refreshDockets() {
        guard !isScanningDockets else { return }
        isScanningDockets = true
        let currentConfig = self.config
        Task.detached {
            let dockets = MediaLogic.scanDockets(config: currentConfig)
            await MainActor.run {
                self.dockets = dockets
                self.isScanningDockets = false
            }
        }
    }
    
    func buildSessionIndex(folder: SearchFolder = .sessions) {
        // Skip if this folder is already being indexed or is already cached
        guard !indexingFolders.contains(folder) && folderCaches[folder] == nil else { return }

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
        // Build index for this folder if not cached
        if folderCaches[folder] == nil { buildSessionIndex(folder: folder) }
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
    
    func startFinderLoop() {
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !isProcessing { checkFinder() }
            }
        }
    }
    
    func checkFinder() {
        var error: NSDictionary?
        if let output = finderScript?.executeAndReturnError(&error) {
            var newItems: [FileItem] = []
            let count = output.numberOfItems
            if count > 0 {
                for i in 1...count {
                    if let path = output.atIndex(i)?.stringValue {
                        newItems.append(FileItem(url: URL(fileURLWithPath: path)))
                    }
                }
            }
            if newItems != selectedFiles { selectedFiles = newItems }
        }
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
    
    func clearFiles() { selectedFiles.removeAll() }

    func cancelProcessing() {
        cancelRequested = true
        statusMessage = "Cancelling..."
    }
    
    func runJob(type: JobType, docket: String, wpDate: Date, prepDate: Date) {
        if selectedFiles.isEmpty { pickFiles(); return }

        // Check directory access before starting
        if !checkDirectoryAccess(for: type.rawValue) {
            return
        }

        cancelRequested = false
        isProcessing = true; progress = 0; statusMessage = "Starting..."
        fileProgress.removeAll() // Clear any previous progress
        fileCompletionState.removeAll() // Clear completion states
        let files = selectedFiles
        let currentConfig = self.config
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let paths = currentConfig.getPaths()
            let total = Double(files.count * (type == .both ? 2 : 1))
            var currentStep = 0.0
            
            var failedFiles: [String] = []

            if type == .workPicture || type == .both {
                await MainActor.run { self.statusMessage = "Filing..." }
                let dateStr = self.formatDate(wpDate)
                let base = paths.workPic.appendingPathComponent(docket)
                let destFolder = self.getNextFolder(base: base, date: dateStr)
                do {
                    try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Failed to create work picture folder: \(error.localizedDescription)"
                        self.showError = true
                        self.isProcessing = false
                    }
                    return
                }

                for f in files {
                    let shouldCancel = await MainActor.run { self.cancelRequested }
                    if shouldCancel {
                        break
                    }

                    // Mark file as starting
                    await MainActor.run { self.fileProgress[f.id] = 0.0 }

                    let dest = destFolder.appendingPathComponent(f.name)
                    if !self.copyItem(from: f.url, to: dest) {
                        failedFiles.append(f.name)
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
                await MainActor.run { self.statusMessage = "Prepping..." }
                let dateStr = self.formatDate(prepDate)
                let folder = "\(docket)_PREP_\(dateStr)"
                let root = paths.prep.appendingPathComponent(folder)
                prepDestinationFolder = root
                do {
                    try fm.createDirectory(at: root, withIntermediateDirectories: true)
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Failed to create prep folder: \(error.localizedDescription)"
                        self.showError = true
                        self.isProcessing = false
                    }
                    return
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

                    let cat = self.getCategory(flatFile, config: currentConfig)
                    let dir = root.appendingPathComponent(cat)
                    do {
                        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    } catch {
                        print("Error creating category directory \(cat): \(error.localizedDescription)")
                    }

                    if !self.copyItem(from: flatFile, to: dir.appendingPathComponent(flatFile.lastPathComponent)) {
                        failedFiles.append(flatFile.lastPathComponent)
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

                // Organize stems and generate summary
                if type == .prep || type == .both {
                    await MainActor.run { self.statusMessage = "Organizing stems..." }
                    self.organizeStems(in: root, config: currentConfig)

                    // Get job name for summary
                    let jobName = await MainActor.run { self.getJobName(for: docket) }

                    await MainActor.run { self.statusMessage = "Generating prep summary..." }
                    let summary = await MediaLogic.generatePrepSummary(
                        docket: docket,
                        jobName: jobName,
                        prepFolderPath: root.path,
                        config: currentConfig
                    )

                    // Save summary to file
                    let summaryFile = root.appendingPathComponent("\(docket)_Prep_Summary.txt")
                    try? summary.write(to: summaryFile, atomically: true, encoding: .utf8)

                    // Update UI and setup file watching
                    await MainActor.run {
                        self.prepSummary = summary
                        self.showPrepSummary = true
                        self.currentPrepFolder = root.path
                        self.setupPrepFolderWatcher(path: root.path, docket: docket)
                    }
                }
            }

            // Capture failedFiles before entering MainActor context
            let finalFailedFiles = failedFiles
            let prepFolderToOpen = prepDestinationFolder

            let wasCancelled = await self.cancelRequested

            await MainActor.run {
                if wasCancelled {
                    self.isProcessing = false
                    self.statusMessage = "Cancelled"
                    return
                }
                self.isProcessing = false
                if finalFailedFiles.isEmpty {
                    self.statusMessage = "Done!"
                    NSSound(named: "Glass")?.play()

                    // Open prep folder if setting is enabled
                    if let prepFolder = prepFolderToOpen, self.config.settings.openPrepFolderWhenDone {
                        NSWorkspace.shared.open(prepFolder)
                    }
                } else {
                    self.statusMessage = "Completed with \(finalFailedFiles.count) error(s)"
                    self.errorMessage = "Failed to copy these files:\n\(finalFailedFiles.joined(separator: "\n"))"
                    self.showError = true
                }
            }
        }
    }
    
    nonisolated private func formatDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMd.yy"; return f.string(from: d)
    }
    
    nonisolated private func getNextFolder(base: URL, date: String) -> URL {
        let fm = FileManager.default
        var p = 1
        if let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            let matches = items.filter { $0.lastPathComponent.hasSuffix(date) }
            let nums = matches.compactMap { Int($0.lastPathComponent.split(separator: "_").first ?? "") }
            if let max = nums.max() { p = max + 1 }
        }
        return base.appendingPathComponent(String(format: "%02d_%@", p, date))
    }
    
    nonisolated private func getCategory(_ u: URL, config: AppConfig) -> String {
        let e = u.pathExtension.lowercased()
        if config.settings.pictureExtensions.contains(e) { return config.settings.pictureFolderName }
        if config.settings.musicExtensions.contains(e) { return config.settings.musicFolderName }
        if config.settings.aafOmfExtensions.contains(e) { return config.settings.aafOmfFolderName }
        return config.settings.otherFolderName
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

    /// Get job name from docket metadata
    func getJobName(for docket: String) -> String {
        // Try to find metadata entry for this docket number
        for (_, metadata) in metadataManager.metadata {
            if metadata.docketNumber == docket && !metadata.jobName.isEmpty {
                return metadata.jobName
            }
        }
        // Fallback to docket number
        return docket
    }

    /// Setup file system monitoring for prep folder
    func setupPrepFolderWatcher(path: String, docket: String) {
        // Stop existing watcher
        prepFolderWatcher?.cancel()
        prepFolderWatcher = nil

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .background)
        )

        source.setEventHandler { [weak self] in
            // Regenerate summary when folder changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.regeneratePrepSummary(path: path, docket: docket)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        prepFolderWatcher = source
    }

    /// Regenerate prep summary
    func regeneratePrepSummary(path: String, docket: String) {
        Task {
            let jobName = getJobName(for: docket)
            let summary = await MediaLogic.generatePrepSummary(
                docket: docket,
                jobName: jobName,
                prepFolderPath: path,
                config: config
            )

            // Save updated summary
            let summaryFile = URL(fileURLWithPath: path).appendingPathComponent("\(docket)_Prep_Summary.txt")
            try? summary.write(to: summaryFile, atomically: true, encoding: .utf8)

            // Update UI
            await MainActor.run {
                self.prepSummary = summary
            }
        }
    }

    // MARK: - Video Conversion

    /// Start background video conversion
    func startVideoConversion(aspectRatio: AspectRatio, outputDirectory: URL) async {
        guard let converter = videoConverter else { return }

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

        // Monitor conversion progress in parallel
        Task {
            while isConverting {
                // Update progress for each job
                for job in converter.jobs {
                    // Find matching file item by URL
                    if let fileItem = selectedFiles.first(where: { $0.url == job.sourceURL }) {
                        conversionProgress[fileItem.id] = job.progress
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
        }

        // Start the actual conversion
        await converter.startConversion()

        // Mark conversion as complete
        isConverting = false

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

        // Move already-copied files to z_unconverted and prepare for conversion
        for (videoURL, _) in pending.videoFiles {
            let filename = videoURL.lastPathComponent
            let picturePath = pictureFolder.appendingPathComponent(filename)
            let unconvertedPath = unconvertedFolder.appendingPathComponent(filename)

            // If file was already copied to picture folder during prep, move it to z_unconverted
            if fm.fileExists(atPath: picturePath.path) {
                // Copy to z_unconverted (keep original)
                try? fm.copyItem(at: picturePath, to: unconvertedPath)
                // Remove from PICTURE (will be replaced with converted version)
                try? fm.removeItem(at: picturePath)
            } else {
                // File wasn't copied yet, so copy source to z_unconverted
                try? fm.copyItem(at: videoURL, to: unconvertedPath)
            }

            // Add source file to converter to create ProRes version in PICTURE folder
            converter.addFiles(
                urls: [videoURL],
                format: .proResProxy,
                aspectRatio: .sixteenNine, // Always 16:9 for prep
                outputDirectory: pictureFolder
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
}
