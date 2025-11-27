import Foundation

// MARK: - Gmail API Models

struct GmailListResponse: Codable {
    let messages: [GmailMessageReference]?
    let nextPageToken: String?
    let resultSizeEstimate: Int
}

struct GmailThread: Codable {
    let id: String
    let messages: [GmailMessage]?
    let historyId: String?
}

struct GmailMessageReference: Codable {
    let id: String
    let threadId: String
}

struct GmailMessage: Codable {
    let id: String
    let threadId: String
    let labelIds: [String]?
    let snippet: String?
    let historyId: String?
    let internalDate: String?
    let payload: GmailMessagePart?
    let sizeEstimate: Int?
    
    enum CodingKeys: String, CodingKey {
        case id
        case threadId
        case labelIds
        case snippet
        case historyId
        case internalDate
        case payload
        case sizeEstimate
    }
}

struct GmailMessagePart: Codable {
    let partId: String?
    let mimeType: String?
    let filename: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailMessagePart]?
    
    enum CodingKeys: String, CodingKey {
        case partId
        case mimeType
        case filename
        case headers
        case body
        case parts
    }
}

struct GmailHeader: Codable {
    let name: String
    let value: String
}

struct GmailBody: Codable {
    let attachmentId: String?
    let size: Int?
    let data: String?
}

struct GmailTokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let token_type: String
    let scope: String?
}

enum GmailError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case apiError(String)
    case invalidURL
    case decodingError(String)
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Gmail authentication required. Please connect your Gmail account."
        case .invalidResponse:
            return "Invalid response from Gmail API"
        case .apiError(let message):
            return "Gmail API error: \(message)"
        case .invalidURL:
            return "Invalid Gmail API URL"
        case .decodingError(let message):
            return "Failed to decode Gmail response: \(message)"
        }
    }
}

// MARK: - Helper Extensions

extension GmailMessagePart {
    /// Get header value by name (case-insensitive)
    func getHeaderValue(name: String) -> String? {
        return headers?.first(where: { $0.name.lowercased() == name.lowercased() })?.value
    }
    
    /// Get plain text body content (recursively searches all nested parts)
    func getPlainTextBody() -> String? {
        // If this part itself has plain text body data, return it
        if mimeType == "text/plain", let body = body, let data = body.data {
            return decodeBase64Url(data)
        }
        
        // Check nested parts recursively
        if let parts = parts {
            // First, try to find text/plain
            for part in parts {
                if part.mimeType == "text/plain" {
                    if let text = part.getPlainTextBody() {
                        return text
                    }
                }
            }
            // If no plain text found, try text/html as fallback
            for part in parts {
                if part.mimeType == "text/html" {
                    if let html = part.getHTMLBody() {
                        // Convert HTML to plain text (simple strip)
                        return stripHTML(html)
                    }
                }
            }
            // If still nothing, recursively check all parts (for multipart/alternative, etc.)
            for part in parts {
                if let text = part.getPlainTextBody() {
                    return text
                }
            }
        }
        
        return nil
    }
    
    /// Simple HTML stripping (removes tags, keeps text)
    private func stripHTML(_ html: String) -> String {
        var text = html
        
        // Remove script and style tags and their content (using NSRegularExpression for multiline support)
        if let scriptRegex = try? NSRegularExpression(pattern: #"<script[^>]*>.*?</script>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = scriptRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if let styleRegex = try? NSRegularExpression(pattern: #"<style[^>]*>.*?</style>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = styleRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        
        // Remove HTML tags
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        
        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        
        // Normalize whitespace
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Get HTML body content
    func getHTMLBody() -> String? {
        if mimeType == "text/html", let body = body, let data = body.data {
            return decodeBase64Url(data)
        }
        
        if let parts = parts {
            for part in parts {
                if part.mimeType == "text/html" {
                    return part.getHTMLBody()
                }
            }
        }
        
        return nil
    }
    
    /// Decode base64url string
    private func decodeBase64Url(_ base64url: String) -> String? {
        var base64 = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: base64),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
}

extension GmailMessage {
    /// Get subject from headers
    var subject: String? {
        return payload?.getHeaderValue(name: "Subject")
    }
    
    /// Get sender from headers
    var from: String? {
        return payload?.getHeaderValue(name: "From")
    }
    
    /// Get recipients from headers (To, Cc, Bcc)
    var to: String? {
        return payload?.getHeaderValue(name: "To")
    }
    
    var cc: String? {
        return payload?.getHeaderValue(name: "Cc")
    }
    
    var bcc: String? {
        return payload?.getHeaderValue(name: "Bcc")
    }
    
    /// Get all recipients (To, Cc, Bcc combined)
    var allRecipients: [String] {
        var recipients: [String] = []
        
        // Parse To field
        if let toField = to {
            recipients.append(contentsOf: parseEmailAddresses(from: toField))
        }
        
        // Parse Cc field
        if let ccField = cc {
            recipients.append(contentsOf: parseEmailAddresses(from: ccField))
        }
        
        // Parse Bcc field
        if let bccField = bcc {
            recipients.append(contentsOf: parseEmailAddresses(from: bccField))
        }
        
        return recipients
    }
    
    /// Parse email addresses from a header field (handles "Name <email@example.com>" format)
    private func parseEmailAddresses(from field: String) -> [String] {
        var addresses: [String] = []
        
        // Split by comma to handle multiple addresses
        let parts = field.components(separatedBy: ",")
        
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check if it's in format "Name <email@example.com>"
            if let regex = try? NSRegularExpression(pattern: #"<([^>]+)>"#, options: []),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               match.numberOfRanges >= 2,
               let emailRange = Range(match.range(at: 1), in: trimmed) {
                let email = String(trimmed[emailRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                addresses.append(email)
            } else {
                // If no angle brackets, assume the whole string is the email
                if trimmed.contains("@") {
                    addresses.append(trimmed)
                }
            }
        }
        
        return addresses
    }
    
    /// Get plain text body
    var plainTextBody: String? {
        return payload?.getPlainTextBody()
    }
    
    /// Get HTML body
    var htmlBody: String? {
        return payload?.getHTMLBody()
    }
    
    /// Get date from headers
    var date: Date? {
        guard let dateString = payload?.getHeaderValue(name: "Date") else {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        // Try alternative formats
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss Z"
        if let date = formatter.date(from: dateString) {
            return date
        }
        
        // Try parsing internal date if available
        if let internalDate = internalDate, let timestamp = Double(internalDate) {
            return Date(timeIntervalSince1970: timestamp / 1000)
        }
        
        return nil
    }
}

