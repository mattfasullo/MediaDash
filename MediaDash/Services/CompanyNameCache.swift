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
    private let sharedCacheFileName = "mediadash_company_cache.json"
    private let legacyCacheFileName = "company_names_cache.json" // Old filename for migration
    private var sharedCacheURL: URL?
    
    private init() {
        loadLocalCache()
    }
    
    // MARK: - Configuration
    
    func configure(sharedCacheURL: String?) {
        if let urlString = sharedCacheURL, !urlString.isEmpty {
            let baseURL = URL(fileURLWithPath: urlString)
            let fileManager = FileManager.default
            
            // Check if the path exists and what it is
            var isDirectory: ObjCBool = false
            let pathExists = fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory)
            
            if pathExists && isDirectory.boolValue {
                // It's an existing directory - append our filename
                self.sharedCacheURL = baseURL.appendingPathComponent(sharedCacheFileName)
            } else if pathExists && !isDirectory.boolValue {
                // It's an existing file - check if it's the same name as our cache file
                if baseURL.lastPathComponent == sharedCacheFileName {
                    // It IS our cache file - use it directly
                    self.sharedCacheURL = baseURL
                } else {
                    // It's a different file, but the path was configured as a directory path
                    // This means a file exists where we expect a directory (e.g., MediaDash_Cache file vs MediaDash_Cache directory)
                    // Use parent directory and append our filename
                    self.sharedCacheURL = baseURL.deletingLastPathComponent().appendingPathComponent(sharedCacheFileName)
                }
            } else {
                // Path doesn't exist - check if it looks like a directory or file
                if baseURL.pathExtension.isEmpty {
                    // No extension, treat as directory - append our filename
                    self.sharedCacheURL = baseURL.appendingPathComponent(sharedCacheFileName)
                } else {
                    // Has extension, but if it matches our filename, use it; otherwise use directory
                    if baseURL.lastPathComponent == sharedCacheFileName {
                        self.sharedCacheURL = baseURL
                    } else {
                        self.sharedCacheURL = baseURL.deletingLastPathComponent().appendingPathComponent(sharedCacheFileName)
                    }
                }
            }
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
        
        // Check for legacy filename and migrate if needed
        let legacyURL = sharedURL.deletingLastPathComponent().appendingPathComponent(legacyCacheFileName)
        if FileManager.default.fileExists(atPath: legacyURL.path) && !FileManager.default.fileExists(atPath: sharedURL.path) {
            // Migrate legacy file to new name
            do {
                try FileManager.default.moveItem(at: legacyURL, to: sharedURL)
                print("CompanyNameCache: Migrated cache file from '\(legacyCacheFileName)' to '\(sharedCacheFileName)'")
            } catch {
                print("CompanyNameCache: Failed to migrate legacy cache file: \(error.localizedDescription)")
            }
        }
        
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
        
        // Ensure directory exists (safely handle file/directory conflicts)
        let directory = sharedURL.deletingLastPathComponent()
        do {
            try safeCreateDirectory(at: directory)
        } catch {
            print("CompanyNameCache: Failed to create cache directory: \(error.localizedDescription)")
            return
        }
        
        let cache = SharedCompanyCache(entries: entries, lastUpdated: Date())
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: sharedURL)
        }
    }
    
    /// Safely create a directory, handling the case where a file with the same name exists
    private func safeCreateDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        let path = url.path
        
        // Check if path exists
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        
        if exists {
            if isDirectory.boolValue {
                // Already a directory, nothing to do
                return
            } else {
                // It's a file - rename it to avoid conflict
                let backupURL = url.appendingPathExtension("old")
                print("CompanyNameCache: Found file where directory expected at \(path), renaming to \(backupURL.path)")
                
                // Remove old backup if it exists
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.removeItem(at: backupURL)
                }
                
                // Rename the file
                try fileManager.moveItem(at: url, to: backupURL)
            }
        }
        
        // Now create the directory
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
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

