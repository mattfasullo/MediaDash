import Foundation
import CodeMind

/// Custom tool for CodeMind to access emails and email classification data
struct MediaDashEmailTool: Tool {
    let name = "mediadash_email"
    let description = """
    Access emails and email classification data in MediaDash.
    Use this tool to:
    - Query emails from Gmail (search for specific emails)
    - Get details about specific emails
    - Check email scanning status and recent classifications
    """
    
    let parameterSchema: [String: ParameterSchema] = [
        "action": ParameterSchema(
            type: .string,
            description: "Action to perform",
            enumValues: ["search_emails", "get_email", "get_recent_classifications", "check_scan_status"]
        ),
        "query": ParameterSchema(
            type: .string,
            description: "Gmail search query (for search_emails action). Examples: 'subject:New Docket', 'is:unread', 'from:client@example.com'",
            required: false
        ),
        "message_id": ParameterSchema(
            type: .string,
            description: "Gmail message ID (for get_email action)",
            required: false
        ),
        "max_results": ParameterSchema(
            type: .integer,
            description: "Maximum number of results to return (default: 10)",
            required: false,
            defaultValue: AnyCodable(10)
        )
    ]
    
    private weak var _gmailService: GmailService?
    private weak var _emailScanningService: EmailScanningService?
    
    public init(gmailService: GmailService? = nil, emailScanningService: EmailScanningService? = nil) {
        self._gmailService = gmailService
        self._emailScanningService = emailScanningService
    }
    
    // Get services at execution time from registry if not provided
    private func getGmailService() async -> GmailService? {
        if let service = _gmailService { return service }
        return await MainActor.run { CodeMindServiceRegistry.shared.gmailService }
    }
    
    private func getEmailScanningService() async -> EmailScanningService? {
        if let service = _emailScanningService { return service }
        return await MainActor.run { CodeMindServiceRegistry.shared.emailScanningService }
    }
    
    public func execute(with parameters: [String: AnyCodable]) async throws -> Any {
        guard let action = parameters["action"]?.value as? String else {
            throw ToolError.invalidParameter("action")
        }
        
        switch action {
        case "search_emails":
            return try await searchEmails(parameters: parameters)
        case "get_email":
            return try await getEmail(parameters: parameters)
        case "get_recent_classifications":
            return try await getRecentClassifications()
        case "check_scan_status":
            return try await checkScanStatus()
        default:
            throw ToolError.invalidParameter("Unknown action: \(action)")
        }
    }
    
    private func searchEmails(parameters: [String: AnyCodable]) async throws -> Any {
        guard let gmailService = await getGmailService() else {
            throw ToolError.executionFailed("Gmail service not available")
        }
        
        let isAuthenticated = await MainActor.run { gmailService.isAuthenticated }
        guard isAuthenticated else {
            throw ToolError.executionFailed("Gmail is not authenticated")
        }
        
        guard let query = parameters["query"]?.value as? String else {
            throw ToolError.invalidParameter("query")
        }
        
        let maxResults = parameters["max_results"]?.value as? Int ?? 10
        
        // Fetch email references
        let messageRefs = try await gmailService.fetchEmails(query: query, maxResults: maxResults)
        
        // Get full email details for first few (limit to avoid too much data)
        let limit = min(maxResults, 5)
        var emails: [[String: Any]] = []
        
        for ref in messageRefs.prefix(limit) {
            do {
                let email = try await gmailService.getEmail(messageId: ref.id)
                // Access email properties on MainActor
                let emailData = await MainActor.run {
                    [
                        "id": ref.id,
                        "threadId": ref.threadId,
                        "subject": email.subject ?? "",
                        "from": email.from ?? "",
                        "snippet": email.snippet ?? "",
                        "date": email.date?.timeIntervalSince1970 ?? 0,
                        "isUnread": email.labelIds?.contains("UNREAD") ?? false
                    ] as [String: Any]
                }
                emails.append(emailData)
            } catch {
                // Skip emails that fail to fetch
                continue
            }
        }
        
        return [
            "total_found": messageRefs.count,
            "emails": emails,
            "query": query
        ]
    }
    
    private func getEmail(parameters: [String: AnyCodable]) async throws -> Any {
        guard let gmailService = await getGmailService() else {
            throw ToolError.executionFailed("Gmail service not available")
        }
        
        guard let messageId = parameters["message_id"]?.value as? String else {
            throw ToolError.invalidParameter("message_id")
        }
        
        let email = try await gmailService.getEmail(messageId: messageId)
        
        // Build result dictionary on MainActor to access email properties
        let result = await MainActor.run { () -> [String: Any] in
            var dict: [String: Any] = [:]
            dict["id"] = email.id
            dict["threadId"] = email.threadId
            dict["subject"] = email.subject ?? ""
            dict["from"] = email.from ?? ""
            dict["to"] = email.to ?? []
            dict["cc"] = email.cc ?? []
            dict["date"] = email.date?.timeIntervalSince1970 ?? 0
            dict["snippet"] = email.snippet ?? ""
            dict["body_plain"] = email.plainTextBody ?? ""
            dict["body_html"] = email.htmlBody ?? ""
            dict["isUnread"] = email.labelIds?.contains("UNREAD") ?? false
            dict["labels"] = email.labelIds ?? []
            return dict
        }
        
        return result
    }
    
    private func getRecentClassifications() async throws -> Any {
        // Get actual classification history from CodeMindClassificationHistory
        let history = await MainActor.run {
            CodeMindClassificationHistory.shared.getRecentClassifications(limit: 20)
        }
        
        let classifications: [[String: Any]] = history.map { record in
            var dict: [String: Any] = [
                "id": record.id.uuidString,
                "email_id": record.emailId,
                "subject": record.subject,
                "from_email": record.fromEmail,
                "classified_at": record.classifiedAt.timeIntervalSince1970,
                "type": record.classificationType.rawValue,
                "confidence": record.confidence,
                "was_verified": record.wasVerified
            ]
            
            if let docket = record.docketNumber {
                dict["docket_number"] = docket
            }
            if let job = record.jobName {
                dict["job_name"] = job
            }
            if let feedback = record.feedback {
                dict["feedback"] = [
                    "rating": feedback.rating,
                    "was_correct": feedback.wasCorrect,
                    "correction": feedback.correction as Any
                ]
            }
            
            return dict
        }
        
        // Also get stats - capture all values on MainActor
        let statsDict = await MainActor.run { () -> [String: Any] in
            let stats = CodeMindClassificationHistory.shared.getStats(forLastDays: 7)
            return [
                "total": stats.totalClassifications,
                "average_confidence": stats.averageConfidence,
                "accuracy": stats.accuracy,
                "feedback_count": stats.feedbackCount
            ]
        }
        
        // Build result dictionary
        var result: [String: Any] = [:]
        result["count"] = classifications.count
        result["classifications"] = classifications
        result["stats_last_7_days"] = statsDict
        
        return result
    }
    
    private func checkScanStatus() async throws -> Any {
        guard let emailScanningService = await getEmailScanningService() else {
            throw ToolError.executionFailed("Email scanning service not available")
        }
        
        return await MainActor.run {
            [
                "is_scanning": emailScanningService.isScanning,
                "is_enabled": emailScanningService.isEnabled,
                "last_scan_time": emailScanningService.lastScanTime?.timeIntervalSince1970 ?? 0,
                "total_dockets_created": emailScanningService.totalDocketsCreated,
                "code_mind_status": emailScanningService.codeMindStatus.displayText,
                "last_error": emailScanningService.lastError ?? ""
            ]
        }
    }
}

