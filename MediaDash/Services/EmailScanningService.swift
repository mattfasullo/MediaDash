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
    @Published var cachedUnreadMessages: [GmailMessage] = []
    @Published var lastRateLimitRetryAfter: Date?
    
    var gmailService: GmailService
    private var parser: EmailDocketParser
    private var scanningTask: Task<Void, Never>?
    private var processedEmailIds: Set<String> = []
    private var processedThreadIds: Set<String> = []  // Track processed threads to prevent duplicates
    private let processedEmailsKey = "gmail_processed_email_ids"
    private let processedThreadsKey = "gmail_processed_thread_ids"
    private let rateLimitRetryAfterKey = "gmail_rate_limit_retry_after"
    
    weak var mediaManager: MediaManager?
    weak var settingsManager: SettingsManager?
    weak var notificationCenter: NotificationCenter?
    weak var metadataManager: DocketMetadataManager?
    weak var asanaCacheManager: AsanaCacheManager?
    var simianService: SimianService?
    
    private var companyNameCache: CompanyNameCache {
        CompanyNameCache.shared
    }
    
    #if DEBUG
    /// Verbose Gmail scan logs (Release: no-op; autoclosure not evaluated).
    private func emailScanDebug(_ message: @autoclosure () -> String) {
        print(message())
    }
    #else
    private func emailScanDebug(_ message: @autoclosure () -> String) {}
    #endif

    /// Gmail user label for new-docket mail; must match the label name in Gmail exactly (including nested `Parent/Child` if used).
    private static let newDocketGmailUserLabelName = "New Docket"

    /// Gmail `label:` search term with quoting for spaces/special characters.
    private static func gmailQuotedLabelSearchTerm(_ name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Gmail list query: **unread and** user label (both required — space is AND in Gmail search).
    /// Resolves label ID so we can double-check `labelIds` after fetch.
    private func newDocketScanQueryAndLabelId() async -> (query: String, newDocketLabelId: String?) {
        let trimmedName = Self.newDocketGmailUserLabelName.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedId: String?
        do {
            resolvedId = try await gmailService.userLabelId(matchingName: trimmedName)
            if resolvedId == nil {
                emailScanDebug("EmailScanningService: ⚠️ No Gmail user label named '\(trimmedName)' — scan uses is:unread label:… but client cannot verify label IDs until this label exists")
            }
        } catch {
            emailScanDebug("EmailScanningService: ⚠️ Could not list Gmail labels (\(error.localizedDescription))")
        }
        let query = "is:unread label:\(Self.gmailQuotedLabelSearchTerm(trimmedName))"
        return (query, resolvedId)
    }

    /// Unread is mandatory; New Docket label is required (verified via `labelIds` when we have a resolved label ID).
    private func isNewDocketScanCandidate(_ message: GmailMessage, newDocketLabelId: String?) -> Bool {
        guard let labelIds = message.labelIds, labelIds.contains("UNREAD") else { return false }
        if let id = newDocketLabelId {
            return labelIds.contains(id)
        }
        // Could not resolve label ID; query already enforced `label:` — only UNREAD is verified here.
        return true
    }
    
    init(gmailService: GmailService, parser: EmailDocketParser) {
        self.gmailService = gmailService
        self.parser = parser
        loadProcessedEmailIds()
        loadRateLimitRetryAfter()

        // Check if Gmail is already authenticated and add to whitelist
        // Use detached task to avoid blocking app launch when network is slow
        Task.detached { [weak self] in
            guard let self = self else { return }
            await self.checkAndAddGmailToWhitelist()
        }
    }

    
    /// Check if Gmail is authenticated and add email to Grayson whitelist
    private func checkAndAddGmailToWhitelist() async {
        guard gmailService.isAuthenticated else { return }
        
        // Check if we have a saved email
        if let savedEmail = UserDefaults.standard.string(forKey: "gmail_connected_email"),
           savedEmail.lowercased().hasSuffix("@graysonmusicgroup.com") {
            _ = GraysonEmployeeWhitelist.shared.addEmail(savedEmail)
            return
        }
        
        // Try to fetch email from Gmail API
        do {
            let email = try await gmailService.getUserEmail()
            if email.lowercased().hasSuffix("@graysonmusicgroup.com") {
                _ = GraysonEmployeeWhitelist.shared.addEmail(email)
                UserDefaults.standard.set(email, forKey: "gmail_connected_email")
            }
        } catch {
            // Silently fail - email will be added when user connects Gmail in settings
        }
    }
    
    
    /// Populate company name cache from various sources
    func populateCompanyNameCache() {
        Task { @MainActor in
            // Configure shared cache URLs
            if let settings = settingsManager?.currentSettings,
               let sharedCacheURL = settings.sharedCacheURL,
               !sharedCacheURL.isEmpty {
                companyNameCache.configure(sharedCacheURL: sharedCacheURL)
                // Configure Notification sync manager (uses same directory, different filename)
                NotificationSyncManager.shared.configure(
                    sharedCacheURL: sharedCacheURL,
                    serverBasePath: settings.serverBasePath
                )
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
    
    /// Start automatic email scanning and pattern syncing
    func startScanning() {
        // Use `isEnabled` here — not `isScanning`. `isScanning` means a fetch is in flight; setting it before
        // `scanNow()` would make every periodic scan return immediately at the top of `scanNow()`.
        guard !isEnabled else { return }
        guard let settings = settingsManager?.currentSettings, settings.gmailEnabled else {
            lastError = "Gmail integration is not enabled in settings"
            return
        }
        
        guard gmailService.isAuthenticated else {
            lastError = "Gmail is not authenticated"
            return
        }
        
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
    
    /// Check if an email is a reply or forward
    /// Perform a manual scan now
    func scanNow(forceRescan: Bool = false) async {
        #if DEBUG
        emailScanDebug("🔍 EmailScanningService.scanNow() called")
        #endif
        // Skip if a scan is already running (do not conflate with `isEnabled` / periodic scanning).
        if isScanning {
            return
        }

        // Clear expired cooldown so banner goes away; we never block scan attempts — let Google return 429 if still limited
        let now = Date()
        if let retryAfter = lastRateLimitRetryAfter, retryAfter <= now {
            clearRateLimitRetryAfter()
        }
        
        guard let settings = settingsManager?.currentSettings, settings.gmailEnabled else {
            let error = "Gmail integration is not enabled"
            print("❌ EmailScanningService: \(error)")
            DispatchQueue.main.async {
                self.lastError = error
            }
            return
        }
        
        guard gmailService.isAuthenticated else {
            let error = "Gmail is not authenticated"
            print("❌ EmailScanningService: \(error)")
            DispatchQueue.main.async {
                self.lastError = error
            }
            return
        }
        
        #if DEBUG
        emailScanDebug("✅ EmailScanningService: Gmail is enabled and authenticated - proceeding with scan")
        emailScanDebug("EmailScanningService: Gmail authenticated, starting email query")
        #endif
        
        // Defer state updates to next run loop cycle to avoid SwiftUI warnings
        // Use DispatchQueue.main.async to ensure we're outside the view update cycle
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
            self.isScanning = true
            self.lastError = nil
                continuation.resume()
            }
        }
        
        do {
            let (query, newDocketLabelId) = await newDocketScanQueryAndLabelId()
            
            emailScanDebug("EmailScanningService: 🔍 Starting scan...")
            emailScanDebug("  📧 Gmail enabled: \(settings.gmailEnabled)")
            emailScanDebug("  🔑 Gmail authenticated: \(gmailService.isAuthenticated)")
            emailScanDebug("  🔎 Query: \(query)")
            
            emailScanDebug("EmailScanningService: Starting email scan - query: \(query), gmailEnabled: \(settings.gmailEnabled), gmailAuthenticated: \(gmailService.isAuthenticated)")
            // Fetch emails matching query
            let messageRefs = try await gmailService.fetchEmails(
                query: query,
                maxResults: 50
            )
            
            emailScanDebug("EmailScanningService: Email query completed - found \(messageRefs.count) emails")
            
            emailScanDebug("  📨 Found \(messageRefs.count) email references matching query")
            
            // Get full email messages
            let messages = try await gmailService.getEmails(messageReferences: messageRefs)
            
            emailScanDebug("  📦 Retrieved \(messages.count) full email messages")
            
            // DEBUG: Log ALL messages retrieved (before filtering)
            emailScanDebug("  🔍 DEBUG: All messages retrieved from Gmail:")
            for (index, message) in messages.enumerated() {
                let subject = message.subject ?? "(no subject)"
                let from = message.from ?? "(no sender)"
                let labelIds = message.labelIds ?? []
                let isUnread = labelIds.contains("UNREAD")
                emailScanDebug("    \(index + 1). \"\(subject)\" | From: \(from) | Unread: \(isUnread)")
            }
            
            // Unread, or (if configured) messages carrying the new-docket user label (e.g. read but labeled)
            let candidateMessages = messages.filter { isNewDocketScanCandidate($0, newDocketLabelId: newDocketLabelId) }
            emailScanDebug("  ✅ \(candidateMessages.count) are scan candidates (unread and '\(Self.newDocketGmailUserLabelName)' label); filtered out \(messages.count - candidateMessages.count)")
            
            // DEBUG: Check if Kids Help Phone email is in the unread list
            let kidsHelpPhoneEmails = candidateMessages.filter { message in
                let subject = message.subject ?? ""
                let from = message.from ?? ""
                return subject.localizedCaseInsensitiveContains("kids help phone") ||
                       from.localizedCaseInsensitiveContains("kids help phone")
            }
            if !kidsHelpPhoneEmails.isEmpty {
                emailScanDebug("  ✅ FOUND Kids Help Phone email(s) in unread list: \(kidsHelpPhoneEmails.count)")
                for email in kidsHelpPhoneEmails {
                    emailScanDebug("    - Subject: \(email.subject ?? "none") | From: \(email.from ?? "none") | ID: \(email.id)")
                }
            } else {
                emailScanDebug("  ⚠️  WARNING: Kids Help Phone email NOT found in candidate list")
                emailScanDebug("     This could mean:")
                emailScanDebug("     1. Email is read, or missing the '\(Self.newDocketGmailUserLabelName)' Gmail label (both unread + label are required)")
                emailScanDebug("     2. Email is not in the first 50 matching messages (Gmail query limit)")
                emailScanDebug("     3. Email was already processed and is in processedEmailIds/processedThreadIds")
            }
            
            // Cache scan candidates for reuse in checklist flow
            await MainActor.run {
                self.cachedUnreadMessages = candidateMessages
            }
            
            // Log ALL candidate emails found
            if !candidateMessages.isEmpty {
                emailScanDebug("  📝 Found \(candidateMessages.count) candidate email(s):")
                for (index, message) in candidateMessages.enumerated() {
                    let subject = message.subject ?? "(no subject)"
                    let from = message.from ?? "(no sender)"
                    let isProcessed = processedEmailIds.contains(message.id)
                    let isThreadProcessed = processedThreadIds.contains(message.threadId)
                    var status = ""
                    if isProcessed { status += " [already processed]" }
                    if isThreadProcessed { status += " [thread already processed]" }
                    emailScanDebug("    \(index + 1). \"\(subject)\" | From: \(from)\(status)")
                    
                    // Log if this might be a request (for debugging)
                    if subject.localizedCaseInsensitiveContains("request") ||
                       subject.localizedCaseInsensitiveContains("help") ||
                       from.localizedCaseInsensitiveContains("kids help phone") {
                        emailScanDebug("      🔍 NOTE: This email might be a request")
                    }
                }
            }
            
            // Process all candidates — parser will determine if they contain new docket information
            let initialEmails = candidateMessages
            emailScanDebug("  📬 Processing all \(initialEmails.count) candidate emails - parser will determine relevance")
            
            // Filter out already processed emails AND threads (unless force rescan)
            // This prevents duplicate notifications from the same email thread
            let newMessages = initialEmails.filter { message in
                if forceRescan { return true }
                let subject = message.subject ?? "(no subject)"
                let from = message.from ?? "(no sender)"
                let emailId = message.id
                let threadId = message.threadId
                
                // Skip if this exact email was already processed
                if processedEmailIds.contains(emailId) {
                    emailScanDebug("  ⏭️  SKIPPED (already processed): \"\(subject)\" from \(from) [emailId: \(emailId)]")
                    return false
                }
                // Skip if this thread was already processed (prevents duplicates from replies)
                if processedThreadIds.contains(threadId) {
                    emailScanDebug("  ⏭️  SKIPPED (thread processed): \"\(subject)\" from \(from) [threadId: \(threadId)]")
                    return false
                }
                return true
            }

            let alreadyProcessedCount = initialEmails.count - newMessages.count
            emailScanDebug("  🆕 \(newMessages.count) are new (not yet processed)")
            if alreadyProcessedCount > 0 {
                emailScanDebug("  ⏭️  Skipped \(alreadyProcessedCount) already-processed emails/threads")
                emailScanDebug("  🔍 DEBUG: If 'Kids Help Phone' email is missing, check if it was in the skipped list above")
            }
            
            // DEBUG: Log all emails that will be processed
            emailScanDebug("  📋 Emails that will be processed:")
            for (index, message) in newMessages.enumerated() {
                let subject = message.subject ?? "(no subject)"
                let from = message.from ?? "(no sender)"
                emailScanDebug("    \(index + 1). \"\(subject)\" | From: \(from)")
                
                // Specifically highlight Kids Help Phone emails
                if subject.localizedCaseInsensitiveContains("kids help phone") ||
                   from.localizedCaseInsensitiveContains("kids help phone") {
                    emailScanDebug("      ✅ Kids Help Phone email WILL BE PROCESSED")
                }
            }
            
            // Parse and create notifications (don't auto-create dockets)
            var notificationCount = 0
            var processedCount = 0
            var rejectedCount = 0
            
            for message in newMessages {
                processedCount += 1
                let subject = message.subject ?? "(no subject)"
                let from = message.from ?? "(no sender)"
                emailScanDebug("  🔄 Processing email \(processedCount)/\(newMessages.count): \"\(subject)\" from \(from)")
                
                if await processEmailAndCreateNotification(message, newDocketLabelId: newDocketLabelId) {
                    notificationCount += 1
                    emailScanDebug("    ✅ Created notification")
                    // Mark email AND thread as processed (prevents duplicate notifications from same thread)
                    _ = await MainActor.run {
                        processedEmailIds.insert(message.id)
                        processedThreadIds.insert(message.threadId)
                    }
                } else {
                    rejectedCount += 1
                    emailScanDebug("    ❌ Rejected (no notification created)")
                }
            }
            
            // Save processed email IDs
            saveProcessedEmailIds()
            
            // Periodically clean up old processed IDs to prevent unbounded growth
            cleanupOldProcessedIds()
            
            // Print diagnostic summary
            emailScanDebug("EmailScanningService: 📊 Scan Summary:")
            emailScanDebug("  📧 Total emails found: \(messageRefs.count)")
            emailScanDebug("  ✅ Scan candidates: \(candidateMessages.count)")
            emailScanDebug("  📬 Initial (not reply/forward): \(initialEmails.count)")
            emailScanDebug("  🆕 New (not processed): \(newMessages.count)")
            emailScanDebug("  ✅ Notifications created: \(notificationCount)")
            emailScanDebug("  ❌ Rejected: \(rejectedCount)")
            
            if notificationCount == 0 && newMessages.count > 0 {
                emailScanDebug("  ⚠️  WARNING: No notifications created despite \(newMessages.count) new emails!")
                emailScanDebug("     This likely means emails are being rejected by the parser.")
                emailScanDebug("     Check console logs for detailed parsing information.")
            }
            
            // Use DispatchQueue to avoid SwiftUI view update cycle conflicts
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    self.lastScanTime = Date()
                    self.isScanning = false
                    self.clearRateLimitRetryAfter()
                    continuation.resume()
                }
            }
            
        } catch {
            let errorMessage = error.localizedDescription
            if let retryAfter = parseRetryAfterDate(from: errorMessage) {
                lastRateLimitRetryAfter = retryAfter
                saveRateLimitRetryAfter(retryAfter)
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    self.lastError = errorMessage
                    self.isScanning = false
                    continuation.resume()
                }
            }
        }
    }
    
    // MARK: - Helper Methods

    private func parseRetryAfterDate(from text: String) -> Date? {
        // Fix: Capture the full date string including timezone
        // Handle two formats:
        // 1. "Retry after 2026-02-12 20:15:59 +0000" (spaced format)
        // 2. "Retry after 2026-02-12T20:17:04.952Z" (ISO8601 format)
        
        // Try spaced format first: "yyyy-MM-dd HH:mm:ss Z"
        let spacedPattern = #"Retry\s+after\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+[+-]\d{4})"#
        if let regex = try? NSRegularExpression(pattern: spacedPattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges >= 2,
               let retryRange = Range(match.range(at: 1), in: text) {
                let value = String(text[retryRange])
                let spaced = DateFormatter()
                spaced.locale = Locale(identifier: "en_US_POSIX")
                spaced.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
                if let date = spaced.date(from: value) {
                    return date
                }
            }
        }
        
        // Try ISO8601 format: "2026-02-12T20:17:04.952Z" or "2026-02-12T20:17:04Z"
        let isoPattern = #"Retry\s+after\s+(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z)"#
        if let regex = try? NSRegularExpression(pattern: isoPattern, options: []) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges >= 2,
               let retryRange = Range(match.range(at: 1), in: text) {
                let value = String(text[retryRange])
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: value) {
                    return date
                }
                let fallback = ISO8601DateFormatter()
                fallback.formatOptions = [.withInternetDateTime]
                if let date = fallback.date(from: value) {
                    return date
                }
            }
        }
        
        return nil
    }
    
    /// Process a single email and create notification (don't auto-create docket)
    func processEmailAndCreateNotification(_ message: GmailMessage, newDocketLabelId: String? = nil) async -> Bool {
        guard let labelIds = message.labelIds else {
            emailScanDebug("    ❌ REJECTED: No label IDs on message")
            return false
        }
        guard labelIds.contains("UNREAD") else {
            emailScanDebug("    ❌ REJECTED: Email is not unread")
            return false
        }
        if let lid = newDocketLabelId {
            guard labelIds.contains(lid) else {
                emailScanDebug("    ❌ REJECTED: Email does not have the '\(Self.newDocketGmailUserLabelName)' Gmail label")
                return false
            }
        }
        
        // Use parser with custom patterns if configured
        guard let settingsManager = settingsManager else {
            emailScanDebug("    ❌ REJECTED: Settings manager is nil")
            return false
        }
        let currentSettings = settingsManager.currentSettings
        let patterns = currentSettings.docketParsingPatterns
        
        // Create company name matcher
        let companyNames = companyNameCache.getAllCompanyNames()
        let matcher = CompanyNameMatcher(companyNames: companyNames)
        
        // Create parser with matcher, metadata manager, and Asana cache manager
        let parser = patterns.isEmpty 
            ? EmailDocketParser(companyNameMatcher: matcher, metadataManager: metadataManager, asanaCacheManager: asanaCacheManager)
            : EmailDocketParser(patterns: patterns, companyNameMatcher: matcher, metadataManager: metadataManager, asanaCacheManager: asanaCacheManager)
        
        let subject = message.subject ?? ""
        let plainBody = message.plainTextBody ?? ""
        let htmlBody = message.htmlBody ?? ""
        var body = !plainBody.isEmpty ? plainBody : htmlBody
        // When body is empty (e.g. HTML not extracted from nested multipart), use Gmail snippet so we still
        // detect "new docket" and docket numbers that appear in the preview (subject + snippet are what we have)
        if body.isEmpty, let snippet = message.snippet, !snippet.isEmpty {
            body = snippet
            emailScanDebug("  Using snippet as body fallback for parsing (\(snippet.count) chars)")
        }
        
        emailScanDebug("EmailScanningService: Parsing email:")
        emailScanDebug("  Subject: \(subject)")
        emailScanDebug("  Plain body length: \(plainBody.count)")
        emailScanDebug("  HTML body length: \(htmlBody.count)")
        emailScanDebug("  Using body: \(!plainBody.isEmpty ? "plain" : (!htmlBody.isEmpty ? "HTML" : (body.isEmpty ? "none" : "snippet")))")
        if !body.isEmpty {
            emailScanDebug("  Body preview: \(body.prefix(200))")
        } else {
            emailScanDebug("  Body: (empty)")
            emailScanDebug("  Snippet: \(message.snippet ?? "(none)")")
        }
        
        // Determine the original sender: check if there's already a notification for this thread
        // If so, use the sourceEmail from that notification (the original sender)
        var originalSenderEmail = message.from
        if !message.threadId.isEmpty, let notificationCenter = notificationCenter {
            let threadId = message.threadId
            // Check if there's an existing notification for this thread
            if let existingNotification = notificationCenter.notifications.first(where: { $0.threadId == threadId && $0.type == .newDocket }) {
                originalSenderEmail = existingNotification.sourceEmail
                emailScanDebug("  📧 Using original sender from existing notification: \(originalSenderEmail ?? "nil")")
            } else {
                // No existing notification - try to get the original sender from the thread
                do {
                    let thread = try await gmailService.getThread(threadId: threadId)
                    if let messages = thread.messages, let firstMessage = messages.first {
                        originalSenderEmail = firstMessage.from
                        emailScanDebug("  📧 Using original sender from thread's first message: \(originalSenderEmail ?? "nil")")
                    }
                } catch {
                    emailScanDebug("  ⚠️ Could not fetch thread to get original sender, using current message sender: \(error.localizedDescription)")
                }
            }
        }
        
        // Parse email using rule-based parser
        var parsedDocket: ParsedDocket? = nil
        
        // Try to parse the email with the original sender
        parsedDocket = parser.parseEmail(
            subject: message.subject,
            body: body,
            from: originalSenderEmail
        )
                
        // Check for multiple docket numbers in the parsed result
        if let docketNum = parsedDocket?.docketNumber {
            let multipleDockets = parseMultipleDocketNumbers(docketNum)
            
            if multipleDockets.count > 1 {
                // Multiple dockets detected - create notifications for each
                emailScanDebug("EmailScanningService: ✅ Parser detected \(multipleDockets.count) docket numbers: \(multipleDockets)")
                
                await MainActor.run {
                    for docket in multipleDockets {
                        guard let parsed = parsedDocket else { continue }
                        createNotificationForDocket(
                            docketNumber: docket,
                            jobName: parsed.jobName,
                            message: message,
                            subject: subject,
                            body: body,
                            originalSenderEmail: originalSenderEmail
                        )
                    }
                }
                return true // All notifications created
            }
        }
        
        // If we don't have a parsed docket yet, try parsing again with original sender
        if parsedDocket == nil {
            parsedDocket = parser.parseEmail(
                subject: message.subject,
                body: body,
                from: originalSenderEmail
            )
        }
        
        guard let parsedDocket = parsedDocket else {
            emailScanDebug("    ❌ REJECTED: Failed to parse email - no docket information found in subject or body")
            return false
        }
        
        emailScanDebug("    ✅ Parsed docket: \(parsedDocket.docketNumber) - \(parsedDocket.jobName)")
        
        // STRICT VALIDATION: Docket number is REQUIRED - no exceptions, no "TBD" allowed
        // If we don't have a valid docket number, reject the notification
        if !isValidDocketNumber(parsedDocket.docketNumber) {
            emailScanDebug("    ❌ REJECTED: Invalid or missing docket number: '\(parsedDocket.docketNumber)' (must be exactly 5 digits, optionally with -US suffix)")
            emailScanDebug("    ⚠️ DOCKET NUMBERS ARE MANDATORY - This email will NOT create a notification")
            return false
        }
        
        // Work Picture may already list this docket — still create a notification so the email appears in New Dockets;
        // checkDuplicatesForNotification marks pre-existing WP / Simian for the UI.
        if let manager = mediaManager,
           manager.dockets.contains("\(parsedDocket.docketNumber)_\(parsedDocket.jobName)") {
            emailScanDebug("    ℹ️ Work Picture already has \(parsedDocket.docketNumber)_\(parsedDocket.jobName) — creating notification anyway (duplicate check will flag WP)")
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
                emailBody: emailBodyToStore,
                threadId: message.threadId  // Track thread to prevent duplicates
            )
            
            
            emailScanDebug("EmailScanningService: Adding notification for docket \(docketNumber ?? "TBD"): \(parsedDocket.jobName)")
            notificationCenter.add(notification)
            emailScanDebug("EmailScanningService: Notification added. Total notifications: \(notificationCenter.notifications.count)")
            
            // Auto-scan for duplicates (Work Picture folder and Simian project)
            Task {
                await checkDuplicatesForNotification(notification)
            }
            
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
        
        emailScanDebug("EmailScanningService: Checking if email \(message.id) is sent to media email")
        emailScanDebug("  Media email: \(mediaEmailLower)")
        emailScanDebug("  Recipients: \(recipients)")
        
        // Check if media email is in recipients
        let isMediaEmail = recipients.contains { recipient in
            recipient.lowercased() == mediaEmailLower
        }
        
        emailScanDebug("  Is media email: \(isMediaEmail)")
        return isMediaEmail
    }
    
    /// Check if an email is an internal request (company → media team) vs outgoing (company → external clients)
    /// Returns true if this appears to be an internal request that should be processed
    private func isInternalRequest(from: String?, recipients: [String], mediaEmail: String) -> Bool {
        guard let from = from else { return false }
        
        // Check if sender is from company domain
        let fromDomain = from.split(separator: "@").last.map(String.init) ?? ""
        let isFromCompany = fromDomain.lowercased().contains("grayson")
        
        if !isFromCompany {
            return false // External sender - not an internal request
        }
        
        // Check if all recipients are internal (company domain or media email)
        let mediaEmailLower = mediaEmail.lowercased()
        let allRecipientsInternal = recipients.allSatisfy { recipient in
            let recipientDomain = recipient.split(separator: "@").last.map(String.init) ?? ""
            return recipientDomain.lowercased().contains("grayson") || recipient.lowercased() == mediaEmailLower
        }
        
        // If all recipients are internal, this is likely an internal request
        // If there are external recipients, this is likely outgoing
        return allRecipientsInternal
    }
    
    /// Process a media email and create notification
    func processMediaEmailAndCreateNotification(_ message: GmailMessage) async -> Bool {
        // Safety check: Only process unread emails
        guard let labelIds = message.labelIds, labelIds.contains("UNREAD") else {
            emailScanDebug("EmailScanningService: Skipping media email \(message.id) - already marked as read")
            return false
        }
        
        guard let settingsManager = settingsManager else {
            emailScanDebug("EmailScanningService: ❌ Failed to create media file notification for email \(message.id) - settingsManager is nil")
            return false
        }
        let settings = settingsManager.currentSettings
        
        // Check if email is actually sent to media email
        guard checkIfMediaEmail(message, mediaEmail: settings.companyMediaEmail) else {
            emailScanDebug("EmailScanningService: ❌ Failed to create media file notification for email \(message.id) - email is not sent to media email address (\(settings.companyMediaEmail))")
            emailScanDebug("  Recipients: \(message.allRecipients.joined(separator: ", "))")
            return false
        }
        
        let subject = message.subject ?? ""
        let plainBody = message.plainTextBody ?? ""
        let htmlBody = message.htmlBody ?? ""
        
        // For file hosting link detection, we want to check BOTH plain text and HTML
        // because links might be in HTML format even if plain text exists
        let bodyForDetection = !plainBody.isEmpty ? (plainBody + " " + htmlBody) : htmlBody
        let body = !plainBody.isEmpty ? plainBody : htmlBody
        
        emailScanDebug("EmailScanningService: Processing media email \(message.id)")
        emailScanDebug("  Subject: \(subject)")
        emailScanDebug("  Plain body length: \(plainBody.count)")
        emailScanDebug("  HTML body length: \(htmlBody.count)")
        emailScanDebug("  Plain body preview: \(plainBody.prefix(200))")
        emailScanDebug("  HTML body preview: \(htmlBody.prefix(200))")
        emailScanDebug("  Combined body for detection preview: \(bodyForDetection.prefix(300))")
        emailScanDebug("  File hosting whitelist: \(settings.grabbedFileHostingWhitelist)")
        
        // Use rule-based detection for file delivery
        var linkResult: QualificationResult? = nil
        var fileLinks: [String] = []
        let fileLinkDescriptions: [String] = []
        
        // Check if email contains file hosting links using the whitelist from settings
        if linkResult == nil {
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
            if !settings.grabbedFileHostingWhitelist.isEmpty {
                linkResult = qualifier.qualifiesByFileHostingLinksWithDebug(bodyForDetection)
            } else {
                // Fallback case - create a simple result
                let hasLink = FileHostingLinkDetector.containsFileHostingLink(bodyForDetection)
                linkResult = QualificationResult(
                    qualifies: hasLink,
                    reasons: ["Using fallback FileHostingLinkDetector", hasLink ? "✅ Found file hosting link" : "❌ No file hosting link found"],
                    matchedCriteria: hasLink ? ["File hosting link (fallback detector)"] : [],
                    exclusionReasons: []
                )
            }
            
            // Extract file links using regular detector
            if fileLinks.isEmpty {
                fileLinks = FileHostingLinkDetector.extractFileHostingLinks(bodyForDetection)
            }
        }
        
        guard let linkResult = linkResult else {
            emailScanDebug("EmailScanningService: Failed to determine file delivery status")
            return false
        }
        
        // Log detailed debug information
        let separator = String(repeating: "=", count: 80)
        emailScanDebug("\n\(separator)")
        emailScanDebug("📧 FILE DELIVERY NOTIFICATION DEBUG - Email ID: \(message.id)")
        emailScanDebug(separator)
        for reason in linkResult.reasons {
            emailScanDebug(reason)
        }
        if linkResult.qualifies {
            emailScanDebug("\n✅ RESULT: QUALIFIED AS FILE DELIVERY")
            emailScanDebug("  Matched criteria: \(linkResult.matchedCriteria.joined(separator: ", "))")
        } else {
            emailScanDebug("\n❌ RESULT: NOT QUALIFIED")
            if !linkResult.exclusionReasons.isEmpty {
                emailScanDebug("  Exclusion reasons: \(linkResult.exclusionReasons.joined(separator: ", "))")
            }
        }
        emailScanDebug("\(separator)\n")
        
        guard linkResult.qualifies else {
            emailScanDebug("EmailScanningService: Media email \(message.id) does not contain file hosting links from whitelist")
            return false
        }
        
        // File links were already extracted above
        
        await MainActor.run {
            guard let notificationCenter = notificationCenter else {
                print("EmailScanningService: ERROR - notificationCenter is nil when trying to add media notification")
                return
            }
            
            // Try to extract docket number from email (subject or body)
            var extractedDocketNumber: String? = nil
            var extractedJobName: String? = nil
            
            // Try parsing the email to extract docket info
            if let parsed = parser.parseEmail(subject: subject, body: body, from: message.from) {
                // Only use parsed docket if it's valid (not "TBD")
                if isValidDocketNumber(parsed.docketNumber) {
                    extractedDocketNumber = parsed.docketNumber
                    extractedJobName = parsed.jobName
                    emailScanDebug("EmailScanningService: ✅ Extracted docket from file delivery email: \(parsed.docketNumber) - \(parsed.jobName)")
                }
            }
            
            // Create a cleaner message - use subject but truncate if too long, or create a summary
            let cleanMessage: String
            if let docketNum = extractedDocketNumber, let jobName = extractedJobName {
                // If we have docket info, create a clean message
                cleanMessage = "Docket \(docketNum): \(jobName)"
            } else if let docketNum = extractedDocketNumber {
                // Just docket number
                cleanMessage = "Docket \(docketNum)"
            } else if !subject.isEmpty {
                // Use subject but truncate if it's very long (likely contains body text)
                let maxLength = 100
                if subject.count > maxLength {
                    cleanMessage = String(subject.prefix(maxLength)) + "..."
                } else {
                    cleanMessage = subject
                }
            } else {
                cleanMessage = "Files shared via \(settings.companyMediaEmail)"
            }
            
            // Create notification for media files
            let notification = Notification(
                type: .mediaFiles,
                title: "File Delivery Available",
                message: cleanMessage,
                timestamp: Date(),
                status: .pending, // Ensure it's marked as pending
                archivedAt: nil,
                docketNumber: extractedDocketNumber,
                jobName: extractedJobName,
                emailId: message.id,
                sourceEmail: message.from,
                projectManager: nil,
                emailSubject: subject.isEmpty ? nil : subject,
                emailBody: body.isEmpty ? nil : body,
                fileLinks: fileLinks.isEmpty ? nil : fileLinks,
                fileLinkDescriptions: fileLinkDescriptions.isEmpty ? nil : fileLinkDescriptions,
                threadId: message.threadId // Store thread ID for tracking replies
            )
            
            
            emailScanDebug("EmailScanningService: ✅ Adding media file notification for email \(message.id)")
            emailScanDebug("  Notification ID: \(notification.id)")
            emailScanDebug("  Type: \(notification.type)")
            emailScanDebug("  Status: \(notification.status)")
            emailScanDebug("  Title: \(notification.title)")
            emailScanDebug("  Message: \(notification.message)")
            emailScanDebug("  File links found: \(fileLinks.count)")
            for (index, link) in fileLinks.enumerated() {
                emailScanDebug("    Link \(index + 1): \(link)")
            }
            notificationCenter.add(notification)
            emailScanDebug("EmailScanningService: ✅ Notification added. Total notifications: \(notificationCenter.notifications.count)")
            emailScanDebug("  Active notifications: \(notificationCenter.activeNotifications.count)")
            emailScanDebug("  Media file notifications: \(notificationCenter.activeNotifications.filter { $0.type == .mediaFiles }.count)")
        }
        
        return true
    }
    
    /// Store feedback about a notification (for future use)
    /// - Parameters:
    ///   - notificationId: The notification ID
    ///   - rating: 1-5 rating (1 = very wrong, 5 = perfect)
    ///   - wasCorrect: Whether the notification was correct
    ///   - correction: Optional correction text
    ///   - comment: Optional additional feedback
    func provideFeedback(
        for notificationId: UUID,
        rating: Int,
        wasCorrect: Bool,
        correction: String? = nil,
        comment: String? = nil
    ) async {
        // Get email ID from notification to store feedback persistently
        var emailId: String? = nil
        if let notification = notificationCenter?.notifications.first(where: { $0.id == notificationId }) {
            emailId = notification.emailId
        }
        
        // Store feedback persistently
        if let emailId = emailId {
            EmailFeedbackTracker.shared.storeFeedback(
                emailId: emailId,
                wasCorrect: wasCorrect,
                rating: rating,
                correction: correction,
                comment: comment
            )
            
            // Also record as interaction
            let interactionType: InteractionType = wasCorrect ? .feedbackThumbsUp : .feedbackThumbsDown
            EmailFeedbackTracker.shared.recordInteraction(
                emailId: emailId,
                type: interactionType
            )
            print("EmailFeedbackTracker: Stored feedback for email \(emailId)")
        }
    }
    
    /// Parse quota/rate limit error to extract retry time and user-friendly message (legacy - no longer used)
    private func parseQuotaError(_ errorMessage: String) -> (retryAfter: Date, message: String)? {
        // Check if this is a quota/rate limit error
        guard errorMessage.contains("429") ||
              errorMessage.contains("RESOURCE_EXHAUSTED") ||
              errorMessage.contains("quota") ||
              errorMessage.contains("Quota") ||
              errorMessage.contains("rate limit") ||
              errorMessage.contains("Rate limit") else {
            return nil
        }
        
        // Try to extract retry delay from error message
        // Look for patterns like "56.955097883s", "56s", "Please retry in 56.955097883s"
        var retrySeconds: Double = 60.0 // Default to 60 seconds if we can't parse
        
        // Try multiple patterns to extract retry time
        let patterns = [
            "(?:retry|wait|delay).*?(\\d+(?:\\.\\d+)?)\\s*s",  // "retry in 56.95s"
            "Please retry in (\\d+(?:\\.\\d+)?)s",              // "Please retry in 56.95s"
            "(\\d+(?:\\.\\d+)?)s(?!\\w)"                        // Just "56.95s"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: errorMessage, range: NSRange(errorMessage.startIndex..., in: errorMessage)),
               let secondsRange = Range(match.range(at: 1), in: errorMessage) {
                let secondsStr = String(errorMessage[secondsRange])
                if let seconds = Double(secondsStr) {
                    retrySeconds = seconds
                    break
                }
            }
        }
        
        // Calculate retry time (add a small buffer to be safe)
        let retryAfter = Date().addingTimeInterval(retrySeconds + 10.0) // Add 10 second buffer
        
        // Create user-friendly message
        let isFreeTier = errorMessage.contains("free_tier") || errorMessage.contains("FreeTier")
        var message = "API rate limit exceeded"
        if isFreeTier {
            message += " (free tier)"
        }
        message += "."
        
        return (retryAfter: retryAfter, message: message)
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
            
            // Create parser with matcher, metadata manager, and Asana cache manager
            let parser = patterns.isEmpty 
                ? EmailDocketParser(companyNameMatcher: matcher, metadataManager: metadataManager, asanaCacheManager: asanaCacheManager)
                : EmailDocketParser(patterns: patterns, companyNameMatcher: matcher, metadataManager: metadataManager, asanaCacheManager: asanaCacheManager)
            
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
    
    /// Create docket from notification (called when user approves).
    /// If docket was found in Asana, pass effectiveDocketNumber and effectiveJobName from Asana so the folder matches Asana; otherwise uses notification values.
    func createDocketFromNotification(
        _ notification: Notification,
        effectiveDocketNumber: String? = nil,
        effectiveJobName: String? = nil
    ) async throws {
        let docketNumber = effectiveDocketNumber ?? notification.docketNumber
        let jobName = effectiveJobName ?? notification.jobName
        guard let docketNumber = docketNumber,
              let jobName = jobName,
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
                do {
                    try await gmailService.markAsRead(messageId: emailId)
                    emailScanDebug("📧 EmailScanningService: Successfully marked email \(emailId) as read after creating docket")
                } catch {
                    emailScanDebug("📧 EmailScanningService: ❌ Failed to mark email \(emailId) as read: \(error.localizedDescription)")
                    print("📧 EmailScanningService: Error details: \(error)")
                }
            } else {
                emailScanDebug("📧 EmailScanningService: ⚠️ Cannot mark email as read - notification has no emailId")
            }
            
            // Don't update status to completed here - let the caller handle it
            // This prevents the notification from disappearing before Simian creation completes
            // await MainActor.run {
            //     notificationCenter?.updateStatus(notification, to: .completed, emailScanningService: self)
            // }
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
        // Also load processed thread IDs
        if let data = UserDefaults.standard.data(forKey: processedThreadsKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            processedThreadIds = ids
        }
    }

    /// Load persisted rate limit retry-after; only apply if still in the future
    private func loadRateLimitRetryAfter() {
        let stored = UserDefaults.standard.double(forKey: rateLimitRetryAfterKey)
        guard stored > 0 else { return }
        let date = Date(timeIntervalSince1970: stored)
        if date > Date() {
            lastRateLimitRetryAfter = date
        } else {
            UserDefaults.standard.removeObject(forKey: rateLimitRetryAfterKey)
        }
    }

    /// Persist rate limit retry-after so it survives app restart
    private func saveRateLimitRetryAfter(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: rateLimitRetryAfterKey)
    }

    /// Clear in-memory and persisted rate limit so we don't block after cooldown has passed or after a successful scan
    private func clearRateLimitRetryAfter() {
        lastRateLimitRetryAfter = nil
        UserDefaults.standard.removeObject(forKey: rateLimitRetryAfterKey)
    }

    /// Call when the countdown has reached 0 so the banner disappears without requiring a new scan
    func clearExpiredRateLimitIfNeeded() {
        guard let retryAfter = lastRateLimitRetryAfter, retryAfter <= Date() else { return }
        clearRateLimitRetryAfter()
    }

    /// Save processed email IDs to UserDefaults
    private func saveProcessedEmailIds() {
        if let data = try? JSONEncoder().encode(processedEmailIds) {
            UserDefaults.standard.set(data, forKey: processedEmailsKey)
        }
        // Also save processed thread IDs
        if let data = try? JSONEncoder().encode(processedThreadIds) {
            UserDefaults.standard.set(data, forKey: processedThreadsKey)
        }
    }

    /// Mark email as processed (used for tracking)
    func markEmailAsProcessed(messageId: String) {
        processedEmailIds.insert(messageId)
        saveProcessedEmailIds()
    }

    /// Mark thread as processed (prevents duplicate processing of same email thread)
    func markThreadAsProcessed(threadId: String) {
        processedThreadIds.insert(threadId)
        saveProcessedEmailIds()
    }

    /// Check if a thread has already been processed
    func isThreadProcessed(threadId: String) -> Bool {
        return processedThreadIds.contains(threadId)
    }

    /// Clear processed email IDs (useful for re-processing)
    func clearProcessedEmails() {
        processedEmailIds.removeAll()
        processedThreadIds.removeAll()
        saveProcessedEmailIds()
    }
    
    /// Clean up old processed email/thread IDs to prevent unbounded growth
    /// Keeps only IDs from emails processed within the last N days
    /// This prevents memory issues from tracking thousands of old emails
    /// Note: We can't track exact timestamps per ID, so we use a size-based cleanup
    /// that keeps the most recent entries (assuming newer emails are added later)
    func cleanupOldProcessedIds(maxEntries: Int = 5000) {
        // If sets are within reasonable size, no cleanup needed
        let totalEntries = processedEmailIds.count + processedThreadIds.count
        guard totalEntries > maxEntries else {
            return
        }
        
        // Calculate how many to keep (keep 80% of max to avoid frequent cleanups)
        let keepCount = Int(Double(maxEntries) * 0.8)
        
        // For processedEmailIds, keep the most recent entries
        // Since Set doesn't preserve order, we'll keep a subset
        // In practice, this is a simple size limit - we keep the first N entries
        // A more sophisticated approach would track timestamps, but that requires
        // changing the data structure
        if processedEmailIds.count > keepCount / 2 {
            // Keep only a subset - convert to array, take first N, rebuild set
            let idsArray = Array(processedEmailIds.prefix(keepCount / 2))
            processedEmailIds = Set(idsArray)
        }
        
        // Same for processedThreadIds
        if processedThreadIds.count > keepCount / 2 {
            let idsArray = Array(processedThreadIds.prefix(keepCount / 2))
            processedThreadIds = Set(idsArray)
        }
        
        // Save the cleaned-up sets
        saveProcessedEmailIds()
        
        emailScanDebug("EmailScanningService: Cleaned up processed IDs (kept \(processedEmailIds.count) emails, \(processedThreadIds.count) threads)")
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
        
        // Clear expired cooldown so banner goes away; never block scan — user can always try; Google returns 429 if still limited
        let now = Date()
        if let retryAfter = lastRateLimitRetryAfter, retryAfter <= now {
            clearRateLimitRetryAfter()
        }
        
        do {
            let (query, newDocketLabelId) = await newDocketScanQueryAndLabelId()
            emailScanDebug("EmailScanningService: Scanning Gmail for new docket notifications — query: \(query)")
            let messageRefs = try await gmailService.fetchEmails(
                query: query,
                maxResults: 50
            )
            
            emailScanDebug("EmailScanningService: Found \(messageRefs.count) message(s) matching query")
            
            guard !messageRefs.isEmpty else {
                emailScanDebug("EmailScanningService: No messages matched the scan query")
                return
            }
            
            // Get full email messages
            let messages = try await gmailService.getEmails(messageReferences: messageRefs)
            emailScanDebug("EmailScanningService: Fetched \(messages.count) full email messages")
            
            let candidateMessages = messages.filter { isNewDocketScanCandidate($0, newDocketLabelId: newDocketLabelId) }
            emailScanDebug("EmailScanningService: \(candidateMessages.count) scan candidates (unread + '\(Self.newDocketGmailUserLabelName)' label) out of \(messages.count) fetched")
            
            // Don't filter out replies/forwards - let the parser determine if they contain new docket info
            let initialEmails = candidateMessages
            emailScanDebug("EmailScanningService: Processing \(initialEmails.count) candidate emails (including replies/forwards - parser will determine relevance)")
            
            let existingEmailIds = await MainActor.run {
                return forceRescan ? Set<String>() : Set(notificationCenter.notifications.compactMap { $0.emailId })
            }
            emailScanDebug("EmailScanningService: \(existingEmailIds.count) emails already have notifications (forceRescan: \(forceRescan))")
            
            var createdCount = 0
            var skippedCount = 0
            var failedCount = 0
            var interactedCount = 0
            
            for message in initialEmails {
                if !forceRescan && existingEmailIds.contains(message.id) {
                    skippedCount += 1
                    continue
                }
                
                let hasInteracted = await MainActor.run {
                    EmailFeedbackTracker.shared.hasAnyInteraction(emailId: message.id)
                }
                if hasInteracted {
                    interactedCount += 1
                    emailScanDebug("EmailScanningService: ⏭️  Skipping email \(message.id) - already interacted with")
                    continue
                }
                
                if forceRescan && existingEmailIds.contains(message.id) {
                    let existingNotification = await MainActor.run {
                        return notificationCenter.notifications.first(where: { $0.emailId == message.id })
                    }
                    if let existingNotification = existingNotification {
                        await notificationCenter.remove(_: existingNotification, emailScanningService: self)
                    }
                }
                
                emailScanDebug("EmailScanningService: Email \(message.id) - attempting to process as new docket email...")
                let isNewDocket = await processEmailAndCreateNotification(message, newDocketLabelId: newDocketLabelId)
                
                if isNewDocket {
                    createdCount += 1
                    emailScanDebug("EmailScanningService: ✅ Created new docket notification for email \(message.id)")
                } else {
                    failedCount += 1
                    emailScanDebug("EmailScanningService: Email \(message.id) - not a new docket, skipping (media files and requests are no longer processed)")
                }
            }
            
            emailScanDebug("EmailScanningService: Summary - Created: \(createdCount), Skipped: \(skippedCount), Failed: \(failedCount), Interacted: \(interactedCount)")
            
            lastScanTime = Date()
            clearRateLimitRetryAfter()
            
            if let grabbedService = notificationCenter.grabbedIndicatorService {
                emailScanDebug("EmailScanningService: Triggering immediate grabbed reply check...")
                Task {
                    await grabbedService.checkForGrabbedReplies()
                }
            }
            
        } catch {
            print("EmailScanningService: Error scanning unread emails: \(error.localizedDescription)")
            let errorMessage = error.localizedDescription
            if let retryAfter = parseRetryAfterDate(from: errorMessage) {
                lastRateLimitRetryAfter = retryAfter
                saveRateLimitRetryAfter(retryAfter)
                print("EmailScanningService: Rate limited - will retry after \(retryAfter)")
            }
            DispatchQueue.main.async {
                self.lastError = errorMessage
            }
        }
    }
    
    // MARK: - Multi-Docket Parsing Helpers
    
    /// Parse a docket number string that may contain multiple docket numbers
    /// Handles formats like: "25493, 25495", "25493/25495", "25493 and 25495", "25493 & 25495"
    /// Valid docket numbers: exactly 5 digits, optionally with "-US" suffix
    private func parseMultipleDocketNumbers(_ docketString: String) -> [String] {
        // Normalize the string - replace separators with comma
        let normalizedString = docketString
            .replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " & ", with: ",")
            .replacingOccurrences(of: "&", with: ",")
            .replacingOccurrences(of: "/", with: ",")
            .replacingOccurrences(of: ";", with: ",")
        
        // Split by comma
        let parts = normalizedString.split(separator: ",").map { 
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Filter to only valid docket numbers (5 digits, optionally with -US suffix)
        let validDockets = parts.filter { isValidDocketNumber($0) }
        
        return validDockets
    }
    
    /// Validate a docket number: must be exactly 5 digits with valid year prefix, optionally with -XX country suffix (e.g. -US, -CA)
    private func isValidDocketNumber(_ docketNumber: String) -> Bool {
        let trimmed = docketNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip optional -XX country suffix (e.g. -US, -CA); suffix must be 2-3 uppercase letters
        let baseNumber: String
        if let dashIndex = trimmed.firstIndex(of: "-"),
           dashIndex > trimmed.startIndex,
           let suffixStart = trimmed.index(dashIndex, offsetBy: 1, limitedBy: trimmed.endIndex),
           trimmed.distance(from: suffixStart, to: trimmed.endIndex) >= 2,
           trimmed.distance(from: suffixStart, to: trimmed.endIndex) <= 3,
           trimmed[suffixStart...].allSatisfy({ $0.isLetter }) {
            baseNumber = String(trimmed[..<dashIndex])
        } else {
            baseNumber = trimmed
        }
        
        // Must be exactly 5 digits
        guard baseNumber.count == 5 else { return false }
        guard baseNumber.allSatisfy({ $0.isNumber }) else { return false }
        
        // Validate year prefix (must start with current year or next year)
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let currentYearLastTwo = currentYear % 100
        let nextYearLastTwo = (currentYearLastTwo + 1) % 100
        
        guard let yearPrefix = Int(String(baseNumber.prefix(2))) else { return false }
        guard yearPrefix == currentYearLastTwo || yearPrefix == nextYearLastTwo else {
            return false
        }
        
        return true
    }
    
    /// Create a notification for a single docket number
    @MainActor
    private func createNotificationForDocket(
        docketNumber: String,
        jobName: String,
        message: GmailMessage,
        subject: String,
        body: String,
        originalSenderEmail: String? = nil
    ) {
        guard let notificationCenter = notificationCenter else {
            print("EmailScanningService: ERROR - notificationCenter is nil when trying to add notification")
            return
        }
        
        // VALIDATE docket number before creating notification
        if !isValidDocketNumber(docketNumber) {
            emailScanDebug("EmailScanningService: ❌ REJECTED: Invalid docket number format: '\(docketNumber)' (must be exactly 5 digits, optionally with -US suffix)")
            return
        }
        
        // Work Picture may already list this docket — still add notification; duplicate UI comes from checkDuplicatesForNotification.
        if let manager = mediaManager,
           manager.dockets.contains("\(docketNumber)_\(jobName)") {
            emailScanDebug("EmailScanningService: Work Picture already has \(docketNumber)_\(jobName) — creating notification anyway")
        }
        
        // Check if notification already exists for this docket + email/thread combo
        // Also check threadId to prevent duplicates from replies in the same thread
        let existingNotification = notificationCenter.notifications.first { notification in
            // Check by emailId OR threadId (either match means duplicate)
            let sameEmail = notification.emailId == message.id
            let sameThread = notification.threadId != nil && notification.threadId == message.threadId
            let sameDocket = notification.docketNumber == docketNumber
            return sameDocket && (sameEmail || sameThread)
        }

        if existingNotification != nil {
            let threadIdDisplay = message.threadId.isEmpty ? "nil" : message.threadId
            emailScanDebug("EmailScanningService: Notification already exists for docket \(docketNumber) from email/thread \(message.id)/\(threadIdDisplay)")
            return
        }

        // Use original sender email if provided, otherwise fall back to current message sender
        let sourceEmail = originalSenderEmail ?? message.from ?? ""

        let messageText = "Docket \(docketNumber): \(jobName)"
        let emailSubjectToStore = subject.isEmpty ? nil : subject
        let emailBodyToStore = body.isEmpty ? nil : body

        let notification = Notification(
            type: .newDocket,
            title: "New Docket Detected",
            message: messageText,
            docketNumber: docketNumber,
            jobName: jobName,
            emailId: message.id,
            sourceEmail: sourceEmail,
            emailSubject: emailSubjectToStore,
            emailBody: emailBodyToStore,
            threadId: message.threadId  // Track thread to prevent duplicates
        )
        
        
        notificationCenter.add(notification)
        emailScanDebug("EmailScanningService: ✅ Created notification for docket \(docketNumber) - \(jobName)")
        totalDocketsCreated += 1
        
        // Auto-scan for duplicates (Work Picture folder and Simian project)
        Task {
            await checkDuplicatesForNotification(notification)
        }
        
        // Show system notification
        NotificationService.shared.showNewDocketNotification(
            docketNumber: docketNumber,
            jobName: jobName
        )
    }
    
    /// Check for existing Work Picture folder and Simian project when notification is added
    private func checkDuplicatesForNotification(_ notification: Notification) async {
        guard let docketNumber = notification.docketNumber, docketNumber != "TBD",
              let jobName = notification.jobName else {
            return
        }
        
        emailScanDebug("📋 [EmailScanningService] Auto-scanning for duplicates: \(docketNumber)_\(jobName)")
        
        var workPictureExists = false
        var simianExists = false
        
        // Check Work Picture folder
        if let mediaManager = mediaManager {
            let docketName = "\(docketNumber)_\(jobName)"
            workPictureExists = mediaManager.dockets.contains(docketName)
            if workPictureExists {
                emailScanDebug("📋 [EmailScanningService] ✅ Found existing Work Picture folder: \(docketName)")
            }
        }
        
        // Check Simian project
        if let simianService = simianService,
           let settings = settingsManager?.currentSettings,
           settings.simianEnabled,
           simianService.isConfigured {
            do {
                simianExists = try await simianService.projectExists(docketNumber: docketNumber, jobName: jobName)
                if simianExists {
                    emailScanDebug("📋 [EmailScanningService] ✅ Found existing Simian project: \(docketNumber)_\(jobName)")
                }
            } catch {
                emailScanDebug("📋 [EmailScanningService] ⚠️ Error checking Simian: \(error.localizedDescription)")
            }
        }
        
        // Update notification with duplicate info using public methods
        if workPictureExists {
            await MainActor.run {
                if let nc = notificationCenter,
                   let currentNotification = nc.notifications.first(where: { $0.id == notification.id }) {
                    nc.markAsInWorkPicture(currentNotification, createdByUs: false)
                    emailScanDebug("📋 [EmailScanningService] Marked notification as pre-existing in Work Picture")
                }
            }
        }
        
        if simianExists {
            await MainActor.run {
                if let nc = notificationCenter,
                   let currentNotification = nc.notifications.first(where: { $0.id == notification.id }) {
                    nc.markAsInSimian(currentNotification, createdByUs: false)
                    emailScanDebug("📋 [EmailScanningService] Marked notification as pre-existing in Simian")
                }
            }
        }
    }
}

