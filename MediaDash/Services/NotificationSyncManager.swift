import Foundation
import Combine

/// Manages synchronization of notification completion status across all MediaDash users
/// Stores completion status in shared cache so all users see when requests are completed
@MainActor
class NotificationSyncManager: ObservableObject {
    static let shared = NotificationSyncManager()
    
    private let sharedCacheFileName = "mediadash_notification_completions.json"
    private var sharedCacheURL: URL?
    private var serverBasePath: String?
    
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isSyncing = false
    
    private init() {
        // Load last sync date from UserDefaults
        if let date = UserDefaults.standard.object(forKey: "notification_sync_last_sync") as? Date {
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
                    self.sharedCacheURL = baseURL
                } else {
                    // It's a different file, use parent directory
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
    
    /// Sync with shared cache - merges completion status intelligently
    func syncWithSharedCache() async {
        guard let sharedURL = sharedCacheURL else {
            print("📋 [NotificationSync] No shared cache URL configured")
            return
        }
        
        // Check if server is connected (if cache is on server)
        if !isServerConnected() {
            print("📋 [NotificationSync] Cannot access shared cache - server not connected")
            return
        }
        
        print("📋 [NotificationSync] Starting cache sync")
        
        await MainActor.run {
            isSyncing = true
        }
        
        defer {
            Task { @MainActor in
                isSyncing = false
                lastSyncDate = Date()
                UserDefaults.standard.set(Date(), forKey: "notification_sync_last_sync")
            }
        }
        
        do {
            // Load local completion status
            let localData = try await loadLocalCompletionData()
            print("📋 [NotificationSync] Loaded local data: \(localData.completions.count) completions")
            
            // Load shared completion status
            let sharedData = try await loadSharedCompletionData(from: sharedURL)
            print("📋 [NotificationSync] Loaded shared data: \(sharedData.completions.count) completions")
            
            // Merge: keep most recent completion status for each notification ID
            let mergedData = mergeCompletionData(local: localData, shared: sharedData)
            print("📋 [NotificationSync] Merged data: \(mergedData.completions.count) completions")
            
            // Save merged data to local location first
            try await saveCompletionData(mergedData, to: getLocalCacheURL())
            
            // Try to save to shared location
            do {
                guard isServerConnected() else {
                    print("📋 [NotificationSync] Cannot save to shared cache - server not connected")
                    return
                }
                
                try await saveSharedCompletionData(mergedData, to: sharedURL)
                print("📋 [NotificationSync] Cache sync completed successfully")
            } catch {
                print("📋 [NotificationSync] Failed to save to shared cache: \(error.localizedDescription)")
                print("📋 [NotificationSync] Local cache sync succeeded")
            }
        } catch {
            print("📋 [NotificationSync] Cache sync failed: \(error.localizedDescription)")
        }
    }
    
    /// Save completion status to shared cache (called when a notification is marked complete/incomplete)
    func saveCompletionStatus(notificationId: UUID, isCompleted: Bool, completedAt: Date?) async {
        guard let sharedURL = sharedCacheURL else {
            print("📋 [NotificationSync] Cannot save - no shared cache URL configured")
            return
        }
        
        // Check server connection
        guard isServerConnected() else {
            print("📋 [NotificationSync] Cannot save - server not connected")
            return
        }
        
        print("📋 [NotificationSync] Saving completion status for notification \(notificationId)")
        
        do {
            // Load existing data
            let localData = try await loadLocalCompletionData()
            
            // Update or add completion status
            var updatedCompletions = localData.completions
            if let index = updatedCompletions.firstIndex(where: { $0.notificationId == notificationId }) {
                // Update existing
                updatedCompletions[index] = NotificationCompletion(
                    notificationId: notificationId,
                    isCompleted: isCompleted,
                    completedAt: completedAt,
                    lastUpdated: Date()
                )
            } else {
                // Add new
                updatedCompletions.append(NotificationCompletion(
                    notificationId: notificationId,
                    isCompleted: isCompleted,
                    completedAt: completedAt,
                    lastUpdated: Date()
                ))
            }
            
            let updatedData = NotificationCompletionData(completions: updatedCompletions)
            
            // Save locally first
            try await saveCompletionData(updatedData, to: getLocalCacheURL())
            
            // Save to shared cache
            try await saveSharedCompletionData(updatedData, to: sharedURL)
            
            print("📋 [NotificationSync] Successfully saved completion status")
        } catch {
            print("📋 [NotificationSync] Failed to save completion status: \(error.localizedDescription)")
        }
    }
    
    /// Get completion status for a notification
    func getCompletionStatus(notificationId: UUID) async -> NotificationCompletion? {
        do {
            let localData = try await loadLocalCompletionData()
            return localData.completions.first(where: { $0.notificationId == notificationId })
        } catch {
            print("📋 [NotificationSync] Failed to load completion status: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Private Helpers
    
    private func getLocalCacheURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let mediaDashPath = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: mediaDashPath, withIntermediateDirectories: true)
        return mediaDashPath.appendingPathComponent(sharedCacheFileName)
    }
    
    private func loadLocalCompletionData() async throws -> NotificationCompletionData {
        let url = getLocalCacheURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return NotificationCompletionData(completions: [])
        }
        
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(NotificationCompletionData.self, from: data)
    }
    
    private func loadSharedCompletionData(from url: URL) async throws -> NotificationCompletionData {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return NotificationCompletionData(completions: [])
        }
        
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(NotificationCompletionData.self, from: data)
    }
    
    /// Merge completion data - keep most recent status for each notification
    private func mergeCompletionData(local: NotificationCompletionData, shared: NotificationCompletionData) -> NotificationCompletionData {
        var completionMap: [UUID: NotificationCompletion] = [:]
        
        // Add all completions, keeping the most recent one for each notification ID
        for completion in local.completions + shared.completions {
            if let existing = completionMap[completion.notificationId] {
                // Keep the one with the most recent lastUpdated
                if completion.lastUpdated > existing.lastUpdated {
                    completionMap[completion.notificationId] = completion
                }
            } else {
                completionMap[completion.notificationId] = completion
            }
        }
        
        return NotificationCompletionData(completions: Array(completionMap.values))
    }
    
    private func saveCompletionData(_ data: NotificationCompletionData, to url: URL) async throws {
        let encoded = try JSONEncoder().encode(data)
        try encoded.write(to: url, options: [.atomic])
    }
    
    private func saveSharedCompletionData(_ data: NotificationCompletionData, to url: URL) async throws {
        // Ensure directory exists
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // Check if we can write to the directory
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw NSError(
                domain: "NotificationSync",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot write to directory: \(directory.path). Check file permissions."]
            )
        }
        
        // Save to shared location
        let encoded = try JSONEncoder().encode(data)
        try encoded.write(to: url, options: [.atomic])
    }
}

// MARK: - Data Models

struct NotificationCompletionData: Codable {
    var completions: [NotificationCompletion]
    var lastUpdated: Date
    
    init(completions: [NotificationCompletion], lastUpdated: Date = Date()) {
        self.completions = completions
        self.lastUpdated = lastUpdated
    }
}

struct NotificationCompletion: Codable, Identifiable {
    var id: UUID { notificationId }
    let notificationId: UUID
    let isCompleted: Bool
    let completedAt: Date?
    let lastUpdated: Date
}
