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
}

