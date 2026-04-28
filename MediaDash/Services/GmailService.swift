import Foundation
import Combine
import SwiftUI

/// Service for interacting with Gmail API
@MainActor
class GmailService: ObservableObject {
    @Published var isFetching = false
    @Published var lastError: String?
    
    private let baseURL = "https://www.googleapis.com/gmail/v1"
    private var accessToken: String?
    private var refreshTask: Task<String, Error>? // Shared task to prevent race conditions
    private var lastRateLimitRetryAfter: Date?
    
    private static let agentLogPath = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug.log"

    private func debugLog(_ location: String, message: String, data: [String: Any], hypothesisId: String, runId: String = "run2") {
        // #region agent log
        let payload: [String: Any] = [
            "sessionId": "debug-session",
            "runId": runId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Date().timeIntervalSince1970 * 1000
        ]
        if let json = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: json, encoding: .utf8) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: GmailService.agentLogPath)) {
                handle.seekToEndOfFile()
                handle.write((line + "\n").data(using: .utf8) ?? Data())
                try? handle.close()
            }
        }
        // #endregion
    }

    /// Log every Gmail API call for app-wide rate-limit debugging (H1/H3/H5)
    private func agentLogApiCall(method: String, data: [String: Any] = [:]) {
        // #region agent log
        var d = data
        d["method"] = method
        let payload: [String: Any] = [
            "hypothesisId": "H1",
            "location": "GmailService",
            "message": "gmail_api_call",
            "data": d,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8) else { return }
        let path = GmailService.agentLogPath
        if !FileManager.default.fileExists(atPath: path) { try? Data().write(to: URL(fileURLWithPath: path)) }
        if let stream = OutputStream(url: URL(fileURLWithPath: path), append: true) {
            stream.open()
            defer { stream.close() }
            let out = (line + "\n").data(using: .utf8)!
            _ = out.withUnsafeBytes { stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: out.count) }
        }
        // #endregion
    }
    
    /// Initialize with access token
    init(accessToken: String? = nil) {
        // Check shared key first (for Grayson employees), then personal key
        self.accessToken = accessToken ?? SharedKeychainService.getGmailAccessToken()
        // Refresh token is loaded lazily via computed property when needed
        // This ensures it's always available from Keychain
    }
    
    /// Get refresh token from keychain (shared or personal)
    private var refreshToken: String? {
        get {
            return SharedKeychainService.getGmailRefreshToken()
        }
        set {
            if let token = newValue {
                _ = KeychainService.store(key: "gmail_refresh_token", value: token)
            } else {
                KeychainService.delete(key: "gmail_refresh_token")
            }
        }
    }
    
    /// Set access token and optionally refresh token
    /// Note: This stores to personal Keychain. Shared keys are set separately by admins.
    func setAccessToken(_ token: String, refreshToken: String? = nil) {
        self.accessToken = token
        invalidateUserLabelIdCache()
        // Store to personal Keychain (shared keys are managed separately)
        _ = KeychainService.store(key: "gmail_access_token", value: token)
        
        if let refreshToken = refreshToken {
            self.refreshToken = refreshToken
        }
    }

    /// Lowercased user label display name → API label id. Cleared when tokens change.
    private var userLabelIdCache: [String: String] = [:]

    /// Clears cached Gmail user label IDs (e.g. after account switch or label rename in Gmail).
    func invalidateUserLabelIdCache() {
        userLabelIdCache.removeAll(keepingCapacity: false)
    }
    
    /// Clear access token and refresh token
    func clearAccessToken() {
        self.accessToken = nil
        KeychainService.delete(key: "gmail_access_token")
        KeychainService.delete(key: "gmail_refresh_token")
        invalidateUserLabelIdCache()
    }
    
    /// Check if authenticated
    var isAuthenticated: Bool {
        return accessToken != nil || refreshToken != nil
    }
    
    /// Refresh access token using refresh token
    /// Uses a shared Task to prevent race conditions when multiple requests need token refresh simultaneously
    private func refreshAccessToken() async throws {
        // If a refresh is already in progress, wait for it to complete
        if let existingTask = refreshTask {
            do {
                let newToken = try await existingTask.value
                // Update access token from the shared task result
                self.accessToken = newToken
                return
            } catch {
                // If the existing task failed, clear it and try again
                refreshTask = nil
                throw error
            }
        }
        
        guard let refreshToken = refreshToken else {
            throw GmailError.notAuthenticated
        }
        
        guard OAuthConfig.isGmailConfigured else {
            throw GmailError.apiError("Gmail OAuth credentials not configured")
        }
        
        // Create a new refresh task that multiple callers can await
        let task = Task<String, Error> {
            let url = URL(string: "https://oauth2.googleapis.com/token")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            
            let body = [
                "grant_type": "refresh_token",
                "client_id": OAuthConfig.gmailClientID,
                "client_secret": OAuthConfig.gmailClientSecret,
                "refresh_token": refreshToken
            ]
            
            request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
                .joined(separator: "&")
                .data(using: .utf8)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GmailError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                // If refresh fails, clear tokens - user needs to re-authenticate
                if httpResponse.statusCode == 401 {
                    clearAccessToken()
                }
                throw GmailError.apiError("Token refresh failed: HTTP \(httpResponse.statusCode): \(errorMessage)")
            }
            
            struct RefreshTokenResponse: Codable {
                let access_token: String
                let expires_in: Int?
                let token_type: String
                let refresh_token: String? // Google may return a new refresh token
            }
            
            let tokenResponse = try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
            let newAccessToken = tokenResponse.access_token
            
            // Update tokens on main actor
            await MainActor.run {
                // If Google returns a new refresh token, use it; otherwise keep the existing one
                if let newRefreshToken = tokenResponse.refresh_token {
                    self.setAccessToken(newAccessToken, refreshToken: newRefreshToken)
                } else {
                    // Keep existing refresh token
                    self.setAccessToken(newAccessToken, refreshToken: nil)
                }
            }
            
            print("GmailService: Successfully refreshed access token")
            return newAccessToken
        }
        
        // Store the task so other callers can await it
        refreshTask = task
        
        // Await the task and clean up when done
        defer { refreshTask = nil }
        
        do {
            let newToken = try await task.value
            self.accessToken = newToken
        } catch {
            // Clear the task on error so a new refresh can be attempted
            refreshTask = nil
            throw error
        }
    }
    
    /// Make an authenticated request with automatic token refresh on 401
    private func makeAuthenticatedRequest(_ request: inout URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let token = accessToken else {
            throw GmailError.notAuthenticated
        }

        // Clear expired cooldown only; never block the request — let Google return 429 if still rate limited
        let now = Date()
        if let retryAfter = lastRateLimitRetryAfter, retryAfter <= now {
            lastRateLimitRetryAfter = nil
        }
        
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            if let retryAfter = parseRetryAfterDate(from: data) {
                lastRateLimitRetryAfter = retryAfter
            }
            debugLog(
                "GmailService.makeAuthenticatedRequest:rateLimit",
                message: "received 429 response",
                data: [
                    "retryAfter": lastRateLimitRetryAfter?.timeIntervalSince1970 as Any
                ],
                hypothesisId: "H3"
            )
        }
        
        // If we get 401, try refreshing the token and retry once
        if httpResponse.statusCode == 401 && refreshToken != nil {
            print("GmailService: Access token expired, attempting refresh...")
            try await refreshAccessToken()
            
            // Retry the request with new token
            guard let newToken = accessToken else {
                throw GmailError.notAuthenticated
            }
            request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            
            let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                throw GmailError.invalidResponse
            }
            
            return (retryData, retryHttpResponse)
        }
        
        return (data, httpResponse)
    }
    
    /// Get the current user's email address
    func getUserEmail() async throws -> String {
        let url = URL(string: "\(baseURL)/users/me/profile")!
        var request = URLRequest(url: url)
        
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        
        if httpResponse.statusCode == 401 {
            throw GmailError.notAuthenticated
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        struct GmailProfile: Codable {
            let emailAddress: String
        }
        
        let profile = try JSONDecoder().decode(GmailProfile.self, from: data)
        return profile.emailAddress
    }
    
    /// Fetch emails matching a query
    /// - Parameters:
    ///   - query: Gmail search query (e.g., "subject:New Docket")
    ///   - maxResults: Maximum number of results to return (default: 10)
    /// - Returns: Array of message references
    func fetchEmails(query: String, maxResults: Int = 10) async throws -> [GmailMessageReference] {
        agentLogApiCall(method: "fetchEmails", data: ["maxResults": maxResults])
        isFetching = true
        lastError = nil
        defer { isFetching = false }
        debugLog(
            "GmailService.fetchEmails:entry",
            message: "fetchEmails called",
            data: [
                "maxResults": maxResults,
                "queryLength": query.count,
                "queryHasUnread": query.contains("is:unread")
            ],
            hypothesisId: "H2"
        )
        
        var components = URLComponents(string: "\(baseURL)/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "\(maxResults)")
        ]
        
        guard let url = components.url else {
            throw GmailError.invalidURL
        }
        
        var request = URLRequest(url: url)
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        debugLog(
            "GmailService.fetchEmails:response",
            message: "fetchEmails response",
            data: [
                "statusCode": httpResponse.statusCode,
                "dataSize": data.count
            ],
            hypothesisId: "H2"
        )
        
        if httpResponse.statusCode == 401 {
            throw GmailError.notAuthenticated
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        let listResponse = try JSONDecoder().decode(GmailListResponse.self, from: data)
        return listResponse.messages ?? []
    }

    /// List all labels (system and user). Used to resolve user label IDs for new-docket scanning.
    func listMailboxLabels() async throws -> [GmailLabelListItem] {
        agentLogApiCall(method: "listMailboxLabels")
        let url = URL(string: "\(baseURL)/users/me/labels")!
        var request = URLRequest(url: url)
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        if httpResponse.statusCode == 401 {
            throw GmailError.notAuthenticated
        }
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        let decoded = try JSONDecoder().decode(GmailLabelListResponse.self, from: data)
        return decoded.labels ?? []
    }

    /// Gmail API label ID for a **user** label with this display name (case-insensitive, exact match).
    /// Caches all user labels from one `listMailboxLabels` call until `invalidateUserLabelIdCache()`.
    func userLabelId(matchingName name: String) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if let cached = userLabelIdCache[lower] {
            return cached
        }
        let labels = try await listMailboxLabels()
        for label in labels where label.type == "user" {
            userLabelIdCache[label.name.lowercased()] = label.id
        }
        return userLabelIdCache[lower]
    }
    
    /// Fetch a single message. Use `format: "metadata"` for label/header filtering without full bodies; `"full"` for parsing.
    func getEmail(messageId: String, format: String = "full") async throws -> GmailMessage {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await getEmailOnce(messageId: messageId, format: format)
            } catch {
                lastError = error
                let msg = error.localizedDescription
                let is429 = msg.contains("429") || msg.contains("RESOURCE_EXHAUSTED")
                if attempt < 3, is429 {
                    let delaySec = pow(2.0, Double(attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? GmailError.apiError("Gmail message fetch failed")
    }

    private func getEmailOnce(messageId: String, format: String) async throws -> GmailMessage {
        agentLogApiCall(method: "getEmail", data: ["format": format])
        isFetching = true
        lastError = nil
        defer { isFetching = false }

        var components = URLComponents(string: "\(baseURL)/users/me/messages/\(messageId)")!
        components.queryItems = [
            URLQueryItem(name: "format", value: format)
        ]

        guard let url = components.url else {
            throw GmailError.invalidURL
        }

        var request = URLRequest(url: url)
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)

        if httpResponse.statusCode == 401 {
            throw GmailError.notAuthenticated
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }

        do {
            let message = try JSONDecoder().decode(GmailMessage.self, from: data)
            return message
        } catch {
            throw GmailError.decodingError(error.localizedDescription)
        }
    }
    
    /// Batch fetch messages. Use `format: "metadata"` to filter by labels cheaply, then `full` only for survivors.
    /// - Returns: Messages in the **same order** as `messageReferences` (missing IDs omitted).
    func getEmails(messageReferences: [GmailMessageReference], format: String = "full") async throws -> [GmailMessage] {
        debugLog(
            "GmailService.getEmails:entry",
            message: "getEmails called",
            data: [
                "messageRefs": messageReferences.count,
                "format": format
            ],
            hypothesisId: "H2"
        )

        let maxConcurrent = 5
        var results: [(Int, GmailMessage?)] = []
        results.reserveCapacity(messageReferences.count)

        await withTaskGroup(of: (Int, GmailMessage?).self) { group in
            var nextIndex = 0
            var inFlight = 0

            func startNext() {
                while inFlight < maxConcurrent, nextIndex < messageReferences.count {
                    let idx = nextIndex
                    nextIndex += 1
                    inFlight += 1
                    let ref = messageReferences[idx]
                    group.addTask {
                        do {
                            let msg = try await self.getEmail(messageId: ref.id, format: format)
                            return (idx, msg)
                        } catch {
                            print("Error fetching email \(ref.id) format=\(format): \(error.localizedDescription)")
                            return (idx, nil)
                        }
                    }
                }
            }

            startNext()

            while let (idx, msg) = await group.next() {
                inFlight -= 1
                results.append((idx, msg))
                startNext()
            }
        }

        let sorted = results.sorted { $0.0 < $1.0 }
        var ordered: [GmailMessage] = []
        ordered.reserveCapacity(messageReferences.count)
        for (_, opt) in sorted {
            if let msg = opt {
                ordered.append(msg)
            }
        }

        debugLog(
            "GmailService.getEmails:exit",
            message: "getEmails completed",
            data: [
                "messages": ordered.count,
                "format": format
            ],
            hypothesisId: "H2"
        )

        return ordered
    }

    private func parseRetryAfterDate(from data: Data) -> Date? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"Retry\s+after\s+([0-9T:\.\-Z]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
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
                return fallback.date(from: value)
            }
        }
        return nil
    }
    
    /// Parse email content to extract docket information
    /// This is a simple helper - actual parsing should be done by EmailDocketParser
    func parseEmailContent(_ email: GmailMessage) -> (subject: String?, body: String?, from: String?) {
        let subject = email.subject
        let body = email.plainTextBody ?? email.htmlBody
        let from = email.from
        
        return (subject, body, from)
    }
    
    /// Mark an email as read
    func markAsRead(messageId: String) async throws {
        print("📧 GmailService: Attempting to mark email \(messageId) as read...")
        
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/modify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "removeLabelIds": ["UNREAD"]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (responseData, httpResponse) = try await makeAuthenticatedRequest(&request)
        
        print("📧 GmailService: markAsRead response status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 401 {
            print("📧 GmailService: ❌ Authentication failed (401)")
            throw GmailError.notAuthenticated
        }
        
        // Gmail API returns 200 for successful modify operations
        // Some APIs return 204 (No Content), but Gmail uses 200
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 204 else {
            let errorMessage = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            print("📧 GmailService: ❌ Failed to mark email as read - HTTP \(httpResponse.statusCode): \(errorMessage)")
            throw GmailError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        print("📧 GmailService: ✅ Successfully marked email \(messageId) as read")
    }
}

