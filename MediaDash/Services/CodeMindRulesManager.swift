import Foundation
import Combine
import SwiftUI

// MARK: - Classification Rule Model

struct ClassificationRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var type: RuleType
    var pattern: String
    var weight: Double
    var isEnabled: Bool
    var action: RuleAction
    var createdAt: Date
    var lastModified: Date
    
    enum RuleType: String, Codable, CaseIterable {
        case subjectContains = "Subject Contains"
        case subjectRegex = "Subject Regex"
        case senderDomain = "Sender Domain"
        case senderEmail = "Sender Email"
        case bodyContains = "Body Contains"
        case bodyRegex = "Body Regex"
        case docketFormat = "Docket Format"
    }
    
    enum RuleAction: String, Codable, CaseIterable {
        case classifyAsNewDocket = "Classify as New Docket"
        case classifyAsFileDelivery = "Classify as File Delivery"
        case ignoreEmail = "Ignore Email"
        case boostConfidence = "Boost Confidence"
        case reduceConfidence = "Reduce Confidence"
    }
    
    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        type: RuleType = .subjectContains,
        pattern: String = "",
        weight: Double = 0.8,
        isEnabled: Bool = true,
        action: RuleAction = .boostConfidence,
        createdAt: Date = Date(),
        lastModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
        self.pattern = pattern
        self.weight = weight
        self.isEnabled = isEnabled
        self.action = action
        self.createdAt = createdAt
        self.lastModified = lastModified
    }
    
    /// Check if this rule matches the given email content
    func matches(subject: String?, body: String?, from: String?) -> Bool {
        guard isEnabled, !pattern.isEmpty else { return false }
        
        switch type {
        case .subjectContains:
            guard let subject = subject else { return false }
            return subject.localizedCaseInsensitiveContains(pattern)
            
        case .subjectRegex:
            guard let subject = subject else { return false }
            return matchesRegex(pattern, in: subject)
            
        case .senderDomain:
            guard let from = from else { return false }
            let domain = from.split(separator: "@").last.map(String.init) ?? ""
            return domain.localizedCaseInsensitiveContains(pattern)
            
        case .senderEmail:
            guard let from = from else { return false }
            return from.localizedCaseInsensitiveContains(pattern)
            
        case .bodyContains:
            guard let body = body else { return false }
            return body.localizedCaseInsensitiveContains(pattern)
            
        case .bodyRegex:
            guard let body = body else { return false }
            return matchesRegex(pattern, in: body)
            
        case .docketFormat:
            // Check if the pattern matches a docket number format in subject or body
            let combinedText = [subject, body].compactMap { $0 }.joined(separator: " ")
            return matchesRegex(pattern, in: combinedText)
        }
    }
    
    private func matchesRegex(_ pattern: String, in text: String) -> Bool {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        } catch {
            // If regex is invalid, fall back to contains
            return text.localizedCaseInsensitiveContains(pattern)
        }
    }
}

// MARK: - Rule Match Result

struct RuleMatchResult {
    let rule: ClassificationRule
    let matchedText: String?
    
    var confidenceModifier: Double {
        switch rule.action {
        case .boostConfidence:
            return rule.weight * 0.2 // Add up to 20% confidence
        case .reduceConfidence:
            return -rule.weight * 0.2 // Reduce up to 20% confidence
        default:
            return 0
        }
    }
}

// MARK: - Rules Manager

@MainActor
class CodeMindRulesManager: ObservableObject {
    static let shared = CodeMindRulesManager()
    
    @Published var rules: [ClassificationRule] = []
    @Published var lastModified: Date?
    
    private let storageURL: URL
    private var hasLoadedRules = false
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        self.storageURL = appFolder.appendingPathComponent("classification_rules.json")
        loadRules()
    }
    
    // MARK: - CRUD Operations
    
    func addRule(_ rule: ClassificationRule) {
        var newRule = rule
        newRule.createdAt = Date()
        newRule.lastModified = Date()
        rules.append(newRule)
        saveRules()
        
        CodeMindLogger.shared.log(.info, "Added classification rule", category: .general, metadata: [
            "ruleName": rule.name,
            "ruleType": rule.type.rawValue,
            "pattern": rule.pattern
        ])
    }
    
    func updateRule(_ rule: ClassificationRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        var updatedRule = rule
        updatedRule.lastModified = Date()
        rules[index] = updatedRule
        saveRules()
        
        CodeMindLogger.shared.log(.info, "Updated classification rule", category: .general, metadata: [
            "ruleName": rule.name,
            "ruleId": rule.id.uuidString
        ])
    }
    
    func deleteRule(_ rule: ClassificationRule) {
        rules.removeAll { $0.id == rule.id }
        saveRules()
        
        CodeMindLogger.shared.log(.info, "Deleted classification rule", category: .general, metadata: [
            "ruleName": rule.name,
            "ruleId": rule.id.uuidString
        ])
    }
    
    func deleteRule(at index: Int) {
        guard index >= 0, index < rules.count else { return }
        let rule = rules[index]
        rules.remove(at: index)
        saveRules()
        
        CodeMindLogger.shared.log(.info, "Deleted classification rule", category: .general, metadata: [
            "ruleName": rule.name,
            "ruleId": rule.id.uuidString
        ])
    }
    
    func moveRule(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        saveRules()
    }
    
    func toggleRule(_ rule: ClassificationRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index].isEnabled.toggle()
        rules[index].lastModified = Date()
        saveRules()
    }
    
    // MARK: - Rule Evaluation
    
    /// Evaluate all rules against an email and return matching rules
    func evaluateRules(subject: String?, body: String?, from: String?) -> [RuleMatchResult] {
        var results: [RuleMatchResult] = []
        
        for rule in rules where rule.isEnabled {
            if rule.matches(subject: subject, body: body, from: from) {
                results.append(RuleMatchResult(rule: rule, matchedText: findMatchedText(rule: rule, subject: subject, body: body, from: from)))
                
                CodeMindLogger.shared.log(.debug, "Rule matched", category: .classification, metadata: [
                    "ruleName": rule.name,
                    "ruleType": rule.type.rawValue,
                    "action": rule.action.rawValue
                ])
            }
        }
        
        return results
    }
    
    /// Get the classification override if any rule dictates it
    func getClassificationOverride(subject: String?, body: String?, from: String?) -> (shouldClassifyAs: String?, shouldIgnore: Bool, confidenceModifier: Double) {
        let matches = evaluateRules(subject: subject, body: body, from: from)
        
        var shouldIgnore = false
        var classifyAs: String?
        var totalConfidenceModifier: Double = 0
        
        for match in matches {
            switch match.rule.action {
            case .classifyAsNewDocket:
                classifyAs = "newDocket"
            case .classifyAsFileDelivery:
                classifyAs = "fileDelivery"
            case .ignoreEmail:
                shouldIgnore = true
            case .boostConfidence, .reduceConfidence:
                totalConfidenceModifier += match.confidenceModifier
            }
        }
        
        // Clamp confidence modifier
        totalConfidenceModifier = max(-0.5, min(0.5, totalConfidenceModifier))
        
        return (classifyAs, shouldIgnore, totalConfidenceModifier)
    }
    
    private func findMatchedText(rule: ClassificationRule, subject: String?, body: String?, from: String?) -> String? {
        switch rule.type {
        case .subjectContains, .subjectRegex:
            return subject
        case .bodyContains, .bodyRegex:
            return body?.prefix(100).description
        case .senderDomain, .senderEmail:
            return from
        case .docketFormat:
            return subject ?? body?.prefix(50).description
        }
    }
    
    // MARK: - Rule Templates
    
    /// Get pre-built rule templates for common patterns
    static var ruleTemplates: [ClassificationRule] {
        [
            ClassificationRule(
                name: "New Docket Subject",
                description: "Emails with 'New Docket' in subject",
                type: .subjectContains,
                pattern: "New Docket",
                weight: 0.9,
                action: .classifyAsNewDocket
            ),
            ClassificationRule(
                name: "Docket Number Format",
                description: "5-digit docket numbers",
                type: .docketFormat,
                pattern: "\\b\\d{5}\\b",
                weight: 0.85,
                action: .boostConfidence
            ),
            ClassificationRule(
                name: "Dropbox Links",
                description: "Emails containing Dropbox links",
                type: .bodyContains,
                pattern: "dropbox.com",
                weight: 0.8,
                action: .classifyAsFileDelivery
            ),
            ClassificationRule(
                name: "WeTransfer Links",
                description: "Emails containing WeTransfer links",
                type: .bodyContains,
                pattern: "wetransfer.com",
                weight: 0.8,
                action: .classifyAsFileDelivery
            ),
            ClassificationRule(
                name: "Google Drive Links",
                description: "Emails containing Google Drive links",
                type: .bodyRegex,
                pattern: "drive\\.google\\.com|docs\\.google\\.com",
                weight: 0.75,
                action: .classifyAsFileDelivery
            ),
            ClassificationRule(
                name: "Newsletter Filter",
                description: "Ignore newsletter/marketing emails",
                type: .subjectContains,
                pattern: "unsubscribe",
                weight: 0.7,
                action: .ignoreEmail
            )
        ]
    }
    
    /// Add a template rule
    func addTemplate(_ template: ClassificationRule) {
        // Create a new rule with a new ID from the template
        let rule = ClassificationRule(
            id: UUID(),
            name: template.name,
            description: template.description,
            type: template.type,
            pattern: template.pattern,
            weight: template.weight,
            isEnabled: template.isEnabled,
            action: template.action,
            createdAt: Date(),
            lastModified: Date()
        )
        addRule(rule)
    }
    
    // MARK: - Persistence
    
    private func loadRules() {
        guard !hasLoadedRules else { return }
        hasLoadedRules = true
        
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            rules = []
            return
        }
        
        do {
            let data = try Data(contentsOf: storageURL)
            rules = try JSONDecoder().decode([ClassificationRule].self, from: data)
            lastModified = try? FileManager.default.attributesOfItem(atPath: storageURL.path)[.modificationDate] as? Date
            print("📋 [RulesManager] Loaded \(rules.count) classification rules")
        } catch {
            print("⚠️ [RulesManager] Failed to load rules: \(error.localizedDescription)")
            rules = []
        }
    }
    
    func saveRules() {
        do {
            let data = try JSONEncoder().encode(rules)
            try data.write(to: storageURL)
            lastModified = Date()
            objectWillChange.send()
            print("💾 [RulesManager] Saved \(rules.count) classification rules")
        } catch {
            print("⚠️ [RulesManager] Failed to save rules: \(error.localizedDescription)")
        }
    }
    
    /// Export rules to a file
    func exportRules(to url: URL) throws {
        let data = try JSONEncoder().encode(rules)
        try data.write(to: url)
    }
    
    /// Import rules from a file
    func importRules(from url: URL, replaceExisting: Bool = false) throws {
        let data = try Data(contentsOf: url)
        let importedRules = try JSONDecoder().decode([ClassificationRule].self, from: data)
        
        if replaceExisting {
            rules = importedRules
        } else {
            // Merge, avoiding duplicates by pattern
            for importedRule in importedRules {
                if !rules.contains(where: { $0.pattern == importedRule.pattern && $0.type == importedRule.type }) {
                    // Create a new rule with a new ID
                    let newRule = ClassificationRule(
                        id: UUID(),
                        name: importedRule.name,
                        description: importedRule.description,
                        type: importedRule.type,
                        pattern: importedRule.pattern,
                        weight: importedRule.weight,
                        isEnabled: importedRule.isEnabled,
                        action: importedRule.action,
                        createdAt: importedRule.createdAt,
                        lastModified: Date()
                    )
                    rules.append(newRule)
                }
            }
        }
        
        saveRules()
    }
}

