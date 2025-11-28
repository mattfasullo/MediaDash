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
    func checkForGrabbedReplies() async {
        print("GrabbedIndicatorService: Starting check for grabbed replies...")
        
        guard let gmailService = gmailService,
              let notificationCenter = notificationCenter,
              let settingsManager = settingsManager else {
            print("GrabbedIndicatorService: Missing dependencies")
            return
        }
        
        let settings = settingsManager.currentSettings
        
        // Only process if Gmail is enabled and authenticated
        guard settings.gmailEnabled && gmailService.isAuthenticated else {
            print("GrabbedIndicatorService: Gmail not enabled or not authenticated")
            return
        }
        
        // Get media team emails
        let mediaTeamEmails = settings.mediaTeamEmails.map { $0.lowercased() }
        print("GrabbedIndicatorService: Media team emails: \(mediaTeamEmails)")
        guard !mediaTeamEmails.isEmpty else {
            print("GrabbedIndicatorService: No media team configured")
            return // No media team configured
        }
        
        // Get company media email
        let companyMediaEmail = settings.companyMediaEmail.lowercased()
        print("GrabbedIndicatorService: Company media email: \(companyMediaEmail)")
        
        // Create qualifier with all settings
        let qualifier = MediaThreadQualifier(
            subjectPatterns: settings.grabbedSubjectPatterns,
            subjectExclusions: settings.grabbedSubjectExclusions,
            attachmentTypes: settings.grabbedAttachmentTypes,
            fileHostingWhitelist: settings.grabbedFileHostingWhitelist,
            senderWhitelist: settings.grabbedSenderWhitelist,
            bodyExclusions: settings.grabbedBodyExclusions
        )
        
        // Get all media file notifications that haven't been grabbed yet
        let mediaNotifications = notificationCenter.notifications.filter { notification in
            notification.type == .mediaFiles && !notification.isGrabbed && notification.threadId != nil
        }
        
        print("GrabbedIndicatorService: Found \(mediaNotifications.count) ungrabbed media file notifications to check")
        
        // Check each notification's thread for new replies
        for notification in mediaNotifications {
            print("GrabbedIndicatorService: Checking notification \(notification.id) (thread: \(notification.threadId ?? "nil"))")
            guard let threadId = notification.threadId else { continue }
            
            do {
                // Fetch thread messages
                let thread = try await gmailService.getThread(threadId: threadId)
                
                // Check each message in the thread
                let messages = thread.messages ?? []
                print("GrabbedIndicatorService: Thread has \(messages.count) message(s)")
                
                for message in messages {
                    print("GrabbedIndicatorService: Checking message \(message.id)")
                    
                    // Skip if this is the original message (we only care about replies)
                    if message.id == notification.emailId {
                        print("GrabbedIndicatorService: Skipping original message")
                        continue
                    }
                    
                    // Check if sender is a media team member
                    guard let fromEmail = message.from else {
                        print("GrabbedIndicatorService: No from email")
                        continue
                    }
                    let fromEmailLower = fromEmail.lowercased()
                    print("GrabbedIndicatorService: From email: \(fromEmailLower)")
                    
                    // Extract email from "Name <email@example.com>" format
                    let senderEmail = extractEmailAddress(from: fromEmailLower)
                    print("GrabbedIndicatorService: Extracted sender email: \(senderEmail)")
                    
                    guard mediaTeamEmails.contains(senderEmail.lowercased()) else {
                        print("GrabbedIndicatorService: Sender \(senderEmail) is not in media team list")
                        continue
                    }
                    print("GrabbedIndicatorService: ✅ Sender is a media team member")
                    
                    // Check if message is a reply (has "Re:" in subject or is part of a thread)
                    let isReply = isReplyMessage(message)
                    print("GrabbedIndicatorService: Is reply: \(isReply)")
                    
                    guard isReply else {
                        print("GrabbedIndicatorService: Not a reply, skipping")
                        continue
                    }
                    
                    // Check if message is addressed to company media email OR if the original notification
                    // was for an email sent to company media email (thread-based check)
                    let recipients = message.allRecipients.map { $0.lowercased() }
                    let isAddressedToMedia = recipients.contains(companyMediaEmail)
                    
                    // Also check if the original notification was for a media email
                    // (this handles cases where replies go to the original sender, not media@)
                    let originalWasMediaEmail = notification.sourceEmail?.lowercased().contains(companyMediaEmail) == true ||
                        notification.emailSubject?.lowercased().contains("media") == true ||
                        notification.type == .mediaFiles
                    
                    print("GrabbedIndicatorService: Recipients: \(recipients)")
                    print("GrabbedIndicatorService: Is addressed to media email: \(isAddressedToMedia)")
                    print("GrabbedIndicatorService: Original was media email: \(originalWasMediaEmail)")
                    
                    guard isAddressedToMedia || originalWasMediaEmail else {
                        print("GrabbedIndicatorService: Not addressed to \(companyMediaEmail) and original was not a media email")
                        continue
                    }
                    print("GrabbedIndicatorService: ✅ Reply qualifies (addressed to media OR original was media email)")
                    
                    // Check if thread qualifies as media-file-delivery
                    // Use the original notification's subject (thread subject stays consistent)
                    // or fall back to current message subject
                    let threadSubject = notification.emailSubject ?? message.subject ?? ""
                    
                    // Check body of current message AND original notification
                    let currentBody = message.plainTextBody ?? message.htmlBody ?? ""
                    let originalBody = notification.emailBody ?? ""
                    let combinedBody = currentBody + " " + originalBody
                    
                    // Check attachments (if any) from current message
                    let attachments = extractAttachments(from: message)
                    
                    // Check if thread qualifies - use thread subject and check for file hosting links in any message
                    print("GrabbedIndicatorService: Checking if thread qualifies...")
                    print("  Thread subject: \(threadSubject)")
                    print("  Combined body preview: \(combinedBody.prefix(200))")
                    
                    // Use debug methods to get detailed qualification information
                    let patternResult = qualifier.qualifiesAsMediaFileDeliveryWithDebug(
                        subject: threadSubject,
                        body: combinedBody,
                        attachments: attachments,
                        labelIds: message.labelIds,
                        senderEmail: notification.sourceEmail
                    )
                    let linkResult = qualifier.qualifiesByFileHostingLinksWithDebug(combinedBody)
                    let qualifies = patternResult.qualifies || linkResult.qualifies
                    
                    // Log detailed debug information
                    let separator = String(repeating: "=", count: 80)
                    print("\n\(separator)")
                    print("🔍 GRABBED INDICATOR QUALIFICATION DEBUG - Notification ID: \(notification.id)")
                    print(separator)
                    print("\n📋 Pattern-based qualification:")
                    for reason in patternResult.reasons {
                        print(reason)
                    }
                    if patternResult.qualifies {
                        print("  ✅ QUALIFIED by patterns")
                        print("  Matched criteria: \(patternResult.matchedCriteria.joined(separator: ", "))")
                    } else {
                        print("  ❌ NOT QUALIFIED by patterns")
                        if !patternResult.exclusionReasons.isEmpty {
                            print("  Exclusion reasons: \(patternResult.exclusionReasons.joined(separator: ", "))")
                        }
                    }
                    
                    print("\n🔗 Link-based qualification:")
                    for reason in linkResult.reasons {
                        print(reason)
                    }
                    if linkResult.qualifies {
                        print("  ✅ QUALIFIED by links")
                        print("  Matched criteria: \(linkResult.matchedCriteria.joined(separator: ", "))")
                    } else {
                        print("  ❌ NOT QUALIFIED by links")
                        if !linkResult.exclusionReasons.isEmpty {
                            print("  Exclusion reasons: \(linkResult.exclusionReasons.joined(separator: ", "))")
                        }
                    }
                    
                    print("\n📊 OVERALL RESULT: \(qualifies ? "✅ QUALIFIED" : "❌ NOT QUALIFIED")")
                    print(separator + "\n")
                    
                    guard qualifies else {
                        print("GrabbedIndicatorService: Thread does not qualify as media-file-delivery")
                        continue
                    }
                    print("GrabbedIndicatorService: ✅ Thread qualifies as media-file-delivery")
                    
                    // Check if reply indicates they couldn't grab the file (priority assist)
                    let isPriorityAssist = checkForPriorityAssist(body: combinedBody, subject: threadSubject)
                    
                    // Mark notification as grabbed
                    await MainActor.run {
                        if let index = notificationCenter.notifications.firstIndex(where: { $0.id == notification.id }) {
                            notificationCenter.notifications[index].isGrabbed = true
                            notificationCenter.notifications[index].grabbedBy = senderEmail
                            notificationCenter.notifications[index].grabbedAt = Date()
                            notificationCenter.notifications[index].isPriorityAssist = isPriorityAssist
                            
                            print("GrabbedIndicatorService: Marked thread \(threadId) as Grabbed by \(senderEmail) (Priority Assist: \(isPriorityAssist))")
                        }
                    }
                }
            } catch {
                print("GrabbedIndicatorService: Error checking thread \(threadId): \(error.localizedDescription)")
            }
        }
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

