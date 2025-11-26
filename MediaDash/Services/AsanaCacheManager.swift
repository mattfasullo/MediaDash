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
    
    // Cache file name
    private let cacheFileName = "asana_dockets_cache.json"
    
    // Store current settings for cache access
    private var sharedCacheURL: String?
    private var useSharedCache: Bool = false
    
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
    }
    
    /// Update cache settings (call when settings change or on init)
    func updateCacheSettings(sharedCacheURL: String?, useSharedCache: Bool) {
        self.sharedCacheURL = sharedCacheURL
        self.useSharedCache = useSharedCache
        
        // If shared cache is enabled but doesn't exist, seed it from local cache
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            Task {
                await seedSharedCacheIfNeeded(from: sharedURL)
            }
        }
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
    private func getFileURL(from urlString: String) -> URL {
        if urlString.hasPrefix("file://") {
            return URL(string: urlString) ?? URL(fileURLWithPath: urlString)
        } else if urlString.hasPrefix("/") || urlString.hasPrefix("\\\\") || urlString.contains(":") {
            return URL(fileURLWithPath: urlString)
        } else {
            // HTTP/HTTPS URLs - return as-is for now
            return URL(fileURLWithPath: urlString)
        }
    }
    
    /// Load cached dockets - PRIMARY: from shared cache, FALLBACK: from local cache
    func loadCachedDockets() -> [DocketInfo] {
        // Try shared cache first if enabled
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            if let dockets = try? loadFromSharedCache(url: sharedURL) {
                print("🟢 [Cache] Loaded \(dockets.count) dockets from SHARED cache")
                
                // Update local cache from shared cache (sync local to shared)
                Task {
                    await updateLocalCacheFromShared(dockets: dockets)
                }
                
                return dockets
            } else {
                print("⚠️ [Cache] Shared cache not available, falling back to local cache")
            }
        }
        
        // Fallback to local cache
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) else {
            print("🔵 [Cache] No cache found or cache is invalid")
            return []
        }
        
        print("🟢 [Cache] Loaded \(cached.dockets.count) dockets from LOCAL cache (last sync: \(cached.lastSync))")
        return cached.dockets
    }
    
    /// Load from shared cache synchronously (for search/display)
    private func loadFromSharedCache(url: String) throws -> [DocketInfo] {
        let fileURL = getFileURL(from: url)
        
        // Read from file system
        let data = try Data(contentsOf: fileURL)
        let cached = try JSONDecoder().decode(CachedDockets.self, from: data)
        return cached.dockets
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
        
        print("🟢 [Cache] Sync complete!")
    }
    
    /// Save dockets to shared cache file
    nonisolated private func saveToSharedCache(dockets: [DocketInfo], url: String) async throws {
        // Create CachedDockets and encode it in a nonisolated context
        // Use a nonisolated helper function to ensure encoding happens off the main actor
        let data = try await encodeCachedDockets(dockets: dockets)
        
        // Handle file:// URLs or direct file paths
        let fileURL: URL
        if url.hasPrefix("file://") {
            guard let parsedURL = URL(string: url) else {
                throw AsanaError.invalidURL
            }
            fileURL = parsedURL
        } else if url.hasPrefix("/") || url.hasPrefix("\\\\") || url.contains(":") {
            // Direct file path (Unix path, Windows UNC path, or Windows drive path)
            fileURL = URL(fileURLWithPath: url)
        } else {
            // HTTP/HTTPS URLs - not supported for writing
            throw AsanaError.apiError("Cannot write to HTTP/HTTPS URL. Shared cache must be a file path.")
        }
        
        // Create parent directory if it doesn't exist
        let parentDir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        // Write atomically (write to temp file, then move)
        let tempURL = fileURL.appendingPathExtension("tmp")
        try data.write(to: tempURL, options: .atomic)
        
        // Move temp file to final location
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        
        print("🟢 [Cache] Saved \(dockets.count) dockets to shared cache")
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

