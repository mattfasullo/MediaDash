import Foundation
import Combine
import SwiftUI

/// Service for scanning emails and creating notifications for new dockets
@MainActor
class EmailScanningService: ObservableObject {
    @Published var isScanning = false
    @Published var isEnabled = false
    @Published var lastScanTime: Date?
    @Published var totalDocketsCreated = 0
    @Published var lastError: String?
    
    var gmailService: GmailService
    private var parser: EmailDocketParser
    private var scanningTask: Task<Void, Never>?
    private var processedEmailIds: Set<String> = []
    private let processedEmailsKey = "gmail_processed_email_ids"
    
    weak var mediaManager: MediaManager?
    weak var settingsManager: SettingsManager?
    weak var notificationCenter: NotificationCenter?
    
    init(gmailService: GmailService, parser: EmailDocketParser) {
        self.gmailService = gmailService
        self.parser = parser
        loadProcessedEmailIds()
    }
    
    /// Start automatic email scanning
    func startScanning() {
        guard !isScanning else { return }
        guard let settings = settingsManager?.currentSettings, settings.gmailEnabled else {
            lastError = "Gmail integration is not enabled in settings"
            return
        }
        
        guard gmailService.isAuthenticated else {
            lastError = "Gmail is not authenticated"
            return
        }
        
        isScanning = true
        isEnabled = true
        lastError = nil
        
        // Perform initial scan
        Task {
            await scanNow()
        }
        
        // Start periodic scanning
        startPeriodicScanning()
    }
    
    /// Stop automatic email scanning
    func stopScanning() {
        isScanning = false
        isEnabled = false
        scanningTask?.cancel()
        scanningTask = nil
    }
    
    /// Build Gmail query from search terms (case-insensitive, supports labels and subject)
    private func buildGmailQuery(from searchTerms: [String]) -> String {
        guard !searchTerms.isEmpty else {
            // Fallback to old gmailQuery if no search terms configured
            return "label:\"New Docket\""
        }
        
        // Build OR query for each term, trying both label and subject
        // Gmail queries are case-insensitive by default, but we'll be explicit
        let queryParts = searchTerms.flatMap { term in
            [
                "label:\"\(term)\"",
                "subject:\"\(term)\""
            ]
        }
        
        return "(\(queryParts.joined(separator: " OR ")))"
    }
    
    /// Perform a manual scan now
    func scanNow(forceRescan: Bool = false) async {
        guard let settings = settingsManager?.currentSettings, settings.gmailEnabled else {
            await MainActor.run {
                lastError = "Gmail integration is not enabled"
            }
            return
        }
        
        guard gmailService.isAuthenticated else {
            await MainActor.run {
                lastError = "Gmail is not authenticated"
            }
            return
        }
        
        await MainActor.run {
            isScanning = true
            lastError = nil
        }
        
        do {
            // Build query from search terms (or fallback to old gmailQuery)
            let baseQuery: String
            if !settings.gmailSearchTerms.isEmpty {
                baseQuery = buildGmailQuery(from: settings.gmailSearchTerms)
            } else if !settings.gmailQuery.isEmpty {
                baseQuery = settings.gmailQuery
            } else {
                baseQuery = "label:\"New Docket\""
            }
            
            // Only fetch unread emails
            let query = "\(baseQuery) is:unread"
            print("EmailScanningService: Scanning with query: \(query)")
            
            // Fetch emails matching query
            let messageRefs = try await gmailService.fetchEmails(
                query: query,
                maxResults: 50
            )
            
            // Get full email messages
            let messages = try await gmailService.getEmails(messageReferences: messageRefs)
            
            // Filter to only unread emails (double-check labelIds)
            let unreadMessages = messages.filter { message in
                guard let labelIds = message.labelIds else { return false }
                return labelIds.contains("UNREAD")
            }
            
            print("EmailScanningService: Found \(unreadMessages.count) unread emails (out of \(messages.count) total)")
            
            // Filter out already processed emails (unless force rescan)
            let newMessages = unreadMessages.filter { 
                forceRescan || !processedEmailIds.contains($0.id) 
            }
            
            // Parse and create notifications (don't auto-create dockets)
            var notificationCount = 0
            for message in newMessages {
                if await processEmailAndCreateNotification(message) {
                    notificationCount += 1
                    // Mark email as processed (so we don't create duplicate notifications)
                    _ = await MainActor.run {
                        processedEmailIds.insert(message.id)
                    }
                }
            }
            
            // Save processed email IDs
            saveProcessedEmailIds()
            
            await MainActor.run {
                lastScanTime = Date()
                isScanning = false
            }
            
        } catch {
            await MainActor.run {
                lastError = error.localizedDescription
                isScanning = false
            }
        }
    }
    
    /// Process a single email and create notification (don't auto-create docket)
    func processEmailAndCreateNotification(_ message: GmailMessage) async -> Bool {
        // Safety check: Only process unread emails
        guard let labelIds = message.labelIds, labelIds.contains("UNREAD") else {
            print("EmailScanningService: Skipping email \(message.id) - already marked as read")
            return false
        }
        
        // Use parser with custom patterns if configured
        guard let settingsManager = settingsManager else { return false }
        let currentSettings = settingsManager.currentSettings
        let patterns = currentSettings.docketParsingPatterns
        let parser = patterns.isEmpty ? self.parser : EmailDocketParser(patterns: patterns)
        
        let subject = message.subject ?? ""
        let body = message.plainTextBody ?? message.htmlBody ?? ""
        
        print("EmailScanningService: Parsing email:")
        print("  Subject: \(subject)")
        print("  Body preview: \(body.prefix(200))")
        
        let parsed = parser.parseEmail(
            subject: message.subject,
            body: message.plainTextBody ?? message.htmlBody,
            from: message.from
        )
        
        guard let parsedDocket = parsed else {
            print("EmailScanningService: Failed to parse email - no docket information found")
            return false
        }
        
        print("EmailScanningService: Parsed docket: \(parsedDocket.docketNumber) - \(parsedDocket.jobName)")
        
        // Check if docket already exists (only if we have a valid docket number, not "TBD")
        if parsedDocket.docketNumber != "TBD",
           let manager = mediaManager,
           manager.dockets.contains("\(parsedDocket.docketNumber)_\(parsedDocket.jobName)") {
            // Docket already exists - mark as processed but don't create notification
            print("EmailScanningService: Docket already exists: \(parsedDocket.docketNumber)_\(parsedDocket.jobName)")
            return false
        }
        
        // Create notification instead of auto-creating docket
        await MainActor.run {
            guard let notificationCenter = notificationCenter else {
                print("EmailScanningService: ERROR - notificationCenter is nil when trying to add notification")
                return
            }
            
            // Format message based on whether we have a docket number
            let messageText: String
            let docketNumber: String?
            
            if parsedDocket.docketNumber == "TBD" {
                // No docket number found - use nil and create a different message
                messageText = "New Docket Email: \(parsedDocket.jobName) (Docket number pending)"
                docketNumber = nil
            } else {
                messageText = "Docket \(parsedDocket.docketNumber): \(parsedDocket.jobName)"
                docketNumber = parsedDocket.docketNumber
            }
            
            let notification = Notification(
                type: .newDocket,
                title: "New Docket Detected",
                message: messageText,
                docketNumber: docketNumber,
                jobName: parsedDocket.jobName,
                emailId: message.id,
                sourceEmail: parsedDocket.sourceEmail
            )
            
            print("EmailScanningService: Adding notification for docket \(docketNumber ?? "TBD"): \(parsedDocket.jobName)")
            notificationCenter.add(notification)
            print("EmailScanningService: Notification added. Total notifications: \(notificationCenter.notifications.count)")
            
            // Show system notification
            NotificationService.shared.showNewDocketNotification(
                docketNumber: docketNumber,
                jobName: parsedDocket.jobName
            )
        }
        
        return true
    }
    
    /// Create docket from notification (called when user approves)
    func createDocketFromNotification(_ notification: Notification) async throws {
        guard let docketNumber = notification.docketNumber,
              let jobName = notification.jobName,
              let manager = mediaManager,
              let settingsManager = settingsManager else {
            throw DocketCreationError.invalidInput("Missing docket information")
        }
        
        let config = AppConfig(settings: settingsManager.currentSettings)
        let useCase = AutoDocketCreationUseCase(config: config)
        let existingDockets = manager.dockets
        
        let result = try await useCase.createDocket(
            docketNumber: docketNumber,
            jobName: jobName,
            existingDockets: existingDockets
        )
        
        if result.success {
            // Refresh dockets
            await MainActor.run {
                manager.refreshDockets()
            }
            
            // Mark email as read if we have email ID
            if let emailId = notification.emailId {
                try? await gmailService.markAsRead(messageId: emailId)
            }
            
            // Update notification status
            await MainActor.run {
                notificationCenter?.updateStatus(notification, to: .completed)
            }
        }
    }
    
    /// Start periodic scanning based on poll interval
    private func startPeriodicScanning() {
        guard let settings = settingsManager?.currentSettings else { return }
        let interval = settings.gmailPollInterval
        
        scanningTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                
                guard let self = self, self.isEnabled else { break }
                
                await self.scanNow()
            }
        }
    }
    
    /// Load processed email IDs from UserDefaults
    private func loadProcessedEmailIds() {
        if let data = UserDefaults.standard.data(forKey: processedEmailsKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            processedEmailIds = ids
        }
    }
    
    /// Save processed email IDs to UserDefaults
    private func saveProcessedEmailIds() {
        if let data = try? JSONEncoder().encode(processedEmailIds) {
            UserDefaults.standard.set(data, forKey: processedEmailsKey)
        }
    }
    
    /// Mark email as processed (used for tracking)
    func markEmailAsProcessed(messageId: String) {
        processedEmailIds.insert(messageId)
        saveProcessedEmailIds()
    }
    
    /// Clear processed email IDs (useful for re-processing)
    func clearProcessedEmails() {
        processedEmailIds.removeAll()
        saveProcessedEmailIds()
    }
    
    /// Scan for unread docket emails and create notifications (used when opening notification window)
    /// - Parameter forceRescan: If true, will rescan emails even if they already have notifications (useful after clearing all)
    func scanUnreadEmails(forceRescan: Bool = false) async {
        guard let settingsManager = settingsManager else {
            print("EmailScanningService: ERROR - settingsManager is nil")
            return
        }
        
        let settings = settingsManager.currentSettings
        
        guard settings.gmailEnabled else {
            print("EmailScanningService: Gmail not enabled")
            return
        }
        
        guard gmailService.isAuthenticated else {
            print("EmailScanningService: Gmail not authenticated")
            return
        }
        
        guard let notificationCenter = notificationCenter else {
            print("EmailScanningService: ERROR - notificationCenter is nil")
            return
        }
        
        do {
            // Build query from search terms (or fallback to old gmailQuery)
            let baseQuery: String
            if !settings.gmailSearchTerms.isEmpty {
                baseQuery = buildGmailQuery(from: settings.gmailSearchTerms)
            } else if !settings.gmailQuery.isEmpty {
                baseQuery = settings.gmailQuery
            } else {
                baseQuery = "label:\"New Docket\""
            }
            
            // Only fetch unread emails
            let query = "\(baseQuery) is:unread"
            print("EmailScanningService: Scanning unread emails with query: \(query)")
            
            // Fetch unread emails matching query
            let messageRefs = try await gmailService.fetchEmails(
                query: query,
                maxResults: 50
            )
            
            print("EmailScanningService: Found \(messageRefs.count) unread email references")
            
            guard !messageRefs.isEmpty else {
                print("EmailScanningService: No unread emails found")
                return
            }
            
            // Get full email messages
            let messages = try await gmailService.getEmails(messageReferences: messageRefs)
            print("EmailScanningService: Fetched \(messages.count) full email messages")
            
            // Filter to only unread emails (check labelIds)
            let unreadMessages = messages.filter { message in
                guard let labelIds = message.labelIds else { return false }
                return labelIds.contains("UNREAD")
            }
            print("EmailScanningService: \(unreadMessages.count) emails are actually unread (out of \(messages.count) total)")
            
            // Get existing notification email IDs to avoid duplicates (unless force rescan)
            let existingEmailIds = await MainActor.run {
                return forceRescan ? Set<String>() : Set(notificationCenter.notifications.compactMap { $0.emailId })
            }
            print("EmailScanningService: \(existingEmailIds.count) emails already have notifications (forceRescan: \(forceRescan))")
            
            // Process unread emails and create notifications if they don't already exist
            var createdCount = 0
            var skippedCount = 0
            var failedCount = 0
            for message in unreadMessages {
                // Skip if notification already exists for this email (unless force rescan)
                if !forceRescan && existingEmailIds.contains(message.id) {
                    skippedCount += 1
                    continue
                }
                
                // If force rescan, remove existing notification first
                if forceRescan && existingEmailIds.contains(message.id) {
                    await MainActor.run {
                        if let existingNotification = notificationCenter.notifications.first(where: { $0.emailId == message.id }) {
                            notificationCenter.remove(existingNotification)
                        }
                    }
                }
                
                // Process and create notification
                if await processEmailAndCreateNotification(message) {
                    createdCount += 1
                    print("EmailScanningService: Created notification for email \(message.id)")
                    // Don't mark as processed - we want to keep showing it until it's read/approved
                } else {
                    failedCount += 1
                    print("EmailScanningService: Failed to create notification for email \(message.id) - likely not a valid docket email")
                }
            }
            
            print("EmailScanningService: Summary - Created: \(createdCount), Skipped: \(skippedCount), Failed: \(failedCount)")
            
        } catch {
            print("EmailScanningService: Error scanning unread emails: \(error.localizedDescription)")
            await MainActor.run {
                lastError = error.localizedDescription
            }
        }
    }
}

