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
    weak var metadataManager: DocketMetadataManager?
    weak var asanaCacheManager: AsanaCacheManager?
    
    private var companyNameCache: CompanyNameCache {
        CompanyNameCache.shared
    }
    
    init(gmailService: GmailService, parser: EmailDocketParser) {
        self.gmailService = gmailService
        self.parser = parser
        loadProcessedEmailIds()
    }
    
    /// Populate company name cache from various sources
    func populateCompanyNameCache() {
        Task { @MainActor in
            // Configure shared cache URL
            if let settings = settingsManager?.currentSettings,
               let sharedCacheURL = settings.sharedCacheURL,
               !sharedCacheURL.isEmpty {
                companyNameCache.configure(sharedCacheURL: sharedCacheURL)
            }
            
            // Get job names from file system (MediaManager.dockets)
            if let manager = mediaManager {
                let docketNames = manager.dockets
                var fileSystemJobNames: [String] = []
                for docketName in docketNames {
                    // Extract job name from "docketNumber_jobName" format
                    if let underscoreIndex = docketName.firstIndex(of: "_") {
                        let jobName = String(docketName[docketName.index(after: underscoreIndex)...])
                        if !jobName.isEmpty {
                            fileSystemJobNames.append(jobName)
                        }
                    }
                }
                companyNameCache.addCompanyNames(fileSystemJobNames, source: "filesystem")
            }
            
            // Get job names from Asana cache (if available)
            if let asanaCache = asanaCacheManager {
                let asanaDockets = asanaCache.loadCachedDockets()
                let asanaJobNames = asanaDockets.map { $0.jobName }.filter { !$0.isEmpty }
                companyNameCache.addCompanyNames(Array(asanaJobNames), source: "asana")
            }
            
            // Sync with shared cache
            companyNameCache.syncWithSharedCache()
        }
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
            // No search terms - search for "new docket" variations in all emails
            return "\"new docket\" OR \"new docket -\" OR \"docket -\""
        }
        
        // Build OR query for each term, trying label, subject, AND body
        // Gmail queries are case-insensitive by default, but we'll be explicit
        let queryParts = searchTerms.flatMap { term in
            [
                "label:\"\(term)\"",
                "subject:\"\(term)\"",
                "\"\(term)\""  // This searches in body too
            ]
        }
        
        return "(\(queryParts.joined(separator: " OR ")))"
    }
    
    /// Check if an email is a reply or forward
    private func isReplyOrForward(_ message: GmailMessage) -> Bool {
        guard let subject = message.subject else { return false }
        let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if subject starts with "Re:" or "Fwd:" (case-insensitive)
        let lowercased = trimmedSubject.lowercased()
        return lowercased.hasPrefix("re:") || 
               lowercased.hasPrefix("fwd:") || 
               lowercased.hasPrefix("fw:")
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
            // Build query from search terms (or fallback to searching for "new docket" in all emails)
            let baseQuery: String
            if !settings.gmailSearchTerms.isEmpty {
                baseQuery = buildGmailQuery(from: settings.gmailSearchTerms)
            } else if !settings.gmailQuery.isEmpty {
                baseQuery = settings.gmailQuery
            } else {
                // No specific terms - search for "new docket" variations in all emails
                baseQuery = "\"new docket\" OR \"new docket -\" OR \"docket -\""
            }
            
            // Only fetch unread emails
            // Search for docket-related content in all unread emails (not just labeled ones)
            let query = "(\(baseQuery) OR \"new docket\" OR \"new docket -\" OR \"docket -\" OR \"New docket\") is:unread"
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
            
            // Filter out replies and forwards (only process initial emails)
            let initialEmails = unreadMessages.filter { message in
                !isReplyOrForward(message)
            }
            
            print("EmailScanningService: \(initialEmails.count) are initial emails (filtered out \(unreadMessages.count - initialEmails.count) replies/forwards)")
            
            // Filter out already processed emails (unless force rescan)
            let newMessages = initialEmails.filter { 
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
        
        // Create company name matcher
        let companyNames = companyNameCache.getAllCompanyNames()
        let matcher = CompanyNameMatcher(companyNames: companyNames)
        
        // Create parser with matcher and metadata manager
        let parser = patterns.isEmpty 
            ? EmailDocketParser(companyNameMatcher: matcher, metadataManager: metadataManager)
            : EmailDocketParser(patterns: patterns, companyNameMatcher: matcher, metadataManager: metadataManager)
        
        let subject = message.subject ?? ""
        let plainBody = message.plainTextBody ?? ""
        let htmlBody = message.htmlBody ?? ""
        let body = !plainBody.isEmpty ? plainBody : htmlBody
        
        print("EmailScanningService: Parsing email:")
        print("  Subject: \(subject)")
        print("  Plain body length: \(plainBody.count)")
        print("  HTML body length: \(htmlBody.count)")
        print("  Using body: \(!plainBody.isEmpty ? "plain" : (!htmlBody.isEmpty ? "HTML" : "none"))")
        if !body.isEmpty {
        print("  Body preview: \(body.prefix(200))")
        } else {
            print("  Body: (empty)")
            print("  Snippet: \(message.snippet ?? "(none)")")
        }
        
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
            
            // Ensure we store non-empty values (not empty strings)
            let emailSubjectToStore = subject.isEmpty ? nil : subject
            let emailBodyToStore = body.isEmpty ? nil : body
            
            let notification = Notification(
                type: .newDocket,
                title: "New Docket Detected",
                message: messageText,
                docketNumber: docketNumber,
                jobName: parsedDocket.jobName,
                emailId: message.id,
                sourceEmail: parsedDocket.sourceEmail,
                emailSubject: emailSubjectToStore,
                emailBody: emailBodyToStore
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
    
    /// Check if email is sent to company media email
    private func checkIfMediaEmail(_ message: GmailMessage, mediaEmail: String) -> Bool {
        let recipients = message.allRecipients
        let mediaEmailLower = mediaEmail.lowercased()
        
        print("EmailScanningService: Checking if email \(message.id) is sent to media email")
        print("  Media email: \(mediaEmailLower)")
        print("  Recipients: \(recipients)")
        
        // Check if media email is in recipients
        let isMediaEmail = recipients.contains { recipient in
            recipient.lowercased() == mediaEmailLower
        }
        
        print("  Is media email: \(isMediaEmail)")
        return isMediaEmail
    }
    
    /// Process a media email and create notification
    func processMediaEmailAndCreateNotification(_ message: GmailMessage) async -> Bool {
        // Safety check: Only process unread emails
        guard let labelIds = message.labelIds, labelIds.contains("UNREAD") else {
            print("EmailScanningService: Skipping media email \(message.id) - already marked as read")
            return false
        }
        
        guard let settingsManager = settingsManager else { return false }
        let settings = settingsManager.currentSettings
        
        // Check if email is actually sent to media email
        guard checkIfMediaEmail(message, mediaEmail: settings.companyMediaEmail) else {
            return false
        }
        
        let subject = message.subject ?? ""
        let plainBody = message.plainTextBody ?? ""
        let htmlBody = message.htmlBody ?? ""
        
        // For file hosting link detection, we want to check BOTH plain text and HTML
        // because links might be in HTML format even if plain text exists
        let bodyForDetection = !plainBody.isEmpty ? (plainBody + " " + htmlBody) : htmlBody
        let body = !plainBody.isEmpty ? plainBody : htmlBody
        
        print("EmailScanningService: Processing media email \(message.id)")
        print("  Subject: \(subject)")
        print("  Plain body length: \(plainBody.count)")
        print("  HTML body length: \(htmlBody.count)")
        print("  Plain body preview: \(plainBody.prefix(200))")
        print("  HTML body preview: \(htmlBody.prefix(200))")
        print("  Combined body for detection preview: \(bodyForDetection.prefix(300))")
        print("  File hosting whitelist: \(settings.grabbedFileHostingWhitelist)")
        
        // Check if email contains file hosting links using the whitelist from settings
        let qualifier = MediaThreadQualifier(
            subjectPatterns: settings.grabbedSubjectPatterns,
            subjectExclusions: settings.grabbedSubjectExclusions,
            attachmentTypes: settings.grabbedAttachmentTypes,
            fileHostingWhitelist: settings.grabbedFileHostingWhitelist,
            senderWhitelist: settings.grabbedSenderWhitelist,
            bodyExclusions: settings.grabbedBodyExclusions
        )
        
        // Use the qualifier's file hosting link detection (which uses the whitelist)
        // Check BOTH plain text and HTML body for links (links might be in HTML)
        // or fall back to general detection if whitelist is empty
        let hasFileHostingLink = !settings.grabbedFileHostingWhitelist.isEmpty
            ? qualifier.qualifiesByFileHostingLinks(bodyForDetection)
            : FileHostingLinkDetector.containsFileHostingLink(bodyForDetection)
        
        print("  Has file hosting link: \(hasFileHostingLink)")
        
        guard hasFileHostingLink else {
            print("EmailScanningService: Media email \(message.id) does not contain file hosting links from whitelist")
            return false
        }
        
        // Extract file hosting links
        let fileLinks = FileHostingLinkDetector.extractFileHostingLinks(body)
        
        await MainActor.run {
            guard let notificationCenter = notificationCenter else {
                print("EmailScanningService: ERROR - notificationCenter is nil when trying to add media notification")
                return
            }
            
            // Create notification for media files
            let notification = Notification(
                type: .mediaFiles,
                title: "File Delivery Available",
                message: subject.isEmpty ? "Files shared via \(settings.companyMediaEmail)" : subject,
                timestamp: Date(),
                status: .pending, // Ensure it's marked as pending
                archivedAt: nil,
                docketNumber: nil,
                jobName: nil,
                emailId: message.id,
                sourceEmail: message.from,
                projectManager: nil,
                emailSubject: subject.isEmpty ? nil : subject,
                emailBody: body.isEmpty ? nil : body,
                fileLinks: fileLinks.isEmpty ? nil : fileLinks,
                threadId: message.threadId // Store thread ID for tracking replies
            )
            
            print("EmailScanningService: ✅ Adding media file notification for email \(message.id)")
            print("  Notification ID: \(notification.id)")
            print("  Type: \(notification.type)")
            print("  Status: \(notification.status)")
            print("  Title: \(notification.title)")
            print("  Message: \(notification.message)")
            print("  File links found: \(fileLinks.count)")
            notificationCenter.add(notification)
            print("EmailScanningService: ✅ Notification added. Total notifications: \(notificationCenter.notifications.count)")
            print("  Active notifications: \(notificationCenter.activeNotifications.count)")
            print("  Media file notifications: \(notificationCenter.activeNotifications.filter { $0.type == .mediaFiles }.count)")
        }
        
        return true
    }
    
    /// Re-parse an email by emailId and return the parsed values
    func reparseEmail(emailId: String) async -> (docketNumber: String?, jobName: String?, subject: String?, body: String?)? {
        do {
            // Fetch the email again
            let message = try await gmailService.getEmail(messageId: emailId)
            
            // Use parser with custom patterns if configured
            guard let settingsManager = settingsManager else { return nil }
            let currentSettings = settingsManager.currentSettings
            let patterns = currentSettings.docketParsingPatterns
            
            // Create company name matcher
            let companyNames = companyNameCache.getAllCompanyNames()
            let matcher = CompanyNameMatcher(companyNames: companyNames)
            
            // Create parser with matcher and metadata manager
            let parser = patterns.isEmpty 
                ? EmailDocketParser(companyNameMatcher: matcher, metadataManager: metadataManager)
                : EmailDocketParser(patterns: patterns, companyNameMatcher: matcher, metadataManager: metadataManager)
            
            let subject = message.subject ?? ""
            let plainBody = message.plainTextBody ?? ""
            let htmlBody = message.htmlBody ?? ""
            let body = !plainBody.isEmpty ? plainBody : htmlBody
            
            let parsed = parser.parseEmail(
                subject: message.subject,
                body: message.plainTextBody ?? message.htmlBody,
                from: message.from
            )
            
            guard let parsedDocket = parsed else {
                print("EmailScanningService: Failed to re-parse email \(emailId)")
                return nil
            }
            
            let docketNumber = parsedDocket.docketNumber == "TBD" ? nil : parsedDocket.docketNumber
            let emailSubjectToStore = subject.isEmpty ? nil : subject
            let emailBodyToStore = body.isEmpty ? nil : body
            
            return (docketNumber: docketNumber, jobName: parsedDocket.jobName, subject: emailSubjectToStore, body: emailBodyToStore)
        } catch {
            print("EmailScanningService: Error re-fetching email \(emailId): \(error.localizedDescription)")
            return nil
        }
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
            // Build query from search terms (or fallback to searching for "new docket" in all emails)
            let baseQuery: String
            if !settings.gmailSearchTerms.isEmpty {
                baseQuery = buildGmailQuery(from: settings.gmailSearchTerms)
            } else if !settings.gmailQuery.isEmpty {
                baseQuery = settings.gmailQuery
            } else {
                // No specific terms - search for "new docket" variations in all emails
                baseQuery = "\"new docket\" OR \"new docket -\" OR \"docket -\""
            }
            
            // Only fetch unread emails
            // Search for docket-related content in all unread emails (not just labeled ones)
            let docketQuery = "(\(baseQuery) OR \"new docket\" OR \"new docket -\" OR \"docket -\" OR \"New docket\") is:unread"
            print("EmailScanningService: Scanning unread emails with query: \(docketQuery)")
            
            // Also scan for media emails (sent to company media email)
            // Check both "to:" and "cc:" fields, and also check if media email is in the recipient list
            let mediaEmail = settings.companyMediaEmail.lowercased()
            // Gmail query: check to, cc, and bcc fields
            let mediaQuery = "(to:\(mediaEmail) OR cc:\(mediaEmail) OR bcc:\(mediaEmail)) is:unread"
            print("EmailScanningService: Also scanning for media emails with query: \(mediaQuery)")
            
            // Fetch unread emails matching docket query
            let docketMessageRefs = try await gmailService.fetchEmails(
                query: docketQuery,
                maxResults: 50
            )
            
            // Fetch unread emails matching media email query
            let mediaMessageRefs = try await gmailService.fetchEmails(
                query: mediaQuery,
                maxResults: 50
            )
            
            // Combine and deduplicate message references
            var allMessageRefs = docketMessageRefs
            let docketIds = Set(docketMessageRefs.map { $0.id })
            for ref in mediaMessageRefs {
                if !docketIds.contains(ref.id) {
                    allMessageRefs.append(ref)
                }
            }
            
            let messageRefs = allMessageRefs
            print("EmailScanningService: Found \(docketMessageRefs.count) docket emails and \(mediaMessageRefs.count) media emails (total unique: \(messageRefs.count))")
            
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
            
            // Filter out replies and forwards (only process initial emails)
            let initialEmails = unreadMessages.filter { message in
                !isReplyOrForward(message)
            }
            print("EmailScanningService: \(initialEmails.count) are initial emails (filtered out \(unreadMessages.count - initialEmails.count) replies/forwards)")
            
            // Get existing notification email IDs to avoid duplicates (unless force rescan)
            let existingEmailIds = await MainActor.run {
                return forceRescan ? Set<String>() : Set(notificationCenter.notifications.compactMap { $0.emailId })
            }
            print("EmailScanningService: \(existingEmailIds.count) emails already have notifications (forceRescan: \(forceRescan))")
            
            // Process unread emails and create notifications if they don't already exist
            var createdCount = 0
            var skippedCount = 0
            var failedCount = 0
            var mediaEmailCount = 0
            
            for message in initialEmails {
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
                
                // Check if this is a media email (sent to company media email)
                let isMediaEmail = checkIfMediaEmail(message, mediaEmail: settings.companyMediaEmail)
                
                print("EmailScanningService: Email \(message.id) - isMediaEmail: \(isMediaEmail)")
                
                if isMediaEmail {
                    // Process as media email
                    print("EmailScanningService: Attempting to process as media email...")
                    if await processMediaEmailAndCreateNotification(message) {
                        mediaEmailCount += 1
                        print("EmailScanningService: ✅ Created media file notification for email \(message.id)")
                    } else {
                        print("EmailScanningService: ❌ Failed to create media file notification for email \(message.id)")
                    }
                } else {
                    // Process as regular docket email
                    if await processEmailAndCreateNotification(message) {
                        createdCount += 1
                        print("EmailScanningService: Created notification for email \(message.id)")
                        // Don't mark as processed - we want to keep showing it until it's read/approved
                    } else {
                        failedCount += 1
                        print("EmailScanningService: Failed to create notification for email \(message.id) - likely not a valid docket email")
                    }
                }
            }
            
            print("EmailScanningService: Summary - Created: \(createdCount), Media Files: \(mediaEmailCount), Skipped: \(skippedCount), Failed: \(failedCount)")
            
            // After scanning emails, check for grabbed replies immediately
            // (in addition to the periodic check)
            if let grabbedService = notificationCenter.grabbedIndicatorService {
                print("EmailScanningService: Triggering immediate grabbed reply check...")
                Task {
                    await grabbedService.checkForGrabbedReplies()
                }
            }
            
        } catch {
            print("EmailScanningService: Error scanning unread emails: \(error.localizedDescription)")
            await MainActor.run {
                lastError = error.localizedDescription
            }
        }
    }
}

