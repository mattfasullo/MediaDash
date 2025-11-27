import Foundation
import Combine
import SwiftUI

/// Central notification manager
@MainActor
class NotificationCenter: ObservableObject {
    @Published var notifications: [Notification] = []
    @Published var unreadCount: Int = 0
    @Published var isExpanded: Bool = false
    
    private let notificationsKey = "mediadash_notifications"
    
    init() {
        loadNotifications()
        removeDuplicates() // Clean up any existing duplicates
        cleanupOldArchivedNotifications()
        updateUnreadCount()
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

