import Foundation
import Combine

/// A suggested pattern for email classification
struct PatternSuggestion: Identifiable, Codable {
    let id: UUID
    let pattern: String
    let patternType: PatternType
    let confidence: Double
    let supportingExamples: Int
    let description: String
    let generatedAt: Date
    
    enum PatternType: String, Codable {
        case subjectKeyword = "subject_keyword"
        case senderDomain = "sender_domain"
        case docketFormat = "docket_format"
        case jobNamePattern = "job_name_pattern"
        case fileDeliveryIndicator = "file_delivery_indicator"
    }
    
    var regexPattern: String? {
        // Convert pattern to regex if applicable
        switch patternType {
        case .docketFormat:
            // Escape special characters and make it a regex
            return pattern.replacingOccurrences(of: "*", with: "\\d+")
        case .subjectKeyword:
            return "(?i)\\b\(NSRegularExpression.escapedPattern(for: pattern))\\b"
        default:
            return nil
        }
    }
}

/// Analysis of a pattern's effectiveness
struct PatternEffectiveness: Identifiable {
    let id: UUID
    let pattern: String
    let patternType: PatternSuggestion.PatternType
    let totalUses: Int
    let correctClassifications: Int
    let incorrectClassifications: Int
    let averageConfidence: Double
    
    var successRate: Double {
        guard totalUses > 0 else { return 0 }
        return Double(correctClassifications) / Double(totalUses)
    }
    
    var needsImprovement: Bool {
        return successRate < 0.7 && totalUses >= 3
    }
}

/// Service for suggesting and analyzing classification patterns
@MainActor
class CodeMindPatternSuggester: ObservableObject {
    static let shared = CodeMindPatternSuggester()
    
    @Published var suggestions: [PatternSuggestion] = []
    @Published var patternEffectiveness: [PatternEffectiveness] = []
    @Published var isAnalyzing = false
    
    private let history = CodeMindClassificationHistory.shared
    private let minConfidenceForPattern = 0.8
    private let minExamplesForPattern = 3
    
    private init() {}
    
    // MARK: - Pattern Extraction
    
    /// Extract patterns from successful high-confidence classifications
    func extractPatternsFromClassifications(
        confidenceThreshold: Double? = nil
    ) async -> [PatternSuggestion] {
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        let threshold = confidenceThreshold ?? minConfidenceForPattern
        
        // Get high-confidence classifications
        let allRecords = history.getRecentClassifications(limit: 500)
        let highConfRecords = allRecords.filter { $0.confidence >= threshold }
        
        // Also prefer records with positive feedback
        let goodRecords = highConfRecords.filter { record in
            record.feedback == nil || record.feedback?.wasCorrect == true
        }
        
        var suggestions: [PatternSuggestion] = []
        
        // Extract subject keyword patterns
        suggestions.append(contentsOf: extractSubjectPatterns(from: goodRecords))
        
        // Extract sender domain patterns
        suggestions.append(contentsOf: extractSenderPatterns(from: goodRecords))
        
        // Extract docket format patterns
        suggestions.append(contentsOf: extractDocketPatterns(from: goodRecords))
        
        // Sort by confidence and supporting examples
        suggestions.sort { ($0.confidence * Double($0.supportingExamples)) > ($1.confidence * Double($1.supportingExamples)) }
        
        self.suggestions = suggestions
        return suggestions
    }
    
    /// Suggest new patterns based on recent classifications
    func suggestNewPatterns() async -> [PatternSuggestion] {
        return await extractPatternsFromClassifications()
    }
    
    // MARK: - Pattern Analysis
    
    /// Analyze effectiveness of existing patterns
    func analyzePatternEffectiveness() async -> [PatternEffectiveness] {
        isAnalyzing = true
        defer { isAnalyzing = false }
        
        var effectiveness: [PatternEffectiveness] = []
        
        let allRecords = history.getRecentClassifications(limit: 500)
        
        // Analyze subject keyword patterns
        let subjectPatterns = extractCommonWords(from: allRecords.map(\.subject))
        for (word, count) in subjectPatterns where count >= 3 {
            let matchingRecords = allRecords.filter { $0.subject.lowercased().contains(word.lowercased()) }
            let correct = matchingRecords.filter { $0.feedback?.wasCorrect != false }.count
            let incorrect = matchingRecords.filter { $0.feedback?.wasCorrect == false }.count
            let avgConf = matchingRecords.map(\.confidence).reduce(0, +) / Double(matchingRecords.count)
            
            effectiveness.append(PatternEffectiveness(
                id: UUID(),
                pattern: word,
                patternType: .subjectKeyword,
                totalUses: matchingRecords.count,
                correctClassifications: correct,
                incorrectClassifications: incorrect,
                averageConfidence: avgConf
            ))
        }
        
        // Sort by total uses and success rate
        effectiveness.sort { $0.totalUses > $1.totalUses }
        
        self.patternEffectiveness = effectiveness
        return effectiveness
    }
    
    /// Get patterns that need improvement
    func getPatternsNeedingImprovement() -> [PatternEffectiveness] {
        return patternEffectiveness.filter { $0.needsImprovement }
    }
    
    // MARK: - Pattern Generation
    
    /// Generate regex pattern from examples
    func generateRegexFromExamples(examples: [String]) -> String? {
        guard !examples.isEmpty else { return nil }
        
        // Find common prefix/suffix
        let commonPrefix = findCommonPrefix(examples)
        let commonSuffix = findCommonSuffix(examples)
        
        if commonPrefix.count >= 3 || commonSuffix.count >= 3 {
            // Build pattern around common elements
            var pattern = ""
            if commonPrefix.count >= 3 {
                pattern += NSRegularExpression.escapedPattern(for: commonPrefix)
            }
            pattern += ".*?"
            if commonSuffix.count >= 3 {
                pattern += NSRegularExpression.escapedPattern(for: commonSuffix)
            }
            return pattern.isEmpty ? nil : "(?i)\(pattern)"
        }
        
        // Try to find common number patterns (e.g., docket numbers)
        let numberPattern = findNumberPattern(examples)
        if let numPattern = numberPattern {
            return numPattern
        }
        
        return nil
    }
    
    // MARK: - Private Extraction Methods
    
    private func extractSubjectPatterns(from records: [ClassificationRecord]) -> [PatternSuggestion] {
        var suggestions: [PatternSuggestion] = []
        
        // Extract common words/phrases from subjects
        let subjects = records.map(\.subject)
        let commonWords = extractCommonWords(from: subjects, minLength: 4, minOccurrences: minExamplesForPattern)
        
        for (word, count) in commonWords {
            let matchingRecords = records.filter { $0.subject.lowercased().contains(word.lowercased()) }
            let avgConfidence = matchingRecords.map(\.confidence).reduce(0, +) / Double(matchingRecords.count)
            
            suggestions.append(PatternSuggestion(
                id: UUID(),
                pattern: word,
                patternType: .subjectKeyword,
                confidence: avgConfidence,
                supportingExamples: count,
                description: "Subject keyword '\(word)' found in \(count) successful classifications",
                generatedAt: Date()
            ))
        }
        
        return suggestions
    }
    
    private func extractSenderPatterns(from records: [ClassificationRecord]) -> [PatternSuggestion] {
        var suggestions: [PatternSuggestion] = []
        
        // Extract common sender domains
        var domainCounts: [String: Int] = [:]
        var domainConfidences: [String: [Double]] = [:]
        
        for record in records {
            if let domain = record.fromEmail.split(separator: "@").last.map(String.init) {
                domainCounts[domain, default: 0] += 1
                domainConfidences[domain, default: []].append(record.confidence)
            }
        }
        
        for (domain, count) in domainCounts where count >= minExamplesForPattern {
            let confidences = domainConfidences[domain] ?? []
            let avgConfidence = confidences.reduce(0, +) / Double(confidences.count)
            
            suggestions.append(PatternSuggestion(
                id: UUID(),
                pattern: domain,
                patternType: .senderDomain,
                confidence: avgConfidence,
                supportingExamples: count,
                description: "Sender domain '\(domain)' associated with \(count) successful classifications",
                generatedAt: Date()
            ))
        }
        
        return suggestions
    }
    
    private func extractDocketPatterns(from records: [ClassificationRecord]) -> [PatternSuggestion] {
        var suggestions: [PatternSuggestion] = []
        
        // Extract docket number formats
        let docketNumbers = records.compactMap(\.docketNumber).filter { !$0.isEmpty }
        
        guard docketNumbers.count >= minExamplesForPattern else { return [] }
        
        // Analyze docket number formats
        var formats: [String: Int] = [:]
        
        for docket in docketNumbers {
            let format = categorizeFormat(docket)
            formats[format, default: 0] += 1
        }
        
        for (format, count) in formats where count >= minExamplesForPattern {
            let matchingRecords = records.filter { record in
                guard let docket = record.docketNumber else { return false }
                return categorizeFormat(docket) == format
            }
            let avgConfidence = matchingRecords.map(\.confidence).reduce(0, +) / Double(matchingRecords.count)
            
            suggestions.append(PatternSuggestion(
                id: UUID(),
                pattern: format,
                patternType: .docketFormat,
                confidence: avgConfidence,
                supportingExamples: count,
                description: "Docket format '\(format)' found in \(count) classifications",
                generatedAt: Date()
            ))
        }
        
        return suggestions
    }
    
    // MARK: - Helper Methods
    
    private func extractCommonWords(
        from strings: [String],
        minLength: Int = 3,
        minOccurrences: Int = 2
    ) -> [(String, Int)] {
        var wordCounts: [String: Int] = [:]
        let stopWords = Set(["the", "and", "for", "with", "from", "new", "your", "this", "that", "have", "has", "are", "was", "were", "been", "being"])
        
        for string in strings {
            let words = string.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= minLength && !stopWords.contains($0) }
            
            for word in Set(words) { // Use Set to count each word once per string
                wordCounts[word, default: 0] += 1
            }
        }
        
        return wordCounts
            .filter { $0.value >= minOccurrences }
            .sorted { $0.value > $1.value }
            .prefix(20)
            .map { ($0.key, $0.value) }
    }
    
    private func categorizeFormat(_ docket: String) -> String {
        // Replace digits with # to find format pattern
        var format = ""
        var digitCount = 0
        
        for char in docket {
            if char.isNumber {
                digitCount += 1
            } else {
                if digitCount > 0 {
                    format += "#\(digitCount > 1 ? "{\(digitCount)}" : "")"
                    digitCount = 0
                }
                format += String(char)
            }
        }
        
        if digitCount > 0 {
            format += "#\(digitCount > 1 ? "{\(digitCount)}" : "")"
        }
        
        return format
    }
    
    private func findCommonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        
        for string in strings.dropFirst() {
            while !string.hasPrefix(prefix) && !prefix.isEmpty {
                prefix = String(prefix.dropLast())
            }
        }
        
        return prefix
    }
    
    private func findCommonSuffix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var suffix = first
        
        for string in strings.dropFirst() {
            while !string.hasSuffix(suffix) && !suffix.isEmpty {
                suffix = String(suffix.dropFirst())
            }
        }
        
        return suffix
    }
    
    private func findNumberPattern(_ examples: [String]) -> String? {
        // Look for consistent number patterns
        var digitCounts: [Int] = []
        
        for example in examples {
            let digits = example.filter { $0.isNumber }
            if !digits.isEmpty {
                digitCounts.append(digits.count)
            }
        }
        
        guard !digitCounts.isEmpty else { return nil }
        
        // If most examples have similar digit counts, create a pattern
        let avgDigits = digitCounts.reduce(0, +) / digitCounts.count
        let consistent = digitCounts.allSatisfy { abs($0 - avgDigits) <= 1 }
        
        if consistent && avgDigits >= 4 {
            return "\\d{\(avgDigits - 1),\(avgDigits + 1)}"
        }
        
        return nil
    }
}

