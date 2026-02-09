import Foundation
import Combine

/// Manages shared cache access for Asana docket information
/// MediaDash relies solely on the shared cache - no local cache is maintained
@MainActor
class AsanaCacheManager: ObservableObject {
    private let asanaService: AsanaService
    @Published var lastSyncDate: Date?
    @Published var isSyncing = false
    @Published var syncError: String?
    @Published var cacheStatus: CacheStatus = .unknown
    @Published var syncProgress: Double = 0  // 0.0 to 1.0
    @Published var syncPhase: String = ""    // Human-readable phase description
    @Published var cachedDockets: [DocketInfo] = []
    @Published var cachedSessions: [AsanaTask] = []  // Upcoming sessions for Prep (today + 5 business days)
    @Published var lastSessionSyncDate: Date?
    /// Sessions for the full 2-week calendar view (next 14 calendar days).
    @Published var cachedSessionsTwoWeeks: [AsanaTask] = []
    @Published var lastSessionTwoWeeksSyncDate: Date?
    /// All tasks (sessions + other) for the full 2-week calendar (next 14 days).
    @Published var cachedTasksTwoWeeks: [AsanaTask] = []
    @Published var lastTasksTwoWeeksSyncDate: Date?
    
    // Track the last reported progress to ensure monotonic increase
    private var lastReportedProgress: Double = 0
    
    // Cache file name - used for reading from shared cache location
    private let cacheFileName = "mediadash_docket_cache.json"
    
    // Store current settings for cache access
    private var sharedCacheURL: String?
    private var useSharedCache: Bool = false
    private var serverBasePath: String?
    private var serverConnectionURL: String?
    
    // Periodic status check timer
    // Note: Using nonisolated(unsafe) to allow cleanup from deinit.
    // This is safe because timers are only invalidated (not created) from nonisolated context.
    nonisolated(unsafe) private var statusCheckTimer: Timer?

    // Periodic sync timer for automatic change detection
    nonisolated(unsafe) private var syncTimer: Timer?

    // Flag to prevent operations after shutdown
    private var isShuttingDown = false
    
    // Store sync settings for periodic background sync
    private var syncWorkspaceID: String?
    private var syncProjectID: String?
    private var syncDocketField: String?
    private var syncJobNameField: String?
    
    // Track last error state to avoid repeated logging
    private var lastSharedCacheError: String?
    private var lastEmptyFileCheck: Date?
    
    // Date formatter for YYYY-MM-DD comparison
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    
    /// Cache status indicator with server connection information
    enum CacheStatus {
        case serverConnectedUsingShared      // Server connected and using shared cache
        case serverConnectedNoCache          // Server connected but no cache available
        case serverDisconnectedNoCache       // Server not connected and no cache available
        case unknown                         // Status not yet determined
    }
    
    /// Published validation result for UI display
    @Published var cacheValidationResult: CacheValidationResult?
    @Published var cacheDataIssues: [String] = []
    
    init() {
        self.asanaService = AsanaService()
        
        // Initial cache status will be set when settings are loaded via updateCacheSettings
    }
    
    /// Public access to the Asana service for fetching additional data (e.g., subtask assignees)
    var service: AsanaService {
        asanaService
    }
    
    /// Update cache settings (call when settings change or on init)
    func updateCacheSettings(sharedCacheURL: String?, useSharedCache: Bool, serverBasePath: String? = nil, serverConnectionURL: String? = nil) {
        self.sharedCacheURL = sharedCacheURL
        self.useSharedCache = useSharedCache
        
        // Store server base path and connection URL for connection checking
        self.serverBasePath = serverBasePath
        self.serverConnectionURL = serverConnectionURL
        
        // Reload lastSyncDate from shared cache
        reloadLastSyncDate()
        
        // Defer cache status check to avoid modifying during view updates
        Task { @MainActor in
            updateCacheStatus()
        }
        
        // Also re-check status after a short delay to catch cases where the file becomes available
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
                updateCacheStatus()
            }
        }
        
        // Start periodic status checking for cache status
        startPeriodicStatusCheck()

        // Preload cache data so views can render immediately
        Task { @MainActor in
            await Task.yield()
            refreshCachedDocketsFromDisk()
        }
    }
    
    /// Update sync settings (for manual sync from Job Info or Settings)
    func updateSyncSettings(workspaceID: String?, projectID: String?, docketField: String?, jobNameField: String?) {
        self.syncWorkspaceID = workspaceID
        self.syncProjectID = projectID
        self.syncDocketField = docketField
        self.syncJobNameField = jobNameField
        
        // Reload lastSyncDate from shared cache
        reloadLastSyncDate()
        
        stopPeriodicSync()
    }
    
    /// Start periodic status checking to keep indicators updated
    private func startPeriodicStatusCheck() {
        // Stop existing timer if any
        statusCheckTimer?.invalidate()

        // Create new timer that checks status every 30 seconds (reduced from 5 seconds)
        // Cache status doesn't change frequently enough to justify checking every 5 seconds,
        // and the frequent file I/O was causing UI sluggishness
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCacheStatus()
            }
        }

        // Add timer to run loop so it works even when app is active
        if let timer = statusCheckTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    /// Stop periodic status checking
    nonisolated private func stopPeriodicStatusCheck() {
        // Timer invalidation can be done from any thread
        if let timer = statusCheckTimer {
            timer.invalidate()
        }
        // Note: We can't set statusCheckTimer to nil from nonisolated context,
        // but invalidating the timer is sufficient for cleanup
    }
    
    nonisolated deinit {
        // Invalidate timers from deinit (runs in nonisolated context)
        statusCheckTimer?.invalidate()
        syncTimer?.invalidate()
    }

    /// Call this to cleanly shut down the cache manager before releasing it
    func shutdown() {
        isShuttingDown = true

        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    /// Start periodic background sync to detect changes automatically
    private func startPeriodicSync() {
        // Stop existing timer if any
        syncTimer?.invalidate()
        
        // Create new timer that performs incremental sync every 5 minutes (300 seconds)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    print("⚠️ [Background Sync] Cache manager deallocated - periodic sync stopped")
                    return
                }
                await self.performBackgroundSync()
            }
        }
        
        // Add timer to run loop so it works even when app is active
        if let timer = syncTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        print("🔄 [Cache] Started periodic background sync (every 5 minutes)")
        
        // Note: This function should not be called anymore - automatic sync is handled by external service
        // MediaDash only performs manual syncs via the UI
    }
    
    /// Stop periodic background sync
    private func stopPeriodicSync() {
        if let timer = syncTimer {
            timer.invalidate()
            syncTimer = nil
            print("🔄 [Cache] Stopped periodic background sync")
        }
    }
    
    /// Perform background incremental sync to detect changes
    /// NOTE: MediaDash no longer performs background syncs - external service handles this
    private func performBackgroundSync() async {
        // MediaDash should NEVER sync from Asana API
        // Only read from shared cache if available - external service handles all syncing
        print("🔄 [Background Sync] MediaDash does not perform background syncs - external service handles this")
        
        // Check if shared cache is available and update lastSyncDate
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            let fileURL = getFileURL(from: sharedURL)
            if let data = try? Data(contentsOf: fileURL),
               let cached = try? JSONDecoder().decode(CachedDockets.self, from: data),
               !cached.dockets.isEmpty {
                // Update lastSyncDate from shared cache
                self.lastSyncDate = cached.lastSync
                print("🟢 [Background Sync] Updated lastSyncDate from shared cache")
            } else {
                print("⚠️ [Background Sync] Shared cache not available - waiting for external service")
            }
        } else {
            print("⚠️ [Background Sync] Shared cache not configured - external service handles syncing")
        }
    }
    
    /// Check if server is connected by detecting which network server the base path is on
    private func isServerConnected() -> Bool {
        // Primary method: Check if the volume that serverBasePath is on is mounted
        // This detects the actual server that's mounted, regardless of IP/hostname
        if let serverBase = serverBasePath, !serverBase.isEmpty {
            // Extract the volume name from the path (e.g., "/Volumes/Grayson Assets/GM" -> "Grayson Assets")
            let pathComponents = (serverBase as NSString).pathComponents
            if pathComponents.count >= 2 && pathComponents[1] == "Volumes" && pathComponents.count >= 3 {
                let volumeName = pathComponents[2]
                let volumePath = "/Volumes/\(volumeName)"
                
                // Check if the volume exists
                let volumeExists = FileManager.default.fileExists(atPath: volumePath)
                if volumeExists {
                    // Verify it's actually a network mount (not a local disk)
                    let isNetworkMount = checkIfVolumeIsNetworkMount(volumePath: volumePath)
                    // Only log if debugging is needed - too verbose for normal operation
                    // print("🔍 [Cache Status] Volume check: \(volumePath) → \(volumeExists ? "exists" : "does not exist") (\(isNetworkMount ? "network mount" : "local"))")
                    if isNetworkMount {
                        return true
                    }
                    // If it exists but is local, we'll fall through to other checks
                }
                // Removed verbose logging for non-existent volumes
            }
        }
        
        // Fallback: If serverConnectionURL is explicitly set, use it to check
        if let connectionURL = serverConnectionURL, !connectionURL.isEmpty {
            let isMounted = checkIfServerIsMounted(connectionURL: connectionURL)
            // Only log if debugging is needed - too verbose for normal operation
            // print("🔍 [Cache Status] Server connection check: \(connectionURL) → \(isMounted ? "mounted" : "not mounted")")
            if isMounted {
                return true
            }
        }
        
        // Fallback: check if shared cache parent directory exists and is on a network mount
        if let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            let fileURL = getFileURL(from: sharedURL)
            let parentDir = fileURL.deletingLastPathComponent()
            let parentPath = parentDir.path
            let parentExists = FileManager.default.fileExists(atPath: parentPath)
            
            if parentExists {
                // Check if parent is on a network mount
                let pathComponents = (parentPath as NSString).pathComponents
                if pathComponents.count >= 2 && pathComponents[1] == "Volumes" && pathComponents.count >= 3 {
                    let volumeName = pathComponents[2]
                    let volumePath = "/Volumes/\(volumeName)"
                    let isNetworkMount = checkIfVolumeIsNetworkMount(volumePath: volumePath)
                    // Only log if debugging is needed - too verbose for normal operation
                    // print("🔍 [Cache Status] Shared cache parent check: \(parentPath) → \(parentExists ? "exists" : "does not exist") (\(isNetworkMount ? "network mount" : "local"))")
                    if isNetworkMount {
                        return true
                    }
                }
                return parentExists
            }
            // Removed verbose logging for non-existent parent directories
        }
        
        // If no paths configured, we can't determine connection status
        return false
    }
    
    /// Check if a volume is a network mount (vs local disk)
    nonisolated private func checkIfVolumeIsNetworkMount(volumePath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.arguments = ["-t", "smbfs,afpfs,cifs,nfs"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Check if this volume path appears in the network mount output
                // Mount output format: "//server/share on /Volumes/Name (smbfs, ...)"
                if output.contains(volumePath) {
                    return true
                }
            }
        } catch {
            // If the command fails, try checking all mounts
        }
        
        // Fallback: Check all mounts and look for network filesystem types
        let allMountsProcess = Process()
        allMountsProcess.executableURL = URL(fileURLWithPath: "/sbin/mount")
        
        let allMountsPipe = Pipe()
        allMountsProcess.standardOutput = allMountsPipe
        
        do {
            try allMountsProcess.run()
            allMountsProcess.waitUntilExit()
            
            let data = allMountsPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Look for the volume path and check if it has a network filesystem type
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.contains(volumePath) {
                        // Check for network filesystem indicators
                        let networkFS = ["smbfs", "afpfs", "cifs", "nfs", "//"]
                        for fs in networkFS {
                            if line.contains(fs) {
                                return true
                            }
                        }
                    }
                }
            }
        } catch {
            print("⚠️ [Cache Status] Failed to check mount type: \(error.localizedDescription)")
        }
        
        return false
    }
    
    /// Check if a specific server (by IP/hostname) is mounted (for explicit server connection URL)
    nonisolated private func checkIfServerIsMounted(connectionURL: String) -> Bool {
        // Extract hostname/IP from URL (remove protocol if present)
        var hostname = connectionURL
        if let url = URL(string: connectionURL) {
            hostname = url.host ?? connectionURL
        } else if connectionURL.hasPrefix("smb://") || connectionURL.hasPrefix("afp://") {
            // Remove protocol prefix
            hostname = String(connectionURL.dropFirst(6))
            if let slashIndex = hostname.firstIndex(of: "/") {
                hostname = String(hostname[..<slashIndex])
            }
        }
        
        // Check mount points using `mount` command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Check if the hostname appears in any mount point
                // Mount output format: "//server/share on /Volumes/Name (smbfs, ...)"
                if output.contains(hostname) {
                    return true
                }
            }
        } catch {
            print("⚠️ [Cache Status] Failed to check mounts: \(error.localizedDescription)")
        }
        
        return false
    }
    
    /// Update cache status by checking which cache is available and server connection
    private func updateCacheStatus() {
        let serverConnected = isServerConnected()
        let fm = FileManager.default
        
        // Try shared cache first if enabled
        var sharedCacheAvailable = false
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            let fileURL = getFileURL(from: sharedURL)
            let fileExists = fm.fileExists(atPath: fileURL.path)
            
            if fileExists {
                // Check file size first to detect empty files
                var isEmpty = false
                if let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
                   let size = attributes[.size] as? Int64 {
                    isEmpty = size == 0
                }
                
                if isEmpty {
                    // Empty file detected - this is corruption
                    let errorMsg = "File is empty (0 bytes) - corrupted cache"
                    
                    // Only log if this is a new error or enough time has passed (every 5 minutes)
                    let shouldLog = lastSharedCacheError != errorMsg || 
                                   lastEmptyFileCheck == nil ||
                                   (lastEmptyFileCheck != nil && Date().timeIntervalSince(lastEmptyFileCheck!) > 300)
                    
                    if shouldLog {
                        print("⚠️ [Cache Status] Shared cache file is empty (corrupted) at: \(fileURL.path)")
                        print("💡 [Cache Status] Consider deleting the empty file to allow regeneration")
                        lastSharedCacheError = errorMsg
                        lastEmptyFileCheck = Date()
                    }
                    
                    // Don't try to load empty files
                    sharedCacheAvailable = false
                } else {
                    // Try to actually load it to verify it's valid
                    do {
                        let _ = try loadFromSharedCache(url: sharedURL)
                        sharedCacheAvailable = true
                        
                        // Clear error state if we successfully loaded
                        if lastSharedCacheError != nil {
                            lastSharedCacheError = nil
                            lastEmptyFileCheck = nil
                        }
                    } catch {
                        let errorMsg = error.localizedDescription
                        
                        // Only log if this is a new error or enough time has passed (every 5 minutes)
                        let shouldLog = lastSharedCacheError != errorMsg || 
                                       lastEmptyFileCheck == nil ||
                                       (lastEmptyFileCheck != nil && Date().timeIntervalSince(lastEmptyFileCheck!) > 300)
                        
                        if shouldLog {
                            print("⚠️ [Cache Status] Shared cache file exists but cannot be read: \(errorMsg)")
                            lastSharedCacheError = errorMsg
                            lastEmptyFileCheck = Date()
                        }
                        // File exists but can't be read - might be a permissions issue or corrupted
                    }
                }
            } else {
                // File doesn't exist - clear error state
                if lastSharedCacheError != nil {
                    lastSharedCacheError = nil
                    lastEmptyFileCheck = nil
                }
            }
        }
        
        // Determine status based on server connection and shared cache availability
        // MediaDash only uses shared cache - no local cache
        let newStatus: CacheStatus
        if serverConnected {
            if sharedCacheAvailable {
                newStatus = .serverConnectedUsingShared
            } else {
                newStatus = .serverConnectedNoCache
            }
        } else {
            newStatus = .serverDisconnectedNoCache
        }
        
        // Only log when status actually changes to reduce log spam
        let statusChanged = newStatus != cacheStatus
        if statusChanged {
            switch newStatus {
            case .serverConnectedUsingShared:
                print("🟢 [Cache Status] Server connected, using shared cache")
            case .serverConnectedNoCache:
                print("⚪ [Cache Status] Server connected, no cache available")
            case .serverDisconnectedNoCache:
                print("⚪ [Cache Status] Server disconnected, no cache available")
            case .unknown:
                break // Don't log unknown status
            }
        }
        
        // Defer to next run loop to avoid publishing during view updates
        Task { @MainActor in
            await Task.yield()
            self.cacheStatus = newStatus
        }
    }
    
    /// Public method to refresh cache status (useful for debugging or manual refresh)
    func refreshCacheStatus() {
        updateCacheStatus()
        refreshCachedDocketsFromDisk()
    }
    
    
    /// Get file URL from string path/URL
    nonisolated func getFileURL(from urlString: String) -> URL {
        // If the path doesn't end with .json, assume it's a directory and append the cache filename
        let path = urlString.trimmingCharacters(in: .whitespaces)
        
        if path.hasPrefix("file://") {
            let url = URL(string: path) ?? URL(fileURLWithPath: path)
            // If it's a directory (no extension or ends with /), append filename
            if url.pathExtension.isEmpty || path.hasSuffix("/") {
                return url.appendingPathComponent(cacheFileName)
            }
            return url
        } else if path.hasPrefix("/") || path.hasPrefix("\\\\") || path.contains(":") {
            let url = URL(fileURLWithPath: path)
            
            // Always check if it's a directory first (most reliable)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // It's a directory, append filename
                    return url.appendingPathComponent(cacheFileName)
                } else {
                    // It's a file - check if it's the right type
                    if url.pathExtension == "json" && url.lastPathComponent == cacheFileName {
                        // It's the correct JSON file, use it as-is (no need to log every time)
                        return url
                    } else {
                        // It's a file but not the right one - use parent directory instead
                        print("⚠️ [Cache] Path is a file (not the cache file), using parent directory: \(url.deletingLastPathComponent().path)")
                        return url.deletingLastPathComponent().appendingPathComponent(cacheFileName)
                    }
                }
            }
            
            // Path doesn't exist yet - check if it looks like a directory
            // If it has no extension and doesn't end with .json, treat as directory
            if url.pathExtension.isEmpty && !path.lowercased().hasSuffix(".json") {
                // Path doesn't exist and has no extension, treating as directory (no need to log every time)
                return url.appendingPathComponent(cacheFileName)
            }
            
            // Has extension or ends with .json - treat as file path (no need to log every time)
            return url
        } else {
            // HTTP/HTTPS URLs - return as-is for now
            return URL(fileURLWithPath: path)
        }
    }
    
    /// Load cached dockets from shared cache only
    /// MediaDash relies solely on the shared cache - no local cache is maintained
    func loadCachedDockets() -> [DocketInfo] {
        // Only load from shared cache if enabled
        guard useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty else {
            print("⚠️ [Cache] Shared cache not configured")
            updateCacheStatus()
            return []
        }
        
        if cachedDockets.isEmpty {
            refreshCachedDocketsFromDisk()
        }
        
        return cachedDockets
    }
    
    /// Returns calendar sessions (as DocketInfo) that match the given docket number/folder name (e.g. "21419" or "21419-US").
    /// Used for "File + Prep" to open prep for a matching session after filing.
    func matchingSessions(for docket: String) -> [DocketInfo] {
        let normalized = docket.trimmingCharacters(in: .whitespaces)
        let matching = cachedSessions.filter { task in
            guard let sessionNum = Self.extractDocketNumber(from: task.name) else { return false }
            return sessionNum == normalized || sessionNum.hasPrefix(normalized + "-") || normalized.hasPrefix(sessionNum)
        }
        return matching.sorted { a, b in
            let dateA = a.effectiveDueDate ?? ""
            let dateB = b.effectiveDueDate ?? ""
            return dateA < dateB
        }.map { docketInfo(from: $0) }
    }
    
    private static func extractDocketNumber(from name: String) -> String? {
        let pattern = #"\d{5}(?:-[A-Z]{1,3})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range, in: name) else {
            return nil
        }
        return String(name[range])
    }
    
    private func cleanSessionName(_ name: String) -> String {
        var cleaned = name
        if let range = cleaned.range(of: "SESSION\\s*[-–]?\\s*", options: [.regularExpression, .caseInsensitive]) {
            cleaned = String(cleaned[range.upperBound...])
        }
        if let range = cleaned.range(of: "^\\d{5}(?:-[A-Z]{1,3})?\\s*[-–]?\\s*", options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
    
    private func docketInfo(from task: AsanaTask) -> DocketInfo {
        docketInfoFromSession(task)
    }

    /// Public conversion for use by full calendar view and other callers.
    func docketInfoFromSession(_ task: AsanaTask) -> DocketInfo {
        let docketNumber = Self.extractDocketNumber(from: task.name) ?? "SESSION"
        let jobName = cleanSessionName(task.name)
        let firstTag = task.tags?.first
        return DocketInfo(
            number: docketNumber,
            jobName: jobName,
            fullName: task.name,
            updatedAt: task.modified_at,
            createdAt: task.created_at,
            metadataType: "SESSION",
            subtasks: nil,
            projectMetadata: nil,
            dueDate: task.effectiveDueDate,
            taskGid: task.gid,
            studio: firstTag?.name,
            studioColor: firstTag?.color,
            completed: task.completed
        )
    }
    
    /// Load from shared cache synchronously (returns both dockets and cache metadata)
    private func loadFromSharedCache(url: String) throws -> (dockets: [DocketInfo], cache: CachedDockets) {
        let fileURL = getFileURL(from: url)
        
        // Check if path exists and is a file (not a directory)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        
        if !exists {
            throw NSError(domain: "AsanaCacheManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "File does not exist at path: \(fileURL.path)"])
        }
        
        if isDirectory.boolValue {
            throw NSError(domain: "AsanaCacheManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path is a directory, not a file: \(fileURL.path). Expected file: \(fileURL.appendingPathComponent(cacheFileName).path)"])
        }
        
        // Check file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? Int64 {
            if size == 0 {
                throw NSError(domain: "AsanaCacheManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "File is empty (0 bytes) at: \(fileURL.path)"])
            }
            // File size check (no need to log every time)
        }
        
        // Read from file system
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw NSError(domain: "AsanaCacheManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to read file data: \(error.localizedDescription). Path: \(fileURL.path)"])
        }
        
        // Check if data is empty
        if data.isEmpty {
            throw NSError(domain: "AsanaCacheManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "File contains no data (empty file) at: \(fileURL.path)"])
        }
        
        // Try to decode JSON - check if it's the wrong cache type first
        if let jsonString = String(data: data, encoding: .utf8) {
            // Check if this is a CompanyNameCache file (has "entries" and "lastUpdated")
            if jsonString.contains("\"entries\"") && jsonString.contains("\"lastUpdated\"") && !jsonString.contains("\"dockets\"") {
                throw NSError(domain: "AsanaCacheManager", code: 10, userInfo: [NSLocalizedDescriptionKey: "File is a CompanyNameCache, not an Asana dockets cache. Expected file: \(fileURL.path). Please use a different filename or location for the Asana cache."])
            }
        }
        
        // Try to decode as CachedDockets
        let cached: CachedDockets
        do {
            cached = try JSONDecoder().decode(CachedDockets.self, from: data)
        } catch {
            // Try to get more info about the JSON error
            if let jsonString = String(data: data, encoding: .utf8) {
                let preview = String(jsonString.prefix(200))
                throw NSError(domain: "AsanaCacheManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in cache file. Error: \(error.localizedDescription). File preview: \(preview)..."])
            } else {
                throw NSError(domain: "AsanaCacheManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON in cache file (not UTF-8). Error: \(error.localizedDescription)"])
            }
        }
        
        return (cached.dockets, cached)
    }
    
    /// Reload last sync date from shared cache
    private func reloadLastSyncDate() {
        // Only load from shared cache if enabled
        guard useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty else {
            lastSyncDate = nil
            return
        }
        
        let fileURL = getFileURL(from: sharedURL)
        if let data = try? Data(contentsOf: fileURL),
           let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) {
            lastSyncDate = cached.lastSync
            print("🔄 [Cache] Reloaded lastSyncDate from shared cache: \(cached.lastSync)")
        } else {
            // No cache found
            lastSyncDate = nil
            print("🔄 [Cache] No shared cache found, lastSyncDate is nil")
        }
    }
    
    /// Check if cache should be synced (stale or missing) so Job Info can show recent Asana jobs
    func shouldSync(maxAgeMinutes: Int = 60) -> Bool {
        if cachedDockets.isEmpty { return true }
        guard let last = lastSyncDate else { return true }
        return Date().timeIntervalSince(last) > Double(maxAgeMinutes * 60)
    }
    
    /// Fetch from shared cache if fresh, otherwise sync from Asana API so Job Info always has recent data
    func syncWithAsana(workspaceID: String?, projectID: String?, docketField: String?, jobNameField: String?, sharedCacheURL: String?, useSharedCache: Bool) async throws {
        isSyncing = true
        syncError = nil
        syncProgress = 0
        syncPhase = "Starting sync..."
        
        // Update settings
        self.sharedCacheURL = sharedCacheURL
        self.useSharedCache = useSharedCache
        
        defer {
            isSyncing = false
            syncProgress = 0
            syncPhase = ""
        }
        
        // If shared cache is configured and recently updated (within 60 min), use it without calling API
        // UNLESS the cache appears incomplete or hasn't had a full sync in a while
        let cacheFreshMinutes = 60
        var forceFullSyncReason: String? = nil
        
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            let fileURL = getFileURL(from: sharedURL)
            if let data = try? Data(contentsOf: fileURL),
               let cached = try? JSONDecoder().decode(CachedDockets.self, from: data),
               !cached.dockets.isEmpty {
                let ageMinutes = Date().timeIntervalSince(cached.lastSync) / 60
                
                // Cache health checks - detect incomplete or corrupted cache
                if let integrity = cached.integrity {
                    // Check if cache appears incomplete (count dropped significantly below peak)
                    if integrity.appearsIncomplete(currentCount: cached.dockets.count) {
                        let peak = integrity.peakDocketCount ?? cached.dockets.count
                        forceFullSyncReason = "Cache appears incomplete (\(cached.dockets.count) dockets, peak was \(peak))"
                        print("⚠️ [Cache] \(forceFullSyncReason!) - forcing full sync")
                    }
                    // Check if it's been too long since a full sync (more than 7 days)
                    else if integrity.needsFullSync(maxAgeDays: 7) {
                        let daysSince = integrity.lastFullSyncDate.map { 
                            Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0
                        } ?? Int.max
                        forceFullSyncReason = "No full sync in \(daysSince) days"
                        print("⚠️ [Cache] \(forceFullSyncReason!) - forcing full sync")
                    }
                }
                
                // Check if cache has due date info (schema migration check)
                // If most dockets are missing due dates, force a full sync to get them
                let docketsWithDueDate = cached.dockets.filter { $0.dueDate != nil && !($0.dueDate?.isEmpty ?? true) }
                let hasDueDateInfo = docketsWithDueDate.count > 0 || cached.dockets.count < 10
                
                // Check if due dates are current (not all older than 1 year)
                // This catches stale caches with old data that would never match the calendar
                let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
                let oneYearAgoStr = Self.dateOnlyFormatter.string(from: oneYearAgo)
                let currentDueDates = docketsWithDueDate.filter { 
                    guard let dueDate = $0.dueDate else { return false }
                    return dueDate >= oneYearAgoStr  // String comparison works for YYYY-MM-DD format
                }
                let hasFreshDueDates = currentDueDates.count > 0 || docketsWithDueDate.count == 0
                
                // Use fresh cache ONLY if all health checks pass
                if forceFullSyncReason == nil && ageMinutes < Double(cacheFreshMinutes) && hasDueDateInfo && hasFreshDueDates {
                    print("🟢 [Cache] Using shared cache (updated \(Int(ageMinutes)) minutes ago) - \(cached.dockets.count) dockets, \(docketsWithDueDate.count) with due dates")
                    self.lastSyncDate = cached.lastSync
                    self.cachedDockets = cached.dockets
                    return
                } else if !hasDueDateInfo {
                    forceFullSyncReason = "Cache missing due date info"
                    print("⚠️ [Cache] \(forceFullSyncReason!) - forcing full sync for calendar support")
                } else if !hasFreshDueDates {
                    forceFullSyncReason = "Cache has stale due dates (all older than 1 year)"
                    print("⚠️ [Cache] \(forceFullSyncReason!) - forcing full sync")
                }
            }
        }
        
        // Cache is stale, empty, or missing — fetch from Asana API so Job Info shows recent jobs
        guard asanaService.isAuthenticated else {
            if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
                let fileURL = getFileURL(from: sharedURL)
                if let data = try? Data(contentsOf: fileURL),
                   let cached = try? JSONDecoder().decode(CachedDockets.self, from: data),
                   !cached.dockets.isEmpty {
                    self.lastSyncDate = cached.lastSync
                    self.cachedDockets = cached.dockets
                    return
                }
            }
            throw AsanaError.notAuthenticated
        }
        
        // Prefer incremental sync: load existing cache and only fetch tasks modified since last sync
        var existingDockets: [DocketInfo] = []
        var existingLastSync: Date?
        var knownDocketBearingProjects: [String]? = nil
        var needsDiscovery = true // Assume we need discovery unless we have recent project data
        
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            let fileURL = getFileURL(from: sharedURL)
            if let data = try? Data(contentsOf: fileURL),
               let cached = try? JSONDecoder().decode(CachedDockets.self, from: data),
               !cached.dockets.isEmpty {
                existingDockets = cached.dockets
                existingLastSync = cached.lastSync
                
                // Extract known docket-bearing projects for smart sync
                if let integrity = cached.integrity {
                    knownDocketBearingProjects = integrity.docketBearingProjectIDs
                    needsDiscovery = integrity.needsDiscovery(maxAgeDays: 7)
                    
                    if let projects = knownDocketBearingProjects, !projects.isEmpty {
                        print("📊 [Cache] Found \(projects.count) known docket-bearing projects (discovery \(needsDiscovery ? "needed" : "not needed"))")
                    }
                }
            }
        }
        // If we have no existing cache, use in-memory cachedDockets/lastSyncDate (e.g. from earlier load)
        if existingDockets.isEmpty, !cachedDockets.isEmpty {
            existingDockets = cachedDockets
            existingLastSync = lastSyncDate
        }
        
        // Check if existing dockets have due date info - if not, force full sync
        let existingWithDueDate = existingDockets.filter { $0.dueDate != nil && !($0.dueDate?.isEmpty ?? true) }
        let existingHasDueDateInfo = existingWithDueDate.count > 0 || existingDockets.count < 10
        
        // Only use incremental if:
        // 1. We have valid existing data WITH due dates
        // 2. AND cache health checks passed (no forceFullSyncReason)
        let useIncremental = existingLastSync != nil && !existingDockets.isEmpty && existingHasDueDateInfo && forceFullSyncReason == nil
        
        if let reason = forceFullSyncReason {
            print("📊 [Cache] Sync decision: FULL SYNC REQUIRED - \(reason)")
            print("   existingDockets=\(existingDockets.count), existingWithDueDate=\(existingWithDueDate.count)")
        } else {
            print("📊 [Cache] Sync decision: useIncremental=\(useIncremental), existingDockets=\(existingDockets.count), existingWithDueDate=\(existingWithDueDate.count)")
        }
        
        if useIncremental {
            syncPhase = "Fetching latest changes from Asana..."
        } else {
            let fullSyncNote = forceFullSyncReason != nil ? " (auto-recovery: \(forceFullSyncReason!))" : ""
            syncPhase = "Fetching all data from Asana\(fullSyncNote)..."
        }
        
        // Determine if we should force discovery (scan all projects)
        // Force discovery if: we have a forceFullSyncReason, OR needsDiscovery is true, OR no known projects
        let shouldForceDiscovery = forceFullSyncReason != nil || needsDiscovery || knownDocketBearingProjects == nil
        
        do {
            let syncResult = try await asanaService.fetchDockets(
                workspaceID: workspaceID,
                projectID: projectID,
                docketField: docketField,
                jobNameField: jobNameField,
                modifiedSince: useIncremental ? existingLastSync : nil,
                knownDocketBearingProjects: shouldForceDiscovery ? nil : knownDocketBearingProjects,
                forceDiscovery: shouldForceDiscovery,
                progressCallback: { [weak self] progress, phase in
                    Task { @MainActor in
                        self?.syncProgress = progress
                        self?.syncPhase = phase
                    }
                }
            )
            
            let merged: [DocketInfo]
            let wasFullSync: Bool
            let discoveredProjectIDs: [String]?
            let wasDiscovery: Bool
            
            if useIncremental && !syncResult.dockets.isEmpty {
                // Merge incremental results into existing cache (by fullName)
                // Build dict without uniqueKeysWithValues to tolerate duplicate fullNames (same task in multiple projects)
                var byFullName: [String: DocketInfo] = [:]
                for docket in existingDockets {
                    byFullName[docket.fullName] = docket
                }
                for docket in syncResult.dockets {
                    byFullName[docket.fullName] = docket
                }
                merged = Array(byFullName.values)
                wasFullSync = false
                // For incremental, merge discovered projects with known projects
                var allProjects = Set(knownDocketBearingProjects ?? [])
                allProjects.formUnion(syncResult.docketBearingProjectIDs)
                discoveredProjectIDs = Array(allProjects)
                wasDiscovery = syncResult.wasDiscovery
                print("🟢 [Cache] Incremental sync: \(syncResult.dockets.count) updated, \(merged.count) total dockets")
            } else if useIncremental && syncResult.dockets.isEmpty {
                // No changes since last sync
                merged = existingDockets
                wasFullSync = false
                discoveredProjectIDs = knownDocketBearingProjects // Keep existing
                wasDiscovery = false
                print("🟢 [Cache] No changes since last sync, using existing \(merged.count) dockets")
            } else {
                merged = syncResult.dockets
                wasFullSync = true
                discoveredProjectIDs = Array(syncResult.docketBearingProjectIDs)
                wasDiscovery = syncResult.wasDiscovery
                print("🟢 [Cache] Full sync: \(merged.count) dockets from Asana (\(syncResult.projectsQueried) projects queried)")
            }
            
            self.cachedDockets = merged
            self.lastSyncDate = Date()
            
            if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
                syncPhase = "Saving to cache..."
                try await saveToSharedCache(dockets: merged, url: sharedURL, lastSync: lastSyncDate, isFullSync: wasFullSync, docketBearingProjectIDs: discoveredProjectIDs, isDiscovery: wasDiscovery)
            }
        } catch {
            // If incremental failed (e.g. API quirk), fall back to full sync once
            if useIncremental {
                print("⚠️ [Cache] Incremental sync failed, falling back to full sync: \(error.localizedDescription)")
                syncPhase = "Fetching from Asana (full sync)..."
                let syncResult = try await asanaService.fetchDockets(
                    workspaceID: workspaceID,
                    projectID: projectID,
                    docketField: docketField,
                    jobNameField: jobNameField,
                    modifiedSince: nil,
                    knownDocketBearingProjects: nil, // Full sync, scan all
                    forceDiscovery: true,
                    progressCallback: { [weak self] progress, phase in
                        Task { @MainActor in
                            self?.syncProgress = progress
                            self?.syncPhase = phase
                        }
                    }
                )
                self.cachedDockets = syncResult.dockets
                self.lastSyncDate = Date()
                if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
                    syncPhase = "Saving to cache..."
                    try await saveToSharedCache(dockets: syncResult.dockets, url: sharedURL, lastSync: lastSyncDate, isFullSync: true, docketBearingProjectIDs: Array(syncResult.docketBearingProjectIDs), isDiscovery: true)
                }
                print("🟢 [Cache] Full sync complete: \(syncResult.dockets.count) dockets from \(syncResult.projectsQueried) projects")
            } else {
                throw error
            }
        }
    }
    
    /// Sync upcoming sessions for Prep view (today + 5 business days; ~7 calendar days).
    func syncUpcomingSessions(workspaceID: String?) async throws {
        guard asanaService.isAuthenticated else {
            print("⚠️ [Sessions] Not authenticated, skipping session sync")
            return
        }
        print("📅 [Sessions] Syncing upcoming sessions (7 days)...")
        do {
            let sessions = try await asanaService.searchUpcomingSessions(workspaceID: workspaceID, daysAhead: 7)
            self.cachedSessions = sessions
            self.lastSessionSyncDate = Date()
            print("📅 [Sessions] Synced \(sessions.count) upcoming sessions")
        } catch {
            print("⚠️ [Sessions] Failed to sync sessions: \(error.localizedDescription)")
        }
    }

    /// Sync sessions for the full 2-week calendar view (next 14 calendar days).
    func syncSessionsTwoWeeks(workspaceID: String?) async throws {
        guard asanaService.isAuthenticated else {
            print("⚠️ [Sessions] Not authenticated, skipping 2-week session sync")
            return
        }
        print("📅 [Sessions] Syncing sessions for 2-week calendar...")
        do {
            let sessions = try await asanaService.searchUpcomingSessions(workspaceID: workspaceID, daysAhead: 14)
            self.cachedSessionsTwoWeeks = sessions
            self.lastSessionTwoWeeksSyncDate = Date()
            print("📅 [Sessions] Synced \(sessions.count) sessions for 2-week calendar")
        } catch {
            print("⚠️ [Sessions] Failed to sync 2-week sessions: \(error.localizedDescription)")
        }
    }

    /// Sync all tasks (not just sessions) for the full 2-week calendar (next 14 days).
    func syncTasksTwoWeeks(workspaceID: String?) async throws {
        guard asanaService.isAuthenticated else { return }
        print("📅 [Calendar] Syncing all tasks for 2-week calendar...")
        do {
            let tasks = try await asanaService.searchTasksByDueDate(workspaceID: workspaceID, daysAhead: 14)
            self.cachedTasksTwoWeeks = tasks
            self.lastTasksTwoWeeksSyncDate = Date()
            print("📅 [Calendar] Synced \(tasks.count) tasks for 2-week calendar")
        } catch {
            print("⚠️ [Calendar] Failed to sync 2-week tasks: \(error.localizedDescription)")
        }
    }
    
    private func refreshCachedDocketsFromDisk() {
        guard useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty else {
            return
        }
        
        do {
            let fileURL = getFileURL(from: sharedURL)
            let data = try Data(contentsOf: fileURL)
            let cached = try JSONDecoder().decode(CachedDockets.self, from: data)
            
            let validation = cached.validateIntegrity()
            cacheValidationResult = validation
            
            if validation.isCorrupted {
                print("⚠️ [Cache] Shared cache CORRUPTED: \(validation.description)")
                updateCacheStatus()
                return
            }
            
            if lastSyncDate != cached.lastSync || cachedDockets.count != cached.dockets.count {
                cachedDockets = cached.dockets
            }
            lastSyncDate = cached.lastSync
            updateCacheStatus()
        } catch {
            updateCacheStatus()
        }
    }
    
    /// Save dockets to shared cache file (public for manual seeding)
    /// - Parameters:
    ///   - dockets: The dockets to save
    ///   - url: The cache file URL/path
    ///   - lastSync: Optional sync timestamp (defaults to now)
    ///   - isFullSync: Whether this was a full sync (vs incremental) - affects peak tracking
    ///   - docketBearingProjectIDs: Project GIDs that contain dockets (for smart sync optimization)
    ///   - isDiscovery: Whether this was a full discovery of all projects
    nonisolated func saveToSharedCache(dockets: [DocketInfo], url: String, lastSync: Date? = nil, isFullSync: Bool = false, docketBearingProjectIDs: [String]? = nil, isDiscovery: Bool = false) async throws {
        // Get the file URL (this handles directory vs file path)
        let fileURL = getFileURL(from: url)
        
        // Read previous peak count from existing cache (if any) for health tracking
        var previousPeakCount: Int? = nil
        var existingProjectIDs: [String]? = nil
        if let existingData = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode(CachedDockets.self, from: existingData),
           let existingIntegrity = existing.integrity {
            previousPeakCount = existingIntegrity.peakDocketCount ?? existingIntegrity.docketCount
            // Preserve existing project IDs if we're not doing discovery
            if !isDiscovery {
                existingProjectIDs = existingIntegrity.docketBearingProjectIDs
            }
        }
        
        // Use provided project IDs, or merge with existing if not doing discovery
        let finalProjectIDs: [String]?
        if isDiscovery {
            finalProjectIDs = docketBearingProjectIDs
        } else if let newIDs = docketBearingProjectIDs {
            // Merge new with existing
            var merged = Set(existingProjectIDs ?? [])
            merged.formUnion(newIDs)
            finalProjectIDs = Array(merged)
        } else {
            finalProjectIDs = existingProjectIDs
        }
        
        // Create CachedDockets and encode it in a nonisolated context
        // Use a nonisolated helper function to ensure encoding happens off the main actor
        let syncTimestamp = lastSync ?? Date()
        let data = try await encodeCachedDockets(dockets: dockets, lastSync: syncTimestamp, previousPeakCount: previousPeakCount, isFullSync: isFullSync, docketBearingProjectIDs: finalProjectIDs, isDiscovery: isDiscovery)
        
        print("📝 [Cache] Saving to shared cache at: \(fileURL.path)")
        print("📝 [Cache] Original path was: \(url)")
        
        // Verify the final path is a file (has .json extension)
        guard fileURL.pathExtension == "json" else {
            throw NSError(domain: "AsanaCacheManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Final path does not have .json extension: \(fileURL.path). This suggests path resolution failed."])
        }
        
        // Create parent directory if it doesn't exist
        let parentDir = fileURL.deletingLastPathComponent()
        print("📝 [Cache] Parent directory: \(parentDir.path)")
        
        // Check if parent is actually a directory
        var parentIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parentDir.path, isDirectory: &parentIsDirectory) {
            if !parentIsDirectory.boolValue {
                throw NSError(domain: "AsanaCacheManager", code: 9, userInfo: [NSLocalizedDescriptionKey: "Parent path is a file, not a directory: \(parentDir.path)"])
            }
        } else {
            // Parent doesn't exist, create it
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            print("📝 [Cache] Created parent directory: \(parentDir.path)")
        }
        
        // Check if target already exists and is a directory (shouldn't happen, but handle it)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) && isDirectory.boolValue {
            throw NSError(domain: "AsanaCacheManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Target path is a directory, not a file: \(fileURL.path)"])
        }
        
        // Write atomically (write directly to final location with .atomic option)
        // This is safer than temp file + move on network volumes
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            print("🟢 [Cache] Saved \(dockets.count) dockets to shared cache at: \(fileURL.path)")
        } catch {
            // If atomic write fails (e.g., on network volumes), try non-atomic write
            print("⚠️ [Cache] Atomic write failed, trying non-atomic: \(error.localizedDescription)")
            try data.write(to: fileURL, options: [])
            print("🟢 [Cache] Saved \(dockets.count) dockets to shared cache (non-atomic) at: \(fileURL.path)")
        }
    }
    
    /// Encode CachedDockets in a nonisolated context
    nonisolated private func encodeCachedDockets(dockets: [DocketInfo], lastSync: Date = Date(), previousPeakCount: Int? = nil, isFullSync: Bool = false, docketBearingProjectIDs: [String]? = nil, isDiscovery: Bool = false) async throws -> Data {
        return try await Task.detached(priority: .utility) {
            let cached = CachedDockets(dockets: dockets, lastSync: lastSync, previousPeakCount: previousPeakCount, isFullSync: isFullSync, docketBearingProjectIDs: docketBearingProjectIDs, isDiscovery: isDiscovery)
            let encoder = JSONEncoder()
            return try encoder.encode(cached)
        }.value
    }
    
    /// Fetch cache from shared cache (supports both HTTP URLs and file paths)
    private func fetchFromSharedCache(url: String) async throws -> [DocketInfo] {
        // Handle file:// URLs or direct file paths
        let fileURL: URL
        if url.hasPrefix("file://") {
            // file:// URL
            guard let parsedURL = URL(string: url) else {
                throw AsanaError.invalidURL
            }
            fileURL = parsedURL
        } else if url.hasPrefix("/") || url.hasPrefix("\\\\") || url.contains(":") {
            // Direct file path (Unix path, Windows UNC path, or Windows drive path)
            fileURL = URL(fileURLWithPath: url)
        } else {
            // Assume HTTP/HTTPS URL
            guard let httpURL = URL(string: url) else {
                throw AsanaError.invalidURL
            }
            
            var request = URLRequest(url: httpURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30.0
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AsanaError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }
            
            // Decode the shared cache (same format as local cache)
            let cached = try JSONDecoder().decode(CachedDockets.self, from: data)
            return cached.dockets
        }
        
        // Read from file system (network share or local file)
        let data = try Data(contentsOf: fileURL)
        let cached = try JSONDecoder().decode(CachedDockets.self, from: data)
        return cached.dockets
    }
    
    /// Search cached dockets (instant, no API calls) - uses shared cache primarily
    func searchCachedDockets(query: String, sortOrder: DocketSortOrder = .recentlyUpdated) -> [DocketInfo] {
        let allDockets = loadCachedDockets() // This now checks shared cache first
        
        guard !query.isEmpty else {
            return []
        }
        
        // Require at least 1 character (allow single/double digit searches for docket numbers)
        guard query.count >= 1 else {
            return []
        }
        
        let searchLower = query.lowercased()
        
        // Check if query is all numeric (for docket number prefix matching)
        let isNumericQuery = query.allSatisfy { $0.isNumber }
        
        // Filter dockets by search query
        let results = allDockets.filter { docket in
            // If query is numeric, match docket numbers that start with the query
            if isNumericQuery {
                let docketNumberLower = docket.number.lowercased()
                return docket.fullName.lowercased().contains(searchLower) ||
                       docketNumberLower.hasPrefix(searchLower) ||
                       docket.jobName.lowercased().contains(searchLower)
            } else {
                // For non-numeric queries, use contains matching
                return docket.fullName.lowercased().contains(searchLower) ||
                       docket.number.lowercased().contains(searchLower) ||
                       docket.jobName.lowercased().contains(searchLower)
            }
        }
        
        // Sort based on selected sort order
        let sorted = results.sorted { d1, d2 in
            switch sortOrder {
            case .recentlyUpdated:
                // Most recently added first (use createdAt, fallback to updatedAt, nil dates go to end)
                // Use createdAt (when docket was added to Asana) for sorting, not modified_at
                let date1 = d1.createdAt ?? d1.updatedAt
                let date2 = d2.createdAt ?? d2.updatedAt
                if let date1 = date1, let date2 = date2 {
                    return date1 > date2
                } else if date1 != nil {
                    return true
                } else if date2 != nil {
                    return false
                }
                // If both nil, fall back to docket number descending
                if let n1 = Int(d1.number.filter { $0.isNumber }),
                   let n2 = Int(d2.number.filter { $0.isNumber }) {
                    return n1 > n2
                }
                return d1.number > d2.number
                
            case .docketNumberDesc:
                if let n1 = Int(d1.number.filter { $0.isNumber }),
                   let n2 = Int(d2.number.filter { $0.isNumber }) {
                    if n1 == n2 {
                        return d1.jobName < d2.jobName
                    }
                    return n1 > n2
                }
                if d1.number == d2.number {
                    return d1.jobName < d2.jobName
                }
                return d1.number > d2.number
                
            case .docketNumberAsc:
                if let n1 = Int(d1.number.filter { $0.isNumber }),
                   let n2 = Int(d2.number.filter { $0.isNumber }) {
                    if n1 == n2 {
                        return d1.jobName < d2.jobName
                    }
                    return n1 < n2
                }
                if d1.number == d2.number {
                    return d1.jobName < d2.jobName
                }
                return d1.number < d2.number
                
            case .jobNameAsc:
                if d1.jobName == d2.jobName {
                    if let n1 = Int(d1.number.filter { $0.isNumber }),
                       let n2 = Int(d2.number.filter { $0.isNumber }) {
                        return n1 > n2
                    }
                    return d1.number > d2.number
                }
                return d1.jobName < d2.jobName
                
            case .jobNameDesc:
                if d1.jobName == d2.jobName {
                    if let n1 = Int(d1.number.filter { $0.isNumber }),
                       let n2 = Int(d2.number.filter { $0.isNumber }) {
                        return n1 > n2
                    }
                    return d1.number > d2.number
                }
                return d1.jobName > d2.jobName
            }
        }
        
        // Clear, focused search log
        print("🔍 [SEARCH] Query: '\(query)' → Found \(sorted.count) results (cache has \(allDockets.count) total)")
        if sorted.count > 0 {
            print("   Top 3: \(sorted.prefix(3).map { $0.fullName }.joined(separator: ", "))")
        } else if allDockets.count > 0 {
            // If no results but cache has data, show sample to help debug
            print("   ⚠️ No matches. Sample from cache: \(allDockets.prefix(3).map { $0.fullName }.joined(separator: ", "))")
        }
        
        return sorted
    }
    
    /// Force a complete sync from Asana (e.g. when user taps Refresh in Job Info)
    func forceFullSync(workspaceID: String?, projectID: String?, docketField: String?, jobNameField: String?) async throws {
        guard asanaService.isAuthenticated else {
            throw AsanaError.notAuthenticated
        }
        isSyncing = true
        syncError = nil
        syncProgress = 0
        syncPhase = "Fetching from Asana (full discovery)..."
        defer {
            isSyncing = false
            syncProgress = 0
            syncPhase = ""
        }
        let syncResult = try await asanaService.fetchDockets(
            workspaceID: workspaceID,
            projectID: projectID,
            docketField: docketField,
            jobNameField: jobNameField,
            modifiedSince: nil,
            knownDocketBearingProjects: nil, // Force full discovery
            forceDiscovery: true,
            progressCallback: { [weak self] progress, phase in
                Task { @MainActor in
                    self?.syncProgress = progress
                    self?.syncPhase = phase
                }
            }
        )
        cachedDockets = syncResult.dockets
        lastSyncDate = Date()
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            try await saveToSharedCache(
                dockets: syncResult.dockets,
                url: sharedURL,
                lastSync: lastSyncDate,
                isFullSync: true,
                docketBearingProjectIDs: Array(syncResult.docketBearingProjectIDs),
                isDiscovery: true
            )
        }
        print("🟢 [Cache] Force sync complete: \(syncResult.dockets.count) dockets from \(syncResult.projectsQueried) projects (\(syncResult.docketBearingProjectIDs.count) have dockets)")
    }
    
    /// Clear the cache state
    /// NOTE: MediaDash only uses shared cache, so this just clears the lastSyncDate
    func clearCache() {
        lastSyncDate = nil
        cacheValidationResult = nil
        cacheDataIssues = []
        print("🟢 [Cache] Cache state cleared (MediaDash only uses shared cache)")
    }
    
    /// Validate cache integrity and return detailed results
    /// MediaDash only validates the shared cache
    func validateCache() -> (local: CacheValidationResult?, shared: CacheValidationResult?, localIssues: [String], sharedIssues: [String]) {
        var sharedResult: CacheValidationResult?
        var sharedIssues: [String] = []
        
        // Validate shared cache if enabled
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            let fileURL = getFileURL(from: sharedURL)
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                // Check if empty
                var isEmpty = false
                if let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
                   let size = attributes[.size] as? Int64 {
                    isEmpty = size == 0
                }
                
                if isEmpty {
                    sharedResult = .corrupted(reason: "File is empty (0 bytes)")
                    print("🔍 [Cache Validation] Shared cache: corrupted (empty file) at \(fileURL.path)")
                } else if let data = try? Data(contentsOf: fileURL),
                          let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) {
                    let (result, issues) = cached.validate()
                    sharedResult = result
                    sharedIssues = issues
                    print("🔍 [Cache Validation] Shared cache: \(result.description)")
                    if !issues.isEmpty {
                        print("🔍 [Cache Validation] Shared cache data issues: \(issues.count)")
                    }
                } else {
                    sharedResult = .corrupted(reason: "Invalid JSON or unreadable")
                    print("🔍 [Cache Validation] Shared cache: corrupted (invalid JSON) at \(fileURL.path)")
                }
            } else {
                print("🔍 [Cache Validation] Shared cache: not found at \(fileURL.path)")
            }
        }
        
        // Update published properties for UI
        DispatchQueue.main.async { [weak self] in
            self?.cacheValidationResult = sharedResult
            self?.cacheDataIssues = sharedIssues
        }
        
        return (nil, sharedResult, [], sharedIssues)
    }
    
    /// Check if the cache is corrupted (convenience method)
    func isCacheCorrupted() -> Bool {
        let (_, sharedResult, _, _) = validateCache()
        
        // Check shared cache if available
        if let shared = sharedResult {
            return shared.isCorrupted
        }
        
        // No cache found
        return false
    }
    
    /// Get human-readable cache health status
    func getCacheHealthStatus() -> String {
        let (_, sharedResult, _, sharedIssues) = validateCache()
        
        var status: [String] = []
        
        if let shared = sharedResult {
            status.append("Shared Cache: \(shared.description)")
            if !sharedIssues.isEmpty {
                status.append("  - \(sharedIssues.count) data issues found")
            }
        } else if useSharedCache {
            status.append("Shared Cache: Not available")
        } else {
            status.append("Shared Cache: Not configured")
        }
        
        return status.joined(separator: "\n")
    }
    
    /// Delete corrupted/empty shared cache file to allow regeneration
    /// Returns true if file was deleted, false if it didn't exist or couldn't be deleted
    func deleteCorruptedSharedCache() -> Bool {
        guard useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty else {
            return false
        }
        
        let fileURL = getFileURL(from: sharedURL)
        let fm = FileManager.default
        
        // Check if file exists and is empty or corrupted
        guard fm.fileExists(atPath: fileURL.path) else {
            return false
        }
        
        // Check if it's empty
        var isEmpty = false
        if let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? Int64 {
            isEmpty = size == 0
        }
        
        // Try to validate it if not empty
        var isCorrupted = isEmpty
        if !isEmpty {
            do {
                let data = try Data(contentsOf: fileURL)
                if data.isEmpty {
                    isCorrupted = true
                } else if let _ = try? JSONDecoder().decode(CachedDockets.self, from: data) {
                    // Valid cache - don't delete
                    return false
                } else {
                    // Invalid JSON
                    isCorrupted = true
                }
            } catch {
                // Can't read - consider corrupted
                isCorrupted = true
            }
        }
        
        if isCorrupted {
            do {
                try fm.removeItem(at: fileURL)
                print("🗑️ [Cache] Deleted corrupted/empty shared cache file: \(fileURL.path)")
                // Clear error state
                lastSharedCacheError = nil
                lastEmptyFileCheck = nil
                // Update status
                updateCacheStatus()
                return true
            } catch {
                print("⚠️ [Cache] Failed to delete corrupted cache file: \(error.localizedDescription)")
                return false
            }
        }
        
        return false
    }
    
    /// Get cache file size from shared cache
    func getCacheSize() -> String? {
        guard useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty else {
            return nil
        }
        
        let fileURL = getFileURL(from: sharedURL)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
