import Foundation
import Combine

/// Service to monitor email replies and mark threads as "Grabbed" when media team members reply
@MainActor
class GrabbedIndicatorService: ObservableObject {
    weak var gmailService: GmailService?
    weak var notificationCenter: NotificationCenter?
    weak var settingsManager: SettingsManager?
    
    private var monitoringTask: Task<Void, Never>?
    
    init(gmailService: GmailService? = nil, notificationCenter: NotificationCenter? = nil, settingsManager: SettingsManager? = nil) {
        self.gmailService = gmailService
        self.notificationCenter = notificationCenter
        self.settingsManager = settingsManager
    }

    
    /// Start monitoring for replies from media team members
    func startMonitoring() {
        guard monitoringTask == nil else { return }
        
        monitoringTask = Task {
            while !Task.isCancelled {
                await checkForGrabbedReplies()
                // Check every 60 seconds
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }
    
    /// Stop monitoring
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }
    
    /// Check for replies from media team members that should mark threads as "Grabbed"
    /// Disabled: Gmail API is only used for new docket search; this feature would call getThread per notification.
    func checkForGrabbedReplies() async {
        // Gmail API is only used for new docket search; grabbed reply checking disabled to avoid extra getThread calls.
    }
    
    /// Extract email address from "Name <email@example.com>" format
    private func extractEmailAddress(from text: String) -> String {
        // Check for angle bracket format
        if let regex = try? NSRegularExpression(pattern: #"<([^>]+)>"#, options: []),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           match.numberOfRanges >= 2,
           let emailRange = Range(match.range(at: 1), in: text) {
            return String(text[emailRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // If no angle brackets, check if it's already an email
        if text.contains("@") {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return text
    }
    
    /// Check if message is a reply
    private func isReplyMessage(_ message: GmailMessage) -> Bool {
        // Check subject for "Re:" prefix
        if let subject = message.subject {
            let subjectLower = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if subjectLower.hasPrefix("re:") {
                return true
            }
        }
        
        // If it's not the first message in a thread, it's likely a reply
        // (We'll assume this based on thread structure)
        return true // Conservative: treat as reply if in thread
    }
    
    /// Extract attachment URLs from message
    private func extractAttachments(from message: GmailMessage) -> [String] {
        // This is a simplified version - in a real implementation, you'd parse the message payload
        // to find attachment URLs. For now, we'll check the body for file links.
        var attachments: [String] = []
        
        let body = message.plainTextBody ?? message.htmlBody ?? ""
        
        // Extract URLs that might be file links
        let urlPattern = #"https?://[^\s<>"']+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
            for match in matches {
                if let urlRange = Range(match.range, in: body) {
                    attachments.append(String(body[urlRange]))
                }
            }
        }
        
        return attachments
    }
    
    /// Check if reply indicates priority assist (couldn't grab file)
    private func checkForPriorityAssist(body: String, subject: String) -> Bool {
        let text = (body + " " + subject).lowercased()
        
        // Keywords that indicate they couldn't grab the file
        let priorityKeywords = [
            "can't access",
            "cannot access",
            "can't download",
            "cannot download",
            "can't grab",
            "cannot grab",
            "link doesn't work",
            "link broken",
            "file not found",
            "access denied",
            "permission denied",
            "error downloading",
            "failed to download",
            "trouble accessing",
            "having trouble",
            "need help",
            "help needed",
            "assistance needed"
        ]
        
        return priorityKeywords.contains { keyword in
            text.contains(keyword)
        }
    }
}

