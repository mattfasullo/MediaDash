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
        // Store to personal Keychain (shared keys are managed separately)
        _ = KeychainService.store(key: "gmail_access_token", value: token)
        
        if let refreshToken = refreshToken {
            self.refreshToken = refreshToken
        }
    }
    
    /// Clear access token and refresh token
    func clearAccessToken() {
        self.accessToken = nil
        KeychainService.delete(key: "gmail_access_token")
        KeychainService.delete(key: "gmail_refresh_token")
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
        
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailError.invalidResponse
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
        isFetching = true
        lastError = nil
        defer { isFetching = false }
        
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
    
    /// Get full email message by ID
    /// - Parameter messageId: The message ID from fetchEmails
    /// - Returns: Full GmailMessage object
    func getEmail(messageId: String) async throws -> GmailMessage {
        isFetching = true
        lastError = nil
        defer { isFetching = false }
        
        // Request full format to get body content
        var components = URLComponents(string: "\(baseURL)/users/me/messages/\(messageId)")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "full")
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
    
    /// Get full thread by ID
    /// - Parameter threadId: The thread ID
    /// - Returns: Full GmailThread object with all messages
    func getThread(threadId: String) async throws -> GmailThread {
        isFetching = true
        lastError = nil
        defer { isFetching = false }
        
        var components = URLComponents(string: "\(baseURL)/users/me/threads/\(threadId)")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "full")
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
            let thread = try JSONDecoder().decode(GmailThread.self, from: data)
            return thread
        } catch {
            throw GmailError.decodingError(error.localizedDescription)
        }
    }
    
    /// Batch fetch full email messages
    /// - Parameter messageReferences: Array of message references from fetchEmails
    /// - Returns: Array of full GmailMessage objects
    func getEmails(messageReferences: [GmailMessageReference]) async throws -> [GmailMessage] {
        var messages: [GmailMessage] = []
        
        // Fetch messages with limited concurrency to avoid rate limits
        let maxConcurrent = 5
        var tasks: [Task<GmailMessage?, Never>] = []
        
        for ref in messageReferences {
            // Wait if we have too many concurrent tasks
            if tasks.count >= maxConcurrent {
                // Wait for one to complete
                if let firstTask = tasks.first {
                    if let message = await firstTask.value {
                        messages.append(message)
                    }
                    tasks.removeFirst()
                }
            }
            
            // Create new task
            let task = Task<GmailMessage?, Never> {
                do {
                    return try await self.getEmail(messageId: ref.id)
                } catch {
                    print("Error fetching email \(ref.id): \(error.localizedDescription)")
                    return nil
                }
            }
            tasks.append(task)
        }
        
        // Wait for remaining tasks
        for task in tasks {
            if let message = await task.value {
                messages.append(message)
            }
        }
        
        return messages
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
    
    /// Download an image from a URL and convert it to a base64 data URI
    /// - Parameter imageURL: The URL of the image to download
    /// - Returns: A data URI string (e.g., "data:image/jpeg;base64,...") or nil if download fails
    private func downloadImageAsDataURI(from imageURL: URL) async throws -> String? {
        // Create request with User-Agent header
        var request = URLRequest(url: imageURL)
        request.setValue("MediaDash/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        
        // Determine MIME type from Content-Type header or file extension
        var mimeType = "image/jpeg" // default
        
        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.hasPrefix("image/") {
            mimeType = contentType
        } else {
            // Fall back to file extension
            let pathExtension = imageURL.pathExtension.lowercased()
            switch pathExtension {
            case "jpg", "jpeg":
                mimeType = "image/jpeg"
            case "png":
                mimeType = "image/png"
            case "gif":
                mimeType = "image/gif"
            case "webp":
                mimeType = "image/webp"
            case "bmp":
                mimeType = "image/bmp"
            case "svg":
                mimeType = "image/svg+xml"
            default:
                // Try to detect from data
                if data.count >= 4 {
                    let header = data.prefix(4)
                    if header.starts(with: [0xFF, 0xD8, 0xFF]) {
                        mimeType = "image/jpeg"
                    } else if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
                        mimeType = "image/png"
                    } else if header.starts(with: [0x47, 0x49, 0x46]) {
                        mimeType = "image/gif"
                    } else if header.starts(with: [0x52, 0x49, 0x46, 0x46]) {
                        mimeType = "image/webp"
                    }
                }
            }
        }
        
        // Convert to base64
        let base64String = data.base64EncodedString()
        
        // Return as data URI
        return "data:\(mimeType);base64,\(base64String)"
    }
    
    /// Send a reply email
    /// IMPORTANT: This reply ONLY goes to the specified recipients in the 'to' parameter.
    /// All other recipients (CC, BCC) are explicitly removed - it will NOT go to clients.
    /// - Parameters:
    ///   - messageId: The ID of the original message to reply to
    ///   - body: The email body text
    ///   - to: Array of recipient email addresses (ONLY these recipients will receive the email)
    ///   - imageURL: Optional image URL to embed in the email (creates HTML email)
    /// - Returns: The sent message ID
    func sendReply(messageId: String, body: String, to: [String], imageURL: URL? = nil) async throws -> String {
        isFetching = true
        lastError = nil
        defer { isFetching = false }
        
        // Get the original message to extract thread ID and subject
        let originalMessage = try await getEmail(messageId: messageId)
        
        // Build the email message
        // Gmail API requires messages to be in RFC 2822 format, base64url encoded
        var emailString = ""
        
        // Headers
        // Get authenticated user's email from original message's "To" or "Cc" headers
        // (they're replying to their own email, so it should be in the thread)
        var userEmail: String? = nil
        if let toHeader = originalMessage.payload?.headers?.first(where: { $0.name.lowercased() == "to" })?.value {
            userEmail = extractEmailAddress(from: toHeader)
        } else if let ccHeader = originalMessage.payload?.headers?.first(where: { $0.name.lowercased() == "cc" })?.value {
            userEmail = extractEmailAddress(from: ccHeader)
        }
        
        // Add From header with display name format for better display in email clients
        if let email = userEmail {
            let displayName = formatDisplayName(from: email)
            emailString += "From: \(displayName) <\(email)>\r\n"
        }
        
        // CRITICAL: Only send to specified recipients (media email only)
        // We only set the To header - no CC/BCC headers are included to ensure
        // this email ONLY goes to the specified recipients and removes everyone else
        emailString += "To: \(to.joined(separator: ", "))\r\n"
        
        // Get original subject and add "Re:" if not already present
        var subject = originalMessage.subject ?? ""
        if !subject.lowercased().hasPrefix("re:") {
            subject = "Re: \(subject)"
        }
        emailString += "Subject: \(subject)\r\n"
        
        // Add In-Reply-To and References headers for threading
        if let messageIdHeader = originalMessage.payload?.headers?.first(where: { $0.name.lowercased() == "message-id" })?.value {
            emailString += "In-Reply-To: \(messageIdHeader)\r\n"
            emailString += "References: \(messageIdHeader)\r\n"
        }
        
        // Thread ID is automatically handled by Gmail when replying (via In-Reply-To and References headers)
        
        // If imageURL is provided, download and embed as base64 data URI
        var imageDataURI: String? = nil
        if let imageURL = imageURL {
            // Download image and convert to data URI
            do {
                imageDataURI = try await downloadImageAsDataURI(from: imageURL)
            } catch {
                // If image download fails, log but continue without image
                print("GmailService: Failed to download image from \(imageURL): \(error.localizedDescription)")
            }
        }
        
        // Create HTML email if we have an image, otherwise plain text
        if let dataURI = imageDataURI {
            // Create multipart/alternative email with both HTML and plain text
            let boundary = "----=_Part_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            
            emailString += "MIME-Version: 1.0\r\n"
            emailString += "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n"
            emailString += "\r\n"
            
            // Plain text version
            emailString += "--\(boundary)\r\n"
            emailString += "Content-Type: text/plain; charset=UTF-8\r\n"
            emailString += "\r\n"
            emailString += "\(body)\r\n\r\n--\r\nGrabbed via MediaDash\r\n"
            
            // HTML version with embedded image
            emailString += "\r\n--\(boundary)\r\n"
            emailString += "Content-Type: text/html; charset=UTF-8\r\n"
            emailString += "\r\n"
            
            // Escape HTML in body text
            let escapedBody = body
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
            
            // Embed image as base64 data URI directly in HTML
            let htmlBody = """
            <html>
            <body>
                <p>\(escapedBody)</p>
                <p><img src="\(dataURI)" alt="Image" style="max-width: 100%; height: auto;" /></p>
                <hr>
                <p style="font-size: 12px; color: #666;">Grabbed via MediaDash</p>
            </body>
            </html>
            """
            
            emailString += htmlBody
            emailString += "\r\n--\(boundary)--\r\n"
        } else {
            // Plain text email
        emailString += "Content-Type: text/plain; charset=UTF-8\r\n"
        emailString += "\r\n"
        
        // Always add MediaDash signature
        let emailBody = "\(body)\n\n--\nGrabbed via MediaDash"
        emailString += emailBody
        }
        
        // Encode to base64url
        let emailData = emailString.data(using: .utf8)!
        let base64String = emailData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        // Prepare the request
        let url = URL(string: "\(baseURL)/users/me/messages/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "raw": base64String,
            "threadId": originalMessage.threadId
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        
        if httpResponse.statusCode == 401 {
            throw GmailError.notAuthenticated
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        struct SendResponse: Codable {
            let id: String
            let threadId: String?
        }
        
        let response = try JSONDecoder().decode(SendResponse.self, from: data)
        return response.id
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
    
    /// Format display name from email address
    /// e.g., "mattfasullo@example.com" -> "Matt Fasullo"
    private func formatDisplayName(from email: String) -> String {
        // Extract username part (before @)
        let username = email.components(separatedBy: "@").first ?? email
        
        // Split on common separators and capitalize
        var nameParts: [String] = []
        
        // Try splitting on dots first
        if username.contains(".") {
            nameParts = username.components(separatedBy: ".")
        }
        // Try splitting on underscores
        else if username.contains("_") {
            nameParts = username.components(separatedBy: "_")
        }
        // Try splitting on camelCase (detect capital letters)
        else if username.rangeOfCharacter(from: CharacterSet.uppercaseLetters) != nil {
            // Split on capital letters (e.g., "mattFasullo" -> ["matt", "Fasullo"])
            let regex = try? NSRegularExpression(pattern: "([a-z]+)([A-Z][a-z]*)", options: [])
            if let matches = regex?.matches(in: username, range: NSRange(username.startIndex..., in: username)) {
                for match in matches {
                    for i in 1..<match.numberOfRanges {
                        if let range = Range(match.range(at: i), in: username) {
                            nameParts.append(String(username[range]))
                        }
                    }
                }
            }
            if nameParts.isEmpty {
                nameParts = [username]
            }
        }
        // Single word
        else {
            nameParts = [username]
        }
        
        // Capitalize each part
        let capitalizedParts = nameParts.map { part in
            part.isEmpty ? "" : part.prefix(1).uppercased() + part.dropFirst().lowercased()
        }
        
        return capitalizedParts.joined(separator: " ")
    }
    
    /// Download an image from a URL and convert it to a base64 data URI
    /// - Parameter url: The URL of the image to download
    /// - Returns: A data URI string (e.g., "data:image/jpeg;base64,...")
    private func downloadImageAsDataURI(from url: URL) async throws -> String {
        // Download the image
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw GmailError.apiError("Failed to download image: HTTP \(response)")
        }
        
        // Determine MIME type from URL or response
        var mimeType = "image/jpeg" // Default
        if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
           contentType.hasPrefix("image/") {
            mimeType = contentType
        } else {
            // Try to determine from URL extension
            let pathExtension = url.pathExtension.lowercased()
            switch pathExtension {
            case "jpg", "jpeg":
                mimeType = "image/jpeg"
            case "png":
                mimeType = "image/png"
            case "gif":
                mimeType = "image/gif"
            case "webp":
                mimeType = "image/webp"
            case "bmp":
                mimeType = "image/bmp"
            case "svg":
                mimeType = "image/svg+xml"
            default:
                mimeType = "image/jpeg" // Default fallback
            }
        }
        
        // Convert to base64
        let base64String = data.base64EncodedString()
        
        // Return as data URI
        return "data:\(mimeType);base64,\(base64String)"
    }
}

