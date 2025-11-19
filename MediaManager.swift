import Foundation
import AppKit
import Combine

// --- CONFIGURATION (Strictly Non-Isolated) ---
struct AppConfig: Sendable {
    let settings: AppSettings

    init(settings: AppSettings) {
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

struct FileItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let name: String

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
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

    nonisolated static func scanDockets(config: AppConfig) -> [String] {
        let base = config.getPaths().workPic
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
                    results.append(item.lastPathComponent)
                }
            }
        } catch {
            print("Error scanning dockets: \(error.localizedDescription)")
        }
        return results
    }
    
    nonisolated static func buildIndex(config: AppConfig) -> [String] {
        let base = URL(fileURLWithPath: config.sessionsBasePath)
        var index: [String] = []
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: base.path, isDirectory: &isDir) {
            do {
                let contents = try fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
                let years = contents.filter { $0.lastPathComponent.contains("_PROTOOLS SESSIONS") }
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
}

@MainActor
class MediaManager: ObservableObject {
    @Published var selectedFiles: [FileItem] = []
    @Published var dockets: [String] = []
    @Published var statusMessage: String = "Ready"
    @Published var isProcessing: Bool = false
    @Published var cancelRequested: Bool = false
    @Published var progress: Double = 0
    @Published var isIndexing: Bool = false
    @Published var isScanningDockets: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    private var cachedSessions: [String] = []
    private var finderScript: NSAppleScript?
    private var config: AppConfig

    init(settingsManager: SettingsManager) {
        self.config = AppConfig(settings: settingsManager.currentSettings)
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
        
        refreshDockets()
        buildSessionIndex()
        startFinderLoop()
    }
    
    func updateConfig(settings: AppSettings) {
        self.config = AppConfig(settings: settings)
        refreshDockets()
        buildSessionIndex()
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
    
    func buildSessionIndex() {
        guard !isIndexing else { return }
        isIndexing = true
        let currentConfig = self.config
        Task.detached(priority: .userInitiated) {
            let index = MediaLogic.buildIndex(config: currentConfig)
            await MainActor.run {
                self.cachedSessions = index
                self.isIndexing = false
            }
        }
    }
    
    func searchSessions(term: String) async -> SearchResults {
        if cachedSessions.isEmpty { buildSessionIndex() }
        if term.isEmpty { return SearchResults(exactMatches: [], fuzzyMatches: []) }

        let currentCache = cachedSessions
        let fuzzyEnabled = config.settings.enableFuzzySearch
        return await Task.detached(priority: .userInitiated) {
            let lower = term.localizedLowercase

            // 1. Exact matches (contains) - highest priority
            let exactMatches = currentCache.filter { $0.lowercased().contains(lower) }

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
        cancelRequested = false
        isProcessing = true; progress = 0; statusMessage = "Starting..."
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
                    let dest = destFolder.appendingPathComponent(f.name)
                    if !self.copyItem(from: f.url, to: dest) {
                        failedFiles.append(f.name)
                    }

                    // FIX: Inline update
                    currentStep += 1
                    let p = currentStep / total
                    await MainActor.run { self.progress = p }
                }
            }
            
            if type == .prep || type == .both {
                await MainActor.run { self.statusMessage = "Prepping..." }
                let dateStr = self.formatDate(prepDate)
                let folder = "\(docket)_PREP_\(dateStr)"
                let root = paths.prep.appendingPathComponent(folder)
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

                var flats: [URL] = []
                for f in files {
                    flats.append(contentsOf: MediaLogic.getAllFiles(at: f.url))
                }

                for f in flats {
                    let shouldCancel = await MainActor.run { self.cancelRequested }
                    if shouldCancel {
                        break
                    }
                    let cat = self.getCategory(f, config: currentConfig)
                    let dir = root.appendingPathComponent(cat)
                    do {
                        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    } catch {
                        print("Error creating category directory \(cat): \(error.localizedDescription)")
                    }

                    if !self.copyItem(from: f, to: dir.appendingPathComponent(f.lastPathComponent)) {
                        failedFiles.append(f.lastPathComponent)
                    }

                    // Update progress for prep files
                    currentStep += 1
                    let p = currentStep / total
                    await MainActor.run { self.progress = p }
                }
            }

            // Capture failedFiles before entering MainActor context
            let finalFailedFiles = failedFiles

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
}
