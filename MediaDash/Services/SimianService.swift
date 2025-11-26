import Foundation
import Combine
import SwiftUI

/// Service for interacting with Simian via Zapier webhook
/// 
/// Uses Zapier as a bridge to create projects in Simian.
/// Requires a Zapier webhook URL configured in settings.
@MainActor
class SimianService: ObservableObject {
    @Published var isFetching = false
    @Published var lastError: String?
    
    private var webhookURL: String?
    
    /// Initialize with webhook URL
    init(webhookURL: String? = nil) {
        self.webhookURL = webhookURL ?? UserDefaults.standard.string(forKey: "simian_webhook_url")
    }
    
    /// Set webhook URL
    func setWebhookURL(_ url: String) {
        self.webhookURL = url
        UserDefaults.standard.set(url, forKey: "simian_webhook_url")
    }
    
    /// Clear webhook URL
    func clearWebhookURL() {
        self.webhookURL = nil
        UserDefaults.standard.removeObject(forKey: "simian_webhook_url")
    }
    
    /// Check if configured
    var isConfigured: Bool {
        guard let url = webhookURL, !url.isEmpty else { return false }
        return URL(string: url) != nil
    }
    
    /// Create a job in Simian via Zapier webhook
    /// - Parameters:
    ///   - docketNumber: The docket number
    ///   - jobName: The job name
    /// - Returns: Success status
    /// 
    /// Sends a POST request to the configured Zapier webhook URL.
    /// The webhook should trigger a Zap that creates a project in Simian.
    func createJob(docketNumber: String, jobName: String) async throws {
        guard let webhookURLString = webhookURL, !webhookURLString.isEmpty,
              let url = URL(string: webhookURLString) else {
            throw SimianError.notConfigured
        }
        
        isFetching = true
        lastError = nil
        
        defer {
            isFetching = false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Zapier webhook expects JSON payload
        // Format: { "docket_number": "...", "job_name": "..." }
        let body: [String: Any] = [
            "docket_number": docketNumber,
            "job_name": jobName
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw SimianError.apiError("Failed to encode request: \(error.localizedDescription)")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SimianError.apiError("Invalid response from webhook")
            }
            
            // Zapier webhooks typically return 200 on success
            // Some may return 201 or other 2xx codes
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw SimianError.apiError("Webhook returned error: \(errorMessage)")
            }
            
            // Success - Zapier received the webhook
            // The actual Simian project creation happens in Zapier
            print("✅ SimianService: Webhook sent successfully for docket \(docketNumber): \(jobName)")
            
        } catch let error as SimianError {
            lastError = error.localizedDescription
            throw error
        } catch {
            let errorMessage = error.localizedDescription
            lastError = errorMessage
            throw SimianError.apiError("Network error: \(errorMessage)")
        }
    }
}

enum SimianError: LocalizedError {
    case notConfigured
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Simian webhook URL is not configured. Please set the Zapier webhook URL in settings."
        case .apiError(let message):
            return "Simian webhook error: \(message)"
        }
    }
}

