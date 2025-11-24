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
    
    /// Load cached dockets from disk
    func loadCachedDockets() -> [DocketInfo] {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) else {
            print("🔵 [Cache] No cache found or cache is invalid")
            return []
        }
        
        print("🟢 [Cache] Loaded \(cached.dockets.count) dockets from cache (last sync: \(cached.lastSync))")
        return cached.dockets
    }
    
    /// Save dockets to cache
    private func saveCachedDockets(_ dockets: [DocketInfo]) {
        let cached = CachedDockets(dockets: dockets, lastSync: Date())
        
        do {
            let data = try JSONEncoder().encode(cached)
            try data.write(to: cacheURL)
            lastSyncDate = cached.lastSync
            print("🟢 [Cache] Saved \(dockets.count) dockets to cache")
        } catch {
            print("🔴 [Cache] Error saving cache: \(error.localizedDescription)")
            syncError = "Failed to save cache: \(error.localizedDescription)"
        }
    }
    
    /// Load last sync date from cache
    private func loadLastSyncDate() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) else {
            return
        }
        lastSyncDate = cached.lastSync
    }
    
    /// Check if cache should be synced (stale or missing)
    func shouldSync(maxAgeMinutes: Int = 60) -> Bool {
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
    
    /// Sync with Asana API and update cache
    func syncWithAsana(workspaceID: String?, projectID: String?, docketField: String?, jobNameField: String?) async throws {
        isSyncing = true
        syncError = nil
        
        defer {
            isSyncing = false
        }
        
        print("🔵 [Cache] Starting sync with Asana...")
        
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
        
        // Save to cache
        saveCachedDockets(dockets)
        
        print("🟢 [Cache] Sync complete!")
    }
    
    /// Search cached dockets (instant, no API calls)
    func searchCachedDockets(query: String) -> [DocketInfo] {
        let allDockets = loadCachedDockets()
        
        guard !query.isEmpty else {
            return []
        }
        
        // Require at least 3 characters
        guard query.count >= 3 else {
            return []
        }
        
        let searchLower = query.lowercased()
        
        // Filter dockets by search query
        let results = allDockets.filter { docket in
            docket.fullName.lowercased().contains(searchLower) ||
            docket.number.lowercased().contains(searchLower) ||
            docket.jobName.lowercased().contains(searchLower)
        }
        
        // Sort by docket number (descending) then job name
        let sorted = results.sorted { d1, d2 in
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

/// Cached dockets data structure
struct CachedDockets: Codable {
    let dockets: [DocketInfo]
    let lastSync: Date
}

