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
    
    init() {
        loadNotifications()
        migrateOldNotifications() // Migrate old notifications to have original values
        removeDuplicates() // Clean up any existing duplicates
        cleanupOldArchivedNotifications()
        updateUnreadCount()
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
    
    /// Add a new notification (prevents duplicates by emailId)
    func add(_ notification: Notification) {
        // Check for duplicate by emailId if emailId is present
        if let emailId = notification.emailId {
            // Remove any existing notification with the same emailId
            notifications.removeAll { $0.emailId == emailId }
        }
        
        notifications.insert(notification, at: 0) // Add to top
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Remove a notification
    func remove(_ notification: Notification) {
        notifications.removeAll { $0.id == notification.id }
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Archive a notification (replaces dismiss)
    func archive(_ notification: Notification) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index].status = .dismissed // Keep using dismissed status for compatibility
            notifications[index].archivedAt = Date()
            updateUnreadCount()
            saveNotifications()
        }
    }
    
    /// Dismiss a notification (kept for backward compatibility, but now archives)
    func dismiss(_ notification: Notification) {
        archive(notification)
    }
    
    /// Mark notification as read
    func markAsRead(_ notification: Notification) {
        // Notifications are considered "read" when status changes from pending
        // This is handled by status changes
    }
    
    /// Update notification status
    func updateStatus(_ notification: Notification, to status: NotificationStatus) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            notifications[index].status = status
            updateUnreadCount()
            saveNotifications()
        }
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
    
    /// Reclassify a notification to a different type
    /// - Parameters:
    ///   - notification: The notification to reclassify
    ///   - newType: The new notification type
    ///   - autoArchive: Whether to automatically archive junk/skipped notifications
    ///   - emailScanningService: Optional service for learning from re-classification
    func reclassify(
        _ notification: Notification,
        to newType: NotificationType,
        autoArchive: Bool = true,
        emailScanningService: EmailScanningService? = nil
    ) async {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }
        
        let oldType = notifications[index].type
        
        // If changing from file delivery to new docket, the notification should "move" sections
        // Reset status if it was archived so it appears in the new section
        if oldType == .mediaFiles && newType == .newDocket {
            if notifications[index].status == .dismissed {
                notifications[index].status = .pending
                notifications[index].archivedAt = nil
            }
        }
        // Similarly, if changing from new docket to file delivery, reset if archived
        else if oldType == .newDocket && newType == .mediaFiles {
            if notifications[index].status == .dismissed {
                notifications[index].status = .pending
                notifications[index].archivedAt = nil
            }
        }
        
        notifications[index].type = newType
        
        // Clear custom type name if not using custom type
        if newType != .custom {
            notifications[index].customTypeName = nil
        }
        
        // Clear old CodeMind metadata since this is a manual correction
        notifications[index].codeMindClassification = nil
        
        // Update title to reflect new type
        switch newType {
        case .newDocket:
            notifications[index].title = "New Docket"
        case .mediaFiles:
            notifications[index].title = "File Delivery"
        case .junk:
            notifications[index].title = "Junk"
        case .skipped:
            notifications[index].title = "Skipped"
        case .info:
            notifications[index].title = "Info"
        case .error:
            notifications[index].title = "Error"
        case .custom:
            // Title will be set by the custom reclassify function
            break
        }
        
        // Auto-archive junk and skipped notifications
        if autoArchive && (newType == .junk || newType == .skipped) {
            notifications[index].status = .dismissed
            notifications[index].archivedAt = Date()
        }
        
        print("📋 [NotificationCenter] Reclassified notification from \(oldType.displayName) to \(newType.displayName)")
        
        // Mark email as read when re-classifying to anything other than "New Docket" or "File Delivery"
        // (Re-classifying is for algorithm learning, so we mark as read to indicate user interaction)
        if newType != .newDocket && newType != .mediaFiles,
           let emailId = notifications[index].emailId,
           let emailService = emailScanningService {
            Task {
                do {
                    try await emailService.gmailService.markAsRead(messageId: emailId)
                    print("📋 [NotificationCenter] Marked email \(emailId) as read after re-classification")
                } catch {
                    print("📋 [NotificationCenter] Failed to mark email as read: \(error.localizedDescription)")
                }
            }
        }
        
        // Learn from the re-classification (teach CodeMind)
        if let emailService = emailScanningService {
            await emailService.learnFromReclassification(
                notification: notifications[index],
                oldType: oldType,
                newType: newType,
                emailSubject: notifications[index].emailSubject,
                emailBody: notifications[index].emailBody,
                emailFrom: notifications[index].sourceEmail
            )
        }
        
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Reclassify a notification to a custom type
    /// - Parameters:
    ///   - notification: The notification to reclassify
    ///   - customTypeName: The custom classification name
    ///   - autoArchive: Whether to automatically archive the notification
    ///   - emailScanningService: Optional service for learning from re-classification
    func reclassify(
        _ notification: Notification,
        toCustomType customTypeName: String,
        autoArchive: Bool = false,
        emailScanningService: EmailScanningService? = nil
    ) async {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else {
            return
        }
        
        let trimmedName = customTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        let oldType = notifications[index].type
        notifications[index].type = .custom
        notifications[index].customTypeName = trimmedName
        notifications[index].title = trimmedName
        
        // Clear old CodeMind metadata since this is a manual correction
        notifications[index].codeMindClassification = nil
        
        // Add to recent custom classifications
        RecentCustomClassificationsManager.shared.add(trimmedName)
        
        // Auto-archive if requested
        if autoArchive {
            notifications[index].status = .dismissed
            notifications[index].archivedAt = Date()
        }
        
        let oldTypeName = oldType == .custom ? (notifications[index].customTypeName ?? "Custom") : oldType.displayName
        print("📋 [NotificationCenter] Reclassified notification from \(oldTypeName) to custom type '\(trimmedName)'")
        
        // Mark email as read when re-classifying to custom type (anything other than "New Docket" or "File Delivery")
        // (Re-classifying is for algorithm learning, so we mark as read to indicate user interaction)
        if let emailId = notifications[index].emailId,
           let emailService = emailScanningService {
            Task {
                do {
                    try await emailService.gmailService.markAsRead(messageId: emailId)
                    print("📋 [NotificationCenter] Marked email \(emailId) as read after custom re-classification")
                } catch {
                    print("📋 [NotificationCenter] Failed to mark email as read: \(error.localizedDescription)")
                }
            }
        }
        
        // Learn from the re-classification (teach CodeMind)
        if let emailService = emailScanningService {
            await emailService.learnFromReclassification(
                notification: notifications[index],
                oldType: oldType,
                newType: .custom,
                emailSubject: notifications[index].emailSubject,
                emailBody: notifications[index].emailBody,
                emailFrom: notifications[index].sourceEmail
            )
        }
        
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Skip a notification (removes from active list without classification)
    func skip(_ notification: Notification, emailScanningService: EmailScanningService? = nil) async {
        await reclassify(notification, to: .skipped, autoArchive: true, emailScanningService: emailScanningService)
    }
    
    /// Mark a notification as junk (ads, promos, spam)
    func markAsJunk(_ notification: Notification, emailScanningService: EmailScanningService? = nil) async {
        await reclassify(notification, to: .junk, autoArchive: true, emailScanningService: emailScanningService)
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
    
    /// Get active notifications (not archived)
    var activeNotifications: [Notification] {
        notifications.filter { $0.status != .dismissed || $0.archivedAt == nil }
    }
    
    /// Clear all dismissed notifications
    func clearDismissed() {
        notifications.removeAll { $0.status == .dismissed }
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Clear all notifications
    func clearAll() {
        notifications.removeAll()
        updateUnreadCount()
        saveNotifications()
    }
    
    /// Remove duplicate notifications (keeps the most recent one for each emailId)
    func removeDuplicates() {
        var seenEmailIds: Set<String> = []
        var uniqueNotifications: [Notification] = []
        
        // Process notifications in reverse order (oldest first) so we keep the newest
        for notification in notifications.reversed() {
            if let emailId = notification.emailId {
                if !seenEmailIds.contains(emailId) {
                    seenEmailIds.insert(emailId)
                    uniqueNotifications.append(notification)
                }
                // Skip duplicate
            } else {
                // No emailId, keep it (can't be a duplicate)
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
    
    /// Update unread count
    private func updateUnreadCount() {
        unreadCount = notifications.filter { $0.status == .pending }.count
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

