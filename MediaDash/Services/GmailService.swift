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
    private var isRefreshing = false
    
    /// Initialize with access token
    init(accessToken: String? = nil) {
        self.accessToken = accessToken ?? KeychainService.retrieve(key: "gmail_access_token")
        // Refresh token is loaded lazily via computed property when needed
        // This ensures it's always available from Keychain
    }
    
    /// Get refresh token from keychain
    private var refreshToken: String? {
        get {
            return KeychainService.retrieve(key: "gmail_refresh_token")
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
    func setAccessToken(_ token: String, refreshToken: String? = nil) {
        self.accessToken = token
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
    private func refreshAccessToken() async throws {
        guard !isRefreshing else {
            // Already refreshing, wait a bit
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            return
        }
        
        guard let refreshToken = refreshToken else {
            throw GmailError.notAuthenticated
        }
        
        guard OAuthConfig.isGmailConfigured else {
            throw GmailError.apiError("Gmail OAuth credentials not configured")
        }
        
        isRefreshing = true
        defer { isRefreshing = false }
        
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
        // If Google returns a new refresh token, use it; otherwise keep the existing one
        if let newRefreshToken = tokenResponse.refresh_token {
            setAccessToken(tokenResponse.access_token, refreshToken: newRefreshToken)
        } else {
            // Keep existing refresh token
            setAccessToken(tokenResponse.access_token, refreshToken: nil)
        }
        
        print("GmailService: Successfully refreshed access token")
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
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/modify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "removeLabelIds": ["UNREAD"]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, httpResponse) = try await makeAuthenticatedRequest(&request)
        
        if httpResponse.statusCode == 401 {
            throw GmailError.notAuthenticated
        }
        
        guard httpResponse.statusCode == 200 else {
            throw GmailError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }
}

