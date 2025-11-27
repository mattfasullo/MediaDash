import Foundation
import SwiftUI

/// Types of notifications
enum NotificationType: String, Codable {
    case newDocket = "new_docket"
    case error = "error"
    case info = "info"
}

/// Status of a notification
enum NotificationStatus: String, Codable {
    case pending = "pending"
    case approved = "approved"
    case dismissed = "dismissed"
    case completed = "completed"
}

/// Notification model
struct Notification: Identifiable, Codable, Equatable {
    let id: UUID
    let type: NotificationType
    let title: String
    var message: String
    let timestamp: Date
    var status: NotificationStatus
    var archivedAt: Date? // When the notification was archived
    
    // New docket specific data
    var docketNumber: String?
    var jobName: String?
    var emailId: String?
    var sourceEmail: String?
    var projectManager: String? // Project manager for Simian (defaults to sourceEmail, editable per notification)
    
    // Action flags (mutable for toggling)
    var shouldCreateWorkPicture: Bool = true // Default to true
    var shouldCreateSimianJob: Bool = false
    
    init(
        id: UUID = UUID(),
        type: NotificationType,
        title: String,
        message: String,
        timestamp: Date = Date(),
        status: NotificationStatus = .pending,
        archivedAt: Date? = nil,
        docketNumber: String? = nil,
        jobName: String? = nil,
        emailId: String? = nil,
        sourceEmail: String? = nil,
        projectManager: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.timestamp = timestamp
        self.status = status
        self.archivedAt = archivedAt
        self.docketNumber = docketNumber
        self.jobName = jobName
        self.emailId = emailId
        self.sourceEmail = sourceEmail
        // Default projectManager to sourceEmail if not provided
        self.projectManager = projectManager ?? sourceEmail
    }
    
    // Equatable conformance
    static func == (lhs: Notification, rhs: Notification) -> Bool {
        lhs.id == rhs.id
    }
}

/// Parsed docket notification data
struct ParsedDocketNotification {
    let docketNumber: String
    let jobName: String
    let emailId: String
    let sourceEmail: String
    let subject: String?
    let body: String?
}

