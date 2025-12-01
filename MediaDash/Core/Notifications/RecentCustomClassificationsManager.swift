import Foundation

/// Manages recent custom notification classifications
@MainActor
class RecentCustomClassificationsManager {
    static let shared = RecentCustomClassificationsManager()
    
    private let userDefaultsKey = "mediadash_recent_custom_classifications"
    private let maxRecentCount = 10 // Maximum number of recent classifications to store
    
    private init() {}
    
    /// Get all recent custom classifications, ordered by most recent first
    func getRecent() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let recent = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return recent
    }
    
    /// Add a custom classification to the recent list
    /// - Parameter classification: The custom classification string to add
    func add(_ classification: String) {
        let trimmed = classification.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var recent = getRecent()
        
        // Remove any existing instance of this classification
        recent.removeAll { $0.lowercased() == trimmed.lowercased() }
        
        // Add to the beginning
        recent.insert(trimmed, at: 0)
        
        // Keep only the most recent items
        if recent.count > maxRecentCount {
            recent = Array(recent.prefix(maxRecentCount))
        }
        
        // Save back to UserDefaults
        if let data = try? JSONEncoder().encode(recent) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
    
    /// Clear all recent custom classifications
    func clearAll() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

