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
    
    // Cache file name
    private let cacheFileName = "asana_dockets_cache.json"
    
    // Store current settings for cache access
    private var sharedCacheURL: String?
    private var useSharedCache: Bool = false
    
    /// Cache status indicator
    enum CacheStatus {
        case shared      // Using shared cache
        case local       // Using local cache
        case unknown     // Status not yet determined
    }
    
    init() {
        // Store cache in Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        
        self.cacheURL = appFolder.appendingPathComponent(cacheFileName)
        self.asanaService = AsanaService()
        
        // Load last sync date from cache
        loadLastSyncDate()
        
        // Initial cache status will be set when settings are loaded via updateCacheSettings
    }
    
    /// Update cache settings (call when settings change or on init)
    func updateCacheSettings(sharedCacheURL: String?, useSharedCache: Bool) {
        self.sharedCacheURL = sharedCacheURL
        self.useSharedCache = useSharedCache
        
        // Check cache status immediately when settings change
        updateCacheStatus()
        
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
    }
    
    /// Update cache status by checking which cache is available
    private func updateCacheStatus() {
        // Try shared cache first if enabled
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            let fileURL = getFileURL(from: sharedURL)
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            
            print("🔍 [Cache Status] Checking shared cache at: \(fileURL.path)")
            print("🔍 [Cache Status] File exists: \(fileExists)")
            
            if fileExists {
                // Try to actually load it to verify it's valid
                do {
                    let _ = try loadFromSharedCache(url: sharedURL)
                    cacheStatus = .shared
                    print("🟢 [Cache Status] Detected shared cache at: \(fileURL.path)")
                    return
                } catch {
                    print("⚠️ [Cache Status] Shared cache file exists but cannot be read: \(error.localizedDescription)")
                    // File exists but can't be read - might be a permissions issue or corrupted
                    // Fall through to check local cache
                }
            } else {
                print("⚠️ [Cache Status] Shared cache file not found at: \(fileURL.path)")
            }
        }
        
        // Check local cache
        if FileManager.default.fileExists(atPath: cacheURL.path),
           let data = try? Data(contentsOf: cacheURL),
           let _ = try? JSONDecoder().decode(CachedDockets.self, from: data) {
            cacheStatus = .local
            print("🟠 [Cache Status] Using local cache at: \(cacheURL.path)")
            return
        }
        
        // No cache available
        cacheStatus = .unknown
        print("⚪ [Cache Status] No cache available")
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
                    // It's a directory, append filename
                    print("📁 [Cache] Path is a directory, appending filename: \(cacheFileName)")
                    return url.appendingPathComponent(cacheFileName)
                } else {
                    // It's a file - check if it's the right type
                    if url.pathExtension == "json" && url.lastPathComponent == cacheFileName {
                        // It's the correct JSON file, use it as-is
                        print("📄 [Cache] Path is the correct cache file, using as-is")
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
                cacheStatus = .shared
                
                // Update local cache from shared cache
                Task {
                    await updateLocalCacheFromShared(dockets: shared.dockets)
                }
                
                return shared.dockets
            } else {
                // Local cache is more recent
                print("🟢 [Cache] Using LOCAL cache (more recent: \(local.lastSync) vs \(shared.lastSync))")
                cacheStatus = .local
                
                // Update shared cache from local cache
                Task {
                    do {
                        try await saveToSharedCache(dockets: local.dockets, url: sharedCacheURL ?? "")
                        print("🟢 [Cache] Updated shared cache with more recent local cache")
                    } catch {
                        print("⚠️ [Cache] Failed to update shared cache: \(error.localizedDescription)")
                    }
                }
                
                return local.dockets
            }
        } else if let shared = sharedCache {
            // Only shared cache available
            print("🟢 [Cache] Using SHARED cache (local cache unavailable)")
            cacheStatus = .shared
            
            // Update local cache from shared cache
            Task {
                await updateLocalCacheFromShared(dockets: shared.dockets)
            }
            
            return shared.dockets
        } else if let local = localCache {
            // Only local cache available
            print("🟢 [Cache] Using LOCAL cache (shared cache unavailable)")
            cacheStatus = .local
            return local.dockets
        } else {
            // No cache available
            print("🔵 [Cache] No cache found or cache is invalid")
            cacheStatus = .unknown
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
            throw NSError(domain: "AsanaCacheManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Path is a directory, not a file: \(fileURL.path). Expected file: \(fileURL.appendingPathComponent("asana_dockets_cache.json").path)"])
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
                
                // Update cache status
                cacheStatus = .shared
                
                // Update local cache from shared cache
                saveCachedDockets(dockets)
                
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
        guard let token = KeychainService.retrieve(key: "asana_access_token") else {
            throw AsanaError.notAuthenticated
        }
        
        asanaService.setAccessToken(token)
        
        // Fetch all dockets from Asana
        // Note: This uses fetchDockets which already handles pagination and all projects
        let dockets = try await asanaService.fetchDockets(
            workspaceID: workspaceID,
            projectID: projectID,
            docketField: docketField,
            jobNameField: jobNameField
        )
        
        print("🟢 [Cache] Fetched \(dockets.count) dockets from Asana, saving to cache...")
        
        // Save to SHARED cache FIRST (primary)
        if let sharedCacheURL = sharedCacheURL, !sharedCacheURL.isEmpty {
            do {
                try await saveToSharedCache(dockets: dockets, url: sharedCacheURL)
                print("🟢 [Cache] Saved \(dockets.count) dockets to SHARED cache")
            } catch {
                print("⚠️ [Cache] Failed to save to shared cache: \(error.localizedDescription)")
                // Continue anyway - still save to local
            }
        }
        
        // Then save to local cache (fallback)
        saveCachedDockets(dockets)
        
        // Update cache status (local sync)
        cacheStatus = .local
        
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

