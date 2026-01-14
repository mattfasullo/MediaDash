import Foundation
import Combine
import SwiftUI

/// Central notification manager
@MainActor
class NotificationCenter: ObservableObject {
    @Published var notifications: [Notification] = []
    @Published var unreadCount: Int = 0
    @Published var isExpanded: Bool = false

    weak var grabbedIndicatorService: GrabbedIndicatorService?

    private let notificationsKey = "mediadash_notifications"

    // MARK: - Index Caches for O(1) Lookups
    // These dictionaries provide fast lookups instead of linear array searches
    private var notificationById: [UUID: Int] = [:]        // id -> array index
    private var notificationByEmailId: [String: Int] = [:] // emailId -> array index
    private var notificationByThreadId: [String: Set<Int>] = [:] // threadId -> set of array indices

    init() {
        Task { @MainActor in
            await Task.yield()
            loadNotifications()
            rebuildIndices() // Build lookup indices
            migrateOldNotifications() // Migrate old notifications to have original values
            removeDuplicates() // Clean up any existing duplicates
            cleanupOldArchivedNotifications()
            cleanupOldCompletedRequests()
            updateUnreadCount()
            
            // Sync completion status from shared cache
            await syncCompletionStatus()
        }
    }

    /// Rebuild all index caches - call after any bulk modification
    private func rebuildIndices() {
        notificationById.removeAll(keepingCapacity: true)
        notificationByEmailId.removeAll(keepingCapacity: true)
        notificationByThreadId.removeAll(keepingCapacity: true)

        for (index, notification) in notifications.enumerated() {
            notificationById[notification.id] = index
            if let emailId = notification.emailId {
                notificationByEmailId[emailId] = index
            }
            if let threadId = notification.threadId {
                notificationByThreadId[threadId, default: []].insert(index)
            }
        }
    }

    /// Find notification index by ID (O(1) lookup)
    private func indexById(_ id: UUID) -> Int? {
        guard let cachedIndex = notificationById[id],
              cachedIndex < notifications.count,
              notifications[cachedIndex].id == id else {
            // Cache miss or stale - fall back to linear search and update cache
            if let index = notifications.firstIndex(where: { $0.id == id }) {
                notificationById[id] = index
                return index
            }
            return nil
        }
        return cachedIndex
    }

    /// Find notification index by emailId (O(1) lookup)
    private func indexByEmailId(_ emailId: String) -> Int? {
        guard let cachedIndex = notificationByEmailId[emailId],
              cachedIndex < notifications.count,
              notifications[cachedIndex].emailId == emailId else {
            // Cache miss or stale - fall back to linear search and update cache
            if let index = notifications.firstIndex(where: { $0.emailId == emailId }) {
                notificationByEmailId[emailId] = index
                return index
            }
            return nil
        }
        return cachedIndex
    }

    /// Find notifications by threadId (O(1) lookup, returns indices)
    private func indicesByThreadId(_ threadId: String) -> [Int] {
        guard let cachedIndices = notificationByThreadId[threadId] else {
            // Build cache for this threadId
            var indices: Set<Int> = []
            for (index, notification) in notifications.enumerated() {
                if notification.threadId == threadId {
                    indices.insert(index)
                }
            }
            if !indices.isEmpty {
                notificationByThreadId[threadId] = indices
            }
            return Array(indices)
        }
        // Validate cached indices
        return cachedIndices.filter { $0 < notifications.count && notifications[$0].threadId == threadId }
    }
    
    /// Migrate old notifications to populate missing original values
    private func migrateOldNotifications() {
        var needsSave = false
        for index in notifications.indices {
            let notification = notifications[index]
            
            // If originalMessage is nil but message exists, set it
            if notification.originalMessage == nil && !notification.message.isEmpty {
                notifications[index].originalMessage = notification.message
                needsSave = true
            }
            
            // If original values are nil but current values exist, set them
            if notification.originalDocketNumber == nil && notification.docketNumber != nil {
                notifications[index].originalDocketNumber = notification.docketNumber
                needsSave = true
            }
            
            if notification.originalJobName == nil && notification.jobName != nil {
                notifications[index].originalJobName = notification.jobName
                needsSave = true
            } else if notification.originalJobName == nil && notification.jobName == nil {
                // Try to extract job name from message if both are nil
                // Pattern: "JOBNAME (Docket number pending)" or "Docket XXX: JOBNAME"
                let message = notification.message
                
                // Pattern 1: "JOBNAME (Docket number pending)"
                if let regex = try? NSRegularExpression(pattern: #"^(.+?)\s*\(Docket number pending\)$"#, options: []),
                   let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                   match.numberOfRanges >= 2,
                   let jobNameRange = Range(match.range(at: 1), in: message) {
                    let jobName = String(message[jobNameRange]).trimmingCharacters(in: .whitespaces)
                    if !jobName.isEmpty {
                        notifications[index].originalJobName = jobName
                        notifications[index].jobName = jobName
                        needsSave = true
                    }
                }
                // Pattern 2: "Docket XXX: JOBNAME"
                else if let regex = try? NSRegularExpression(pattern: #"^Docket \d+:\s*(.+)$"#, options: []),
                        let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                        match.numberOfRanges >= 2,
                        let jobNameRange = Range(match.range(at: 1), in: message) {
                    let jobName = String(message[jobNameRange]).trimmingCharacters(in: .whitespaces)
                    if !jobName.isEmpty {
                        notifications[index].originalJobName = jobName
                        notifications[index].jobName = jobName
                        needsSave = true
                    }
                }
            }
            
            if notification.originalProjectManager == nil && notification.projectManager != nil {
                notifications[index].originalProjectManager = notification.projectManager
                needsSave = true
            }
        }
        
        if needsSave {
            saveNotifications()
            print("NotificationCenter: Migrated \(notifications.count) notification(s) with missing original values")
        }
    }
    
    /// Remove archived notifications older than 24 hours
    func cleanupOldArchivedNotifications() {
        let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60) // 24 hours ago
        let beforeCount = notifications.count
        notifications.removeAll { notification in
            if let archivedAt = notification.archivedAt, archivedAt < cutoffDate {
                return true
            }
            return false
        }
        if notifications.count < beforeCount {
            updateUnreadCount()
            saveNotifications()
        }
    }
    
    /// Remove completed request notifications older than 24 hours
    func cleanupOldCompletedRequests() {
        let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60) // 24 hours ago
        let beforeCount = notifications.count
        notifications.removeAll { notification in
            if notification.type == .request,
               notification.status == .completed,
               let completedAt = notification.completedAt,
               completedAt < cutoffDate {
                return true
            }
            return false
        }
        if notifications.count < beforeCount {
            updateUnreadCount()
            saveNotifications()
        }
    }
    
    /// Add a new notification (prevents duplicates by emailId, threadId, or docket+jobName)
    /// If a notification already exists for the same thread, silently skips unless there's new actionable content
    func add(_ notification: Notification) {
        // Check for duplicate by emailId if emailId is present
        if let emailId = notification.emailId {
            // Remove any existing notification with the same emailId
            notifications.removeAll { $0.emailId == emailId }
        }

        // Check for duplicate by threadId - skip if we already have a notification for this thread
        // Replies to existing threads don't need new notifications (just conversation noise)
        if let threadId = notification.threadId {
            // For docket notifications, skip if we already have one for this thread
            if notification.type == .newDocket {
                let existingThreadNotification = notifications.first { existing in
                    existing.threadId == threadId &&
                    existing.type == .newDocket
                }
                if existingThreadNotification != nil {
                    print("📋 [NotificationCenter] Skipping thread reply - already have docket notification for thread \(threadId)")
                    return
                }
            }
            // For file delivery, only update if there are NEW file links
            if notification.type == .mediaFiles {
                if let existingIndex = notifications.firstIndex(where: { existing in
                    existing.threadId == threadId && existing.type == .mediaFiles
                }) {
                    // Check if there are genuinely new file links worth notifying about
                    if let newLinks = notification.fileLinks, !newLinks.isEmpty {
                        let existingLinks = notifications[existingIndex].fileLinks ?? []
                        let existingLinksSet = Set(existingLinks)
                        let newDescriptions = notification.fileLinkDescriptions ?? []

                        // Find indices of truly new links
                        var trulyNewLinks: [String] = []
                        var trulyNewDescriptions: [String] = []
                        for (index, link) in newLinks.enumerated() {
                            if !existingLinksSet.contains(link) {
                                trulyNewLinks.append(link)
                                let desc = index < newDescriptions.count ? newDescriptions[index] : "Unknown contents"
                                trulyNewDescriptions.append(desc)
                            }
                        }

                        if !trulyNewLinks.isEmpty {
                            // Add the new links and descriptions to the existing notification
                            var updatedLinks = existingLinks
                            updatedLinks.append(contentsOf: trulyNewLinks)
                            notifications[existingIndex].fileLinks = updatedLinks

                            var updatedDescriptions = notifications[existingIndex].fileLinkDescriptions ?? []
                            updatedDescriptions.append(contentsOf: trulyNewDescriptions)
                            notifications[existingIndex].fileLinkDescriptions = updatedDescriptions

                            saveNotifications()
                            print("📋 [NotificationCenter] Added \(trulyNewLinks.count) new file links to existing notification for thread \(threadId)")
                        } else {
                            print("📋 [NotificationCenter] Skipping thread reply - no new file links for thread \(threadId)")
                        }
                    } else {
                        print("📋 [NotificationCenter] Skipping thread reply - already have file delivery notification for thread \(threadId)")
                    }
                    return
                }
            }
            // For requests, skip if we already have one for this thread
            if notification.type == .request {
                let existingThreadNotification = notifications.first { existing in
                    existing.threadId == threadId && existing.type == .request
                }
                if existingThreadNotification != nil {
                    print("📋 [NotificationCenter] Skipping thread reply - already have request notification for thread \(threadId)")
                    return
                }
            }
        }

        // Additional check: for newDocket, prevent duplicates with same docketNumber + jobName
        if notification.type == .newDocket,
           let docketNum = notification.docketNumber,
           let jobName = notification.jobName {
            let existingDocketNotification = notifications.first { existing in
                existing.type == .newDocket &&
                existing.docketNumber == docketNum &&
                existing.jobName == jobName
            }
            if existingDocketNotification != nil {
                print("📋 [NotificationCenter] Skipping duplicate - same docket+job already exists: \(docketNum) \(jobName)")
                return
            }
        }

        notifications.insert(notification, at: 0) // Add to top
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Remove a notification and mark email as read
    func remove(_ notification: Notification, emailScanningService: EmailScanningService? = nil) async {
        // Mark email as read before removing (await to ensure it completes)
        if let emailId = notification.emailId, let emailService = emailScanningService {
            do {
                try await emailService.gmailService.markAsRead(messageId: emailId)
                print("📋 [NotificationCenter] ✅ Successfully marked email \(emailId) as read before removing notification")
            } catch {
                print("📋 [NotificationCenter] ❌ Failed to mark email \(emailId) as read: \(error.localizedDescription)")
                print("📋 [NotificationCenter] Error details: \(error)")
            }
        } else {
            if notification.emailId == nil {
                print("📋 [NotificationCenter] ⚠️ Cannot mark email as read - notification has no emailId")
            }
            if emailScanningService == nil {
                print("📋 [NotificationCenter] ⚠️ Cannot mark email as read - emailScanningService is nil")
            }
        }
        
        notifications.removeAll { $0.id == notification.id }
        rebuildIndices() // Rebuild indices after removal
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Archive a notification - now removes it and marks email as read
    func archive(_ notification: Notification, emailScanningService: EmailScanningService? = nil) {
        // Mark email as read before removing
        if let emailId = notification.emailId, let emailService = emailScanningService {
                Task {
                    do {
                        try await emailService.gmailService.markAsRead(messageId: emailId)
                    print("📋 [NotificationCenter] ✅ Successfully marked email \(emailId) as read before removing notification")
                    } catch {
                    print("📋 [NotificationCenter] ❌ Failed to mark email \(emailId) as read: \(error.localizedDescription)")
                    print("📋 [NotificationCenter] Error details: \(error)")
                    }
                }
        } else {
            if notification.emailId == nil {
                print("📋 [NotificationCenter] ⚠️ Cannot mark email as read - notification has no emailId")
            }
            if emailScanningService == nil {
                print("📋 [NotificationCenter] ⚠️ Cannot mark email as read - emailScanningService is nil")
            }
        }
        
        // Remove notification instead of archiving
        notifications.removeAll { $0.id == notification.id }
        rebuildIndices() // Rebuild indices after removal
        updateUnreadCount()
        saveNotifications()
        print("📋 [NotificationCenter] Removed notification (archived)")
    }
    
    /// Dismiss a notification (kept for backward compatibility, but now archives)
    func dismiss(_ notification: Notification, emailScanningService: EmailScanningService? = nil) {
        archive(notification, emailScanningService: emailScanningService)
    }
    
    /// Mark notification as read
    func markAsRead(_ notification: Notification) {
        // Notifications are considered "read" when status changes from pending
        // This is handled by status changes
    }
    
    /// Update notification status
    func updateStatus(_ notification: Notification, to status: NotificationStatus, emailScanningService: EmailScanningService? = nil) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index].status = status
            updateUnreadCount()
            saveNotifications()
            
            // Mark email as read when status changes to completed or dismissed
            if (status == .completed || status == .dismissed),
               let emailId = notifications[index].emailId,
               let emailService = emailScanningService {
                Task {
                    do {
                        try await emailService.gmailService.markAsRead(messageId: emailId)
                        print("📋 [NotificationCenter] ✅ Successfully marked email \(emailId) as read after status change to \(status)")
                    } catch {
                        print("📋 [NotificationCenter] ❌ Failed to mark email \(emailId) as read: \(error.localizedDescription)")
                        print("📋 [NotificationCenter] Error details: \(error)")
                    }
                }
            } else if (status == .completed || status == .dismissed) {
                if notifications[index].emailId == nil {
                    print("📋 [NotificationCenter] ⚠️ Cannot mark email as read - notification has no emailId")
                }
                if emailScanningService == nil {
                    print("📋 [NotificationCenter] ⚠️ Cannot mark email as read - emailScanningService is nil")
                }
            }
        }
    }
    
    /// Mark a request notification as complete (syncs with other users)
    func markRequestComplete(_ notification: Notification) async {
        guard notification.type == .request else {
            print("📋 [NotificationCenter] ⚠️ Cannot mark non-request notification as complete")
            return
        }
        
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            let completedAt = Date()
            notifications[index].status = .completed
            notifications[index].completedAt = completedAt
            updateUnreadCount()
            saveNotifications()
            
            // Sync completion status to shared cache
            await NotificationSyncManager.shared.saveCompletionStatus(
                notificationId: notification.id,
                isCompleted: true,
                completedAt: completedAt
            )
            
            print("📋 [NotificationCenter] ✅ Marked request notification as complete")
        }
    }
    
    /// Mark a request notification as incomplete (undoes completion, syncs with other users)
    func markRequestIncomplete(_ notification: Notification) async {
        guard notification.type == .request else {
            print("📋 [NotificationCenter] ⚠️ Cannot mark non-request notification as incomplete")
            return
        }
        
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index].status = .pending
            notifications[index].completedAt = nil
            updateUnreadCount()
            saveNotifications()
            
            // Sync completion status to shared cache
            await NotificationSyncManager.shared.saveCompletionStatus(
                notificationId: notification.id,
                isCompleted: false,
                completedAt: nil
            )
            
            print("📋 [NotificationCenter] ✅ Marked request notification as incomplete")
        }
    }
    
    /// Sync completion status from shared cache
    func syncCompletionStatus() async {
        await Task.yield()
        await NotificationSyncManager.shared.syncWithSharedCache()
        
        // Apply synced completion status to local notifications
        for index in notifications.indices {
            let notification = notifications[index]
            if notification.type == .request {
                if let completionStatus = await NotificationSyncManager.shared.getCompletionStatus(notificationId: notification.id) {
                    // Update local notification to match synced status
                    if completionStatus.isCompleted {
                        if notifications[index].status != .completed {
                            notifications[index].status = .completed
                            notifications[index].completedAt = completionStatus.completedAt
                        }
                    } else {
                        // If synced status says incomplete, but we have it as completed, update it
                        if notifications[index].status == .completed {
                            notifications[index].status = .pending
                            notifications[index].completedAt = nil
                        }
                    }
                }
            }
        }
        
        // Clean up old completed requests after syncing
        cleanupOldCompletedRequests()
        saveNotifications()
        updateUnreadCount()
    }
    
    /// Update notification action flags
    func updateActionFlags(_ notification: Notification, workPicture: Bool? = nil, simianJob: Bool? = nil) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            if let wp = workPicture {
                notifications[index].shouldCreateWorkPicture = wp
            }
            if let sj = simianJob {
                notifications[index].shouldCreateSimianJob = sj
            }
            // Don't save to UserDefaults - these are just UI state
        }
    }
    
    /// Update notification docket number
    func updateDocketNumber(_ notification: Notification, to docketNumber: String) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index].docketNumber = docketNumber
            // Update message to reflect new docket number
            if let jobName = notifications[index].jobName {
                notifications[index].message = "Docket \(docketNumber): \(jobName)"
            }
            saveNotifications()
        }
    }
    
    /// Update notification project manager
    func updateProjectManager(_ notification: Notification, to projectManager: String?) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index].projectManager = projectManager
            saveNotifications()
        }
    }
    
    /// Update notification job name (does not affect docket number)
    func updateJobName(_ notification: Notification, to jobName: String) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            // Explicitly preserve the docket number before updating
            let preservedDocketNumber = notifications[index].docketNumber
            
            // Only update job name - docket number remains unchanged
            notifications[index].jobName = jobName
            
            // Ensure docket number is preserved (defensive check)
            notifications[index].docketNumber = preservedDocketNumber
            
            // Update message to reflect new job name (using existing docket number)
            if let docketNumber = preservedDocketNumber, docketNumber != "TBD" {
                notifications[index].message = "Docket \(docketNumber): \(jobName)"
            } else {
                notifications[index].message = "\(jobName) (Docket number pending)"
            }
            saveNotifications()
        }
    }
    
    /// Mark a notification as junk or skipped (removes it and marks email as read)
    /// - Parameters:
    ///   - notification: The notification to mark
    ///   - newType: Must be .junk or .skipped
    ///   - autoArchive: Unused (kept for compatibility)
    ///   - emailScanningService: Optional service for email operations
    func reclassify(
        _ notification: Notification,
        to newType: NotificationType,
        autoArchive: Bool = true,
        emailScanningService: EmailScanningService? = nil
    ) async {
        // Only support junk and skipped (both remove the notification)
        guard newType == .junk || newType == .skipped else {
            print("📋 [NotificationCenter] ⚠️ reclassify only supports .junk or .skipped, got \(newType.displayName)")
            return
        }
        
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }
        
        let emailId = notifications[index].emailId
        
        // Mark email as read before removing
        if let emailId = emailId, let emailService = emailScanningService {
            Task {
                do {
                    try await emailService.gmailService.markAsRead(messageId: emailId)
                    print("📋 [NotificationCenter] ✅ Successfully marked email \(emailId) as read after marking as \(newType.displayName)")
                } catch {
                    print("📋 [NotificationCenter] ❌ Failed to mark email \(emailId) as read: \(error.localizedDescription)")
                    print("📋 [NotificationCenter] Error details: \(error)")
                }
            }
        } else {
            if emailId == nil {
                print("📋 [NotificationCenter] ⚠️ Cannot mark email as read - notification has no emailId")
            }
            if emailScanningService == nil {
                print("📋 [NotificationCenter] ⚠️ Cannot mark email as read - emailScanningService is nil")
            }
        }
        
        // Remove notification
        notifications.removeAll { $0.id == notification.id }
        rebuildIndices()
        updateUnreadCount()
        saveNotifications()
        print("📋 [NotificationCenter] Removed notification after marking as \(newType.displayName)")
    }
    
    /// Skip a notification (removes from active list)
    func skip(_ notification: Notification, emailScanningService: EmailScanningService? = nil) async {
        await reclassify(notification, to: .skipped, autoArchive: true, emailScanningService: emailScanningService)
    }
    
    /// Mark a notification as junk (ads, promos, spam)
    func markAsJunk(_ notification: Notification, emailScanningService: EmailScanningService? = nil) async {
        await reclassify(notification, to: .junk, autoArchive: true, emailScanningService: emailScanningService)
    }
    
    /// Update duplicate detection flags for a notification
    func updateDuplicateDetection(_ notification: Notification, mediaManager: MediaManager?, settingsManager: SettingsManager?) {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }),
              let docketNumber = notification.docketNumber, docketNumber != "TBD",
              let jobName = notification.jobName else {
            return
        }
        
        // Check Work Picture
        if let mediaManager = mediaManager {
            let docketName = "\(docketNumber)_\(jobName)"
            notifications[index].isInWorkPicture = mediaManager.dockets.contains(docketName)
        }
        
        // Check Simian - for now, we'll track this via a property set when Simian job is created
        // In the future, this could check Simian API if available
        // For now, if shouldCreateSimianJob was true and notification was approved, assume it's in Simian
        // This is a simplified approach - in production you might want to query Simian API
        
        saveNotifications()
    }
    
    /// Mark notification as in Simian
    func markAsInSimian(_ notification: Notification) {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }
        notifications[index].isInSimian = true
        saveNotifications()
    }
    
    func markAsInWorkPicture(_ notification: Notification) {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }
        notifications[index].isInWorkPicture = true
        saveNotifications()
    }
    
    /// Reset notification to original values by re-fetching and re-parsing the email
    func resetToDefaults(_ notification: Notification, emailScanningService: EmailScanningService?) async {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }),
              let emailId = notification.emailId,
              let emailService = emailScanningService else {
            // Fallback to stored original values if we can't re-fetch
            if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
                notifications[index].docketNumber = notifications[index].originalDocketNumber
                notifications[index].jobName = notifications[index].originalJobName
                notifications[index].projectManager = notifications[index].originalProjectManager
                if let originalMessage = notifications[index].originalMessage {
                    notifications[index].message = originalMessage
                }
                saveNotifications()
            }
            return
        }
        
        // Re-fetch and re-parse the email
        if let parsed = await emailService.reparseEmail(emailId: emailId) {
            // Update with freshly parsed values
            notifications[index].docketNumber = parsed.docketNumber
            notifications[index].jobName = parsed.jobName
            notifications[index].emailSubject = parsed.subject
            notifications[index].emailBody = parsed.body
            
            // Update original values to match (so future resets use these)
            notifications[index].originalDocketNumber = parsed.docketNumber
            notifications[index].originalJobName = parsed.jobName
            notifications[index].originalProjectManager = notification.sourceEmail // Reset to source email
            
            // Reconstruct message
            if let docketNumber = parsed.docketNumber, docketNumber != "TBD" {
                if let jobName = parsed.jobName {
                    notifications[index].message = "Docket \(docketNumber): \(jobName)"
                } else {
                    notifications[index].message = "Docket \(docketNumber)"
                }
            } else if let jobName = parsed.jobName {
                notifications[index].message = "\(jobName) (Docket number pending)"
            }
            
            // Update original message
            notifications[index].originalMessage = notifications[index].message
            
            saveNotifications()
            print("NotificationCenter: Reset notification \(notification.id) to freshly parsed values from email")
        } else {
            // Fallback to stored original values if re-parsing fails
            notifications[index].docketNumber = notifications[index].originalDocketNumber
            notifications[index].jobName = notifications[index].originalJobName
            notifications[index].projectManager = notifications[index].originalProjectManager
            if let originalMessage = notifications[index].originalMessage {
                notifications[index].message = originalMessage
            }
            saveNotifications()
        }
    }
    
    /// Get pending notifications
    var pendingNotifications: [Notification] {
        notifications.filter { $0.status == .pending }
    }
    
    /// Get unread notifications (pending status)
    var unreadNotifications: [Notification] {
        notifications.filter { $0.status == .pending }
    }
    
    /// Get archived notifications (dismissed status with archivedAt)
    var archivedNotifications: [Notification] {
        notifications.filter { $0.status == .dismissed && $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? Date.distantPast) > ($1.archivedAt ?? Date.distantPast) }
    }
    
    /// Get active notifications (not archived, only newDocket type - mediaFiles and requests excluded)
    var activeNotifications: [Notification] {
        let active = notifications.filter { 
            ($0.status != .dismissed || $0.archivedAt == nil) && $0.type == .newDocket
        }
        
        // Debug: Log if there's a mismatch between unreadCount and active notifications
        let pendingActive = active.filter { $0.status == .pending }
        if unreadCount > 0 && pendingActive.isEmpty && !notifications.filter({ $0.status == .pending }).isEmpty {
            print("📋 [NotificationCenter] ⚠️ DEBUG: unreadCount=\(unreadCount) but no pending active notifications")
            let allPending = notifications.filter { $0.status == .pending }
            print("📋 [NotificationCenter]   Total pending: \(allPending.count)")
            for (index, notif) in allPending.enumerated() {
                print("📋 [NotificationCenter]   Pending[\(index)]: id=\(notif.id), type=\(notif.type), status=\(notif.status), archivedAt=\(notif.archivedAt?.description ?? "nil"), dismissed=\(notif.status == .dismissed)")
            }
        }
        
        return active
    }
    
    /// Clear all dismissed notifications
    func clearDismissed() {
        notifications.removeAll { $0.status == .dismissed }
        rebuildIndices() // Rebuild indices after removal
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Clear all notifications
    func clearAll() {
        notifications.removeAll()
        rebuildIndices() // Rebuild indices after removal
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Remove duplicate notifications (keeps the most recent one for each emailId)
    func removeDuplicates() {
        var seenEmailIds: Set<String> = []
        var seenThreadDockets: Set<String> = []  // "threadId:docketNumber" combinations
        var seenDocketJobs: Set<String> = []     // "docketNumber:jobName" combinations for newDocket
        var uniqueNotifications: [Notification] = []

        // Process notifications in reverse order (oldest first) so we keep the newest
        for notification in notifications.reversed() {
            var isDuplicate = false

            // Check by emailId
            if let emailId = notification.emailId {
                if seenEmailIds.contains(emailId) {
                    isDuplicate = true
                } else {
                    seenEmailIds.insert(emailId)
                }
            }

            // Check by threadId + docketNumber (for same thread with same docket)
            if !isDuplicate, let threadId = notification.threadId, let docketNum = notification.docketNumber {
                let key = "\(threadId):\(docketNum)"
                if seenThreadDockets.contains(key) {
                    isDuplicate = true
                    print("📋 [NotificationCenter] Removing duplicate: same thread+docket - \(docketNum)")
                } else {
                    seenThreadDockets.insert(key)
                }
            }

            // Check by docketNumber + jobName (for newDocket type only)
            if !isDuplicate, notification.type == .newDocket,
               let docketNum = notification.docketNumber, let jobName = notification.jobName {
                let key = "\(docketNum):\(jobName)"
                if seenDocketJobs.contains(key) {
                    isDuplicate = true
                    print("📋 [NotificationCenter] Removing duplicate: same docket+job - \(docketNum) \(jobName)")
                } else {
                    seenDocketJobs.insert(key)
                }
            }

            if !isDuplicate {
                uniqueNotifications.append(notification)
            }
        }

        // Reverse back to original order (newest first)
        uniqueNotifications.reverse()

        let removedCount = notifications.count - uniqueNotifications.count
        if removedCount > 0 {
            notifications = uniqueNotifications
            updateUnreadCount()
            saveNotifications()
            print("NotificationCenter: Removed \(removedCount) duplicate notification(s)")
        }
    }
    
    /// Update unread count (only counts newDocket notifications - mediaFiles and requests are excluded)
    private func updateUnreadCount() {
        // Only count newDocket notifications - we no longer process mediaFiles or requests
        let pendingCount = notifications.filter { 
            $0.status == .pending && $0.type == .newDocket 
        }.count
        if unreadCount != pendingCount {
            print("📋 [NotificationCenter] Updating unread count: \(unreadCount) -> \(pendingCount) (total notifications: \(notifications.count), newDocket only)")
        }
        
        // Debug: Check for notifications in bad state (pending but archived)
        let badStateNotifications = notifications.filter { $0.status == .pending && $0.archivedAt != nil }
        if !badStateNotifications.isEmpty {
            print("📋 [NotificationCenter] ⚠️ WARNING: Found \(badStateNotifications.count) notification(s) in bad state (pending but archived)")
            for notif in badStateNotifications {
                print("📋 [NotificationCenter]   - ID: \(notif.id), type: \(notif.type), archivedAt: \(notif.archivedAt?.description ?? "nil")")
                // Fix: Clear archivedAt for pending notifications
                if let index = notifications.firstIndex(where: { $0.id == notif.id }) {
                    notifications[index].archivedAt = nil
                    print("📋 [NotificationCenter]   ✅ Fixed: Cleared archivedAt for notification \(notif.id)")
                }
            }
            saveNotifications()
        }
        
        unreadCount = pendingCount
    }
    
    /// Save notifications to UserDefaults
    private func saveNotifications() {
        if let data = try? JSONEncoder().encode(notifications) {
            UserDefaults.standard.set(data, forKey: notificationsKey)
        }
    }
    
    /// Load notifications from UserDefaults
    private func loadNotifications() {
        if let data = UserDefaults.standard.data(forKey: notificationsKey),
           let loaded = try? JSONDecoder().decode([Notification].self, from: data) {
            notifications = loaded
        }
    }
}

