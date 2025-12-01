import Foundation
import Combine

/// Record of a single email classification
struct ClassificationRecord: Codable, Identifiable {
    let id: UUID
    let emailId: String
    let threadId: String?
    let subject: String
    let fromEmail: String
    let classifiedAt: Date
    let classificationType: ClassificationType
    let result: ClassificationResult
    let confidence: Double
    let docketNumber: String?
    let jobName: String?
    let wasVerified: Bool // Whether docket was verified in metadata/Asana
    var feedback: ClassificationFeedback?
    
    enum ClassificationType: String, Codable {
        case newDocket
        case fileDelivery
        case unknown
    }
    
    struct ClassificationResult: Codable {
        let isNewDocket: Bool?
        let isFileDelivery: Bool?
        let extractedDocket: String?
        let extractedJobName: String?
        let fileLinks: [String]?
        let rawResponse: String?
    }
    
    struct ClassificationFeedback: Codable {
        let rating: Int // 1-5
        let wasCorrect: Bool
        let correction: String?
        let feedbackAt: Date
    }
}

/// Statistics about classifications over a time range
struct ClassificationStats: Codable {
    let totalClassifications: Int
    let newDocketCount: Int
    let fileDeliveryCount: Int
    let averageConfidence: Double
    let lowConfidenceCount: Int // Below 0.7
    let feedbackCount: Int
    let correctCount: Int
    let incorrectCount: Int
    let timeRange: TimeRange
    
    struct TimeRange: Codable {
        let start: Date
        let end: Date
    }
    
    var accuracy: Double {
        guard feedbackCount > 0 else { return 0 }
        return Double(correctCount) / Double(feedbackCount)
    }
}

/// Service to track and analyze email classification history
@MainActor
class CodeMindClassificationHistory: ObservableObject {
    static let shared = CodeMindClassificationHistory()
    
    @Published var records: [ClassificationRecord] = []
    @Published var lastUpdated: Date?
    
    private let storageURL: URL
    private let maxRecords = 10000 // Keep last 10k records
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        self.storageURL = appFolder.appendingPathComponent("classification_history.json")
        loadHistory()
    }
    
    // MARK: - Recording Classifications
    
    /// Record a new docket email classification
    func recordNewDocketClassification(
        emailId: String,
        threadId: String?,
        subject: String,
        fromEmail: String,
        confidence: Double,
        docketNumber: String?,
        jobName: String?,
        wasVerified: Bool,
        rawResponse: String?
    ) {
        let record = ClassificationRecord(
            id: UUID(),
            emailId: emailId,
            threadId: threadId,
            subject: subject,
            fromEmail: fromEmail,
            classifiedAt: Date(),
            classificationType: .newDocket,
            result: ClassificationRecord.ClassificationResult(
                isNewDocket: true,
                isFileDelivery: nil,
                extractedDocket: docketNumber,
                extractedJobName: jobName,
                fileLinks: nil,
                rawResponse: rawResponse
            ),
            confidence: confidence,
            docketNumber: docketNumber,
            jobName: jobName,
            wasVerified: wasVerified,
            feedback: nil
        )
        addRecord(record)
    }
    
    /// Record a file delivery email classification
    func recordFileDeliveryClassification(
        emailId: String,
        threadId: String?,
        subject: String,
        fromEmail: String,
        confidence: Double,
        isFileDelivery: Bool,
        fileLinks: [String],
        rawResponse: String?
    ) {
        let record = ClassificationRecord(
            id: UUID(),
            emailId: emailId,
            threadId: threadId,
            subject: subject,
            fromEmail: fromEmail,
            classifiedAt: Date(),
            classificationType: .fileDelivery,
            result: ClassificationRecord.ClassificationResult(
                isNewDocket: nil,
                isFileDelivery: isFileDelivery,
                extractedDocket: nil,
                extractedJobName: nil,
                fileLinks: fileLinks,
                rawResponse: rawResponse
            ),
            confidence: confidence,
            docketNumber: nil,
            jobName: nil,
            wasVerified: false,
            feedback: nil
        )
        addRecord(record)
    }
    
    /// Add feedback to an existing classification
    func addFeedback(
        recordId: UUID,
        rating: Int,
        wasCorrect: Bool,
        correction: String?
    ) {
        guard let index = records.firstIndex(where: { $0.id == recordId }) else { return }
        
        records[index].feedback = ClassificationRecord.ClassificationFeedback(
            rating: rating,
            wasCorrect: wasCorrect,
            correction: correction,
            feedbackAt: Date()
        )
        saveHistory()
    }
    
    /// Add feedback by email ID
    func addFeedbackByEmailId(
        emailId: String,
        rating: Int,
        wasCorrect: Bool,
        correction: String?
    ) {
        guard let index = records.firstIndex(where: { $0.emailId == emailId }) else { return }
        
        records[index].feedback = ClassificationRecord.ClassificationFeedback(
            rating: rating,
            wasCorrect: wasCorrect,
            correction: correction,
            feedbackAt: Date()
        )
        saveHistory()
    }
    
    // MARK: - Querying History
    
    /// Get classifications similar to a given email
    func getSimilarClassifications(
        subject: String? = nil,
        fromEmail: String? = nil,
        docketNumber: String? = nil,
        limit: Int = 10
    ) -> [ClassificationRecord] {
        var filtered = records
        
        // Filter by criteria
        if let subject = subject, !subject.isEmpty {
            let subjectWords = Set(subject.lowercased().split(separator: " ").map(String.init))
            filtered = filtered.filter { record in
                let recordWords = Set(record.subject.lowercased().split(separator: " ").map(String.init))
                let commonWords = subjectWords.intersection(recordWords)
                return commonWords.count >= 2 // At least 2 common words
            }
        }
        
        if let fromEmail = fromEmail, !fromEmail.isEmpty {
            let domain = fromEmail.split(separator: "@").last.map(String.init)
            filtered = filtered.filter { record in
                if let domain = domain {
                    return record.fromEmail.contains(domain)
                }
                return record.fromEmail == fromEmail
            }
        }
        
        if let docketNumber = docketNumber, !docketNumber.isEmpty {
            filtered = filtered.filter { $0.docketNumber == docketNumber }
        }
        
        // Sort by date (newest first) and limit
        return Array(filtered.sorted { $0.classifiedAt > $1.classifiedAt }.prefix(limit))
    }
    
    /// Get classifications in a time range
    func getClassifications(from start: Date, to end: Date) -> [ClassificationRecord] {
        return records.filter { $0.classifiedAt >= start && $0.classifiedAt <= end }
    }
    
    /// Get low confidence classifications
    func getLowConfidenceClassifications(threshold: Double = 0.7, limit: Int = 50) -> [ClassificationRecord] {
        return Array(
            records
                .filter { $0.confidence < threshold }
                .sorted { $0.classifiedAt > $1.classifiedAt }
                .prefix(limit)
        )
    }
    
    /// Get classifications without feedback
    func getClassificationsNeedingFeedback(limit: Int = 20) -> [ClassificationRecord] {
        return Array(
            records
                .filter { $0.feedback == nil }
                .sorted { $0.classifiedAt > $1.classifiedAt }
                .prefix(limit)
        )
    }
    
    /// Get recent classifications
    func getRecentClassifications(limit: Int = 50) -> [ClassificationRecord] {
        return Array(
            records
                .sorted { $0.classifiedAt > $1.classifiedAt }
                .prefix(limit)
        )
    }
    
    /// Get classification by email ID
    func getClassification(forEmailId emailId: String) -> ClassificationRecord? {
        return records.first { $0.emailId == emailId }
    }
    
    // MARK: - Statistics
    
    /// Calculate statistics for a time range
    func getStats(from start: Date, to end: Date) -> ClassificationStats {
        let rangeRecords = getClassifications(from: start, to: end)
        
        let newDocketCount = rangeRecords.filter { $0.classificationType == .newDocket }.count
        let fileDeliveryCount = rangeRecords.filter { $0.classificationType == .fileDelivery }.count
        let avgConfidence = rangeRecords.isEmpty ? 0 : rangeRecords.map(\.confidence).reduce(0, +) / Double(rangeRecords.count)
        let lowConfidenceCount = rangeRecords.filter { $0.confidence < 0.7 }.count
        
        let feedbackRecords = rangeRecords.filter { $0.feedback != nil }
        let correctCount = feedbackRecords.filter { $0.feedback?.wasCorrect == true }.count
        let incorrectCount = feedbackRecords.filter { $0.feedback?.wasCorrect == false }.count
        
        return ClassificationStats(
            totalClassifications: rangeRecords.count,
            newDocketCount: newDocketCount,
            fileDeliveryCount: fileDeliveryCount,
            averageConfidence: avgConfidence,
            lowConfidenceCount: lowConfidenceCount,
            feedbackCount: feedbackRecords.count,
            correctCount: correctCount,
            incorrectCount: incorrectCount,
            timeRange: ClassificationStats.TimeRange(start: start, end: end)
        )
    }
    
    /// Get stats for last N days
    func getStats(forLastDays days: Int) -> ClassificationStats {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        return getStats(from: start, to: end)
    }
    
    /// Get confidence trend over time (average per day)
    func getConfidenceTrend(forLastDays days: Int) -> [(date: Date, avgConfidence: Double, count: Int)] {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        let rangeRecords = getClassifications(from: start, to: end)
        
        // Group by day
        var dayStats: [String: (total: Double, count: Int)] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        for record in rangeRecords {
            let dayKey = dateFormatter.string(from: record.classifiedAt)
            let existing = dayStats[dayKey] ?? (0, 0)
            dayStats[dayKey] = (existing.total + record.confidence, existing.count + 1)
        }
        
        // Convert to sorted array
        return dayStats.compactMap { key, value in
            guard let date = dateFormatter.date(from: key) else { return nil }
            return (date: date, avgConfidence: value.total / Double(value.count), count: value.count)
        }.sorted { $0.date < $1.date }
    }
    
    // MARK: - Private Methods
    
    private func addRecord(_ record: ClassificationRecord) {
        records.insert(record, at: 0)
        
        // Trim old records if needed
        if records.count > maxRecords {
            records = Array(records.prefix(maxRecords))
        }
        
        lastUpdated = Date()
        saveHistory()
    }
    
    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            records = []
            return
        }
        
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([ClassificationRecord].self, from: data)
            records = decoded
            print("📊 [ClassificationHistory] Loaded \(records.count) classification records")
        } catch {
            print("⚠️ [ClassificationHistory] Failed to load history: \(error.localizedDescription)")
            records = []
        }
    }
    
    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageURL)
        } catch {
            print("⚠️ [ClassificationHistory] Failed to save history: \(error.localizedDescription)")
        }
    }
    
    /// Clear all history (for testing)
    func clearHistory() {
        records = []
        try? FileManager.default.removeItem(at: storageURL)
    }
}

