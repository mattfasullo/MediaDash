import Foundation
import Combine

/// Types of anomalies that can be detected
enum ClassificationAnomaly: Codable, Identifiable {
    case unclassifiedEmail(emailId: String, subject: String, reason: String)
    case lowConfidence(recordId: UUID, confidence: Double, subject: String)
    case misclassification(recordId: UUID, expectedType: String, actualType: String)
    case confidenceDrop(date: Date, previousAvg: Double, currentAvg: Double)
    case patternMismatch(pattern: String, frequency: Int, successRate: Double)
    
    var id: String {
        switch self {
        case .unclassifiedEmail(let emailId, _, _):
            return "unclassified_\(emailId)"
        case .lowConfidence(let recordId, _, _):
            return "lowconf_\(recordId.uuidString)"
        case .misclassification(let recordId, _, _):
            return "misclass_\(recordId.uuidString)"
        case .confidenceDrop(let date, _, _):
            return "confdrop_\(date.timeIntervalSince1970)"
        case .patternMismatch(let pattern, _, _):
            return "pattern_\(pattern.hashValue)"
        }
    }
    
    var severity: AnomalySeverity {
        switch self {
        case .unclassifiedEmail: return .warning
        case .lowConfidence(_, let conf, _): return conf < 0.5 ? .high : .medium
        case .misclassification: return .high
        case .confidenceDrop(_, _, let current): return current < 0.6 ? .high : .medium
        case .patternMismatch(_, _, let rate): return rate < 0.5 ? .high : .medium
        }
    }
    
    var description: String {
        switch self {
        case .unclassifiedEmail(_, let subject, let reason):
            return "Email may have been missed: '\(subject.prefix(50))...' - \(reason)"
        case .lowConfidence(_, let confidence, let subject):
            return "Low confidence (\(String(format: "%.1f%%", confidence * 100))) for '\(subject.prefix(40))...'"
        case .misclassification(_, let expected, let actual):
            return "Classification mismatch: expected \(expected), got \(actual)"
        case .confidenceDrop(_, let prev, let curr):
            return "Confidence dropped from \(String(format: "%.1f%%", prev * 100)) to \(String(format: "%.1f%%", curr * 100))"
        case .patternMismatch(let pattern, let freq, let rate):
            return "Pattern '\(pattern)' has low success rate (\(String(format: "%.1f%%", rate * 100))) with \(freq) uses"
        }
    }
}

enum AnomalySeverity: String, Codable, Comparable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case warning = "warning"
    
    static func < (lhs: AnomalySeverity, rhs: AnomalySeverity) -> Bool {
        let order: [AnomalySeverity] = [.low, .warning, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// Service for detecting anomalies in email classification
@MainActor
class CodeMindAnomalyDetector: ObservableObject {
    static let shared = CodeMindAnomalyDetector()
    
    @Published var detectedAnomalies: [ClassificationAnomaly] = []
    @Published var lastCheckTime: Date?
    @Published var isChecking = false
    
    private let history = CodeMindClassificationHistory.shared
    private let confidenceThreshold = 0.7
    private let confidenceDropThreshold = 0.15 // 15% drop triggers anomaly
    
    private init() {}
    
    // MARK: - Run All Checks
    
    /// Run all anomaly detection checks
    func runAllChecks() async {
        isChecking = true
        defer { isChecking = false }
        
        var anomalies: [ClassificationAnomaly] = []
        
        // Check for low confidence classifications
        let lowConfidence = await checkLowConfidenceClassifications()
        anomalies.append(contentsOf: lowConfidence)
        
        // Check for confidence drops over time
        let confidenceDrops = await checkConfidenceTrends()
        anomalies.append(contentsOf: confidenceDrops)
        
        // Check for misclassifications (from feedback)
        let misclassifications = await analyzeMisclassifications()
        anomalies.append(contentsOf: misclassifications)
        
        // Sort by severity (high first)
        anomalies.sort { $0.severity > $1.severity }
        
        detectedAnomalies = anomalies
        lastCheckTime = Date()
    }
    
    // MARK: - Individual Checks
    
    /// Find emails with docket keywords that weren't classified
    func detectUnclassifiedEmails(
        gmailService: GmailService?,
        query: String = "subject:(docket OR \"new docket\") is:unread",
        timeRange: DateInterval? = nil
    ) async -> [ClassificationAnomaly] {
        guard let gmail = gmailService, gmail.isAuthenticated else {
            return []
        }
        
        var anomalies: [ClassificationAnomaly] = []
        
        do {
            // Search for emails with docket-related keywords
            let messageRefs = try await gmail.fetchEmails(query: query, maxResults: 20)
            
            for ref in messageRefs {
                // Check if this email was classified
                let existingClassification = history.getClassification(forEmailId: ref.id)
                
                if existingClassification == nil {
                    // Email wasn't classified - potential miss
                    do {
                        let email = try await gmail.getEmail(messageId: ref.id)
                        let subject = email.subject ?? "No subject"
                        
                        // Check if within time range if specified
                        if let range = timeRange, let date = email.date {
                            guard range.contains(date) else { continue }
                        }
                        
                        anomalies.append(.unclassifiedEmail(
                            emailId: ref.id,
                            subject: subject,
                            reason: "Contains docket keywords but wasn't classified"
                        ))
                    } catch {
                        // Skip emails we can't fetch
                        continue
                    }
                }
            }
        } catch {
            print("⚠️ [AnomalyDetector] Error searching emails: \(error.localizedDescription)")
        }
        
        return anomalies
    }
    
    /// Find classifications with low confidence scores
    func checkLowConfidenceClassifications(
        threshold: Double? = nil,
        limit: Int = 20
    ) async -> [ClassificationAnomaly] {
        let effectiveThreshold = threshold ?? confidenceThreshold
        let lowConfRecords = history.getLowConfidenceClassifications(
            threshold: effectiveThreshold,
            limit: limit
        )
        
        return lowConfRecords.map { record in
            ClassificationAnomaly.lowConfidence(
                recordId: record.id,
                confidence: record.confidence,
                subject: record.subject
            )
        }
    }
    
    /// Analyze classifications that were marked as incorrect
    func analyzeMisclassifications(
        timeRange: DateInterval? = nil
    ) async -> [ClassificationAnomaly] {
        var anomalies: [ClassificationAnomaly] = []
        
        // Get records with negative feedback
        let records: [ClassificationRecord]
        if let range = timeRange {
            records = history.getClassifications(from: range.start, to: range.end)
        } else {
            records = history.getRecentClassifications(limit: 100)
        }
        
        let incorrectRecords = records.filter { $0.feedback?.wasCorrect == false }
        
        for record in incorrectRecords {
            let expectedType: String
            if let correction = record.feedback?.correction, !correction.isEmpty {
                expectedType = correction
            } else {
                // Infer expected type from feedback
                expectedType = record.classificationType == .newDocket ? "not new docket" : "new docket"
            }
            
            anomalies.append(.misclassification(
                recordId: record.id,
                expectedType: expectedType,
                actualType: record.classificationType.rawValue
            ))
        }
        
        return anomalies
    }
    
    /// Check for significant drops in confidence over time
    func checkConfidenceTrends(days: Int = 14) async -> [ClassificationAnomaly] {
        var anomalies: [ClassificationAnomaly] = []
        
        let trend = history.getConfidenceTrend(forLastDays: days)
        
        guard trend.count >= 4 else {
            // Not enough data
            return []
        }
        
        // Compare recent average to older average
        let midpoint = trend.count / 2
        let olderRecords = Array(trend.prefix(midpoint))
        let recentRecords = Array(trend.suffix(midpoint))
        
        guard !olderRecords.isEmpty, !recentRecords.isEmpty else {
            return []
        }
        
        let olderAvg = olderRecords.map(\.avgConfidence).reduce(0, +) / Double(olderRecords.count)
        let recentAvg = recentRecords.map(\.avgConfidence).reduce(0, +) / Double(recentRecords.count)
        
        let drop = olderAvg - recentAvg
        
        if drop >= confidenceDropThreshold {
            anomalies.append(.confidenceDrop(
                date: Date(),
                previousAvg: olderAvg,
                currentAvg: recentAvg
            ))
        }
        
        return anomalies
    }
    
    // MARK: - Analysis Helpers
    
    /// Get summary of current anomaly status
    func getAnomalySummary() -> (high: Int, medium: Int, low: Int, total: Int) {
        let high = detectedAnomalies.filter { $0.severity == .high }.count
        let medium = detectedAnomalies.filter { $0.severity == .medium }.count
        let low = detectedAnomalies.filter { $0.severity == .low || $0.severity == .warning }.count
        return (high, medium, low, detectedAnomalies.count)
    }
    
    /// Clear detected anomalies
    func clearAnomalies() {
        detectedAnomalies = []
    }
    
    /// Get anomalies filtered by severity
    func getAnomalies(minimumSeverity: AnomalySeverity) -> [ClassificationAnomaly] {
        return detectedAnomalies.filter { $0.severity >= minimumSeverity }
    }
}

