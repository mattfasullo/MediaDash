import Foundation
import Combine

/// Result of a sync operation
struct AirtableSyncResult {
    let created: Int
    let updated: Int
    let skipped: Int
    let errors: [String]
    
    var total: Int { created + updated }
}

/// One table in an Airtable base (from Meta API or manual entry)
struct AirtableTableInfo: Identifiable {
    let id: String   // table ID (tbl...)
    let name: String
}

/// Service for syncing data from Asana to Airtable
@MainActor
class AirtableService: ObservableObject {
    @Published var isSyncing = false
    @Published var syncError: String?
    
    private let baseURL = "https://api.airtable.com/v0"
    private let metaBaseURL = "https://api.airtable.com/v0/meta/bases"
    
    // Rate limiting: Airtable allows 5 requests/second per base
    private var rateLimitResumeTime: Date?
    private let requestsPerSecond: Double = 5.0
    private let minDelayBetweenRequests: TimeInterval = 0.2 // 200ms = 5 req/sec
    
    /// Field mapping configuration
    struct FieldMapping {
        let docketNumberField: String
        let jobNameField: String
        let fullNameField: String?
        let dueDateField: String?
        let clientField: String?
        let producerField: String?
        let studioField: String?
        let completedField: String?
        let lastUpdatedField: String?
    }
    
    /// Look up an existing Airtable record by docket number
    private func findRecordByDocketNumber(
        baseID: String,
        tableID: String,
        docketNumber: String,
        docketNumberField: String,
        apiKey: String
    ) async throws -> String? {
        // Escape single quotes in docket number for Airtable formula
        let escapedDocket = docketNumber.replacingOccurrences(of: "'", with: "''")
        
        let urlString = "\(baseURL)/\(baseID)/\(tableID)"
        var components = URLComponents(string: urlString)
        components?.queryItems = [
            URLQueryItem(name: "filterByFormula", value: "{\(docketNumberField)} = '\(escapedDocket)'"),
            URLQueryItem(name: "maxRecords", value: "1")
        ]
        
        guard let url = components?.url else {
            throw AirtableError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["records"] as? [[String: Any]],
              let firstRecord = records.first,
              let recordID = firstRecord["id"] as? String else {
            return nil
        }
        
        return recordID
    }
    
    /// Fetch table column names by reading records (empty columns may still be missing if no row has a value).
    /// Paginates through records to avoid only seeing the first page's keys.
    func fetchTableFieldNames(baseID: String, tableID: String) async throws -> [String] {
        guard let apiKey = SharedKeychainService.getAirtableAPIKey(), !apiKey.isEmpty else {
            throw AirtableError.missingAPIKey
        }
        let urlString = "\(baseURL)/\(baseID)/\(tableID)"
        var fieldNames = Set<String>()
        var offset: String?
        var pagesFetched = 0
        let maxPages = 25
        
        repeat {
            var components = URLComponents(string: urlString)
            var queryItems: [URLQueryItem] = [URLQueryItem(name: "pageSize", value: "100")]
            if let offset = offset, !offset.isEmpty {
                queryItems.append(URLQueryItem(name: "offset", value: offset))
            }
            components?.queryItems = queryItems
            guard let url = components?.url else { throw AirtableError.invalidURL }
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err = json["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    throw AirtableError.apiError(msg)
                }
                throw AirtableError.invalidResponse
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                break
            }
            let records = json["records"] as? [[String: Any]] ?? []
            for rec in records {
                if let fields = rec["fields"] as? [String: Any] {
                    fieldNames.formUnion(fields.keys)
                }
            }
            
            offset = json["offset"] as? String
            pagesFetched += 1
            if pagesFetched >= maxPages {
                break
            }
        } while offset != nil
        
        return Array(fieldNames).sorted()
    }
    
    /// Fetch table column names from the Meta API (table schema). Returns the exact field names Airtable expects for every column, including empty ones.
    /// Use this for building the push payload so keys match Airtable exactly. Returns empty array if Meta scope is unavailable or table not found.
    func fetchTableFieldNamesFromMeta(baseID: String, tableID: String) async -> [String] {
        guard let apiKey = SharedKeychainService.getAirtableAPIKey(), !apiKey.isEmpty,
              !baseID.isEmpty, !tableID.isEmpty else { return [] }
        let urlString = "\(metaBaseURL)/\(baseID)/tables"
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            let tables = (json["tables"] as? [[String: Any]]) ?? (json["tableSchemas"] as? [[String: Any]]) ?? []
            guard let table = tables.first(where: { ($0["id"] as? String) == tableID }) else {
                return []
            }
            let fields = table["fields"] as? [[String: Any]] ?? []
            let names = fields.compactMap { $0["name"] as? String }
            return names
        } catch {
            return []
        }
    }
    
    /// Fetch list of tables in a base (Meta API). Returns empty array if token lacks meta scope or request fails.
    func fetchTablesInBase(baseID: String) async -> [AirtableTableInfo] {
        guard let apiKey = SharedKeychainService.getAirtableAPIKey(), !apiKey.isEmpty,
              !baseID.isEmpty else { return [] }
        let urlString = "\(metaBaseURL)/\(baseID)/tables"
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            let tables = (json["tables"] as? [[String: Any]]) ?? (json["tableSchemas"] as? [[String: Any]]) ?? []
            return tables.compactMap { tbl -> AirtableTableInfo? in
                guard let id = tbl["id"] as? String else { return nil }
                let name = tbl["name"] as? String ?? id
                return AirtableTableInfo(id: id, name: name)
            }
        } catch {
            return []
        }
    }
    
    /// Push only selected fields to Airtable: find row by docket or create one, then write only fields whose column exists.
    /// - Parameters:
    ///   - docketNumberField: Airtable column name for docket (must match table exactly, e.g. "Docket")
    ///   - projectTitleField: Airtable column name for project title (must match table exactly, e.g. "Project Title")
    ///   - existingColumnNames: Exact column names from the table schema (prefer fetchTableFieldNamesFromMeta so all columns and spelling match Airtable)
    /// - Returns: "created" or "updated"
    func pushSelectedFields(
        baseID: String,
        tableID: String,
        docketNumber: String,
        projectTitle: String,
        fieldsToPush: [String: Any],
        docketNumberField: String,
        projectTitleField: String,
        existingColumnNames: [String]
    ) async throws -> String {
        guard let apiKey = SharedKeychainService.getAirtableAPIKey(), !apiKey.isEmpty else {
            throw AirtableError.missingAPIKey
        }
        let allowed = Set(existingColumnNames)
        var fields: [String: Any] = [:]
        // Always include docket and job/project title so new rows get them (existingColumnNames may omit columns that no row has filled yet)
        if !docketNumber.isEmpty {
            fields[docketNumberField] = docketNumber
        }
        if !projectTitle.isEmpty {
            fields[projectTitleField] = projectTitle
        }
        for (key, value) in fieldsToPush {
            if allowed.contains(key) {
                fields[key] = value
            }
        }
        if fields.isEmpty {
            throw AirtableError.apiError("No matching columns in Airtable table")
        }
        
        try await respectRateLimit()
        
        let existingID = try await findRecordByDocketNumber(
            baseID: baseID,
            tableID: tableID,
            docketNumber: docketNumber,
            docketNumberField: docketNumberField,
            apiKey: apiKey
        )
        
        if let recordID = existingID {
            try await patchRecord(baseID: baseID, tableID: tableID, recordID: recordID, fields: fields, apiKey: apiKey)
            return "updated"
        } else {
            try await postRecord(baseID: baseID, tableID: tableID, fields: fields, apiKey: apiKey)
            return "created"
        }
    }
    
    private func postRecord(baseID: String, tableID: String, fields: [String: Any], apiKey: String) async throws {
        let urlString = "\(baseURL)/\(baseID)/\(tableID)"
        guard let url = URL(string: urlString) else { throw AirtableError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["records": [["fields": fields]], "typecast": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AirtableError.invalidResponse }
        if httpResponse.statusCode == 429 {
            handleRateLimit(response: httpResponse)
            throw AirtableError.apiError("Rate limit exceeded. Try again in 30 seconds.")
        }
        guard httpResponse.statusCode == 200 else {
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = j["error"] as? [String: Any],
               let msg = err["message"] as? String { throw AirtableError.apiError(msg) }
            throw AirtableError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }
    
    private func patchRecord(baseID: String, tableID: String, recordID: String, fields: [String: Any], apiKey: String) async throws {
        let urlString = "\(baseURL)/\(baseID)/\(tableID)/\(recordID)"
        guard let url = URL(string: urlString) else { throw AirtableError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["fields": fields, "typecast": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AirtableError.invalidResponse }
        if httpResponse.statusCode == 429 {
            handleRateLimit(response: httpResponse)
            throw AirtableError.apiError("Rate limit exceeded. Try again in 30 seconds.")
        }
        guard httpResponse.statusCode == 200 else {
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = j["error"] as? [String: Any],
               let msg = err["message"] as? String { throw AirtableError.apiError(msg) }
            throw AirtableError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }
    
    /// Sync dockets from Asana to Airtable with update support
    /// - Parameters:
    ///   - baseID: Airtable base ID
    ///   - tableID: Airtable table ID
    ///   - dockets: Array of DocketInfo to sync
    ///   - fieldMapping: Field mapping configuration
    ///   - progressCallback: Optional callback for progress updates (0.0 to 1.0, status message)
    /// - Returns: Sync result with created/updated counts
    func syncDocketsToAirtable(
        baseID: String,
        tableID: String,
        dockets: [DocketInfo],
        fieldMapping: FieldMapping,
        progressCallback: ((Double, String) -> Void)? = nil
    ) async throws -> AirtableSyncResult {
        guard let apiKey = SharedKeychainService.getAirtableAPIKey(),
              !apiKey.isEmpty else {
            throw AirtableError.missingAPIKey
        }
        
        guard !baseID.isEmpty, !tableID.isEmpty else {
            throw AirtableError.missingConfiguration
        }
        
        isSyncing = true
        syncError = nil
        
        defer {
            isSyncing = false
        }
        
        progressCallback?(0.0, "Preparing sync...")
        
        let baseURLString = "\(baseURL)/\(baseID)/\(tableID)"
        guard URL(string: baseURLString) != nil else {
            throw AirtableError.invalidURL
        }
        
        var created = 0
        var updated = 0
        var skipped = 0
        var errors: [String] = []
        
        // Separate dockets into creates and updates
        var toCreate: [DocketInfo] = []
        var toUpdate: [(recordID: String, docket: DocketInfo)] = []
        
        // First pass: Look up existing records
        progressCallback?(0.1, "Checking existing records...")
        for (index, docket) in dockets.enumerated() {
            let progress = 0.1 + (Double(index) / Double(dockets.count)) * 0.3
            progressCallback?(progress, "Checking \(docket.number)...")
            
            do {
                // Rate limit: wait if needed
                try await respectRateLimit()
                
                if let existingRecordID = try await findRecordByDocketNumber(
                    baseID: baseID,
                    tableID: tableID,
                    docketNumber: docket.number,
                    docketNumberField: fieldMapping.docketNumberField,
                    apiKey: apiKey
                ) {
                    toUpdate.append((recordID: existingRecordID, docket: docket))
                } else {
                    toCreate.append(docket)
                }
            } catch {
                // If lookup fails, try to create (might be a transient error)
                toCreate.append(docket)
            }
        }
        
        // Second pass: Batch create records (up to 10 per batch)
        progressCallback?(0.4, "Creating \(toCreate.count) new records...")
        for (index, batch) in toCreate.chunked(into: 10).enumerated() {
            let progress = 0.4 + (Double(index) / Double(max(1, toCreate.count / 10))) * 0.3
            progressCallback?(progress, "Creating batch \(index + 1)...")
            
            do {
                try await respectRateLimit()
                try await createRecordsBatch(
                    baseID: baseID,
                    tableID: tableID,
                    dockets: batch,
                    fieldMapping: fieldMapping,
                    apiKey: apiKey
                )
                created += batch.count
            } catch {
                // Fall back to individual creates if batch fails
                for docket in batch {
                    do {
                        try await respectRateLimit()
                        try await createRecord(
                            baseID: baseID,
                            tableID: tableID,
                            docket: docket,
                            fieldMapping: fieldMapping,
                            apiKey: apiKey
                        )
                        created += 1
                    } catch {
                        let errorMsg = "\(docket.number): \(error.localizedDescription)"
                        errors.append(errorMsg)
                        skipped += 1
                    }
                }
            }
        }
        
        // Third pass: Update existing records (individual updates)
        progressCallback?(0.7, "Updating \(toUpdate.count) existing records...")
        for (index, update) in toUpdate.enumerated() {
            let progress = 0.7 + (Double(index) / Double(max(1, toUpdate.count))) * 0.3
            progressCallback?(progress, "Updating \(update.docket.number)...")
            
            do {
                try await respectRateLimit()
                try await updateRecord(
                    baseID: baseID,
                    tableID: tableID,
                    recordID: update.recordID,
                    docket: update.docket,
                    fieldMapping: fieldMapping,
                    apiKey: apiKey
                )
                updated += 1
            } catch {
                let errorMsg = "\(update.docket.number): \(error.localizedDescription)"
                errors.append(errorMsg)
                skipped += 1
            }
        }
        
        progressCallback?(1.0, "Sync complete! Created: \(created), Updated: \(updated)")
        return AirtableSyncResult(created: created, updated: updated, skipped: skipped, errors: errors)
    }
    
    /// Respect rate limits by waiting if necessary
    private func respectRateLimit() async throws {
        if let resumeTime = rateLimitResumeTime, Date() < resumeTime {
            let waitTime = resumeTime.timeIntervalSince(Date())
            try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            rateLimitResumeTime = nil
        }
        
        // Always maintain minimum delay between requests
        try await Task.sleep(nanoseconds: UInt64(minDelayBetweenRequests * 1_000_000_000))
    }
    
    /// Handle rate limit response (429)
    private func handleRateLimit(response: HTTPURLResponse) {
        if response.statusCode == 429 {
            // Airtable requires 30 second wait on rate limit
            rateLimitResumeTime = Date().addingTimeInterval(30)
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
               let retrySeconds = Double(retryAfter) {
                rateLimitResumeTime = Date().addingTimeInterval(retrySeconds)
            }
        }
    }
    
    /// Create multiple records in a batch (up to 10)
    private func createRecordsBatch(
        baseID: String,
        tableID: String,
        dockets: [DocketInfo],
        fieldMapping: FieldMapping,
        apiKey: String
    ) async throws {
        guard !dockets.isEmpty, dockets.count <= 10 else {
            throw AirtableError.apiError("Batch size must be between 1 and 10 records")
        }
        
        let urlString = "\(baseURL)/\(baseID)/\(tableID)"
        guard let url = URL(string: urlString) else {
            throw AirtableError.invalidURL
        }
        
        let records = dockets.map { docket in
            createFields(from: docket, fieldMapping: fieldMapping)
        }
        
        let requestBody: [String: Any] = [
            "records": records.map { ["fields": $0] },
            "typecast": true
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw AirtableError.serializationError
        }
        
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AirtableError.invalidResponse
        }
        
        // Handle rate limiting
        if httpResponse.statusCode == 429 {
            handleRateLimit(response: httpResponse)
            throw AirtableError.apiError("Rate limit exceeded. Please wait 30 seconds and try again.")
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorData["error"] as? [String: Any],
               let message = errorMessage["message"] as? String {
                throw AirtableError.apiError(message)
            } else {
                throw AirtableError.apiError("HTTP \(httpResponse.statusCode)")
            }
        }
    }
    
    /// Create a new Airtable record
    private func createRecord(
        baseID: String,
        tableID: String,
        docket: DocketInfo,
        fieldMapping: FieldMapping,
        apiKey: String
    ) async throws {
        let urlString = "\(baseURL)/\(baseID)/\(tableID)"
        guard let url = URL(string: urlString) else {
            throw AirtableError.invalidURL
        }
        
        let fields = createFields(from: docket, fieldMapping: fieldMapping)
        let requestBody: [String: Any] = [
            "fields": fields,
            "typecast": true
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw AirtableError.serializationError
        }
        
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AirtableError.invalidResponse
        }
        
        // Handle rate limiting
        if httpResponse.statusCode == 429 {
            handleRateLimit(response: httpResponse)
            throw AirtableError.apiError("Rate limit exceeded. Please wait 30 seconds and try again.")
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorData["error"] as? [String: Any],
               let message = errorMessage["message"] as? String {
                throw AirtableError.apiError(message)
            } else {
                throw AirtableError.apiError("HTTP \(httpResponse.statusCode)")
            }
        }
    }
    
    /// Update an existing Airtable record
    private func updateRecord(
        baseID: String,
        tableID: String,
        recordID: String,
        docket: DocketInfo,
        fieldMapping: FieldMapping,
        apiKey: String
    ) async throws {
        let urlString = "\(baseURL)/\(baseID)/\(tableID)/\(recordID)"
        guard let url = URL(string: urlString) else {
            throw AirtableError.invalidURL
        }
        
        let fields = createFields(from: docket, fieldMapping: fieldMapping)
        let requestBody: [String: Any] = [
            "fields": fields,
            "typecast": true
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw AirtableError.serializationError
        }
        
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AirtableError.invalidResponse
        }
        
        // Handle rate limiting
        if httpResponse.statusCode == 429 {
            handleRateLimit(response: httpResponse)
            throw AirtableError.apiError("Rate limit exceeded. Please wait 30 seconds and try again.")
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorMessage = errorData["error"] as? [String: Any],
               let message = errorMessage["message"] as? String {
                throw AirtableError.apiError(message)
            } else {
                throw AirtableError.apiError("HTTP \(httpResponse.statusCode)")
            }
        }
    }
    
    /// Create Airtable fields dictionary from DocketInfo using field mapping
    private func createFields(from docket: DocketInfo, fieldMapping: FieldMapping) -> [String: Any] {
        var fields: [String: Any] = [:]
        
        // Required fields
        fields[fieldMapping.docketNumberField] = docket.number
        fields[fieldMapping.jobNameField] = docket.jobName
        
        // Optional fields
        if let fullNameField = fieldMapping.fullNameField {
            fields[fullNameField] = docket.fullName
        }
        
        if let dueDateField = fieldMapping.dueDateField, let dueDate = docket.dueDate {
            fields[dueDateField] = dueDate
        }
        
        if let lastUpdatedField = fieldMapping.lastUpdatedField, let updatedAt = docket.updatedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fields[lastUpdatedField] = formatter.string(from: updatedAt)
        }
        
        if let completedField = fieldMapping.completedField, let completed = docket.completed {
            fields[completedField] = completed
        }
        
        if let studioField = fieldMapping.studioField, let studio = docket.studio {
            fields[studioField] = studio
        }
        
        // Project metadata - extract from customFields
        if let projectMetadata = docket.projectMetadata {
            // Extract client from customFields (common field name variations)
            if let clientField = fieldMapping.clientField {
                let client = projectMetadata.customFields["Client"] ?? 
                            projectMetadata.customFields["Licensor"] ?? 
                            projectMetadata.customFields["Licensor/Client"] ??
                            projectMetadata.customFields["Licensor / Client"]
                if let client = client, !client.isEmpty {
                    fields[clientField] = client
                }
            }
            
            // Extract producer from customFields (common field name variations)
            if let producerField = fieldMapping.producerField {
                let producer = projectMetadata.customFields["Producer"] ?? 
                              projectMetadata.customFields["Grayson Producer"] ?? 
                              projectMetadata.customFields["Internal Producer"]
                if let producer = producer, !producer.isEmpty {
                    fields[producerField] = producer
                }
            }
        }
        
        return fields
    }
}

// MARK: - Airtable Errors

enum AirtableError: LocalizedError {
    case missingAPIKey
    case missingConfiguration
    case invalidURL
    case serializationError
    case invalidResponse
    case apiError(String)
    case networkError(String)
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Airtable API key is not configured"
        case .missingConfiguration:
            return "Airtable base ID or table ID is not configured"
        case .invalidURL:
            return "Invalid Airtable URL"
        case .serializationError:
            return "Failed to serialize request data"
        case .invalidResponse:
            return "Invalid response from Airtable"
        case .apiError(let message):
            return "Airtable API error: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
