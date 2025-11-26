import Foundation

// MARK: - Gmail API Models

struct GmailListResponse: Codable {
    let messages: [GmailMessageReference]?
    let nextPageToken: String?
    let resultSizeEstimate: Int
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
    
    /// Get plain text body content
    func getPlainTextBody() -> String? {
        if let body = body, let data = body.data {
            return decodeBase64Url(data)
        }
        
        // Check nested parts
        if let parts = parts {
            for part in parts {
                if part.mimeType == "text/plain" || part.mimeType == "text/html" {
                    return part.getPlainTextBody()
                }
            }
        }
        
        return nil
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

