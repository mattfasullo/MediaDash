import Foundation
import CodeMind

/// Custom tool for CodeMind to access MediaDash data for improved classification accuracy
struct MediaDashDataTool: Tool {
    let name = "mediadash_data"
    let description = """
    Access MediaDash data for docket verification and classification context.
    Use this tool to:
    - Verify if a docket number exists in metadata, Asana, or filesystem
    - Get docket metadata (client, producer, job name, etc.)
    - Search for dockets by number, job name, or client
    - Access classification history for similar emails
    - Check if docket folders exist on the server
    """
    
    let parameterSchema: [String: ParameterSchema] = [
        "action": ParameterSchema(
            type: .string,
            description: "Action to perform",
            enumValues: ["verify_docket", "get_docket_metadata", "search_dockets", "get_classification_history", "check_docket_exists", "get_classification_stats"]
        ),
        "docket_number": ParameterSchema(
            type: .string,
            description: "Docket number to look up",
            required: false
        ),
        "job_name": ParameterSchema(
            type: .string,
            description: "Job name to search for",
            required: false
        ),
        "search_query": ParameterSchema(
            type: .string,
            description: "Search query for dockets (searches number, job name, client)",
            required: false
        ),
        "email_subject": ParameterSchema(
            type: .string,
            description: "Email subject for finding similar classifications",
            required: false
        ),
        "from_email": ParameterSchema(
            type: .string,
            description: "Sender email for finding similar classifications",
            required: false
        ),
        "limit": ParameterSchema(
            type: .integer,
            description: "Maximum number of results to return (default: 10)",
            required: false,
            defaultValue: AnyCodable(10)
        ),
        "days": ParameterSchema(
            type: .integer,
            description: "Number of days for stats (default: 30)",
            required: false,
            defaultValue: AnyCodable(30)
        )
    ]
    
    init() {}
    
    func execute(with parameters: [String: AnyCodable]) async throws -> Any {
        guard let action = parameters["action"]?.value as? String else {
            throw ToolError.invalidParameter("action")
        }
        
        switch action {
        case "verify_docket":
            return try await verifyDocket(parameters: parameters)
        case "get_docket_metadata":
            return try await getDocketMetadata(parameters: parameters)
        case "search_dockets":
            return try await searchDockets(parameters: parameters)
        case "get_classification_history":
            return try await getClassificationHistory(parameters: parameters)
        case "check_docket_exists":
            return try await checkDocketExists(parameters: parameters)
        case "get_classification_stats":
            return try await getClassificationStats(parameters: parameters)
        default:
            throw ToolError.invalidParameter("Unknown action: \(action)")
        }
    }
    
    // MARK: - Verify Docket
    
    private func verifyDocket(parameters: [String: AnyCodable]) async throws -> Any {
        guard let docketNumber = parameters["docket_number"]?.value as? String, !docketNumber.isEmpty else {
            throw ToolError.invalidParameter("docket_number required for verify_docket")
        }
        
        var result: [String: Any] = [
            "docket_number": docketNumber,
            "exists_in_metadata": false,
            "exists_in_asana": false,
            "exists_in_filesystem": false,
            "is_verified": false
        ]
        
        // Check metadata
        let metadataManager = await MainActor.run { CodeMindServiceRegistry.shared.metadataManager }
        if let metadataManager = metadataManager {
            let matches = await MainActor.run {
                Array(metadataManager.metadata.values.filter { $0.docketNumber == docketNumber })
            }
            if !matches.isEmpty {
                result["exists_in_metadata"] = true
                if let first = matches.first {
                    result["metadata_job_name"] = first.jobName
                    result["metadata_client"] = first.client
                }
            }
        }
        
        // Check Asana cache
        let asanaCache = await MainActor.run { CodeMindServiceRegistry.shared.asanaCacheManager }
        if let asanaCache = asanaCache {
            let dockets = await MainActor.run {
                asanaCache.loadCachedDockets()
            }
            let matches = dockets.filter { $0.number == docketNumber }
            if !matches.isEmpty {
                result["exists_in_asana"] = true
                if let first = matches.first {
                    result["asana_job_name"] = first.jobName
                }
            }
        }
        
        // Check filesystem
        let settingsManager = await MainActor.run { CodeMindServiceRegistry.shared.settingsManager }
        if let settingsManager = settingsManager {
            let settings = await MainActor.run { settingsManager.currentSettings }
            let folderExists = await checkDocketFolderExists(
                docketNumber: docketNumber,
                serverBasePath: settings.serverBasePath,
                yearPrefix: settings.yearPrefix
            )
            result["exists_in_filesystem"] = folderExists
        }
        
        // Overall verification
        let inMetadata = result["exists_in_metadata"] as? Bool ?? false
        let inAsana = result["exists_in_asana"] as? Bool ?? false
        let inFilesystem = result["exists_in_filesystem"] as? Bool ?? false
        result["is_verified"] = inMetadata || inAsana || inFilesystem
        
        return result
    }
    
    // MARK: - Get Docket Metadata
    
    private func getDocketMetadata(parameters: [String: AnyCodable]) async throws -> Any {
        guard let docketNumber = parameters["docket_number"]?.value as? String, !docketNumber.isEmpty else {
            throw ToolError.invalidParameter("docket_number required for get_docket_metadata")
        }
        
        let jobName = parameters["job_name"]?.value as? String
        
        // Try to find in metadata
        let metadataManager = await MainActor.run { CodeMindServiceRegistry.shared.metadataManager }
        if let metadataManager = metadataManager {
            let allMetadata = await MainActor.run { metadataManager.metadata }
            
            // Find matching docket(s)
            let matches = Array(allMetadata.values.filter { $0.docketNumber == docketNumber })
            
            if let jobName = jobName {
                // Filter by job name if provided
                if let exact = matches.first(where: { $0.jobName.lowercased() == jobName.lowercased() }) {
                    return metadataToDict(exact)
                }
            }
            
            if let first = matches.first {
                return metadataToDict(first)
            }
        }
        
        // Try Asana cache
        let asanaCache = await MainActor.run { CodeMindServiceRegistry.shared.asanaCacheManager }
        if let asanaCache = asanaCache {
            let dockets = await MainActor.run { asanaCache.loadCachedDockets() }
            let matches = dockets.filter { $0.number == docketNumber }
            
            if let first = matches.first {
                return [
                    "docket_number": first.number,
                    "job_name": first.jobName,
                    "source": "asana"
                ]
            }
        }
        
        return [
            "found": false,
            "docket_number": docketNumber,
            "message": "Docket not found in metadata or Asana"
        ]
    }
    
    // MARK: - Search Dockets
    
    private func searchDockets(parameters: [String: AnyCodable]) async throws -> Any {
        let query = parameters["search_query"]?.value as? String ?? ""
        let docketNumber = parameters["docket_number"]?.value as? String
        let jobName = parameters["job_name"]?.value as? String
        let limit = parameters["limit"]?.value as? Int ?? 10
        
        var results: [[String: Any]] = []
        
        // Search metadata
        let metadataManager = await MainActor.run { CodeMindServiceRegistry.shared.metadataManager }
        if let metadataManager = metadataManager {
            let allMetadata = await MainActor.run { Array(metadataManager.metadata.values) }
            
            var filtered = allMetadata
            
            if let docketNumber = docketNumber, !docketNumber.isEmpty {
                filtered = filtered.filter { $0.docketNumber.contains(docketNumber) }
            }
            
            if let jobName = jobName, !jobName.isEmpty {
                filtered = filtered.filter { $0.jobName.lowercased().contains(jobName.lowercased()) }
            }
            
            if !query.isEmpty {
                let lowerQuery = query.lowercased()
                filtered = filtered.filter {
                    $0.docketNumber.lowercased().contains(lowerQuery) ||
                    $0.jobName.lowercased().contains(lowerQuery) ||
                    $0.client.lowercased().contains(lowerQuery)
                }
            }
            
            for meta in filtered.prefix(limit) {
                results.append(metadataToDict(meta))
            }
        }
        
        // Also search Asana if not enough results
        let asanaCache = await MainActor.run { CodeMindServiceRegistry.shared.asanaCacheManager }
        if results.count < limit, let asanaCache = asanaCache {
            let dockets = await MainActor.run { asanaCache.loadCachedDockets() }
            
            var filtered = dockets
            
            if let docketNumber = docketNumber, !docketNumber.isEmpty {
                filtered = filtered.filter { $0.number.contains(docketNumber) }
            }
            
            if let jobName = jobName, !jobName.isEmpty {
                filtered = filtered.filter { $0.jobName.lowercased().contains(jobName.lowercased()) }
            }
            
            if !query.isEmpty {
                let lowerQuery = query.lowercased()
                filtered = filtered.filter {
                    $0.number.lowercased().contains(lowerQuery) ||
                    $0.jobName.lowercased().contains(lowerQuery)
                }
            }
            
            // Add Asana results that aren't already in results
            let existingDockets = Set(results.compactMap { $0["docket_number"] as? String })
            for docket in filtered.prefix(limit - results.count) {
                if !existingDockets.contains(docket.number) {
                    results.append([
                        "docket_number": docket.number,
                        "job_name": docket.jobName,
                        "source": "asana"
                    ])
                }
            }
        }
        
        return [
            "count": results.count,
            "results": results
        ]
    }
    
    // MARK: - Get Classification History
    
    private func getClassificationHistory(parameters: [String: AnyCodable]) async throws -> Any {
        let emailSubject = parameters["email_subject"]?.value as? String
        let fromEmail = parameters["from_email"]?.value as? String
        let docketNumber = parameters["docket_number"]?.value as? String
        let limit = parameters["limit"]?.value as? Int ?? 10
        
        let history = await MainActor.run {
            CodeMindClassificationHistory.shared.getSimilarClassifications(
                subject: emailSubject,
                fromEmail: fromEmail,
                docketNumber: docketNumber,
                limit: limit
            )
        }
        
        let records: [[String: Any]] = history.map { record in
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
        
        return [
            "count": records.count,
            "classifications": records
        ]
    }
    
    // MARK: - Check Docket Exists on Filesystem
    
    private func checkDocketExists(parameters: [String: AnyCodable]) async throws -> Any {
        guard let docketNumber = parameters["docket_number"]?.value as? String, !docketNumber.isEmpty else {
            throw ToolError.invalidParameter("docket_number required for check_docket_exists")
        }
        
        let settingsManager = await MainActor.run { CodeMindServiceRegistry.shared.settingsManager }
        guard let settingsManager = settingsManager else {
            return [
                "docket_number": docketNumber,
                "exists": false,
                "error": "Settings not available"
            ]
        }
        
        let settings = await MainActor.run { settingsManager.currentSettings }
        
        let exists = await checkDocketFolderExists(
            docketNumber: docketNumber,
            serverBasePath: settings.serverBasePath,
            yearPrefix: settings.yearPrefix
        )
        
        var result: [String: Any] = [
            "docket_number": docketNumber,
            "exists": exists,
            "server_path": settings.serverBasePath
        ]
        
        if exists {
            result["message"] = "Docket folder found on server"
        } else {
            result["message"] = "Docket folder not found on server"
        }
        
        return result
    }
    
    // MARK: - Get Classification Stats
    
    private func getClassificationStats(parameters: [String: AnyCodable]) async throws -> Any {
        let days = parameters["days"]?.value as? Int ?? 30
        
        // Capture all values on MainActor to avoid Swift 6 isolation issues
        let result = await MainActor.run { () -> [String: Any] in
            let stats = CodeMindClassificationHistory.shared.getStats(forLastDays: days)
            let trend = CodeMindClassificationHistory.shared.getConfidenceTrend(forLastDays: days)
            
            var dict: [String: Any] = [:]
            dict["days"] = days
            dict["total_classifications"] = stats.totalClassifications
            dict["new_docket_count"] = stats.newDocketCount
            dict["file_delivery_count"] = stats.fileDeliveryCount
            dict["average_confidence"] = stats.averageConfidence
            dict["low_confidence_count"] = stats.lowConfidenceCount
            dict["feedback_count"] = stats.feedbackCount
            dict["correct_count"] = stats.correctCount
            dict["incorrect_count"] = stats.incorrectCount
            dict["accuracy"] = stats.accuracy
            
            let trendData = trend.map { item -> [String: Any] in
                [
                    "date": item.date.timeIntervalSince1970,
                    "avg_confidence": item.avgConfidence,
                    "count": item.count
                ]
            }
            dict["confidence_trend"] = trendData
            
            return dict
        }
        
        return result
    }
    
    // MARK: - Helpers
    
    private func metadataToDict(_ meta: DocketMetadata) -> [String: Any] {
        return [
            "docket_number": meta.docketNumber,
            "job_name": meta.jobName,
            "client": meta.client,
            "producer": meta.producer,
            "status": meta.status,
            "agency": meta.agency,
            "agency_producer": meta.agencyProducer,
            "music_type": meta.musicType,
            "track": meta.track,
            "media": meta.media,
            "notes": meta.notes,
            "source": "metadata"
        ]
    }
    
    private func checkDocketFolderExists(
        docketNumber: String,
        serverBasePath: String,
        yearPrefix: String
    ) async -> Bool {
        // Check common locations for docket folders
        let fm = FileManager.default
        
        // Get current year and a few previous years
        let currentYear = Calendar.current.component(.year, from: Date())
        let yearsToCheck = [currentYear, currentYear - 1, currentYear - 2]
        
        for year in yearsToCheck {
            // Try Work Picture folder
            let wpPath = "\(serverBasePath)/\(yearPrefix)\(year)/\(year)_WORK PICTURE"
            let wpFolderPath = "\(wpPath)/\(docketNumber)"
            
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: wpFolderPath, isDirectory: &isDir), isDir.boolValue {
                return true
            }
            
            // Try looking for folders containing the docket number
            if fm.fileExists(atPath: wpPath, isDirectory: &isDir), isDir.boolValue {
                if let contents = try? fm.contentsOfDirectory(atPath: wpPath) {
                    if contents.contains(where: { $0.hasPrefix(docketNumber) || $0.contains(docketNumber) }) {
                        return true
                    }
                }
            }
        }
        
        return false
    }
}

