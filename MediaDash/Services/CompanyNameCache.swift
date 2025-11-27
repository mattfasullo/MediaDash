import Foundation
import Combine

// MARK: - Company Name Entry

struct CompanyNameEntry: Codable, Hashable {
    let name: String
    let lastSeen: Date
    let source: String // "filesystem", "asana", "user"
    
    init(name: String, lastSeen: Date = Date(), source: String) {
        self.name = name
        self.lastSeen = lastSeen
        self.source = source
    }
}

// MARK: - Company Name Cache

/// Manages a synchronized cache of company names from multiple sources
@MainActor
class CompanyNameCache: ObservableObject {
    static let shared = CompanyNameCache()
    
    @Published private(set) var companyNames: Set<String> = []
    private var entries: [String: CompanyNameEntry] = [:]
    
    private let localCacheKey = "companyNameCache"
    private let sharedCacheFileName = "company_names_cache.json"
    private var sharedCacheURL: URL?
    
    private init() {
        loadLocalCache()
    }
    
    // MARK: - Configuration
    
    func configure(sharedCacheURL: String?) {
        if let urlString = sharedCacheURL, !urlString.isEmpty {
            self.sharedCacheURL = URL(fileURLWithPath: urlString)
        } else {
            self.sharedCacheURL = nil
        }
        syncWithSharedCache()
    }
    
    // MARK: - Public API
    
    /// Add a company name to the cache
    func addCompanyName(_ name: String, source: String = "user") {
        let cleaned = cleanCompanyName(name)
        guard !cleaned.isEmpty else { return }
        
        let entry = CompanyNameEntry(name: cleaned, source: source)
        entries[cleaned] = entry
        companyNames.insert(cleaned)
        
        saveLocalCache()
        saveSharedCache()
    }
    
    /// Add multiple company names from a source
    func addCompanyNames(_ names: [String], source: String) {
        for name in names {
            let cleaned = cleanCompanyName(name)
            guard !cleaned.isEmpty else { continue }
            
            // Only update if this source is more recent or entry doesn't exist
            if let existing = entries[cleaned] {
                // Keep existing if it's from a more reliable source
                let newSourcePriority = sourcePriority(for: source)
                let existingSourcePriority = sourcePriority(for: existing.source)
                if existingSourcePriority >= newSourcePriority {
                    continue
                }
            }
            
            let entry = CompanyNameEntry(name: cleaned, source: source)
            entries[cleaned] = entry
            companyNames.insert(cleaned)
        }
        
        saveLocalCache()
        saveSharedCache()
    }
    
    /// Get all company names as a sorted array
    func getAllCompanyNames() -> [String] {
        Array(companyNames).sorted()
    }
    
    /// Check if a company name exists in cache
    func contains(_ name: String) -> Bool {
        companyNames.contains(cleanCompanyName(name))
    }
    
    /// Clear the cache
    func clear() {
        entries.removeAll()
        companyNames.removeAll()
        saveLocalCache()
        saveSharedCache()
    }
    
    /// Get a readable text representation of the cache
    func getCacheAsText() -> String {
        var output = "Company Name Cache\n"
        output += "==================\n\n"
        output += "Total entries: \(entries.count)\n"
        output += "Last updated: \(Date())\n\n"
        
        // Group by source
        let bySource = Dictionary(grouping: entries.values) { $0.source }
        
        for (source, entries) in bySource.sorted(by: { sourcePriority(for: $0.key) > sourcePriority(for: $1.key) }) {
            output += "\n\(source.uppercased()) (\(entries.count) entries):\n"
            output += String(repeating: "-", count: source.count + 20) + "\n"
            for entry in entries.sorted(by: { $0.name < $1.name }) {
                output += "  • \(entry.name)\n"
                output += "    Last seen: \(entry.lastSeen.formatted(date: .abbreviated, time: .shortened))\n"
            }
        }
        
        // Also show shared cache location if configured
        if let sharedURL = sharedCacheURL {
            output += "\n\nShared Cache Location:\n"
            output += "\(sharedURL.path)\n"
        }
        
        return output
    }
    
    /// Get the shared cache file path (if configured)
    func getSharedCachePath() -> String? {
        guard let sharedURL = sharedCacheURL else { return nil }
        return sharedURL.path
    }
    
    // MARK: - Sync
    
    /// Sync with shared cache (compare timestamps, use most recent)
    func syncWithSharedCache() {
        guard let sharedURL = sharedCacheURL else { return }
        guard FileManager.default.fileExists(atPath: sharedURL.path) else {
            // Shared cache doesn't exist, save ours
            saveSharedCache()
            return
        }
        
        do {
            let data = try Data(contentsOf: sharedURL)
            let sharedCache = try JSONDecoder().decode(SharedCompanyCache.self, from: data)
            
            // Merge: use most recent entry for each company name
            for (name, sharedEntry) in sharedCache.entries {
                let cleaned = cleanCompanyName(name)
                if let localEntry = entries[cleaned] {
                    // Use the more recent one
                    if sharedEntry.lastSeen > localEntry.lastSeen {
                        entries[cleaned] = sharedEntry
                    }
                } else {
                    // New entry from shared cache
                    entries[cleaned] = sharedEntry
                    companyNames.insert(cleaned)
                }
            }
            
            // Save merged cache
            saveLocalCache()
            saveSharedCache()
        } catch {
            print("CompanyNameCache: Failed to sync with shared cache: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Helpers
    
    private func cleanCompanyName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
    
    private func sourcePriority(for source: String) -> Int {
        switch source {
        case "filesystem": return 3 // Highest priority
        case "asana": return 2
        case "user": return 1
        default: return 0
        }
    }
    
    // MARK: - Local Cache
    
    private func loadLocalCache() {
        guard let data = UserDefaults.standard.data(forKey: localCacheKey),
              let cache = try? JSONDecoder().decode(SharedCompanyCache.self, from: data) else {
            return
        }
        
        entries = cache.entries
        companyNames = Set(entries.keys)
    }
    
    private func saveLocalCache() {
        let cache = SharedCompanyCache(entries: entries, lastUpdated: Date())
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: localCacheKey)
        }
    }
    
    // MARK: - Shared Cache
    
    private func saveSharedCache() {
        guard let sharedURL = sharedCacheURL else { return }
        
        // Ensure directory exists
        let directory = sharedURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        let cache = SharedCompanyCache(entries: entries, lastUpdated: Date())
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: sharedURL)
        }
    }
}

// MARK: - Shared Cache Format

struct SharedCompanyCache: Codable {
    let entries: [String: CompanyNameEntry]
    let lastUpdated: Date
    
    init(entries: [String: CompanyNameEntry], lastUpdated: Date) {
        self.entries = entries
        self.lastUpdated = lastUpdated
    }
}

