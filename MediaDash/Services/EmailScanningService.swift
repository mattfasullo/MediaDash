import Foundation
import Combine
import SwiftUI
import CodeMind

/// Service for scanning emails and creating notifications for new dockets
@MainActor
class EmailScanningService: ObservableObject {
    @Published var isScanning = false
    @Published var isEnabled = false
    @Published var lastScanTime: Date?
    @Published var totalDocketsCreated = 0
    @Published var lastError: String?
    
    // CodeMind status tracking
    @Published var codeMindStatus: CodeMindStatus = .unavailable
    
    enum CodeMindStatus: Equatable {
        case working          // CodeMind is active and working
        case disabled         // CodeMind is disabled/not configured
        case error(String)    // CodeMind failed with error message
        case quotaExceeded(retryAfter: Date, userMessage: String)  // Quota/rate limit exceeded with retry time
        case unavailable      // CodeMind not available (no API key, etc.)
        
        static func == (lhs: CodeMindStatus, rhs: CodeMindStatus) -> Bool {
            switch (lhs, rhs) {
            case (.working, .working),
                 (.disabled, .disabled),
                 (.unavailable, .unavailable):
                return true
            case (.error(let lhsMessage), .error(let rhsMessage)):
                return lhsMessage == rhsMessage
            case (.quotaExceeded(let lhsRetry, let lhsMessage), .quotaExceeded(let rhsRetry, let rhsMessage)):
                // Compare messages and retry times (within 1 second tolerance for retry time)
                return lhsMessage == rhsMessage && abs(lhsRetry.timeIntervalSince(rhsRetry)) < 1.0
            default:
                return false
            }
        }
        
        var isActive: Bool {
            switch self {
            case .working: return true
            default: return false
            }
        }
        
        var displayText: String {
            switch self {
            case .working:
                return "CodeMind Active"
            case .disabled:
                return "CodeMind Disabled"
            case .error(let message):
                return "CodeMind Error: \(message)"
            case .quotaExceeded(let retryAfter, _):
                let timeUntil = retryAfter.timeIntervalSinceNow
                if timeUntil > 0 {
                    let minutes = Int(timeUntil) / 60
                    let seconds = Int(timeUntil) % 60
                    if minutes > 0 {
                        return "Rate Limit: Available in \(minutes)m \(seconds)s"
                    } else {
                        return "Rate Limit: Available in \(seconds)s"
                    }
                } else {
                    return "Rate Limit: Available now"
                }
            case .unavailable:
                return "CodeMind Unavailable"
            }
        }
    }
    
    var gmailService: GmailService
    private var parser: EmailDocketParser
    private var scanningTask: Task<Void, Never>?
    private var patternSyncTask: Task<Void, Never>?
    private var processedEmailIds: Set<String> = []
    private let processedEmailsKey = "gmail_processed_email_ids"
    
    // CodeMind AI classifier for enhanced email understanding
    private var codeMindClassifier: CodeMindEmailClassifier?
    private var useCodeMind: Bool = false
    // Store CodeMind responses for feedback (keyed by notification ID)
    private var codeMindResponses: [UUID: CodeMindResponse] = [:]
    
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
        
        // Check if Gmail is already authenticated and add to whitelist
        Task { @MainActor in
            await checkAndAddGmailToWhitelist()
        }
        
        // Initialize CodeMind classifier if API key is available
        Task { @MainActor in
            await initializeCodeMindIfAvailable()
        }
    }
    
    /// Check if Gmail is authenticated and add email to Grayson whitelist
    private func checkAndAddGmailToWhitelist() async {
        guard gmailService.isAuthenticated else { return }
        
        // Check if we have a saved email
        if let savedEmail = UserDefaults.standard.string(forKey: "gmail_connected_email"),
           savedEmail.lowercased().hasSuffix("@graysonmusicgroup.com") {
            _ = GraysonEmployeeWhitelist.shared.addEmail(savedEmail)
            print("✅ Added existing Gmail email \(savedEmail) to Grayson employee whitelist")
            return
        }
        
        // Try to fetch email from Gmail API
        do {
            let email = try await gmailService.getUserEmail()
            if email.lowercased().hasSuffix("@graysonmusicgroup.com") {
                _ = GraysonEmployeeWhitelist.shared.addEmail(email)
                UserDefaults.standard.set(email, forKey: "gmail_connected_email")
                print("✅ Fetched and added Gmail email \(email) to Grayson employee whitelist")
            }
        } catch {
            // Silently fail - email will be added when user connects Gmail in settings
        }
    }
    
    /// Initialize CodeMind classifier if API key is available
    private func initializeCodeMindIfAvailable() async {
        // Get provider from settings or default to Gemini
        let provider = settingsManager?.currentSettings.codeMindProvider ?? CodeMindConfig.getDefaultProvider()
        
        // Get API key for the selected provider
        let apiKey = CodeMindConfig.getAPIKey(for: provider) ??
                     (provider == "gemini" ? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] : nil) ??
                     (provider == "grok" ? ProcessInfo.processInfo.environment["GROK_API_KEY"] : nil)
        
        guard let key = apiKey else {
            let providerName = provider.capitalized
            print("CodeMindEmailClassifier: No \(providerName) API key found. Add your API key in Settings > CodeMind AI to enable AI classification.")
            codeMindStatus = .unavailable
            useCodeMind = false
            return
        }
        
        do {
            let classifier = CodeMindEmailClassifier()
            try await classifier.initialize(apiKey: key, provider: provider)
            self.codeMindClassifier = classifier
            self.useCodeMind = true
            codeMindStatus = .working
            
            // Configure pattern bridge to sync learned patterns to rule-based patterns
            if let settingsManager = settingsManager {
                CodeMindPatternBridge.shared.configure(
                    settingsManager: settingsManager,
                    codeMindClassifier: classifier
                )
            }
            
            print("CodeMindEmailClassifier: ✅ Initialized and enabled for email classification")
        } catch {
            let errorMessage = error.localizedDescription
            print("CodeMindEmailClassifier: Failed to initialize: \(errorMessage)")
            // Parse error to check if it's a quota/rate limit error
            if let quotaInfo = parseQuotaError(errorMessage) {
                codeMindStatus = .quotaExceeded(retryAfter: quotaInfo.retryAfter, userMessage: quotaInfo.message)
            } else {
                codeMindStatus = .error(errorMessage)
            }
            useCodeMind = false
            codeMindClassifier = nil
        }
    }
    
    /// Re-initialize CodeMind if quota retry time has expired
    func reinitializeCodeMindIfNeeded() async {
        // Only re-initialize if we're in quota exceeded state and the retry time has passed
        if case .quotaExceeded(let retryAfter, _) = codeMindStatus {
            let timeUntil = retryAfter.timeIntervalSinceNow
            if timeUntil <= 0 {
                // Retry time has expired - attempt to re-initialize
                print("CodeMindEmailClassifier: Quota retry time expired, attempting to re-initialize...")
                await initializeCodeMindIfAvailable()
            }
        }
    }
    
    /// Enable or disable CodeMind classification
    func setUseCodeMind(_ enabled: Bool) {
        useCodeMind = enabled && codeMindClassifier != nil
        if !enabled {
            codeMindStatus = .disabled
        } else if codeMindClassifier != nil {
            codeMindStatus = .working
        } else {
            codeMindStatus = .unavailable
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
                // Configure CodeMind shared cache (uses same directory, different filename)
                CodeMindSharedCacheManager.shared.configure(sharedCacheURL: sharedCacheURL)
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
        
        // Start periodic pattern syncing (every 30 minutes) if CodeMind is active
        if codeMindStatus.isActive {
            startPeriodicPatternSync()
        }
    }
    
    /// Stop automatic email scanning
    func stopScanning() {
        isScanning = false
        isEnabled = false
        scanningTask?.cancel()
        scanningTask = nil
        patternSyncTask?.cancel()
        patternSyncTask = nil
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
        print("🔍 EmailScanningService.scanNow() called")
        CodeMindLogger.shared.log(.info, "Email scanning started", category: .classification, metadata: [
            "forceRescan": String(forceRescan)
        ])
        
        guard let settings = settingsManager?.currentSettings, settings.gmailEnabled else {
            let error = "Gmail integration is not enabled"
            print("❌ EmailScanningService: \(error)")
            CodeMindLogger.shared.log(.warning, error, category: .classification)
            DispatchQueue.main.async {
                self.lastError = error
            }
            return
        }
        
        guard gmailService.isAuthenticated else {
            let error = "Gmail is not authenticated"
            print("❌ EmailScanningService: \(error)")
            CodeMindLogger.shared.log(.warning, error, category: .classification)
            DispatchQueue.main.async {
                self.lastError = error
            }
            return
        }
        
        print("✅ EmailScanningService: Gmail is enabled and authenticated - proceeding with scan")
        CodeMindLogger.shared.log(.info, "Gmail authenticated, starting email query", category: .classification)
        
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
            print("EmailScanningService: 🔍 Starting scan...")
            print("  📧 Gmail enabled: \(settings.gmailEnabled)")
            print("  🔑 Gmail authenticated: \(gmailService.isAuthenticated)")
            print("  🔎 Query: \(query)")
            print("  📋 Search terms: \(settings.gmailSearchTerms.isEmpty ? "none (using default)" : settings.gmailSearchTerms.joined(separator: ", "))")
            
            CodeMindLogger.shared.log(.info, "Starting email scan", category: .classification, metadata: [
                "query": query,
                "gmailEnabled": String(settings.gmailEnabled),
                "gmailAuthenticated": String(gmailService.isAuthenticated)
            ])
            
            // Fetch emails matching query
            let messageRefs = try await gmailService.fetchEmails(
                query: query,
                maxResults: 50
            )
            
            CodeMindLogger.shared.log(.info, "Email query completed", category: .classification, metadata: [
                "emailsFound": String(messageRefs.count)
            ])
            
            print("  📨 Found \(messageRefs.count) email references matching query")
            
            // Get full email messages
            let messages = try await gmailService.getEmails(messageReferences: messageRefs)
            
            print("  📦 Retrieved \(messages.count) full email messages")
            
            // Filter to only unread emails (double-check labelIds)
            let unreadMessages = messages.filter { message in
                guard let labelIds = message.labelIds else { return false }
                return labelIds.contains("UNREAD")
            }
            
            print("  ✅ \(unreadMessages.count) are unread (filtered out \(messages.count - unreadMessages.count) already-read emails)")
            
            // Log sample of unread emails for debugging
            if !unreadMessages.isEmpty {
                print("  📝 Sample unread emails:")
                for (index, message) in unreadMessages.prefix(5).enumerated() {
                    let subject = message.subject ?? "(no subject)"
                    let from = message.from ?? "(no sender)"
                    print("    \(index + 1). Subject: \"\(subject)\" | From: \(from)")
                }
            }
            
            // Filter out replies and forwards (only process initial emails)
            let initialEmails = unreadMessages.filter { message in
                !isReplyOrForward(message)
            }
            
            let replyForwardCount = unreadMessages.count - initialEmails.count
            print("  📬 \(initialEmails.count) are initial emails (filtered out \(replyForwardCount) replies/forwards)")
            
            // Filter out already processed emails (unless force rescan)
            let newMessages = initialEmails.filter { 
                forceRescan || !processedEmailIds.contains($0.id) 
            }
            
            let alreadyProcessedCount = initialEmails.count - newMessages.count
            print("  🆕 \(newMessages.count) are new (not yet processed)")
            if alreadyProcessedCount > 0 {
                print("  ⏭️  Skipped \(alreadyProcessedCount) already-processed emails")
            }
            
            // Parse and create notifications (don't auto-create dockets)
            var notificationCount = 0
            var processedCount = 0
            var rejectedCount = 0
            
            for message in newMessages {
                processedCount += 1
                let subject = message.subject ?? "(no subject)"
                let from = message.from ?? "(no sender)"
                print("  🔄 Processing email \(processedCount)/\(newMessages.count): \"\(subject)\" from \(from)")
                
                if await processEmailAndCreateNotification(message) {
                    notificationCount += 1
                    print("    ✅ Created notification")
                    // Mark email as processed (so we don't create duplicate notifications)
                    _ = await MainActor.run {
                        processedEmailIds.insert(message.id)
                    }
                } else {
                    rejectedCount += 1
                    print("    ❌ Rejected (no notification created)")
                }
            }
            
            // Save processed email IDs
            saveProcessedEmailIds()
            
            // Print diagnostic summary
            print("EmailScanningService: 📊 Scan Summary:")
            print("  📧 Total emails found: \(messageRefs.count)")
            print("  ✅ Unread: \(unreadMessages.count)")
            print("  📬 Initial (not reply/forward): \(initialEmails.count)")
            print("  🆕 New (not processed): \(newMessages.count)")
            print("  ✅ Notifications created: \(notificationCount)")
            print("  ❌ Rejected: \(rejectedCount)")
            
            if notificationCount == 0 && newMessages.count > 0 {
                print("  ⚠️  WARNING: No notifications created despite \(newMessages.count) new emails!")
                print("     This likely means emails are being rejected by CodeMind or the parser.")
                print("     Check CodeMind debugger for detailed classification logs.")
            }
            
            // Use DispatchQueue to avoid SwiftUI view update cycle conflicts
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    self.lastScanTime = Date()
                    self.isScanning = false
                    continuation.resume()
                }
            }
            
        } catch {
            let errorMessage = error.localizedDescription
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    self.lastError = errorMessage
                    self.isScanning = false
                    continuation.resume()
                }
            }
        }
    }
    
    /// Process a single email and create notification (don't auto-create docket)
    func processEmailAndCreateNotification(_ message: GmailMessage) async -> Bool {
        // Safety check: Only process unread emails
        guard let labelIds = message.labelIds, labelIds.contains("UNREAD") else {
            print("    ❌ REJECTED: Email already marked as read")
            return false
        }
        
        // Use parser with custom patterns if configured
        guard let settingsManager = settingsManager else {
            print("    ❌ REJECTED: Settings manager is nil")
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
        
        // Try CodeMind classification first if enabled
        var parsedDocket: ParsedDocket? = nil
        var codeMindMetadata: CodeMindClassificationMetadata? = nil
        var codeMindResponse: CodeMindResponse? = nil
        
        // Check if we should skip CodeMind based on patterns (but NOT based on parser confidence)
        // We want CodeMind to run even when parser is confident, so it can catch false positives
        // Low confidence CodeMind results will go to "For Review" section for user voting
        var shouldSkipCodeMind = false
        var skipReason: String? = nil
        
        // Track if CodeMind is available but was skipped (for feedback purposes)
        let codeMindAvailable = useCodeMind && codeMindClassifier != nil
        
        // 1. Check skip patterns (subject/body patterns that should skip CodeMind)
        // These are explicit patterns the user has configured to skip CodeMind
        let skipPatterns = currentSettings.codeMindSkipPatterns
        if !skipPatterns.isEmpty {
            let combinedText = "\(subject)\n\(body)".lowercased()
            for pattern in skipPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   regex.firstMatch(in: combinedText, range: NSRange(combinedText.startIndex..., in: combinedText)) != nil {
                    shouldSkipCodeMind = true
                    skipReason = "Matched skip pattern: \(pattern)"
                    print("    ⏭️  SKIPPING CodeMind: \(skipReason ?? "pattern match")")
                    break
                }
            }
        }
        
        // 2. Check if parser can parse (but DON'T skip CodeMind - use parser result as fallback)
        // CodeMind will still run to validate and catch false positives
        // If CodeMind has low confidence, notification will go to "For Review" for user voting
        if !shouldSkipCodeMind {
            if let confidentParse = parser.canParseWithHighConfidence(subject: subject, body: body, from: message.from) {
                // Use parser result as initial fallback, but still run CodeMind to validate
                parsedDocket = confidentParse
                print("    ✅ Parser found potential docket: \(confidentParse.docketNumber) - \(confidentParse.jobName)")
                print("    🤖 Still running CodeMind to validate and catch false positives...")
            }
        }
        
        // If CodeMind was skipped due to skip patterns, create metadata for feedback
        if shouldSkipCodeMind && codeMindMetadata == nil && codeMindAvailable {
            codeMindMetadata = CodeMindClassificationMetadata(
                wasUsed: false,
                confidence: 0.0,
                reasoning: skipReason,
                classificationType: "newDocket",
                extractedData: nil
            )
        }
        
        // Debug: Log why CodeMind might not be used
        if !useCodeMind {
            print("EmailScanningService: ⚠️ CodeMind not used: useCodeMind=false (status: \(codeMindStatus))")
        } else if shouldSkipCodeMind {
            print("EmailScanningService: ⚠️ CodeMind not used: skipped (\(skipReason ?? "unknown reason"))")
        } else if codeMindClassifier == nil {
            print("EmailScanningService: ⚠️ CodeMind not used: classifier is nil (status: \(codeMindStatus))")
        }
        
        // Only use CodeMind if we haven't skipped it
        if useCodeMind && !shouldSkipCodeMind, let classifier = codeMindClassifier {
            do {
                print("EmailScanningService: 🤖 Using CodeMind to classify email...")
                print("EmailScanningService: CodeMind status: useCodeMind=\(useCodeMind), shouldSkipCodeMind=\(shouldSkipCodeMind), classifier=exists")
                CodeMindLogger.shared.log(.info, "Starting CodeMind classification for new docket email", category: .classification, metadata: [
                    "subject": subject,
                    "from": message.from ?? "(unknown)",
                    "bodyLength": String(body.count)
                ])
                let result = try await classifier.classifyNewDocketEmail(
                    subject: message.subject,
                    body: body,
                    from: message.from,
                    threadId: message.threadId,
                    gmailService: gmailService
                )
                let classification = result.classification
                codeMindResponse = result.response
                
                print("CodeMind Classification Result:")
                print("  Is New Docket: \(classification.isNewDocket)")
                print("  Confidence: \(classification.confidence)")
                print("  Docket Number: \(classification.docketNumber ?? "none")")
                print("  Job Name: \(classification.jobName ?? "none")")
                print("  Reasoning: \(classification.reasoning)")
                
                // Store classification metadata for feedback
                var extractedData: [String: String] = [:]
                if let docketNum = classification.docketNumber {
                    extractedData["docketNumber"] = docketNum
                }
                if let jobName = classification.jobName {
                    extractedData["jobName"] = jobName
                }
                codeMindMetadata = CodeMindClassificationMetadata(
                    wasUsed: true,
                    confidence: classification.confidence,
                    reasoning: classification.reasoning,
                    classificationType: "newDocket",
                    extractedData: extractedData.isEmpty ? nil : extractedData
                )
                
                // Use CodeMind's classification - create notifications even for low confidence
                // Low confidence notifications will automatically go to "For Review" section for user voting
                if classification.isNewDocket {
                    if let jobName = classification.jobName {
                        // If we have a docket number, process it (including multiple dockets)
                        if let docketNum = classification.docketNumber {
                            // Check for multiple docket numbers (comma, slash, or "and" separated)
                            let multipleDockets = parseMultipleDocketNumbers(docketNum)
                            
                            if multipleDockets.count > 1 {
                                // Multiple dockets detected - create notifications for each
                                print("EmailScanningService: ✅ CodeMind detected \(multipleDockets.count) docket numbers: \(multipleDockets)")
                                
                                await MainActor.run {
                                    for docket in multipleDockets {
                                        createNotificationForDocket(
                                            docketNumber: docket,
                                            jobName: jobName,
                                            message: message,
                                            subject: subject,
                                            body: body,
                                            classification: classification,
                                            codeMindMetadata: codeMindMetadata
                                        )
                                    }
                                }
                                return true // All notifications created
                            } else {
                                // Single docket - use normal flow
                                parsedDocket = ParsedDocket(
                                    docketNumber: multipleDockets.first ?? docketNum,
                                    jobName: jobName,
                                    sourceEmail: message.from ?? "",
                                    confidence: classification.confidence,
                                    rawData: [
                                        "codeMindReasoning": classification.reasoning,
                                        "extractedMetadata": classification.extractedMetadata as Any
                                    ]
                                )
                                if classification.confidence < 0.7 {
                                    print("EmailScanningService: ⚠️ CodeMind extracted docket but has low confidence (\(Int(classification.confidence * 100))%) - will go to 'For Review'")
                                } else {
                                print("EmailScanningService: ✅ CodeMind successfully extracted docket info")
                                }
                            }
                        } else {
                            // CodeMind identified new docket with job name but no docket number
                            // Create notification with "TBD" as docket number
                            print("EmailScanningService: ✅ CodeMind identified new docket with job name but no docket number - using 'TBD'")
                            parsedDocket = ParsedDocket(
                                docketNumber: "TBD",
                                jobName: jobName,
                                sourceEmail: message.from ?? "",
                                confidence: classification.confidence,
                                rawData: [
                                    "codeMindReasoning": classification.reasoning,
                                    "extractedMetadata": classification.extractedMetadata as Any,
                                    "docketNumberMissing": true
                                ]
                            )
                            if classification.confidence < 0.7 {
                                print("EmailScanningService: ⚠️ CodeMind identified docket but has low confidence (\(Int(classification.confidence * 100))%) - will go to 'For Review'")
                            } else {
                            print("EmailScanningService: ✅ CodeMind successfully extracted job name, docket number will be 'TBD'")
                        }
                    }
                    }
                } else if !classification.isNewDocket {
                    // CodeMind says it's NOT a new docket email
                    if classification.confidence >= 0.7 {
                        // High confidence rejection - don't create notification
                        print("    ❌ CodeMind determined this is NOT a new docket email (high confidence: \(Int(classification.confidence * 100))%)")
                    print("      Reasoning: \(classification.reasoning)")
                    } else {
                        // Low confidence rejection - still create notification for review
                        // Use parser result if available, otherwise create with CodeMind's reasoning
                        print("    ⚠️ CodeMind says NOT a new docket but has low confidence (\(Int(classification.confidence * 100))%)")
                        print("      Reasoning: \(classification.reasoning)")
                        print("      Will create notification for review - user can vote")
                        // Fall through to use parser result or create notification for review
                    }
                    
                    // Check if this is an internal request from company domain
                    // Internal requests should fall through to regular parser instead of being rejected
                    let recipients = message.allRecipients
                    let mediaEmail = settingsManager.currentSettings.companyMediaEmail
                    
                    if isInternalRequest(from: message.from, recipients: recipients, mediaEmail: mediaEmail) {
                        let warningMessage = """
                        ⚠️ WARNING: Internal Grayson email rejected by CodeMind as 'not new docket'
                        However, this appears to be an internal request (company → media team).
                        Falling through to regular parser instead of rejecting.
                        
                        - Subject: \(subject)
                        - From: \(message.from ?? "unknown")
                        - Recipients: \(recipients.joined(separator: ", "))
                        - CodeMind Confidence: \(classification.confidence)
                        - CodeMind Reasoning: \(classification.reasoning)
                        """
                        print(warningMessage)
                        CodeMindLogger.shared.log(.warning, "Internal Grayson email rejected by CodeMind as 'not new docket' - falling through to parser", category: .classification, metadata: [
                            "subject": subject,
                            "from": message.from ?? "unknown",
                            "recipients": recipients.joined(separator: ", "),
                            "confidence": String(format: "%.2f", classification.confidence),
                            "reasoning": classification.reasoning,
                            "action": "Falling through to regular parser"
                        ])
                        // Don't return false - fall through to regular parser
                    } else {
                        // External or outgoing email - safe to reject
                        if let from = message.from {
                            let domain = from.split(separator: "@").last.map(String.init) ?? ""
                            if domain.lowercased().contains("grayson") {
                                let warningMessage = """
                                ⚠️ WARNING: Grayson email rejected as 'not new docket'
                                This appears to be outgoing (company → external clients), so rejection is likely correct.
                                
                                - Subject: \(subject)
                                - From: \(from)
                                - Recipients: \(recipients.joined(separator: ", "))
                                - Confidence: \(classification.confidence)
                                - Reasoning: \(classification.reasoning)
                                """
                                print(warningMessage)
                                CodeMindLogger.shared.log(.warning, "Grayson email rejected as 'not new docket' - appears to be outgoing", category: .classification, metadata: [
                                    "subject": subject,
                                    "from": from,
                                    "recipients": recipients.joined(separator: ", "),
                                    "confidence": String(format: "%.2f", classification.confidence),
                                    "reasoning": classification.reasoning
                                ])
                            }
                        }
                        return false
                    }
                }
                // If confidence is low, fall through to regular parser
            } catch {
                let errorMessage = error.localizedDescription
                print("EmailScanningService: CodeMind classification failed: \(errorMessage). Falling back to regular parser.")
                // Parse error to check if it's a quota/rate limit error
                if let quotaInfo = parseQuotaError(errorMessage) {
                    codeMindStatus = .quotaExceeded(retryAfter: quotaInfo.retryAfter, userMessage: quotaInfo.message)
                } else {
                    codeMindStatus = .error(errorMessage)
                }
                // Don't disable CodeMind permanently - it might be a transient error
                // Just log it and use fallback for this email
            }
        }
        
        // Fall back to regular parser if CodeMind didn't provide a result
        // This happens automatically - no user intervention needed
        if parsedDocket == nil {
            parsedDocket = parser.parseEmail(
                subject: message.subject,
                body: message.plainTextBody ?? message.htmlBody,
                from: message.from
            )
        }
        
        guard let parsedDocket = parsedDocket else {
            print("    ❌ REJECTED: Failed to parse email - no docket information found in subject or body")
            return false
        }
        
        print("    ✅ Parsed docket: \(parsedDocket.docketNumber) - \(parsedDocket.jobName)")
        
        // VALIDATE docket number before creating notification (unless it's "TBD")
        if parsedDocket.docketNumber != "TBD" {
            // Validate that it's a proper 5-digit docket number
            if !isValidDocketNumber(parsedDocket.docketNumber) {
                print("    ❌ REJECTED: Invalid docket number format: '\(parsedDocket.docketNumber)' (must be exactly 5 digits, optionally with -US suffix)")
                return false
            }
        }
        
        // Check if docket already exists (only if we have a valid docket number, not "TBD")
        if parsedDocket.docketNumber != "TBD",
           let manager = mediaManager,
           manager.dockets.contains("\(parsedDocket.docketNumber)_\(parsedDocket.jobName)") {
            // Docket already exists - mark as processed but don't create notification
            print("    ❌ REJECTED: Docket already exists: \(parsedDocket.docketNumber)_\(parsedDocket.jobName)")
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
            
            var notification = Notification(
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
            
            // Store CodeMind classification metadata if available
            notification.codeMindClassification = codeMindMetadata
            
            // Debug: Log if CodeMind metadata is missing
            if codeMindMetadata == nil {
                print("EmailScanningService: ⚠️ WARNING: CodeMind metadata is nil for notification - feedback UI will not show")
                print("  - useCodeMind: \(useCodeMind)")
                print("  - shouldSkipCodeMind: \(shouldSkipCodeMind)")
                print("  - codeMindClassifier exists: \(codeMindClassifier != nil)")
                print("  - codeMindStatus: \(codeMindStatus)")
            } else {
                print("EmailScanningService: ✅ CodeMind metadata set: wasUsed=\(codeMindMetadata!.wasUsed), confidence=\(codeMindMetadata!.confidence)")
            }
            
            // Store CodeMind response for feedback if available
            if let response = codeMindResponse {
                codeMindResponses[notification.id] = response
            }
            
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
            print("EmailScanningService: Skipping media email \(message.id) - already marked as read")
            return false
        }
        
        guard let settingsManager = settingsManager else {
            print("EmailScanningService: ❌ Failed to create media file notification for email \(message.id) - settingsManager is nil")
            return false
        }
        let settings = settingsManager.currentSettings
        
        // Check if email is actually sent to media email
        guard checkIfMediaEmail(message, mediaEmail: settings.companyMediaEmail) else {
            print("EmailScanningService: ❌ Failed to create media file notification for email \(message.id) - email is not sent to media email address (\(settings.companyMediaEmail))")
            print("  Recipients: \(message.allRecipients.joined(separator: ", "))")
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
        
        // Try CodeMind classification first if enabled
        var linkResult: QualificationResult? = nil
        var fileLinks: [String] = []
        var codeMindMetadata: CodeMindClassificationMetadata? = nil
        var codeMindResponse: CodeMindResponse? = nil
        
        // Check if we should skip CodeMind based on patterns
        var shouldSkipCodeMind = false
        var skipReason: String? = nil
        
        // Check skip patterns for file delivery emails
        let skipPatterns = settings.codeMindSkipPatterns
        if !skipPatterns.isEmpty {
            let combinedText = "\(subject)\n\(bodyForDetection)".lowercased()
            for pattern in skipPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   regex.firstMatch(in: combinedText, range: NSRange(combinedText.startIndex..., in: combinedText)) != nil {
                    shouldSkipCodeMind = true
                    skipReason = "Matched skip pattern: \(pattern)"
                    print("EmailScanningService: ⏭️  SKIPPING CodeMind for file delivery: \(skipReason ?? "pattern match")")
                    break
                }
            }
        }
        
        // Only use CodeMind if we haven't skipped it
        if useCodeMind && !shouldSkipCodeMind, let classifier = codeMindClassifier {
            do {
                print("EmailScanningService: 🤖 Using CodeMind to classify file delivery email...")
                let recipients = message.allRecipients
                let result = try await classifier.classifyFileDeliveryEmail(
                    subject: message.subject,
                    body: bodyForDetection,
                    from: message.from,
                    recipients: recipients,
                    threadId: message.threadId,
                    gmailService: gmailService
                )
                let classification = result.classification
                codeMindResponse = result.response
                
                print("CodeMind File Delivery Classification Result:")
                print("  Is File Delivery: \(classification.isFileDelivery)")
                print("  Confidence: \(classification.confidence)")
                print("  File Links: \(classification.fileLinks.count)")
                print("  Services: \(classification.fileHostingServices.joined(separator: ", "))")
                print("  Reasoning: \(classification.reasoning)")
                
                // Store classification metadata for feedback
                var extractedData: [String: String] = [:]
                if !classification.fileLinks.isEmpty {
                    extractedData["fileLinks"] = classification.fileLinks.joined(separator: ", ")
                }
                if !classification.fileHostingServices.isEmpty {
                    extractedData["services"] = classification.fileHostingServices.joined(separator: ", ")
                }
                codeMindMetadata = CodeMindClassificationMetadata(
                    wasUsed: true,
                    confidence: classification.confidence,
                    reasoning: classification.reasoning,
                    classificationType: "fileDelivery",
                    extractedData: extractedData.isEmpty ? nil : extractedData
                )
                
                if classification.isFileDelivery && classification.confidence >= 0.7 {
                    fileLinks = classification.fileLinks
                    linkResult = QualificationResult(
                        qualifies: true,
                        reasons: ["CodeMind classification: \(classification.reasoning)"] + classification.fileHostingServices.map { "Found \($0) link" },
                        matchedCriteria: ["CodeMind AI classification"] + classification.fileHostingServices,
                        exclusionReasons: []
                    )
                    print("EmailScanningService: ✅ CodeMind confirmed file delivery email")
                } else if !classification.isFileDelivery && classification.confidence >= 0.7 {
                    print("EmailScanningService: ❌ CodeMind determined this is NOT a file delivery email")
                    print("  Subject: \(subject.isEmpty ? "nil" : subject)")
                    print("  From: \(message.from ?? "unknown")")
                    print("  Reasoning: \(classification.reasoning)")
                    print("  Confidence: \(classification.confidence)")
                    
                    // Check if this is an internal request from company domain
                    // Internal requests should fall through to regular detection instead of being rejected
                    if isInternalRequest(from: message.from, recipients: recipients, mediaEmail: settings.companyMediaEmail) {
                        let warningMessage = """
                        ⚠️ WARNING: Internal Grayson email rejected by CodeMind as 'not file delivery'
                        However, this appears to be an internal request (company → media team).
                        Falling through to regular file detection instead of rejecting.
                        
                        - Subject: \(subject.isEmpty ? "nil" : subject)
                        - From: \(message.from ?? "unknown")
                        - Recipients: \(recipients.joined(separator: ", "))
                        - CodeMind Confidence: \(classification.confidence)
                        - CodeMind Reasoning: \(classification.reasoning)
                        """
                        print(warningMessage)
                        CodeMindLogger.shared.log(.warning, "Internal Grayson email rejected by CodeMind as 'not file delivery' - falling through to regular detection", category: .classification, metadata: [
                            "subject": subject.isEmpty ? "nil" : subject,
                            "from": message.from ?? "unknown",
                            "recipients": recipients.joined(separator: ", "),
                            "confidence": String(format: "%.2f", classification.confidence),
                            "reasoning": classification.reasoning,
                            "action": "Falling through to regular file detection"
                        ])
                        // Don't set linkResult to rejection - let it fall through to regular detection
                    } else {
                        // External or outgoing email - safe to reject
                        linkResult = QualificationResult(
                            qualifies: false,
                            reasons: ["CodeMind determined this is NOT a file delivery email: \(classification.reasoning)"],
                            matchedCriteria: [],
                            exclusionReasons: ["CodeMind AI classification: not a file delivery"]
                        )
                        
                        if let from = message.from {
                            let domain = from.split(separator: "@").last.map(String.init) ?? ""
                            if domain.lowercased().contains("grayson") {
                                let warningMessage = """
                                ⚠️ WARNING: Grayson email rejected as 'not file delivery'
                                This appears to be outgoing (company → external clients), so rejection is likely correct.
                                
                                - Subject: \(subject.isEmpty ? "nil" : subject)
                                - From: \(from)
                                - Recipients: \(recipients.joined(separator: ", "))
                                - Confidence: \(classification.confidence)
                                - Reasoning: \(classification.reasoning)
                                """
                                print(warningMessage)
                                CodeMindLogger.shared.log(.warning, "Grayson email rejected as 'not file delivery' - appears to be outgoing", category: .classification, metadata: [
                                    "subject": subject.isEmpty ? "nil" : subject,
                                    "from": from,
                                    "recipients": recipients.joined(separator: ", "),
                                    "confidence": String(format: "%.2f", classification.confidence),
                                    "reasoning": classification.reasoning
                                ])
                            }
                        }
                    }
                }
            } catch {
                let errorMessage = error.localizedDescription
                print("EmailScanningService: CodeMind classification failed: \(errorMessage). Falling back to regular detection.")
                // Parse error to check if it's a quota/rate limit error
                if let quotaInfo = parseQuotaError(errorMessage) {
                    codeMindStatus = .quotaExceeded(retryAfter: quotaInfo.retryAfter, userMessage: quotaInfo.message)
                } else {
                    codeMindStatus = .error(errorMessage)
                }
                // Don't disable CodeMind permanently - it might be a transient error
                // Just log it and use fallback for this email
            }
        }
        
        // Fall back to regular detection if CodeMind didn't provide a result
        // This happens automatically - no user intervention needed
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
            
            // Extract file links using regular detector if CodeMind didn't provide them
            if fileLinks.isEmpty {
                fileLinks = FileHostingLinkDetector.extractFileHostingLinks(bodyForDetection)
            }
        }
        
        guard let linkResult = linkResult else {
            print("EmailScanningService: Failed to determine file delivery status")
            return false
        }
        
        // Log detailed debug information
        let separator = String(repeating: "=", count: 80)
        print("\n\(separator)")
        print("📧 FILE DELIVERY NOTIFICATION DEBUG - Email ID: \(message.id)")
        print(separator)
        for reason in linkResult.reasons {
            print(reason)
        }
        if linkResult.qualifies {
            print("\n✅ RESULT: QUALIFIED AS FILE DELIVERY")
            print("  Matched criteria: \(linkResult.matchedCriteria.joined(separator: ", "))")
        } else {
            print("\n❌ RESULT: NOT QUALIFIED")
            if !linkResult.exclusionReasons.isEmpty {
                print("  Exclusion reasons: \(linkResult.exclusionReasons.joined(separator: ", "))")
            }
        }
        print("\(separator)\n")
        
        guard linkResult.qualifies else {
            print("EmailScanningService: Media email \(message.id) does not contain file hosting links from whitelist")
            return false
        }
        
        // File links were already extracted above (either by CodeMind or regular detector)
        
        await MainActor.run {
            guard let notificationCenter = notificationCenter else {
                print("EmailScanningService: ERROR - notificationCenter is nil when trying to add media notification")
                return
            }
            
            // Create notification for media files
            var notification = Notification(
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
            
            // Store CodeMind classification metadata if available
            var finalMetadata = codeMindMetadata
            
            // If no file links were found, route to "For Review" by lowering confidence
            if fileLinks.isEmpty {
                let threshold = settings.codeMindReviewThreshold
                if let existingMeta = codeMindMetadata {
                    // Lower confidence to below threshold to ensure it goes to "For Review"
                    let reviewConfidence = min(0.96, threshold - 0.01)
                    finalMetadata = CodeMindClassificationMetadata(
                        wasUsed: existingMeta.wasUsed,
                        confidence: reviewConfidence,
                        reasoning: (existingMeta.reasoning ?? "No file links found") + " (No file links or attachments detected - requires review)",
                        classificationType: existingMeta.classificationType,
                        extractedData: existingMeta.extractedData
                    )
                    print("EmailScanningService: ⚠️ No file links found - setting confidence to \(Int(reviewConfidence * 100))% to route to 'For Review'")
                } else {
                    // Create metadata if none exists (shouldn't happen, but handle it)
                    finalMetadata = CodeMindClassificationMetadata(
                        wasUsed: true,
                        confidence: min(0.96, threshold - 0.01),
                        reasoning: "File delivery classification but no file links or attachments detected - requires review",
                        classificationType: "fileDelivery",
                        extractedData: nil
                    )
                    print("EmailScanningService: ⚠️ No file links found and no existing metadata - creating metadata with low confidence for 'For Review'")
                }
            }
            
            notification.codeMindClassification = finalMetadata
            
            // Store CodeMind response for feedback if available
            if let response = codeMindResponse {
                codeMindResponses[notification.id] = response
            }
            
            print("EmailScanningService: ✅ Adding media file notification for email \(message.id)")
            print("  Notification ID: \(notification.id)")
            print("  Type: \(notification.type)")
            print("  Status: \(notification.status)")
            print("  Title: \(notification.title)")
            print("  Message: \(notification.message)")
            print("  File links found: \(fileLinks.count)")
            for (index, link) in fileLinks.enumerated() {
                print("    Link \(index + 1): \(link)")
            }
            notificationCenter.add(notification)
            print("EmailScanningService: ✅ Notification added. Total notifications: \(notificationCenter.notifications.count)")
            print("  Active notifications: \(notificationCenter.activeNotifications.count)")
            print("  Media file notifications: \(notificationCenter.activeNotifications.filter { $0.type == .mediaFiles }.count)")
        }
        
        return true
    }
    
    /// Provide feedback to CodeMind about a classification
    /// - Parameters:
    ///   - notificationId: The notification ID
    ///   - rating: 1-5 rating (1 = very wrong, 5 = perfect)
    ///   - wasCorrect: Whether the classification was correct
    ///   - correction: Optional correction text
    ///   - comment: Optional additional feedback
    func provideCodeMindFeedback(
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
        
        // Always store feedback persistently, even if there's no CodeMind response
        // This ensures feedback persists across app restarts and tab switches
        if let emailId = emailId {
            EmailFeedbackTracker.shared.storeFeedback(
                emailId: emailId,
                wasCorrect: wasCorrect,
                rating: rating,
                correction: correction,
                comment: comment
            )
            
            // Also record as interaction
            let interactionType: EmailFeedbackTracker.InteractionType = wasCorrect ? .feedbackThumbsUp : .feedbackThumbsDown
            EmailFeedbackTracker.shared.recordInteraction(
                emailId: emailId,
                type: interactionType
            )
            print("EmailFeedbackTracker: Stored feedback for email \(emailId)")
            
            // Also record feedback in classification history for statistics tracking
            CodeMindClassificationHistory.shared.addFeedbackByEmailId(
                emailId: emailId,
                rating: rating,
                wasCorrect: wasCorrect,
                correction: correction
            )
            print("CodeMindClassificationHistory: Recorded feedback for email \(emailId)")
        }
        
        // Only provide feedback to CodeMind if we have a response and classifier
        guard let response = codeMindResponses[notificationId],
              let classifier = codeMindClassifier else {
            // No CodeMind response - this is fine, we've already stored the feedback above
            print("EmailScanningService: No CodeMind response found for notification \(notificationId) - feedback stored but not sent to CodeMind")
            return
        }
        
        do {
            try await classifier.provideFeedback(
                for: response,
                rating: rating,
                wasCorrect: wasCorrect,
                correction: correction,
                comment: comment
            )
            print("EmailScanningService: ✅ Feedback provided to CodeMind for notification \(notificationId)")
            
            // Trigger pattern sync after feedback to check if new patterns should be adopted
            // Only sync if rating is high (positive feedback) to learn from successes
            if rating >= 4 {
                Task {
                    await CodeMindPatternBridge.shared.triggerSync()
                }
            }
        } catch {
            print("EmailScanningService: ❌ Failed to provide feedback to CodeMind: \(error.localizedDescription)")
        }
    }
    
    /// Parse quota/rate limit error to extract retry time and user-friendly message
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
        message += ". CodeMind will automatically retry when the limit resets."
        
        return (retryAfter: retryAfter, message: message)
    }
    
    /// Learn from a re-classification - sends feedback to CodeMind and creates rules if appropriate
    func learnFromReclassification(
        notification: Notification,
        oldType: NotificationType,
        newType: NotificationType,
        emailSubject: String?,
        emailBody: String?,
        emailFrom: String?
    ) async {
        // Track re-classification interaction by email ID
        if let emailId = notification.emailId {
            let details: [String: String] = [
                "fromType": oldType.rawValue,
                "toType": newType.rawValue,
                "fromDisplayName": oldType.displayName,
                "toDisplayName": newType.displayName
            ]
            EmailFeedbackTracker.shared.recordInteraction(
                emailId: emailId,
                type: .reclassified,
                details: details
            )
            print("EmailFeedbackTracker: Recorded re-classification for email \(emailId)")
        }
        
        // 1. Send feedback to CodeMind if it was involved
        if let codeMindMeta = notification.codeMindClassification,
           codeMindMeta.wasUsed {
            
            let correction = "Re-classified from \(oldType.displayName) to \(newType.displayName)"
            
            await provideCodeMindFeedback(
                for: notification.id,
                rating: 1, // Negative rating - classification was wrong
                wasCorrect: false,
                correction: correction,
                comment: "User manually re-classified this email"
            )
            
            print("📚 EmailScanningService: Sent feedback to CodeMind about re-classification")
        }
        
        // 2. For junk emails, create a rule to prevent similar ones
        if newType == .junk {
            await createJunkFilterRule(
                emailSubject: emailSubject,
                emailBody: emailBody,
                emailFrom: emailFrom
            )
        }
        
        // 3. Log the re-classification for pattern learning
        CodeMindLogger.shared.log(.info, "Re-classification learned", category: .classification, metadata: [
            "oldType": oldType.displayName,
            "newType": newType.displayName,
            "from": emailFrom ?? "unknown",
            "hasCodeMindMeta": notification.codeMindClassification?.wasUsed == true ? "yes" : "no"
        ])
    }
    
    /// Create a rule to filter out junk emails based on the email characteristics
    private func createJunkFilterRule(
        emailSubject: String?,
        emailBody: String?,
        emailFrom: String?
    ) async {
        let rulesManager = CodeMindRulesManager.shared
        
        // Determine the best rule pattern based on what we know
        var ruleType: ClassificationRule.RuleType = .subjectContains
        var pattern: String = ""
        var ruleName: String = ""
        
        // Prefer sender domain for junk emails (most reliable)
        if let from = emailFrom, let domain = from.split(separator: "@").last.map(String.init) {
            ruleType = .senderDomain
            pattern = domain.lowercased()
            ruleName = "Ignore emails from \(domain)"
        }
        // Fall back to sender email if domain isn't specific enough
        else if let from = emailFrom, !from.isEmpty {
            ruleType = .senderEmail
            pattern = from.lowercased()
            ruleName = "Ignore emails from \(from)"
        }
        // Or use subject line if it's distinctive
        else if let subject = emailSubject, !subject.isEmpty, subject.count < 100 {
            ruleType = .subjectContains
            // Use first few words of subject
            let words = subject.split(separator: " ").prefix(3).joined(separator: " ")
            pattern = words.lowercased()
            ruleName = "Ignore emails with subject '\(words)'"
        }
        
        guard !pattern.isEmpty else {
            print("⚠️ EmailScanningService: Could not extract pattern for junk email filter")
            return
        }
        
        // Check if a similar rule already exists
        let existingRule = rulesManager.rules.first { rule in
            rule.type == ruleType &&
            rule.pattern.lowercased() == pattern.lowercased() &&
            rule.action == .ignoreEmail
        }
        
        if existingRule != nil {
            print("📋 EmailScanningService: Similar junk filter rule already exists, skipping creation")
            return
        }
        
        // Create the rule
        let rule = ClassificationRule(
            name: ruleName,
            description: "Auto-generated rule to filter out junk emails based on user re-classification",
            type: ruleType,
            pattern: pattern,
            weight: 1.0,
            isEnabled: true,
            action: .ignoreEmail
        )
        
        await MainActor.run {
            rulesManager.addRule(rule)
        }
        
        print("✅ EmailScanningService: Created junk filter rule: \(ruleName)")
        CodeMindLogger.shared.log(.success, "Created junk filter rule from re-classification", category: .classification, metadata: [
            "ruleName": ruleName,
            "pattern": pattern,
            "ruleType": ruleType.rawValue
        ])
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
                do {
                    try await gmailService.markAsRead(messageId: emailId)
                    print("📧 EmailScanningService: Successfully marked email \(emailId) as read after creating docket")
                } catch {
                    print("📧 EmailScanningService: ❌ Failed to mark email \(emailId) as read: \(error.localizedDescription)")
                    print("📧 EmailScanningService: Error details: \(error)")
                }
            } else {
                print("📧 EmailScanningService: ⚠️ Cannot mark email as read - notification has no emailId")
            }
            
            // Update notification status
            await MainActor.run {
                notificationCenter?.updateStatus(notification, to: .completed, emailScanningService: self)
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
    
    /// Start periodic pattern syncing from CodeMind
    private func startPeriodicPatternSync() {
        // Cancel existing task if any
        patternSyncTask?.cancel()
        
        // Sync patterns every 30 minutes (1800 seconds)
        patternSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000_000) // 30 minutes
                
                guard let self = self, self.codeMindStatus.isActive else { continue }
                
                await CodeMindPatternBridge.shared.triggerSync()
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
            var interactedCount = 0
            
            for message in initialEmails {
                // Skip if notification already exists for this email (unless force rescan)
                if !forceRescan && existingEmailIds.contains(message.id) {
                    skippedCount += 1
                    continue
                }
                
                // Skip if email has been interacted with (downvoted, grabbed, reclassified, approved, etc.)
                // This prevents showing notifications for emails we've already handled
                let hasInteracted = await MainActor.run {
                    EmailFeedbackTracker.shared.hasAnyInteraction(emailId: message.id)
                }
                if hasInteracted {
                    interactedCount += 1
                    print("EmailScanningService: ⏭️  Skipping email \(message.id) - already interacted with")
                    continue
                }
                
                // If force rescan, remove existing notification first
                if forceRescan && existingEmailIds.contains(message.id) {
                    await MainActor.run {
                        if let existingNotification = notificationCenter.notifications.first(where: { $0.emailId == message.id }) {
                            notificationCenter.remove(existingNotification, emailScanningService: self)
                        }
                    }
                }
                
                // IMPORTANT: Try to process as new docket email FIRST
                // This ensures emails with docket numbers are classified correctly,
                // even if they're also sent to the media email address
                print("EmailScanningService: Email \(message.id) - attempting to process as new docket email first...")
                let isNewDocket = await processEmailAndCreateNotification(message)
                
                if isNewDocket {
                    // Successfully processed as new docket email
                    createdCount += 1
                    print("EmailScanningService: ✅ Created new docket notification for email \(message.id)")
                    // Don't mark as processed - we want to keep showing it until it's read/approved
                } else {
                    // Not a new docket email - check if it's a media email (file delivery)
                    let isMediaEmail = checkIfMediaEmail(message, mediaEmail: settings.companyMediaEmail)
                    
                    print("EmailScanningService: Email \(message.id) - not a new docket, isMediaEmail: \(isMediaEmail)")
                    
                    if isMediaEmail {
                        // Process as media email (file delivery)
                        print("EmailScanningService: Attempting to process as media email...")
                        if await processMediaEmailAndCreateNotification(message) {
                            mediaEmailCount += 1
                            print("EmailScanningService: ✅ Created media file notification for email \(message.id)")
                        } else {
                            failedCount += 1
                            print("EmailScanningService: ❌ Failed to create media file notification for email \(message.id)")
                        }
                    } else {
                        // Not a new docket and not a media email - skip it
                        failedCount += 1
                        print("EmailScanningService: Email \(message.id) - not a new docket and not a media email, skipping")
                    }
                }
            }
            
            print("EmailScanningService: Summary - Created: \(createdCount), Media Files: \(mediaEmailCount), Skipped: \(skippedCount), Failed: \(failedCount), Interacted: \(interactedCount)")
            
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
            let errorMessage = error.localizedDescription
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
    
    /// Validate a docket number: must be exactly 5 digits, optionally with "-US" suffix
    private func isValidDocketNumber(_ docketNumber: String) -> Bool {
        let trimmed = docketNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for -US suffix
        let baseNumber: String
        if trimmed.uppercased().hasSuffix("-US") {
            baseNumber = String(trimmed.dropLast(3)) // Remove "-US"
        } else {
            baseNumber = trimmed
        }
        
        // Must be exactly 5 digits
        guard baseNumber.count == 5 else { return false }
        guard baseNumber.allSatisfy({ $0.isNumber }) else { return false }
        
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
        classification: DocketEmailClassification,
        codeMindMetadata: CodeMindClassificationMetadata?
    ) {
        guard let notificationCenter = notificationCenter else {
            print("EmailScanningService: ERROR - notificationCenter is nil when trying to add notification")
            return
        }
        
        // VALIDATE docket number before creating notification
        if !isValidDocketNumber(docketNumber) {
            print("EmailScanningService: ❌ REJECTED: Invalid docket number format: '\(docketNumber)' (must be exactly 5 digits, optionally with -US suffix)")
            return
        }
        
        // Check if docket already exists
        if let manager = mediaManager,
           manager.dockets.contains("\(docketNumber)_\(jobName)") {
            print("EmailScanningService: Docket already exists: \(docketNumber)_\(jobName)")
            return
        }
        
        // Check if notification already exists for this docket + email combo
        let existingNotification = notificationCenter.notifications.first { notification in
            notification.emailId == message.id && notification.docketNumber == docketNumber
        }
        
        if existingNotification != nil {
            print("EmailScanningService: Notification already exists for docket \(docketNumber) from email \(message.id)")
            return
        }
        
        let messageText = "Docket \(docketNumber): \(jobName)"
        let emailSubjectToStore = subject.isEmpty ? nil : subject
        let emailBodyToStore = body.isEmpty ? nil : body
        
        var notification = Notification(
            type: .newDocket,
            title: "New Docket Detected",
            message: messageText,
            docketNumber: docketNumber,
            jobName: jobName,
            emailId: message.id,
            sourceEmail: message.from ?? "",
            emailSubject: emailSubjectToStore,
            emailBody: emailBodyToStore
        )
        
        // Add CodeMind classification metadata if available
        if let metadata = codeMindMetadata {
            notification.codeMindClassification = metadata
            print("EmailScanningService: ✅ CodeMind metadata set in createNotificationForDocket: wasUsed=\(metadata.wasUsed), confidence=\(metadata.confidence)")
        } else {
            print("EmailScanningService: ⚠️ WARNING: CodeMind metadata is nil in createNotificationForDocket - feedback UI will not show")
        }
        
        notificationCenter.add(notification)
        print("EmailScanningService: ✅ Created notification for docket \(docketNumber) - \(jobName)")
        totalDocketsCreated += 1
        
        // Show system notification
        NotificationService.shared.showNewDocketNotification(
            docketNumber: docketNumber,
            jobName: jobName
        )
    }
}

