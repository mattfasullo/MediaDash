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
    
    /// Initialize with access token
    init(accessToken: String? = nil) {
        self.accessToken = accessToken ?? KeychainService.retrieve(key: "gmail_access_token")
    }
    
    /// Set access token
    func setAccessToken(_ token: String) {
        self.accessToken = token
        _ = KeychainService.store(key: "gmail_access_token", value: token)
    }
    
    /// Clear access token
    func clearAccessToken() {
        self.accessToken = nil
        KeychainService.delete(key: "gmail_access_token")
    }
    
    /// Check if authenticated
    var isAuthenticated: Bool {
        return accessToken != nil
    }
    
    /// Get the current user's email address
    func getUserEmail() async throws -> String {
        guard let token = accessToken else {
            throw GmailError.notAuthenticated
        }
        
        let url = URL(string: "\(baseURL)/users/me/profile")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailError.invalidResponse
        }
        
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
        guard let token = accessToken else {
            throw GmailError.notAuthenticated
        }
        
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailError.invalidResponse
        }
        
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
        guard let token = accessToken else {
            throw GmailError.notAuthenticated
        }
        
        isFetching = true
        lastError = nil
        defer { isFetching = false }
        
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailError.invalidResponse
        }
        
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
        guard let token = accessToken else {
            throw GmailError.notAuthenticated
        }
        
        let url = URL(string: "\(baseURL)/users/me/messages/\(messageId)/modify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "removeLabelIds": ["UNREAD"]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw GmailError.notAuthenticated
        }
        
        guard httpResponse.statusCode == 200 else {
            throw GmailError.apiError("HTTP \(httpResponse.statusCode)")
        }
    }
}

