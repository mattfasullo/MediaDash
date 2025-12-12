import Foundation
import Combine
import CodeMind

/// Manages shared synchronization of CodeMind learning data across all users
/// Merges intelligence updates without overwriting existing knowledge
@MainActor
class CodeMindSharedCacheManager: ObservableObject {
    static let shared = CodeMindSharedCacheManager()
    
    private let sharedCacheFileName = "mediadash_codemind_cache.json"
    private let legacyCacheFileName = "codemind_learning_cache.json" // Old filename for migration
    private var sharedCacheURL: URL?
    private var serverBasePath: String? // For checking server connection
    
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isSyncing = false
    
    private init() {
        // Load last sync date from UserDefaults
        if let date = UserDefaults.standard.object(forKey: "codemind_last_sync") as? Date {
            lastSyncDate = date
        }
    }
    
    // MARK: - Configuration
    
    func configure(sharedCacheURL: String?, serverBasePath: String? = nil) {
        self.serverBasePath = serverBasePath
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
                    // Rename the file and create the directory
                    let backupURL = baseURL.appendingPathExtension("old")
                    CodeMindLogger.shared.log(.warning, "Found file where directory expected, renaming to backup", category: .cache, metadata: [
                        "path": baseURL.path,
                        "backupPath": backupURL.path
                    ])
                    
                    do {
                        // Remove old backup if it exists
                        if fileManager.fileExists(atPath: backupURL.path) {
                            try? fileManager.removeItem(at: backupURL)
                        }
                        // Rename the file
                        try fileManager.moveItem(at: baseURL, to: backupURL)
                        // Now create the directory
                        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
                        // Use the directory with our filename
                        self.sharedCacheURL = baseURL.appendingPathComponent(sharedCacheFileName)
                    } catch {
                        CodeMindLogger.shared.log(.error, "Failed to rename file and create directory", category: .cache, metadata: [
                            "path": baseURL.path,
                            "error": error.localizedDescription
                        ])
                        // Fallback: use parent directory
                        self.sharedCacheURL = baseURL.deletingLastPathComponent().appendingPathComponent(sharedCacheFileName)
                    }
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
            
            CodeMindLogger.shared.log(.debug, "Configured shared cache URL", category: .cache, metadata: [
                "configuredPath": self.sharedCacheURL?.path ?? "nil",
                "originalPath": urlString
            ])
        } else {
            self.sharedCacheURL = nil
        }
        
        // Perform initial sync
        Task {
            await syncWithSharedCache()
        }
    }
    
    // MARK: - Sync
    
    /// Check if server is connected (if shared cache requires server access)
    private func isServerConnected() -> Bool {
        guard let serverPath = serverBasePath, !serverPath.isEmpty else {
            // No server path configured - assume it's not needed
            return true
        }
        return FileManager.default.fileExists(atPath: serverPath)
    }
    
    /// Sync with shared cache - merges learning data intelligently
    func syncWithSharedCache() async {
        guard let sharedURL = sharedCacheURL else {
            CodeMindLogger.shared.log(.warning, "No shared cache URL configured", category: .cache)
            CodeMindActivityManager.shared.recordError(message: "CodeMind: No shared cache URL configured. Check Settings > CodeMind AI.")
            return
        }
        
        // Check if server is connected (if cache is on server)
        if !isServerConnected() {
            let errorMessage = "CodeMind: Cannot access shared cache - server not connected. Please connect to the Grayson server to enable shared learning cache."
            CodeMindLogger.shared.log(.error, errorMessage, category: .cache, metadata: [
                "serverPath": serverBasePath ?? "not configured",
                "sharedCachePath": sharedURL.path
            ])
            CodeMindActivityManager.shared.recordError(message: errorMessage)
            return
        }
        
        CodeMindLogger.shared.log(.info, "Starting cache sync", category: .cache, metadata: ["sharedURL": sharedURL.path])
        
        await MainActor.run {
            isSyncing = true
        }
        
        defer {
            Task { @MainActor in
                isSyncing = false
                lastSyncDate = Date()
                UserDefaults.standard.set(Date(), forKey: "codemind_last_sync")
            }
        }
        
        do {
            // Get CodeMind's learning engine storage path
            guard let codeMindStoragePath = getCodeMindStoragePath() else {
                CodeMindLogger.shared.log(.error, "Could not determine CodeMind storage path", category: .cache)
                return
            }
            
            CodeMindLogger.shared.log(.debug, "Loading local learning data", category: .cache, metadata: ["path": codeMindStoragePath])
            // Load local learning data
            let localData = try await loadLocalLearningData(from: codeMindStoragePath)
            CodeMindLogger.shared.log(.info, "Loaded local data", category: .cache, metadata: [
                "patterns": "\(localData.patterns.count)",
                "feedbackRecords": "\(localData.feedbackRecords.count)"
            ])
            
            CodeMindLogger.shared.log(.debug, "Loading shared learning data", category: .cache)
            // Load shared learning data
            let sharedData = try await loadSharedLearningData(from: sharedURL)
            CodeMindLogger.shared.log(.info, "Loaded shared data", category: .cache, metadata: [
                "patterns": "\(sharedData.patterns.count)",
                "feedbackRecords": "\(sharedData.feedbackRecords.count)"
            ])
            
            CodeMindLogger.shared.log(.debug, "Merging learning data", category: .cache)
            // Merge: combine patterns and feedback intelligently
            let mergedData = mergeLearningData(local: localData, shared: sharedData)
            CodeMindLogger.shared.log(.info, "Merged learning data", category: .cache, metadata: [
                "mergedPatterns": "\(mergedData.patterns.count)",
                "mergedFeedbackRecords": "\(mergedData.feedbackRecords.count)"
            ])
            
            CodeMindLogger.shared.log(.debug, "Saving merged data", category: .cache)
            // Save merged data to local location first (always succeeds)
            try await saveLearningData(mergedData, to: codeMindStoragePath)
            
            // Try to save to shared location - if it fails, log but don't fail the entire sync
            do {
                // Check server connection again before saving
                guard isServerConnected() else {
                    let errorMessage = "CodeMind: Cannot save to shared cache - server not connected. Please connect to the Grayson server."
                    CodeMindLogger.shared.log(.error, errorMessage, category: .cache, metadata: [
                        "serverPath": serverBasePath ?? "not configured",
                        "note": "Local cache sync succeeded. Shared cache save failed - server not connected."
                    ])
                    CodeMindActivityManager.shared.recordError(message: errorMessage)
                    return
                }
                
                try await saveSharedLearningData(mergedData, to: sharedURL)
            } catch {
                // Shared cache write failed (permissions, network issues, etc.)
                // Check if it's a server connection issue
                let isServerIssue = !isServerConnected()
                let errorMessage = isServerIssue 
                    ? "CodeMind: Cannot save to shared cache - server not connected. Please connect to the Grayson server."
                    : "CodeMind: Could not save to shared cache: \(error.localizedDescription). Local cache sync succeeded."
                
                CodeMindLogger.shared.log(isServerIssue ? .error : .warning, errorMessage, category: .cache, metadata: [
                    "error": error.localizedDescription,
                    "serverConnected": "\(isServerConnected())",
                    "note": "Local cache sync succeeded. Shared cache write failed."
                ])
                CodeMindActivityManager.shared.recordError(message: errorMessage)
            }
            
            CodeMindLogger.shared.log(.success, "Cache sync completed", category: .cache, metadata: [
                "patterns": "\(mergedData.patterns.count)",
                "feedbackRecords": "\(mergedData.feedbackRecords.count)"
            ])
            
        } catch {
            // Check if error is due to server connection
            let isServerIssue = !isServerConnected()
            let errorMessage = isServerIssue
                ? "CodeMind: Cache sync failed - server not connected. Please connect to the Grayson server to enable shared learning cache."
                : "CodeMind: Cache sync failed: \(error.localizedDescription)"
            
            CodeMindLogger.shared.log(.error, errorMessage, category: .cache, metadata: [
                "error": error.localizedDescription,
                "serverConnected": "\(isServerConnected())",
                "serverPath": serverBasePath ?? "not configured"
            ])
            CodeMindActivityManager.shared.recordError(message: errorMessage)
        }
    }
    
    /// Save local learning data to shared cache (called after feedback is provided)
    func saveToSharedCache() async {
        guard let sharedURL = sharedCacheURL else {
            let errorMessage = "CodeMind: Cannot save to shared cache - no URL configured. Check Settings > CodeMind AI."
            CodeMindLogger.shared.log(.warning, errorMessage, category: .cache)
            CodeMindActivityManager.shared.recordError(message: errorMessage)
            return
        }
        
        // Check server connection
        guard isServerConnected() else {
            let errorMessage = "CodeMind: Cannot save to shared cache - server not connected. Please connect to the Grayson server."
            CodeMindLogger.shared.log(.error, errorMessage, category: .cache, metadata: [
                "serverPath": serverBasePath ?? "not configured"
            ])
            CodeMindActivityManager.shared.recordError(message: errorMessage)
            return
        }
        
        CodeMindLogger.shared.log(.info, "Saving to shared cache", category: .cache)
        
        do {
            guard let codeMindStoragePath = getCodeMindStoragePath() else {
                CodeMindLogger.shared.log(.error, "Could not determine storage path", category: .cache)
                return
            }
            
            let localData = try await loadLocalLearningData(from: codeMindStoragePath)
            try await saveSharedLearningData(localData, to: sharedURL)
            
            CodeMindLogger.shared.log(.success, "Saved to shared cache", category: .cache, metadata: [
                "patterns": "\(localData.patterns.count)",
                "feedbackRecords": "\(localData.feedbackRecords.count)"
            ])
        } catch {
            // Check if error is due to server connection
            let isServerIssue = !isServerConnected()
            let errorMessage = isServerIssue
                ? "CodeMind: Failed to save to shared cache - server not connected. Please connect to the Grayson server."
                : "CodeMind: Failed to save to shared cache: \(error.localizedDescription)"
            
            CodeMindLogger.shared.log(.error, errorMessage, category: .cache, metadata: [
                "error": error.localizedDescription,
                "serverConnected": "\(isServerConnected())",
                "serverPath": serverBasePath ?? "not configured"
            ])
            CodeMindActivityManager.shared.recordError(message: errorMessage)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Safely create a directory, handling the case where a file with the same name exists
    /// If a file exists, it will be renamed with a .old extension before creating the directory
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
                CodeMindLogger.shared.log(.warning, "Found file where directory expected, renaming to backup", category: .cache, metadata: [
                    "path": path,
                    "backupPath": backupURL.path
                ])
                
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
    
    private func getCodeMindStoragePath() -> String? {
        // CodeMind stores data in Application Support/CodeMind
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let codeMindPath = appSupport.appendingPathComponent("CodeMind", isDirectory: true).path
        
        // Ensure directory exists
        try? FileManager.default.createDirectory(atPath: codeMindPath, withIntermediateDirectories: true)
        
        return codeMindPath
    }
    
    private func loadLocalLearningData(from path: String) async throws -> SharedLearningData {
        let patternsPath = (path as NSString).appendingPathComponent("patterns.json")
        let feedbackPath = (path as NSString).appendingPathComponent("feedback.json")
        
        var patterns: [LearnedPattern] = []
        var feedbackRecords: [FeedbackRecord] = []
        
        // Load patterns
        if FileManager.default.fileExists(atPath: patternsPath),
           let patternsData = FileManager.default.contents(atPath: patternsPath) {
            patterns = try JSONDecoder().decode([LearnedPattern].self, from: patternsData)
        }
        
        // Load feedback
        if FileManager.default.fileExists(atPath: feedbackPath),
           let feedbackData = FileManager.default.contents(atPath: feedbackPath) {
            feedbackRecords = try JSONDecoder().decode([FeedbackRecord].self, from: feedbackData)
        }
        
        return SharedLearningData(patterns: patterns, feedbackRecords: feedbackRecords)
    }
    
    private func loadSharedLearningData(from url: URL) async throws -> SharedLearningData {
        // Check for legacy filename and migrate if needed
        let legacyURL = url.deletingLastPathComponent().appendingPathComponent(legacyCacheFileName)
        if FileManager.default.fileExists(atPath: legacyURL.path) && !FileManager.default.fileExists(atPath: url.path) {
            // Migrate legacy file to new name
            CodeMindLogger.shared.log(.info, "Migrating cache file from legacy name", category: .cache, metadata: [
                "from": legacyURL.path,
                "to": url.path
            ])
            do {
                try FileManager.default.moveItem(at: legacyURL, to: url)
            } catch {
                CodeMindLogger.shared.log(.warning, "Failed to migrate legacy cache file, will use legacy name", category: .cache, metadata: ["error": error.localizedDescription])
                // Fall back to legacy file
                return try await loadSharedLearningData(from: legacyURL)
            }
        }
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Shared cache doesn't exist yet - return empty data
            return SharedLearningData(patterns: [], feedbackRecords: [])
        }
        
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SharedLearningData.self, from: data)
    }
    
    /// Merge learning data intelligently - accumulates knowledge without overwriting
    private func mergeLearningData(local: SharedLearningData, shared: SharedLearningData) -> SharedLearningData {
        // Merge patterns: combine similar patterns, keep unique ones
        var mergedPatterns: [LearnedPattern] = []
        var patternMap: [String: [LearnedPattern]] = [:] // Group by keyword signature
        
        // Add all patterns to map, grouped by their keyword signature
        for pattern in local.patterns + shared.patterns {
            let signature = pattern.keywords.sorted().joined(separator: "|")
            patternMap[signature, default: []].append(pattern)
        }
        
        // Merge patterns with similar keywords
        for (_, similarPatterns) in patternMap {
            if similarPatterns.count == 1 {
                // Unique pattern - keep as is
                mergedPatterns.append(similarPatterns[0])
            } else {
                // Multiple similar patterns - merge them
                if let merged = mergeSimilarPatterns(similarPatterns) {
                    mergedPatterns.append(merged)
                }
            }
        }
        
        // Merge feedback records: append all unique records (by ID)
        var feedbackMap: [String: FeedbackRecord] = [:]
        for record in local.feedbackRecords + shared.feedbackRecords {
            // Keep the most recent version if duplicate
            if let existing = feedbackMap[record.id] {
                if record.timestamp > existing.timestamp {
                    feedbackMap[record.id] = record
                }
            } else {
                feedbackMap[record.id] = record
            }
        }
        
        let mergedFeedback = Array(feedbackMap.values)
        
        return SharedLearningData(
            patterns: mergedPatterns,
            feedbackRecords: mergedFeedback
        )
    }
    
    /// Merge similar patterns by combining their knowledge
    /// - Parameter patterns: Array of patterns to merge (must not be empty)
    /// - Returns: A merged pattern combining knowledge from all input patterns, or nil if input is empty
    private func mergeSimilarPatterns(_ patterns: [LearnedPattern]) -> LearnedPattern? {
        guard !patterns.isEmpty else {
            CodeMindLogger.shared.log(.error, "Cannot merge empty patterns array - returning nil", category: .cache)
            return nil
        }

        if patterns.count == 1 {
            return patterns[0]
        }
        
        // Use the first pattern as base
        var merged = patterns[0]
        
        // Combine keywords (union)
        var allKeywords = Set(merged.keywords)
        for pattern in patterns[1...] {
            allKeywords.formUnion(pattern.keywords)
        }
        merged.keywords = Array(allKeywords).sorted()
        
        // Combine suggested tools (union)
        var allTools = Set(merged.suggestedTools)
        for pattern in patterns[1...] {
            allTools.formUnion(pattern.suggestedTools)
        }
        merged.suggestedTools = Array(allTools).sorted()
        
        // Average confidence (weighted by usage count)
        var totalUsage = merged.usageCount
        var weightedConfidence = merged.confidence * Float(merged.usageCount)
        for pattern in patterns[1...] {
            totalUsage += pattern.usageCount
            weightedConfidence += pattern.confidence * Float(pattern.usageCount)
        }
        merged.confidence = totalUsage > 0 ? weightedConfidence / Float(totalUsage) : merged.confidence
        
        // Sum usage counts
        merged.usageCount = patterns.reduce(0) { $0 + $1.usageCount }
        
        // Use most recent lastUsed date
        merged.lastUsed = patterns.map { $0.lastUsed }.max() ?? merged.lastUsed
        
        // Combine suggested approaches (prefer non-nil, concatenate if multiple)
        let approaches = patterns.compactMap { $0.suggestedApproach }.filter { !$0.isEmpty }
        if !approaches.isEmpty {
            // Combine unique approaches
            let uniqueApproaches = Array(Set(approaches))
            merged.suggestedApproach = uniqueApproaches.joined(separator: " | ")
        }
        
        // Update description to reflect merged nature
        if patterns.count > 1 {
            merged.description = "Merged pattern (from \(patterns.count) sources): \(merged.description)"
        }
        
        return merged
    }
    
    private func saveLearningData(_ data: SharedLearningData, to path: String) async throws {
        let patternsPath = (path as NSString).appendingPathComponent("patterns.json")
        let feedbackPath = (path as NSString).appendingPathComponent("feedback.json")
        
        // Save patterns
        let patternsData = try JSONEncoder().encode(data.patterns)
        try patternsData.write(to: URL(fileURLWithPath: patternsPath))
        
        // Save feedback (keep only recent 500 to avoid file bloat)
        let recentFeedback = Array(data.feedbackRecords.suffix(500))
        let feedbackData = try JSONEncoder().encode(recentFeedback)
        try feedbackData.write(to: URL(fileURLWithPath: feedbackPath))
    }
    
    private func saveSharedLearningData(_ data: SharedLearningData, to url: URL) async throws {
        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        
        // Check if we can write to the directory
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            let error = NSError(
                domain: "CodeMindCache",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot write to directory: \(directory.path). Check file permissions."]
            )
            throw error
        }
        
        // Safely create directory, handling case where a file with same name exists
        do {
            try safeCreateDirectory(at: directory)
        } catch {
            CodeMindLogger.shared.log(.warning, "Could not create cache directory (may already exist or permission issue)", category: .cache, metadata: [
                "path": directory.path,
                "error": error.localizedDescription
            ])
            // Continue - directory might already exist
        }
        
        // Check if file already exists and remove it first to avoid conflicts
        if FileManager.default.fileExists(atPath: url.path) {
            CodeMindLogger.shared.log(.debug, "Removing existing cache file before save", category: .cache, metadata: ["path": url.path])
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                CodeMindLogger.shared.log(.warning, "Could not remove existing cache file", category: .cache, metadata: [
                    "path": url.path,
                    "error": error.localizedDescription
                ])
                // Continue - we'll try to overwrite
            }
        }
        
        // Try to save to shared location with error handling
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: url, options: [.atomic])
            
            CodeMindLogger.shared.log(.debug, "Saved shared learning data", category: .cache, metadata: [
                "path": url.path,
                "patterns": "\(data.patterns.count)",
                "feedbackRecords": "\(data.feedbackRecords.count)"
            ])
        } catch {
            // If write fails, log detailed error and rethrow
            CodeMindLogger.shared.log(.error, "Failed to write cache file", category: .cache, metadata: [
                "path": url.path,
                "error": error.localizedDescription,
                "errorDetails": "\(error)"
            ])
            throw error
        }
    }
}

// MARK: - Shared Learning Data Format

struct SharedLearningData: Codable {
    let patterns: [LearnedPattern]
    let feedbackRecords: [FeedbackRecord]
    let lastUpdated: Date
    
    init(patterns: [LearnedPattern], feedbackRecords: [FeedbackRecord], lastUpdated: Date = Date()) {
        self.patterns = patterns
        self.feedbackRecords = feedbackRecords
        self.lastUpdated = lastUpdated
    }
}

// MARK: - Feedback Record (from CodeMind)

struct FeedbackRecord: Codable {
    let id: String
    let timestamp: Date
    let responseContent: String
    let feedback: Feedback
    let toolsUsed: [String]
}

