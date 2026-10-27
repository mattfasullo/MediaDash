import Foundation
import UserNotifications

/// Service for showing system notifications
@MainActor
class NotificationService {
    static let shared = NotificationService()
    
    private init() {
        requestAuthorization()
    }
    
    /// Request notification authorization
    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("NotificationService: Failed to request authorization: \(error.localizedDescription)")
            } else if granted {
                print("NotificationService: Notification authorization granted")
            } else {
                print("NotificationService: Notification authorization denied")
            }
        }
    }
    
    /// One OS banner for a scan batch instead of one alert per docket.
    func showNewDocketsBatch(count: Int) {
        guard count > 0 else { return }
        if count == 1 {
            showNewDocketNotification(docketNumber: nil, jobName: "1 new docket")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "New Dockets Detected"
        content.body = "\(count) new dockets"
        content.sound = .default
        content.categoryIdentifier = "NEW_DOCKET"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("NotificationService: Failed to show batch notification: \(error.localizedDescription)")
            }
        }
    }

    /// Show a notification for a new docket
    func showNewDocketNotification(docketNumber: String?, jobName: String) {
        let content = UNMutableNotificationContent()
        
        if let docketNumber = docketNumber, docketNumber != "TBD" {
            content.title = "New Docket Detected"
            content.body = "Docket \(docketNumber): \(jobName)"
        } else {
            content.title = "New Docket Email"
            content.body = "\(jobName) (Docket number pending)"
        }
        
        content.sound = .default
        content.categoryIdentifier = "NEW_DOCKET"
        
        // Create request with immediate trigger
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // nil trigger means show immediately
        )
        
        // Schedule notification
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("NotificationService: Failed to show notification: \(error.localizedDescription)")
            }
        }
    }

    func showBanner(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("NotificationService: Failed to show banner: \(error.localizedDescription)")
            }
        }
    }

    /// Softer OS alert for parser hits without the Gmail "New Docket" label (review queue).
    func showDocketReviewCandidateNotification(docketNumber: String?, jobName: String) {
        let content = UNMutableNotificationContent()
        if let docketNumber = docketNumber, docketNumber != "TBD" {
            content.title = "Docket candidate (needs review)"
            content.body = "Docket \(docketNumber): \(jobName) — confirm in MediaDash"
        } else {
            content.title = "Docket candidate (needs review)"
            content.body = "\(jobName)"
        }
        content.sound = nil
        content.categoryIdentifier = "NEW_DOCKET_REVIEW"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("NotificationService: Failed to show review candidate notification: \(error.localizedDescription)")
            }
        }
    }
}

