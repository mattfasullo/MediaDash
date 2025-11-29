import Foundation
import Combine

/// Manages local caching of Asana docket information for fast, offline search
@MainActor
class AsanaCacheManager: ObservableObject {
    private let cacheURL: URL
    private let asanaService: AsanaService
    @Published var lastSyncDate: Date?
    @Published var isSyncing = false
    @Published var syncError: String?
    @Published var cacheStatus: CacheStatus = .unknown
    
    // Cache file name - stores Asana docket data for fast offline search
    private let cacheFileName = "mediadash_docket_cache.json"
    private let legacyCacheFileName = "mediadash_docket_search_cache.json" // Old filename for migration
    
    // Store current settings for cache access
    private var sharedCacheURL: String?
    private var useSharedCache: Bool = false
    private var serverBasePath: String?
    private var serverConnectionURL: String?
    
    // Periodic status check timer (nonisolated for deinit access)
    nonisolated(unsafe) private var statusCheckTimer: Timer?
    
    // Periodic sync timer for automatic change detection (nonisolated for deinit access)
    nonisolated(unsafe) private var syncTimer: Timer?
    
    // Store sync settings for periodic background sync
    private var syncWorkspaceID: String?
    private var syncProjectID: String?
    private var syncDocketField: String?
    private var syncJobNameField: String?
    
    /// Cache status indicator with server connection information
    enum CacheStatus {
        case serverConnectedUsingShared      // Server connected and using shared cache
        case serverConnectedUsingLocal       // Server connected but using local cache (shared cache unavailable)
        case serverConnectedNoCache          // Server connected but no cache available
        case serverDisconnectedUsingLocal    // Server not connected, using local cache
        case serverDisconnectedNoCache       // Server not connected and no cache available
        case unknown                         // Status not yet determined
    }
    
    init() {
        // Store cache in Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        
        self.cacheURL = appFolder.appendingPathComponent(cacheFileName)
        self.asanaService = AsanaService()
        
        // Migrate old cache file if it exists
        migrateOldCacheFileIfNeeded()
        
        // Load last sync date from cache
        loadLastSyncDate()
        
        // Initial cache status will be set when settings are loaded via updateCacheSettings
    }
    
    /// Migrate cache file from old name to new name if old file exists
    private func migrateOldCacheFileIfNeeded() {
        let fm = FileManager.default
        let directory = cacheURL.deletingLastPathComponent()
        
        // List of legacy filenames to check (in order of preference)
        let legacyFilenames = [legacyCacheFileName, "asana_dockets_cache.json"]
        
        // Check each legacy filename
        for oldCacheFileName in legacyFilenames {
            let oldCacheURL = directory.appendingPathComponent(oldCacheFileName)
            
            // Check if old cache file exists and new one doesn't
            if fm.fileExists(atPath: oldCacheURL.path) && !fm.fileExists(atPath: cacheURL.path) {
                do {
                    // Try to read and validate old cache file
                    let data = try Data(contentsOf: oldCacheURL)
                    if let _ = try? JSONDecoder().decode(CachedDockets.self, from: data) {
                        // Valid cache file, migrate it
                        try fm.moveItem(at: oldCacheURL, to: cacheURL)
                        print("✅ [Cache] Migrated cache file from '\(oldCacheFileName)' to '\(cacheFileName)'")
                        return // Successfully migrated, no need to check other legacy names
                    } else {
                        // Invalid cache file, remove old one
                        try? fm.removeItem(at: oldCacheURL)
                        print("⚠️ [Cache] Old cache file '\(oldCacheFileName)' was invalid, removed it")
                    }
                } catch {
                    print("⚠️ [Cache] Failed to migrate old cache file '\(oldCacheFileName)': \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Update cache settings (call when settings change or on init)
    func updateCacheSettings(sharedCacheURL: String?, useSharedCache: Bool, serverBasePath: String? = nil, serverConnectionURL: String? = nil) {
        self.sharedCacheURL = sharedCacheURL
        self.useSharedCache = useSharedCache
        
        // Store server base path and connection URL for connection checking
        self.serverBasePath = serverBasePath
        self.serverConnectionURL = serverConnectionURL
        
        // Defer cache status check to avoid modifying during view updates
        Task { @MainActor in
            updateCacheStatus()
        }
        
        // If shared cache is enabled but doesn't exist, seed it from local cache
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            Task {
                await seedSharedCacheIfNeeded(from: sharedURL)
                // Update status after seeding attempt
                await MainActor.run {
                    updateCacheStatus()
                }
            }
        }
        
        // Also re-check status after a short delay to catch cases where the file becomes available
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
                updateCacheStatus()
            }
        }
        
        // Start periodic status checking (every 5 seconds) for live updates
        startPeriodicStatusCheck()
    }
    
    /// Update sync settings and start periodic background sync
    func updateSyncSettings(workspaceID: String?, projectID: String?, docketField: String?, jobNameField: String?) {
        self.syncWorkspaceID = workspaceID
        self.syncProjectID = projectID
        self.syncDocketField = docketField
        self.syncJobNameField = jobNameField
        
        // Start periodic sync if settings are valid and authenticated
        if (workspaceID != nil || projectID != nil) && SharedKeychainService.getAsanaAccessToken() != nil {
            startPeriodicSync()
        } else {
            stopPeriodicSync()
        }
    }
    
    /// Start periodic status checking to keep indicators updated
    private func startPeriodicStatusCheck() {
        // Stop existing timer if any
        statusCheckTimer?.invalidate()
        
        // Create new timer that checks status every 5 seconds
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
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
        if let timer = statusCheckTimer {
            timer.invalidate()
        }
        if let timer = syncTimer {
            timer.invalidate()
        }
    }
    
    /// Start periodic background sync to detect changes automatically
    private func startPeriodicSync() {
        // Stop existing timer if any
        syncTimer?.invalidate()
        
        // Create new timer that performs incremental sync every 5 minutes (300 seconds)
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performBackgroundSync()
            }
        }
        
        // Add timer to run loop so it works even when app is active
        if let timer = syncTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
        
        print("🔄 [Cache] Started periodic background sync (every 5 minutes)")
        
        // Perform initial sync immediately (after a short delay to let app initialize)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            await performBackgroundSync()
        }
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
    private func performBackgroundSync() async {
        // Don't sync if already syncing
        guard !isSyncing else {
            print("🔄 [Background Sync] Skipping - sync already in progress")
            return
        }
        
        // Don't sync if no sync settings configured
        guard syncWorkspaceID != nil || syncProjectID != nil else {
            print("🔄 [Background Sync] Skipping - no sync settings configured")
            return
        }
        
        // Don't sync if not authenticated
        guard SharedKeychainService.getAsanaAccessToken() != nil else {
            print("🔄 [Background Sync] Skipping - not authenticated")
            return
        }
        
        // Don't sync if cache is very fresh (less than 30 seconds old) to avoid rapid successive syncs
        if let lastSync = lastSyncDate {
            let age = Date().timeIntervalSince(lastSync)
            if age < 30 {
                print("🔄 [Background Sync] Skipping - cache is very fresh (\(Int(age)) seconds old)")
                return
            }
        }
        
        print("🔄 [Background Sync] Starting incremental sync to detect changes...")
        
        do {
            // Perform incremental sync (will use modified_since internally)
            try await syncWithAsana(
                workspaceID: syncWorkspaceID,
                projectID: syncProjectID,
                docketField: syncDocketField,
                jobNameField: syncJobNameField,
                sharedCacheURL: sharedCacheURL,
                useSharedCache: useSharedCache
            )
            print("🟢 [Background Sync] Completed successfully")
        } catch {
            print("⚠️ [Background Sync] Failed: \(error.localizedDescription)")
            // Don't update syncError for background syncs - only log it
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
                    print("🔍 [Cache Status] Volume check: \(volumePath) → \(volumeExists ? "exists" : "does not exist") (\(isNetworkMount ? "network mount" : "local"))")
                    if isNetworkMount {
                        return true
                    }
                    // If it exists but is local, we'll fall through to other checks
                } else {
                    print("🔍 [Cache Status] Volume check: \(volumePath) → does not exist")
                }
            }
        }
        
        // Fallback: If serverConnectionURL is explicitly set, use it to check
        if let connectionURL = serverConnectionURL, !connectionURL.isEmpty {
            let isMounted = checkIfServerIsMounted(connectionURL: connectionURL)
            print("🔍 [Cache Status] Server connection check: \(connectionURL) → \(isMounted ? "mounted" : "not mounted")")
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
                    print("🔍 [Cache Status] Shared cache parent check: \(parentPath) → \(parentExists ? "exists" : "does not exist") (\(isNetworkMount ? "network mount" : "local"))")
                    if isNetworkMount {
                        return true
                    }
                } else {
                    print("🔍 [Cache Status] Shared cache parent check: \(parentPath) → \(parentExists ? "exists" : "does not exist")")
            return parentExists
        }
            } else {
                print("🔍 [Cache Status] Shared cache parent check: \(parentPath) → does not exist")
            }
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
            
            print("🔍 [Cache Status] Checking shared cache at: \(fileURL.path)")
            print("🔍 [Cache Status] File exists: \(fileExists)")
            
            if fileExists {
                // Try to actually load it to verify it's valid
                do {
                    let _ = try loadFromSharedCache(url: sharedURL)
                    sharedCacheAvailable = true
                    print("🟢 [Cache Status] Detected shared cache at: \(fileURL.path)")
                } catch {
                    print("⚠️ [Cache Status] Shared cache file exists but cannot be read: \(error.localizedDescription)")
                    // File exists but can't be read - might be a permissions issue or corrupted
                }
            } else {
                print("⚠️ [Cache Status] Shared cache file not found at: \(fileURL.path)")
            }
        }
        
        // Check local cache (try migration first if new cache doesn't exist)
        var localCacheAvailable = false
        if !fm.fileExists(atPath: cacheURL.path) {
            migrateOldCacheFileIfNeeded()
        }
        if fm.fileExists(atPath: cacheURL.path) {
            if let data = try? Data(contentsOf: cacheURL),
               let _ = try? JSONDecoder().decode(CachedDockets.self, from: data) {
                localCacheAvailable = true
            }
        }
        
        // Determine status based on server connection and cache availability
        // Defer Published property updates to avoid SwiftUI warnings
        let newStatus: CacheStatus
        if serverConnected {
            if sharedCacheAvailable {
                newStatus = .serverConnectedUsingShared
                print("🟢 [Cache Status] Server connected, using shared cache")
            } else if localCacheAvailable {
                newStatus = .serverConnectedUsingLocal
                print("🟠 [Cache Status] Server connected, using local cache (shared unavailable)")
            } else {
                newStatus = .serverConnectedNoCache
                print("⚪ [Cache Status] Server connected, no cache available")
            }
        } else {
            if localCacheAvailable {
                newStatus = .serverDisconnectedUsingLocal
                print("🟠 [Cache Status] Server disconnected, using local cache")
            } else {
                newStatus = .serverDisconnectedNoCache
                print("⚪ [Cache Status] Server disconnected, no cache available")
            }
        }
        
        // Update Published property asynchronously to avoid SwiftUI warnings
        Task { @MainActor in
            self.cacheStatus = newStatus
        }
    }
    
    /// Public method to refresh cache status (useful for debugging or manual refresh)
    func refreshCacheStatus() {
        updateCacheStatus()
    }
    
    /// Seed shared cache from local cache if shared cache doesn't exist
    private func seedSharedCacheIfNeeded(from sharedCacheURL: String) async {
        let sharedFileURL = getFileURL(from: sharedCacheURL)
        
        // Check if shared cache exists
        let sharedExists = FileManager.default.fileExists(atPath: sharedFileURL.path)
        
        if !sharedExists {
            // Try to copy from local cache
            if let localData = try? Data(contentsOf: cacheURL),
               let cached = try? JSONDecoder().decode(CachedDockets.self, from: localData),
               !cached.dockets.isEmpty {
                print("🌱 [Cache] Shared cache doesn't exist, seeding from local cache...")
                do {
                    try await saveToSharedCache(dockets: cached.dockets, url: sharedCacheURL)
                    print("🟢 [Cache] Seeded shared cache with \(cached.dockets.count) dockets from local cache")
                } catch {
                    print("⚠️ [Cache] Failed to seed shared cache: \(error.localizedDescription)")
                }
            }
        }
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
                    // It's a directory, append filename (check for legacy first)
                    let newFileURL = url.appendingPathComponent(cacheFileName)
                    let legacyFileURL = url.appendingPathComponent(legacyCacheFileName)
                    
                    // If legacy file exists and new one doesn't, migrate it
                    if FileManager.default.fileExists(atPath: legacyFileURL.path) && !FileManager.default.fileExists(atPath: newFileURL.path) {
                        try? FileManager.default.moveItem(at: legacyFileURL, to: newFileURL)
                        print("✅ [Cache] Migrated shared cache from '\(legacyCacheFileName)' to '\(cacheFileName)'")
                    }
                    
                    print("📁 [Cache] Path is a directory, appending filename: \(cacheFileName)")
                    return newFileURL
                } else {
                    // It's a file - check if it's the right type
                    if url.pathExtension == "json" && url.lastPathComponent == cacheFileName {
                        // It's the correct JSON file, use it as-is
                        print("📄 [Cache] Path is the correct cache file, using as-is")
                        return url
                    } else if url.pathExtension == "json" && url.lastPathComponent == legacyCacheFileName {
                        // It's the legacy file - migrate it
                        let newURL = url.deletingLastPathComponent().appendingPathComponent(cacheFileName)
                        try? FileManager.default.moveItem(at: url, to: newURL)
                        print("✅ [Cache] Migrated shared cache from '\(legacyCacheFileName)' to '\(cacheFileName)'")
                        return newURL
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
                print("📁 [Cache] Path doesn't exist and has no extension, treating as directory")
                return url.appendingPathComponent(cacheFileName)
            }
            
            // Has extension or ends with .json - treat as file path
            print("📄 [Cache] Path has extension, treating as file path")
            return url
        } else {
            // HTTP/HTTPS URLs - return as-is for now
            return URL(fileURLWithPath: path)
        }
    }
    
    /// Load cached dockets - Uses most recent cache (compares timestamps)
    func loadCachedDockets() -> [DocketInfo] {
        var sharedCache: CachedDockets?
        var localCache: CachedDockets?
        
        // Try to load shared cache if enabled
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            do {
                let fileURL = getFileURL(from: sharedURL)
                let data = try Data(contentsOf: fileURL)
                sharedCache = try JSONDecoder().decode(CachedDockets.self, from: data)
                print("🔍 [Cache] Loaded shared cache (last sync: \(sharedCache?.lastSync ?? Date.distantPast))")
            } catch {
                let fileURL = getFileURL(from: sharedURL)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    print("⚠️ [Cache] Shared cache file not found at: \(fileURL.path)")
                } else {
                    print("⚠️ [Cache] Shared cache not available: \(error.localizedDescription)")
                }
            }
        }
        
        // Try to load local cache
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) {
            localCache = cached
            print("🔍 [Cache] Loaded local cache (last sync: \(cached.lastSync))")
        }
        
        // Compare timestamps and use the most recent
        if let shared = sharedCache, let local = localCache {
            if shared.lastSync > local.lastSync {
                // Shared cache is more recent
                print("🟢 [Cache] Using SHARED cache (more recent: \(shared.lastSync) vs \(local.lastSync))")
                
                // Update local cache from shared cache
                Task {
                    await updateLocalCacheFromShared(dockets: shared.dockets)
                }
                
                // Update status after determining which cache to use
                updateCacheStatus()
                
                return shared.dockets
            } else {
                // Local cache is more recent
                print("🟢 [Cache] Using LOCAL cache (more recent: \(local.lastSync) vs \(shared.lastSync))")
                
                // Update shared cache from local cache
                Task {
                    do {
                        try await saveToSharedCache(dockets: local.dockets, url: sharedCacheURL ?? "")
                        print("🟢 [Cache] Updated shared cache with more recent local cache")
                    } catch {
                        print("⚠️ [Cache] Failed to update shared cache: \(error.localizedDescription)")
                    }
                }
                
                // Update status after determining which cache to use
                updateCacheStatus()
                
                return local.dockets
            }
        } else if let shared = sharedCache {
            // Only shared cache available
            print("🟢 [Cache] Using SHARED cache (local cache unavailable)")
            
            // Update local cache from shared cache
            Task {
                await updateLocalCacheFromShared(dockets: shared.dockets)
            }
            
            // Update status after determining which cache to use
            updateCacheStatus()
            
            return shared.dockets
        } else if let local = localCache {
            // Only local cache available
            print("🟢 [Cache] Using LOCAL cache (shared cache unavailable)")
            
            // Update status after determining which cache to use
            updateCacheStatus()
            
            return local.dockets
        } else {
            // No cache available
            print("🔵 [Cache] No cache found or cache is invalid")
            
            // Update status after determining which cache to use
            updateCacheStatus()
            
            return []
        }
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
            print("📊 [Cache] File size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
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
    
    /// Update local cache from shared cache data
    private func updateLocalCacheFromShared(dockets: [DocketInfo]) async {
        saveCachedDockets(dockets)
    }
    
    /// Save dockets to cache (local only)
    private func saveCachedDockets(_ dockets: [DocketInfo]) {
        let cached = CachedDockets(dockets: dockets, lastSync: Date())
        
        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: cacheURL)
            lastSyncDate = cached.lastSync
            print("🟢 [Cache] Saved \(dockets.count) dockets to LOCAL cache")
        } catch {
            print("🔴 [Cache] Error saving local cache: \(error.localizedDescription)")
            syncError = "Failed to save cache: \(error.localizedDescription)"
        }
    }
    
    /// Load last sync date from cache (check shared first, then local)
    private func loadLastSyncDate() {
        // Try shared cache first if available (will be set after updateCacheSettings is called)
        // For now, just check local - will be updated when settings are loaded
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) else {
            return
        }
        lastSyncDate = cached.lastSync
    }
    
    /// Check if cache should be synced (stale or missing) - checks shared cache first
    func shouldSync(maxAgeMinutes: Int = 60) -> Bool {
        // Check shared cache first if enabled
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            let fileURL = getFileURL(from: sharedURL)
            if let data = try? Data(contentsOf: fileURL),
               let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) {
                let lastSync = cached.lastSync
                let age = Date().timeIntervalSince(lastSync)
                let shouldSync = age > Double(maxAgeMinutes * 60)
                
                if shouldSync {
                    print("🔵 [Cache] Shared cache is stale (\(Int(age / 60)) minutes old), should sync")
                } else {
                    print("🟢 [Cache] Shared cache is fresh (\(Int(age / 60)) minutes old), no sync needed")
                }
                return shouldSync
            }
        }
        
        // Fallback to local cache check
        guard let lastSync = lastSyncDate else {
            print("🔵 [Cache] No cache exists, should sync")
            return true
        }
        
        let age = Date().timeIntervalSince(lastSync)
        let shouldSync = age > Double(maxAgeMinutes * 60)
        
        if shouldSync {
            print("🔵 [Cache] Cache is stale (\(Int(age / 60)) minutes old), should sync")
        } else {
            print("🟢 [Cache] Cache is fresh (\(Int(age / 60)) minutes old), no sync needed")
        }
        
        return shouldSync
    }
    
    /// Fetch from shared cache if available, otherwise sync with Asana API
    func syncWithAsana(workspaceID: String?, projectID: String?, docketField: String?, jobNameField: String?, sharedCacheURL: String?, useSharedCache: Bool) async throws {
        isSyncing = true
        syncError = nil
        
        // Update settings
        self.sharedCacheURL = sharedCacheURL
        self.useSharedCache = useSharedCache
        
        defer {
            isSyncing = false
        }
        
        // Try shared cache first if enabled
        if useSharedCache, let cacheURL = sharedCacheURL, !cacheURL.isEmpty {
            print("🔵 [Cache] Attempting to fetch from shared cache: \(cacheURL)")
            
            do {
                let dockets = try await fetchFromSharedCache(url: cacheURL)
                print("🟢 [Cache] Successfully fetched \(dockets.count) dockets from shared cache")
                
                // Update local cache from shared cache
                saveCachedDockets(dockets)
                
                // Update cache status after sync
                updateCacheStatus()
                
                print("🟢 [Cache] Shared cache sync complete!")
                return
            } catch {
                print("⚠️ [Cache] Failed to fetch from shared cache: \(error.localizedDescription)")
                print("🔄 [Cache] Falling back to local Asana sync...")
                // Fall through to local sync
            }
        }
        
        // Local sync with Asana API
        print("🔵 [Cache] Starting local sync with Asana...")
        
        // Check if token exists
        guard let token = SharedKeychainService.getAsanaAccessToken() else {
            throw AsanaError.notAuthenticated
        }
        
        asanaService.setAccessToken(token)
        
        // Load existing cache to get lastSync timestamp and existing dockets
        let existingDockets = loadCachedDockets()
        let existingCache: CachedDockets?
        
        // Try to get the actual CachedDockets object to access lastSync
        var lastSyncDate: Date? = nil
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            do {
                let fileURL = getFileURL(from: sharedURL)
                let data = try Data(contentsOf: fileURL)
                existingCache = try JSONDecoder().decode(CachedDockets.self, from: data)
                lastSyncDate = existingCache?.lastSync
            } catch {
                existingCache = nil
            }
        }
        
        if lastSyncDate == nil {
            // Try local cache
            if let data = try? Data(contentsOf: cacheURL),
               let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) {
                lastSyncDate = cached.lastSync
            }
        }
        
        // Determine if we should do incremental sync
        let isIncremental = lastSyncDate != nil && !existingDockets.isEmpty
        let modifiedSince = isIncremental ? lastSyncDate : nil
        
        if isIncremental {
            print("🔄 [Cache] Performing INCREMENTAL sync (modified since \(lastSyncDate!))")
        } else {
            print("🔄 [Cache] Performing FULL sync (no existing cache or cache is empty)")
        }
        
        // Fetch dockets from Asana (incremental if we have a lastSync date)
        let fetchedDockets = try await asanaService.fetchDockets(
            workspaceID: workspaceID,
            projectID: projectID,
            docketField: docketField,
            jobNameField: jobNameField,
            modifiedSince: modifiedSince
        )
        
        print("🟢 [Cache] Fetched \(fetchedDockets.count) dockets from Asana")
        
        // Merge fetched dockets with existing cache
        var mergedDockets: [DocketInfo]
        if isIncremental {
            // Create a dictionary keyed by fullName for efficient lookup
            var docketMap: [String: DocketInfo] = [:]
            
            // Add all existing dockets to the map
            for docket in existingDockets {
                docketMap[docket.fullName] = docket
            }
            
            // Update or add fetched dockets
            for fetchedDocket in fetchedDockets {
                docketMap[fetchedDocket.fullName] = fetchedDocket
            }
            
            // Convert back to array
            mergedDockets = Array(docketMap.values)
            
            let updatedCount = fetchedDockets.count
            let totalCount = mergedDockets.count
            print("🔄 [Cache] Merged \(updatedCount) new/updated dockets with existing cache (total: \(totalCount))")
        } else {
            // Full sync - use fetched dockets as-is
            mergedDockets = fetchedDockets
            print("🔄 [Cache] Full sync complete (\(mergedDockets.count) dockets)")
        }
        
        // Save to SHARED cache FIRST (primary)
        if let sharedCacheURL = sharedCacheURL, !sharedCacheURL.isEmpty {
            do {
                try await saveToSharedCache(dockets: mergedDockets, url: sharedCacheURL)
                print("🟢 [Cache] Saved \(mergedDockets.count) dockets to SHARED cache")
            } catch {
                print("⚠️ [Cache] Failed to save to shared cache: \(error.localizedDescription)")
                // Continue anyway - still save to local
            }
        }
        
        // Then save to local cache (fallback)
        saveCachedDockets(mergedDockets)
        
        // Update cache status after sync
        updateCacheStatus()
        
        print("🟢 [Cache] Sync complete!")
    }
    
    /// Save dockets to shared cache file (public for manual seeding)
    nonisolated func saveToSharedCache(dockets: [DocketInfo], url: String) async throws {
        // Create CachedDockets and encode it in a nonisolated context
        // Use a nonisolated helper function to ensure encoding happens off the main actor
        let data = try await encodeCachedDockets(dockets: dockets)
        
        // Get the file URL (this handles directory vs file path)
        let fileURL = getFileURL(from: url)
        
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
    nonisolated private func encodeCachedDockets(dockets: [DocketInfo]) async throws -> Data {
        return try await Task.detached(priority: .utility) {
            let cached = CachedDockets(dockets: dockets, lastSync: Date())
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
                // Most recently updated first (nil dates go to end)
                if let date1 = d1.updatedAt, let date2 = d2.updatedAt {
                    return date1 > date2
                } else if d1.updatedAt != nil {
                    return true
                } else if d2.updatedAt != nil {
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
    
    /// Clear the cache
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        lastSyncDate = nil
        print("🟢 [Cache] Cache cleared")
    }
    
    /// Get cache file size
    func getCacheSize() -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

