import Foundation
import Combine

/// Logger for CodeMind operations - captures all activity for debug window
@MainActor
class CodeMindLogger: ObservableObject {
    static let shared = CodeMindLogger()
    
    @Published var logs: [CodeMindLogEntry] = []
    @Published var isEnabled = true
    
    private let maxLogs = 1000 // Keep last 1000 logs
    private var logQueue = DispatchQueue(label: "com.mediadash.codemind.logger", qos: .utility)

    // Patterns to redact from log messages (API keys, tokens, etc.)
    private let sensitivePatterns: [(pattern: String, replacement: String)] = [
        // Google API keys (key=...)
        (#"key=[A-Za-z0-9_-]{20,}"#, "key=[REDACTED]"),
        // Bearer tokens
        (#"Bearer [A-Za-z0-9._-]+"#, "Bearer [REDACTED]"),
        // Generic API key patterns
        (#"api[_-]?key[=:]\s*[A-Za-z0-9_-]{16,}"#, "api_key=[REDACTED]"),
        // OAuth tokens
        (#"access[_-]?token[=:]\s*[A-Za-z0-9._-]+"#, "access_token=[REDACTED]"),
        (#"refresh[_-]?token[=:]\s*[A-Za-z0-9._-]+"#, "refresh_token=[REDACTED]"),
    ]

    private init() {}

    /// Sanitize a message by redacting sensitive information like API keys
    private func sanitize(_ message: String) -> String {
        var sanitized = message
        for (pattern, replacement) in sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                sanitized = regex.stringByReplacingMatches(
                    in: sanitized,
                    options: [],
                    range: NSRange(sanitized.startIndex..., in: sanitized),
                    withTemplate: replacement
                )
            }
        }
        return sanitized
    }

    /// Sanitize metadata dictionary values
    private func sanitizeMetadata(_ metadata: [String: Any]?) -> [String: Any]? {
        guard let metadata = metadata else { return nil }
        var sanitized: [String: Any] = [:]
        for (key, value) in metadata {
            if let stringValue = value as? String {
                sanitized[key] = sanitize(stringValue)
            } else {
                sanitized[key] = value
            }
        }
        return sanitized
    }
    
    /// Log a CodeMind operation
    func log(_ level: CodeMindLogLevel, _ message: String, category: CodeMindLogCategory = .general, metadata: [String: Any]? = nil) {
        guard isEnabled else { return }

        // Sanitize message and metadata to remove API keys and other sensitive data
        let sanitizedMessage = sanitize(message)
        let sanitizedMetadata = sanitizeMetadata(metadata)

        let entry = CodeMindLogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: sanitizedMessage,
            metadata: sanitizedMetadata
        )
        
        logQueue.async { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                self.logs.append(entry)
                
                // Trim logs if too many
                if self.logs.count > self.maxLogs {
                    self.logs.removeFirst(self.logs.count - self.maxLogs)
                }
            }
        }
        
        // Also write to FileLogger for AI workflow (following debug workflow pattern)
        let logLevel: LogLevel
        switch level {
        case .debug: logLevel = .debug
        case .info: logLevel = .info
        case .success: logLevel = .info
        case .warning: logLevel = .warning
        case .error: logLevel = .error
        }
        
        var logMessage = sanitizedMessage
        if let metadata = sanitizedMetadata, !metadata.isEmpty {
            let metadataString = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            logMessage += " [\(metadataString)]"
        }
        
        // Write to FileLogger (FileLogger uses synchronizeFile() so writes are immediate)
        // Use Task to ensure we're on MainActor since FileLogger is @MainActor
        Task { @MainActor in
            FileLogger.shared.log(logMessage, level: logLevel, component: "CodeMind-\(category.rawValue)")
        }
        
        // Also print to console for development (Xcode console)
        // Note: These print() statements appear in Xcode console but are NOT captured by FileLogger
        // Only the FileLogger.shared.log() call above writes to the file
        let emoji = level.emoji
        print("\(emoji) [CodeMind \(category.rawValue)] \(sanitizedMessage)")
        if let metadata = sanitizedMetadata, !metadata.isEmpty {
            print("   Metadata: \(metadata)")
        }
    }
    
    /// Clear all logs
    func clear() {
        logs.removeAll()
    }
    
    /// Get logs filtered by category
    func logs(for category: CodeMindLogCategory) -> [CodeMindLogEntry] {
        logs.filter { $0.category == category }
    }
    
    /// Get logs filtered by level
    func logs(for level: CodeMindLogLevel) -> [CodeMindLogEntry] {
        logs.filter { $0.level == level }
    }
    
    /// Get all logs as a formatted string for copying
    func getAllLogsAsText(filtered: [CodeMindLogEntry]) -> String {
        var output = "=== CodeMind Debug Logs ===\n"
        output += "Generated: \(Date().formatted(date: .complete, time: .complete))\n"
        output += "Total Logs: \(filtered.count)\n"
        output += String(repeating: "=", count: 50) + "\n\n"
        
        for log in filtered {
            output += "[\(log.timestamp.formatted(date: .omitted, time: .standard))] "
            output += "\(log.level.rawValue) [\(log.category.rawValue)]\n"
            output += "\(log.message)\n"
            
            if let metadata = log.metadata, !metadata.isEmpty {
                for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
                    output += "  \(key): \(value)\n"
                }
            }
            
            output += "\n"
        }
        
        return output
    }
    
    /// Log detailed classification information for debugging
    func logDetailedClassification(
        emailId: String,
        subject: String?,
        from: String?,
        threadId: String?,
        classificationType: String, // "newDocket" or "fileDelivery"
        isFileDelivery: Bool?,
        confidence: Double?,
        reasoning: String?,
        threadContext: String?,
        prompt: String?,
        llmResponse: String?,
        recipients: [String]?,
        emailBody: String?
    ) {
        var debugMessage = "📊 Classification: \"\(subject ?? "no subject")\" from \(from ?? "unknown")\n"
        
        // Brief summary only
        if let from = from {
            let domain = from.split(separator: "@").last.map(String.init) ?? ""
            let isCompany = domain.lowercased().contains("grayson")
            if isCompany {
                debugMessage += "  ⚠️ Company domain detected\n"
            }
        }
        
        // Brief email body preview (first 200 chars only)
        if let emailBody = emailBody, !emailBody.isEmpty {
            let preview = String(emailBody.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            debugMessage += "EMAIL PREVIEW: \(preview)\(emailBody.count > 200 ? "..." : "")\n\n"
        }
        
        debugMessage += "CLASSIFICATION RESULT:\n"
        if let isFileDelivery = isFileDelivery {
            debugMessage += "- Is File Delivery: \(isFileDelivery)\n"
        }
        if let confidence = confidence {
            debugMessage += "- Confidence: \(String(format: "%.0f", confidence * 100))%\n"
        }
        if let reasoning = reasoning {
            debugMessage += "- Reasoning: \(reasoning)\n"
        }
        
        // Brief LLM response preview (just the JSON result, not full prompt)
        if let llmResponse = llmResponse, !llmResponse.isEmpty {
            // Try to extract just the JSON part if it's wrapped in other text
            let jsonPreview = llmResponse.count > 300 ? String(llmResponse.prefix(300)) + "..." : llmResponse
            debugMessage += "\nRESPONSE: \(jsonPreview)\n"
        }
        
        // Log as a single entry with concise debug info
        self.log(.debug, debugMessage, category: .classification, metadata: [
            "emailId": emailId,
            "subject": subject ?? "nil",
            "from": from ?? "unknown",
            "classificationType": classificationType,
            "isFileDelivery": isFileDelivery.map { "\($0)" } ?? "nil",
            "confidence": confidence.map { String(format: "%.2f", $0) } ?? "nil"
        ])
    }
}

// MARK: - Log Entry

struct CodeMindLogEntry: Identifiable {
    let id: String
    let timestamp: Date
    let level: CodeMindLogLevel
    let category: CodeMindLogCategory
    let message: String
    let metadata: [String: String]? // Simplified for Codable
    
    init(timestamp: Date, level: CodeMindLogLevel, category: CodeMindLogCategory, message: String, metadata: [String: Any]? = nil) {
        self.id = UUID().uuidString
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        // Convert metadata to String values for Codable
        self.metadata = metadata?.mapValues { "\($0)" }
    }
}

// MARK: - Log Level

enum CodeMindLogLevel: String, Codable {
    case debug = "DEBUG"
    case info = "INFO"
    case success = "SUCCESS"
    case warning = "WARNING"
    case error = "ERROR"
    
    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .success: return "✅"
        case .warning: return "⚠️"
        case .error: return "❌"
        }
    }
    
    var color: String {
        switch self {
        case .debug: return "gray"
        case .info: return "blue"
        case .success: return "green"
        case .warning: return "orange"
        case .error: return "red"
        }
    }
}

// MARK: - Log Category

enum CodeMindLogCategory: String, Codable, CaseIterable {
    case initialization = "Initialization"
    case classification = "Classification"
    case feedback = "Feedback"
    case cache = "Cache"
    case llm = "LLM"
    case indexing = "Indexing"
    case general = "General"
}

