import Foundation
import SwiftUI

/// Types of notifications
/// Marked as @frozen for performance optimization - enum cases are stable
@frozen public enum NotificationType: String, Codable, CaseIterable {
    case newDocket = "new_docket"
    case mediaFiles = "media_files" // Internal name kept for compatibility, displayed as "File Deliveries"
    case request = "request" // Requests for the media team
    case error = "error"
    case info = "info"
    case junk = "junk" // Ads, promos, spam - removes notification
    case skipped = "skipped" // User chose to skip/ignore this notification
    
    /// Display name for the notification type
    var displayName: String {
        switch self {
        case .newDocket: return "New Docket"
        case .mediaFiles: return "File Delivery"
        case .request: return "Request"
        case .error: return "Error"
        case .info: return "Info"
        case .junk: return "Junk"
        case .skipped: return "Skipped"
        }
    }
    
    /// Icon for the notification type
    var icon: String {
        switch self {
        case .newDocket: return "doc.badge.plus"
        case .mediaFiles: return "arrow.down.doc"
        case .request: return "hand.raised"
        case .error: return "exclamationmark.triangle"
        case .info: return "info.circle"
        case .junk: return "trash"
        case .skipped: return "forward"
        }
    }
    
    /// Color for the notification type
    var color: Color {
        switch self {
        case .newDocket: return .blue
        case .mediaFiles: return .green
        case .request: return .orange
        case .error: return .red
        case .info: return .orange
        case .junk: return .gray
        case .skipped: return .secondary
        }
    }
    
    /// Types available for marking as junk or skipped (removes notification)
    static var reclassifiableTypes: [NotificationType] {
        [.junk, .skipped]
        // Note: Only junk and skipped are supported - these remove the notification
    }
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
    var type: NotificationType // Mutable to allow marking as junk/skipped
    var title: String
    var message: String
    let timestamp: Date
    var status: NotificationStatus
    var archivedAt: Date? // When the notification was archived
    var completedAt: Date? // When the notification was marked as complete (for request notifications)
    var threadId: String? // Gmail thread ID for tracking replies
    var isGrabbed: Bool = false // Whether a media team member has "grabbed" this thread
    var isPriorityAssist: Bool = false // Whether this needs priority assistance (couldn't grab file)
    var grabbedBy: String? // Email of media team member who grabbed it
    var grabbedAt: Date? // When it was grabbed
    
    // New docket specific data
    var docketNumber: String?
    var jobName: String?
    var emailId: String?
    var sourceEmail: String?
    var projectManager: String? // Project manager for Simian (defaults to sourceEmail, editable per notification)
    var emailSubject: String? // Original email subject for preview
    var emailBody: String? // Original email body for preview
    var fileLinks: [String]? // File hosting links extracted from email (for File Delivery notifications)
    var fileLinkDescriptions: [String]? // Descriptions of what each link contains (parallel array to fileLinks)

    // Original values (for reset functionality)
    var originalDocketNumber: String?
    var originalJobName: String?
    var originalProjectManager: String?
    var originalMessage: String?
    
    // Action flags (mutable for toggling)
    var shouldCreateWorkPicture: Bool = true // Default to true
    var shouldCreateSimianJob: Bool = false
    
    // Duplicate detection flags (computed/checked, not stored)
    var isInWorkPicture: Bool = false // Whether docket folder exists in work picture
    var isInSimian: Bool = false // Whether job already exists in Simian
    
    
    init(
        id: UUID = UUID(),
        type: NotificationType,
        title: String,
        message: String,
        timestamp: Date = Date(),
        status: NotificationStatus = .pending,
        archivedAt: Date? = nil,
        completedAt: Date? = nil,
        docketNumber: String? = nil,
        jobName: String? = nil,
        emailId: String? = nil,
        sourceEmail: String? = nil,
        projectManager: String? = nil,
        emailSubject: String? = nil,
        emailBody: String? = nil,
        fileLinks: [String]? = nil,
        fileLinkDescriptions: [String]? = nil,
        threadId: String? = nil,
        isGrabbed: Bool = false,
        isPriorityAssist: Bool = false,
        grabbedBy: String? = nil,
        grabbedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.message = message
        self.timestamp = timestamp
        self.status = status
        self.archivedAt = archivedAt
        self.completedAt = completedAt
        self.docketNumber = docketNumber
        self.jobName = jobName
        self.emailId = emailId
        self.sourceEmail = sourceEmail
        // Default projectManager to sourceEmail if not provided
        self.projectManager = projectManager ?? sourceEmail
        self.emailSubject = emailSubject
        self.emailBody = emailBody
        self.fileLinks = fileLinks
        self.fileLinkDescriptions = fileLinkDescriptions
        self.threadId = threadId
        self.isGrabbed = isGrabbed
        self.isPriorityAssist = isPriorityAssist
        self.grabbedBy = grabbedBy
        self.grabbedAt = grabbedAt
        // Store original values for reset
        self.originalDocketNumber = docketNumber
        self.originalJobName = jobName
        self.originalProjectManager = projectManager ?? sourceEmail
        self.originalMessage = message
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


