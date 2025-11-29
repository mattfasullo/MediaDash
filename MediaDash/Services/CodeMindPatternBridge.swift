import Foundation
import Combine
import CodeMind

/// Bridge between CodeMind's learned patterns and rule-based classification patterns
/// Monitors CodeMind's learning data and updates rule-based patterns when appropriate
@MainActor
class CodeMindPatternBridge: ObservableObject {
    var objectWillChange = PassthroughSubject<Void, Never>()
    static let shared = CodeMindPatternBridge()
    
    weak var settingsManager: SettingsManager?
    weak var codeMindClassifier: CodeMindEmailClassifier?
    
    // Minimum confidence threshold for automatic pattern adoption
    private let minConfidenceForAutoAdoption: Float = 0.85
    private let minUsageCountForAutoAdoption: Int = 5
    
    // Track last update time to avoid excessive updates
    private var lastUpdateTime: Date?
    private let minUpdateInterval: TimeInterval = 300 // 5 minutes
    
    private init() {}
    
    /// Configure the bridge with required dependencies
    func configure(settingsManager: SettingsManager, codeMindClassifier: CodeMindEmailClassifier?) {
        self.settingsManager = settingsManager
        self.codeMindClassifier = codeMindClassifier
    }
    
    /// Check CodeMind's learned patterns and update rule-based patterns if appropriate
    /// This should be called periodically or after feedback is provided
    func syncPatternsFromCodeMind() async {
        guard settingsManager != nil else {
            print("CodeMindPatternBridge: SettingsManager not configured")
            return
        }
        
        // Throttle updates
        if let lastUpdate = lastUpdateTime,
           Date().timeIntervalSince(lastUpdate) < minUpdateInterval {
            return
        }
        
        // Get CodeMind's learned patterns
        // Note: We'll need to expose this through CodeMindEmailClassifier
        guard let patterns = await getCodeMindLearnedPatterns() else {
            print("CodeMindPatternBridge: Could not retrieve CodeMind patterns")
            return
        }
        
        var updated = false
        var newDocketPatterns: [String] = []
        var newSubjectPatterns: [String] = []
        
        // Analyze patterns and convert to rule-based patterns
        for pattern in patterns {
            // Only consider high-confidence patterns that have been used multiple times
            guard pattern.confidence >= minConfidenceForAutoAdoption,
                  pattern.usageCount >= minUsageCountForAutoAdoption else {
                continue
            }
            
            // Determine pattern type based on keywords and description
            if isDocketParsingPattern(pattern) {
                // Convert to regex pattern for docket parsing
                if let regexPattern = convertToDocketRegexPattern(pattern) {
                    newDocketPatterns.append(regexPattern)
                    updated = true
                    print("CodeMindPatternBridge: ✅ Generated new docket parsing pattern: \(regexPattern)")
                }
            } else if isFileDeliveryPattern(pattern) {
                // Convert to subject keyword pattern
                if let keyword = extractSubjectKeyword(pattern) {
                    newSubjectPatterns.append(keyword)
                    updated = true
                    print("CodeMindPatternBridge: ✅ Generated new subject pattern: \(keyword)")
                }
            }
        }
        
        if updated {
            // Update settings with new patterns
            await updateSettingsWithPatterns(
                docketPatterns: newDocketPatterns,
                subjectPatterns: newSubjectPatterns
            )
            lastUpdateTime = Date()
        }
    }
    
    /// Get learned patterns from CodeMind's storage
    private func getCodeMindLearnedPatterns() async -> [LearnedPattern]? {
        // CodeMind stores patterns in ~/Library/Application Support/CodeMind/
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let codeMindDir = appSupport.appendingPathComponent("CodeMind", isDirectory: true)
        let patternsPath = codeMindDir.appendingPathComponent("patterns.json")
        
        guard fileManager.fileExists(atPath: patternsPath.path),
              let data = try? Data(contentsOf: patternsPath) else {
            return []
        }
        
        do {
            let patterns = try JSONDecoder().decode([LearnedPattern].self, from: data)
            return patterns
        } catch {
            print("CodeMindPatternBridge: Failed to decode patterns: \(error)")
            return []
        }
    }
    
    /// Determine if a pattern is related to docket parsing
    private func isDocketParsingPattern(_ pattern: LearnedPattern) -> Bool {
        let docketKeywords = ["docket", "new docket", "job name", "project", "client"]
        let patternText = (pattern.description + " " + pattern.keywords.joined(separator: " ")).lowercased()
        
        return docketKeywords.contains { patternText.contains($0) } ||
               pattern.type == .queryPattern ||
               pattern.type == .correction
    }
    
    /// Determine if a pattern is related to file delivery detection
    private func isFileDeliveryPattern(_ pattern: LearnedPattern) -> Bool {
        let deliveryKeywords = ["file", "delivery", "media", "audio", "sfx", "mix", "omf", "aaf"]
        let patternText = (pattern.description + " " + pattern.keywords.joined(separator: " ")).lowercased()
        
        return deliveryKeywords.contains { patternText.contains($0) } ||
               pattern.type == .toolUsage
    }
    
    /// Convert a learned pattern to a regex pattern for docket parsing
    private func convertToDocketRegexPattern(_ pattern: LearnedPattern) -> String? {
        // Extract key information from the pattern
        let keywords = pattern.keywords
        
        // Look for docket number patterns in keywords
        // Common patterns: "25484", "25484-US", "Docket: 25484", "New Docket 25484"
        
        // Try to build a regex pattern from the keywords
        // This is a simplified approach - we'll build common patterns
        
        // Pattern 1: Direct docket number format (5+ digits)
        if let docketNum = keywords.first(where: { $0.range(of: #"\d{5,}"#, options: .regularExpression) != nil }) {
            if let regex = try? NSRegularExpression(pattern: #"\d{5,}"#, options: []),
               let match = regex.firstMatch(in: docketNum, range: NSRange(docketNum.startIndex..., in: docketNum)),
               let range = Range(match.range, in: docketNum) {
                let _ = String(docketNum[range]) // Extract number to validate format
                
                // Build a pattern around this number format
                // Look for context in other keywords
                if keywords.contains(where: { $0.lowercased().contains("new") || $0.lowercased().contains("docket") }) {
                    // Pattern: "New Docket 25484 - JobName"
                    if keywords.contains(where: { $0.lowercased().contains("job") || $0.lowercased().contains("name") }) {
                        return #"(?i)(?:New\s+)?Docket\s+(\d{5,})\s*[-–]\s*(.+?)(?:\s|$|,|\.)"#
                    } else {
                        return #"(?i)(?:New\s+)?Docket\s+(\d{5,})(?:\s|$|,|\.)"#
                    }
                } else if keywords.contains(where: { $0.lowercased().contains("docket") && $0.contains(":") }) {
                    // Pattern: "Docket: 25484"
                    return #"(?i)Docket\s*:\s*(\d{5,})(?:\s|$|,|\.)"#
                }
            }
        }
        
        // Pattern 2: If we have job name keywords, create a pattern that captures both
        if keywords.contains(where: { $0.count > 3 && $0.range(of: #"^\d+$"#, options: .regularExpression) == nil }) {
            // Generic pattern: "25484 JobName"
            return #"(\d{5,})\s+([A-Za-z0-9\s]+?)(?:\s|$|,|\.)"#
        }
        
        // If we can't extract a meaningful pattern, return nil
        return nil
    }
    
    /// Extract a subject keyword from a learned pattern for file delivery detection
    private func extractSubjectKeyword(_ pattern: LearnedPattern) -> String? {
        // Look for meaningful keywords that aren't too generic
        let excludedWords = ["the", "a", "an", "and", "or", "for", "with", "from", "to", "in", "on", "at", "by"]
        
        for keyword in pattern.keywords {
            let lower = keyword.lowercased()
            
            // Skip very short or common words
            guard keyword.count >= 3,
                  !excludedWords.contains(lower),
                  lower.count <= 20 else {
                continue
            }
            
            // Prefer keywords that match known file delivery terms
            let deliveryTerms = ["file", "delivery", "audio", "sfx", "mix", "omf", "aaf", "prep", "elements"]
            if deliveryTerms.contains(lower) || deliveryTerms.contains(where: { lower.contains($0) }) {
                return lower
            }
        }
        
        // If no delivery term found, use the first substantial keyword
        return pattern.keywords.first { $0.count >= 3 && !excludedWords.contains($0.lowercased()) }?.lowercased()
    }
    
    /// Update AppSettings with new patterns (merging with existing patterns)
    private func updateSettingsWithPatterns(
        docketPatterns: [String],
        subjectPatterns: [String]
    ) async {
        guard let settingsManager = settingsManager else { return }
        
        var settings = settingsManager.currentSettings
        
        // Merge new docket patterns with existing ones (avoid duplicates)
        var updatedDocketPatterns = settings.docketParsingPatterns
        for pattern in docketPatterns {
            if !updatedDocketPatterns.contains(pattern) {
                updatedDocketPatterns.append(pattern)
                print("CodeMindPatternBridge: Added docket pattern: \(pattern)")
            }
        }
        
        // Merge new subject patterns with existing ones (avoid duplicates)
        var updatedSubjectPatterns = settings.grabbedSubjectPatterns
        for pattern in subjectPatterns {
            let lowerPattern = pattern.lowercased()
            if !updatedSubjectPatterns.contains(where: { $0.lowercased() == lowerPattern }) {
                updatedSubjectPatterns.append(pattern)
                print("CodeMindPatternBridge: Added subject pattern: \(pattern)")
            }
        }
        
        // Update settings
        settings.docketParsingPatterns = updatedDocketPatterns
        settings.grabbedSubjectPatterns = updatedSubjectPatterns
        
        // Save through SettingsManager
        settingsManager.saveProfile(settings: settings, name: settings.profileName)
        
        print("CodeMindPatternBridge: ✅ Updated rule-based patterns from CodeMind learning")
        print("  New docket patterns: \(docketPatterns.count)")
        print("  New subject patterns: \(subjectPatterns.count)")
    }
    
    /// Manually trigger pattern sync (useful for testing or after feedback)
    func triggerSync() async {
        await syncPatternsFromCodeMind()
    }
}

