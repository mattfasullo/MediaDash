import Foundation

/// Tracks feedback and interactions per email ID for persistent storage
/// This allows the app to remember feedback even if emails are marked unread and re-scanned
@MainActor
class EmailFeedbackTracker {
    static let shared = EmailFeedbackTracker()
    
    /// Feedback data for a single email
    struct EmailFeedback: Codable, Equatable {
        let emailId: String
        let wasCorrect: Bool
        let rating: Int
        let timestamp: Date
        let correction: String?
        let comment: String?
        
        init(emailId: String, wasCorrect: Bool, rating: Int, timestamp: Date = Date(), correction: String? = nil, comment: String? = nil) {
            self.emailId = emailId
            self.wasCorrect = wasCorrect
            self.rating = rating
            self.timestamp = timestamp
            self.correction = correction
            self.comment = comment
        }
    }
    
    /// Interaction types that can be tracked per email
    enum InteractionType: String, Codable {
        case feedbackThumbsUp = "feedback_thumbs_up"
        case feedbackThumbsDown = "feedback_thumbs_down"
        case reclassified = "reclassified"
        case approved = "approved"
        case grabbed = "grabbed"
    }
    
    /// Interaction record for tracking user actions
    struct EmailInteraction: Codable, Equatable {
        let emailId: String
        let interactionType: InteractionType
        let timestamp: Date
        let details: [String: String]? // Additional context (e.g., "fromType": "newDocket", "toType": "junk")
        
        init(emailId: String, interactionType: InteractionType, timestamp: Date = Date(), details: [String: String]? = nil) {
            self.emailId = emailId
            self.interactionType = interactionType
            self.timestamp = timestamp
            self.details = details
        }
    }
    
    /// Storage structure
    private struct FeedbackStorage: Codable {
        var feedback: [String: EmailFeedback] = [:] // Keyed by emailId
        var interactions: [String: [EmailInteraction]] = [:] // Keyed by emailId, array of interactions
    }
    
    private var storage = FeedbackStorage()
    private let storageURL: URL
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let mediaDashFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
        
        // Create MediaDash folder if it doesn't exist
        try? FileManager.default.createDirectory(at: mediaDashFolder, withIntermediateDirectories: true)
        
        storageURL = mediaDashFolder.appendingPathComponent("email_feedback.json")
        loadStorage()
    }
    
    // MARK: - Feedback Methods
    
    /// Check if feedback exists for an email
    func hasFeedback(for emailId: String) -> Bool {
        return storage.feedback[emailId] != nil
    }
    
    /// Get feedback for an email
    func getFeedback(for emailId: String) -> EmailFeedback? {
        return storage.feedback[emailId]
    }
    
    /// Store feedback for an email
    func storeFeedback(_ feedback: EmailFeedback) {
        storage.feedback[feedback.emailId] = feedback
        saveStorage()
    }
    
    /// Store feedback with convenience parameters
    func storeFeedback(emailId: String, wasCorrect: Bool, rating: Int, correction: String? = nil, comment: String? = nil) {
        let feedback = EmailFeedback(
            emailId: emailId,
            wasCorrect: wasCorrect,
            rating: rating,
            correction: correction,
            comment: comment
        )
        storeFeedback(feedback)
    }
    
    // MARK: - Interaction Methods
    
    /// Record an interaction for an email
    func recordInteraction(emailId: String, type: InteractionType, details: [String: String]? = nil) {
        let interaction = EmailInteraction(
            emailId: emailId,
            interactionType: type,
            details: details
        )
        
        if storage.interactions[emailId] == nil {
            storage.interactions[emailId] = []
        }
        storage.interactions[emailId]?.append(interaction)
        saveStorage()
    }
    
    /// Get all interactions for an email
    func getInteractions(for emailId: String) -> [EmailInteraction] {
        return storage.interactions[emailId] ?? []
    }
    
    /// Check if an email has a specific type of interaction
    func hasInteraction(emailId: String, type: InteractionType) -> Bool {
        return storage.interactions[emailId]?.contains(where: { $0.interactionType == type }) ?? false
    }
    
    /// Check if an email has any interaction (any type)
    /// This is useful for filtering out emails that have been interacted with
    func hasAnyInteraction(emailId: String) -> Bool {
        return !(storage.interactions[emailId]?.isEmpty ?? true)
    }
    
    /// Get the most recent interaction of a specific type for an email
    func getMostRecentInteraction(emailId: String, type: InteractionType) -> EmailInteraction? {
        return storage.interactions[emailId]?
            .filter { $0.interactionType == type }
            .sorted { $0.timestamp > $1.timestamp }
            .first
    }
    
    // MARK: - Storage Management
    
    private func loadStorage() {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode(FeedbackStorage.self, from: data) else {
            // No existing storage, start fresh
            storage = FeedbackStorage()
            return
        }
        storage = loaded
    }
    
    private func saveStorage() {
        guard let data = try? JSONEncoder().encode(storage) else {
            print("EmailFeedbackTracker: Failed to encode feedback storage")
            return
        }
        
        do {
            try data.write(to: storageURL)
        } catch {
            print("EmailFeedbackTracker: Failed to save feedback storage: \(error.localizedDescription)")
        }
    }
    
    /// Clean up old feedback/interactions (optional maintenance method)
    /// Removes entries older than the specified number of days
    func cleanupOldEntries(olderThanDays days: Int = 90) {
        let cutoffDate = Date().addingTimeInterval(-Double(days * 24 * 60 * 60))
        var hasChanges = false
        
        // Clean up old feedback
        let oldFeedbackKeys = storage.feedback.filter { $0.value.timestamp < cutoffDate }.map { $0.key }
        for key in oldFeedbackKeys {
            storage.feedback.removeValue(forKey: key)
            hasChanges = true
        }
        
        // Clean up old interactions
        for (emailId, interactions) in storage.interactions {
            let filtered = interactions.filter { $0.timestamp >= cutoffDate }
            if filtered.count != interactions.count {
                storage.interactions[emailId] = filtered.isEmpty ? nil : filtered
                hasChanges = true
            }
        }
        
        // Remove empty interaction arrays
        storage.interactions = storage.interactions.filter { !($0.value.isEmpty) }
        
        if hasChanges {
            saveStorage()
            print("EmailFeedbackTracker: Cleaned up \(oldFeedbackKeys.count) old feedback entries")
        }
    }
    
    /// Get statistics about stored feedback
    func getStatistics() -> (feedbackCount: Int, interactionCount: Int, uniqueEmails: Int) {
        let feedbackCount = storage.feedback.count
        let interactionCount = storage.interactions.values.reduce(0) { $0 + $1.count }
        let uniqueEmails = Set(storage.feedback.keys).union(Set(storage.interactions.keys)).count
        return (feedbackCount, interactionCount, uniqueEmails)
    }
}

