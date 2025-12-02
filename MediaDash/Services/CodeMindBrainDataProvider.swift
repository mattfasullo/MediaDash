import Foundation
import Combine
import SwiftUI

// MARK: - Brain Node Types

/// Extended categories for brain visualization
enum BrainNodeCategory: String, Codable, CaseIterable {
    case core = "Core"
    case rule = "Rule"
    case memory = "Memory"
    case pattern = "Pattern"
    case anomaly = "Anomaly"
    // Intelligence categories
    case docket = "Docket"
    case emailThread = "Email Thread"
    case file = "File"
    case session = "Session"
    case metadata = "Metadata"
    case suggestion = "Suggestion"
    case conflict = "Conflict"
    
    var color: Color {
        switch self {
        case .core: return .blue
        case .rule: return .green
        case .memory: return .cyan
        case .pattern: return .purple
        case .anomaly: return .orange
        case .docket: return .indigo
        case .emailThread: return .teal
        case .file: return .mint
        case .session: return .pink
        case .metadata: return .yellow
        case .suggestion: return Color(red: 0.4, green: 0.8, blue: 0.4) // Light green
        case .conflict: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .core: return "brain.head.profile"
        case .rule: return "list.bullet.rectangle"
        case .memory: return "clock.arrow.circlepath"
        case .pattern: return "waveform.path"
        case .anomaly: return "exclamationmark.triangle"
        case .docket: return "folder"
        case .emailThread: return "envelope"
        case .file: return "doc"
        case .session: return "waveform"
        case .metadata: return "tag"
        case .suggestion: return "lightbulb"
        case .conflict: return "exclamationmark.2"
        }
    }
    
    var displayName: String {
        rawValue
    }
}

/// Extended node for brain visualization
struct BrainNode: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let category: BrainNodeCategory
    let confidence: Double
    var position: CGPoint
    
    // Linked data IDs
    var docketNumber: String?
    var ruleId: UUID?
    var emailThreadId: String?
    var fileId: String?
    var sessionId: String?
    var suggestionId: UUID?
    var conflictId: UUID?
    
    // Status flags
    var hasIssue: Bool
    var isHighlighted: Bool
    
    // Detail data (for popover)
    var detailData: [String: String]?
    
    static func == (lhs: BrainNode, rhs: BrainNode) -> Bool {
        lhs.id == rhs.id
    }
}

/// Connection between brain nodes
struct BrainConnection: Identifiable {
    let id: UUID
    let fromId: String
    let toId: String
    let strength: Double
    let connectionType: ConnectionType
    var color: Color
    var isAnimated: Bool
    
    enum ConnectionType: String {
        case parentChild = "Parent-Child"
        case related = "Related"
        case dependency = "Dependency"
        case conflict = "Conflict"
        case suggestion = "Suggestion"
    }
}

// MARK: - Brain Data Provider

/// Provides unified data for BrainView from all intelligence engines
@MainActor
class CodeMindBrainDataProvider: ObservableObject {
    static let shared = CodeMindBrainDataProvider()
    
    // Published state
    @Published private(set) var nodes: [BrainNode] = []
    @Published private(set) var connections: [BrainConnection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?
    
    // Filter state
    @Published var showDockets = true
    @Published var showEmails = true
    @Published var showFiles = true
    @Published var showSessions = true
    @Published var showSuggestions = true
    @Published var showConflicts = true
    @Published var showRules = true
    @Published var showFileDeliveries = true
    @Published var showUserPreferences = true
    
    // Statistics for display
    @Published private(set) var totalDocketsCount: Int = 0
    @Published private(set) var totalEmailThreadsCount: Int = 0
    @Published private(set) var totalSessionsCount: Int = 0
    @Published private(set) var totalFilesCount: Int = 0
    @Published private(set) var totalFileDeliveriesCount: Int = 0
    @Published private(set) var totalSuggestionsCount: Int = 0
    @Published private(set) var totalConflictsCount: Int = 0
    @Published private(set) var totalRulesCount: Int = 0
    @Published private(set) var totalUserPreferencesCount: Int = 0
    
    // References to engines
    private var contextEngine: CodeMindContextEngine { CodeMindContextEngine.shared }
    private var fileIntelligence: CodeMindFileIntelligence { CodeMindFileIntelligence.shared }
    private var metadataIntelligence: CodeMindMetadataIntelligence { CodeMindMetadataIntelligence.shared }
    private var sessionAnalyzer: CodeMindSessionAnalyzer { CodeMindSessionAnalyzer.shared }
    private var dataFusion: CodeMindDataFusion { CodeMindDataFusion.shared }
    private var rulesManager: CodeMindRulesManager { CodeMindRulesManager.shared }
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupSubscriptions()
    }
    
    // MARK: - Subscriptions
    
    private func setupSubscriptions() {
        // Subscribe to data changes from all engines
        contextEngine.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshNodes() }
            }
            .store(in: &cancellables)
        
        fileIntelligence.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshNodes() }
            }
            .store(in: &cancellables)
        
        sessionAnalyzer.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshNodes() }
            }
            .store(in: &cancellables)
        
        dataFusion.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshNodes() }
            }
            .store(in: &cancellables)
        
        rulesManager.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshNodes() }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Node Generation
    
    /// Refresh all nodes from intelligence engines
    func refreshNodes() async {
        isLoading = true
        
        var newNodes: [BrainNode] = []
        var newConnections: [BrainConnection] = []
        
        // Central CodeMind node
        let centerNode = BrainNode(
            id: "codemind_center",
            title: "CodeMind",
            subtitle: nil,
            category: .core,
            confidence: 1.0,
            position: CGPoint(x: 0.5, y: 0.5),
            hasIssue: false,
            isHighlighted: false
        )
        newNodes.append(centerNode)
        
        // Add nodes from each source
        var nodeIndex = 0
        // No hard limits - show everything CodeMind knows
        
        // 1. Docket nodes (from data fusion)
        if showDockets {
            totalDocketsCount = dataFusion.unifiedIntelligence.count
            let dockets = Array(dataFusion.unifiedIntelligence)
            for (i, intel) in dockets.enumerated() {
                let angle = angleForIndex(i, total: dockets.count, ring: 1)
                let position = positionForAngle(angle, ring: 1, totalNodes: dockets.count)
                
                var node = BrainNode(
                    id: "docket_\(intel.docketNumber)",
                    title: intel.docketNumber,
                    subtitle: intel.jobName,
                    category: .docket,
                    confidence: intel.confidenceScore,
                    position: position,
                    docketNumber: intel.docketNumber,
                    hasIssue: intel.status != .healthy,
                    isHighlighted: intel.status == .needsAttention
                )
                node.detailData = [
                    "Status": intel.status.rawValue,
                    "Stage": intel.lifecycleStage?.rawValue ?? "Unknown",
                    "Completeness": "\(Int(intel.completeness.overallScore * 100))%",
                    "Sources": "\(intel.sources.count)",
                    "Suggestions": "\(intel.suggestions.count)"
                ]
                newNodes.append(node)
                
                // Connect to center
                newConnections.append(BrainConnection(
                    id: UUID(),
                    fromId: centerNode.id,
                    toId: node.id,
                    strength: intel.confidenceScore,
                    connectionType: .parentChild,
                    color: intel.status == .healthy ? .blue : .orange,
                    isAnimated: false
                ))
                
                nodeIndex += 1
            }
        }
        
        // 2. Email thread nodes
        if showEmails {
            totalEmailThreadsCount = contextEngine.emailThreads.count
            let threads = Array(contextEngine.emailThreads)
            for (i, thread) in threads.enumerated() {
                let angle = angleForIndex(i, total: threads.count, ring: 2)
                let position = positionForAngle(angle, ring: 2, totalNodes: threads.count)
                
                var node = BrainNode(
                    id: "thread_\(thread.id)",
                    title: String(thread.subject.prefix(25)),
                    subtitle: "\(thread.messages.count) messages",
                    category: .emailThread,
                    confidence: thread.confidence,
                    position: position,
                    emailThreadId: thread.id,
                    hasIssue: false,
                    isHighlighted: false
                )
                node.docketNumber = thread.docketNumber
                node.detailData = [
                    "Subject": thread.subject,
                    "Messages": "\(thread.messages.count)",
                    "Type": thread.classificationType?.rawValue ?? "Unknown",
                    "Docket": thread.docketNumber ?? "None"
                ]
                newNodes.append(node)
                
                // Connect to docket if linked
                if let docket = thread.docketNumber {
                    let docketNodeId = "docket_\(docket)"
                    if newNodes.contains(where: { $0.id == docketNodeId }) {
                        newConnections.append(BrainConnection(
                            id: UUID(),
                            fromId: docketNodeId,
                            toId: node.id,
                            strength: thread.confidence,
                            connectionType: .related,
                            color: .teal,
                            isAnimated: false
                        ))
                    }
                } else {
                    // Connect to center if no docket
                    newConnections.append(BrainConnection(
                        id: UUID(),
                        fromId: centerNode.id,
                        toId: node.id,
                        strength: 0.3,
                        connectionType: .parentChild,
                        color: .gray.opacity(0.5),
                        isAnimated: false
                    ))
                }
                
                nodeIndex += 1
            }
        }
        
        // 3. Session nodes
        if showSessions {
            totalSessionsCount = sessionAnalyzer.detectedSessions.count
            let sessions = Array(sessionAnalyzer.detectedSessions)
            for (i, session) in sessions.enumerated() {
                let angle = angleForIndex(i, total: sessions.count, ring: 3)
                let position = positionForAngle(angle, ring: 3, totalNodes: sessions.count)
                
                let hasIssues = !session.issues.isEmpty
                var node = BrainNode(
                    id: "session_\(session.id)",
                    title: session.name,
                    subtitle: session.sessionType.rawValue,
                    category: .session,
                    confidence: session.completenessScore,
                    position: position,
                    sessionId: session.id,
                    hasIssue: hasIssues,
                    isHighlighted: session.issues.contains { $0.severity == .critical }
                )
                node.docketNumber = session.linkedDocketNumber ?? session.docketNumber
                node.detailData = [
                    "Type": session.sessionType.rawValue,
                    "Completeness": "\(Int(session.completenessScore * 100))%",
                    "Issues": "\(session.issues.count)",
                    "Docket": session.linkedDocketNumber ?? session.docketNumber ?? "Not linked"
                ]
                newNodes.append(node)
                
                // Connect to docket if linked
                if let docket = session.linkedDocketNumber ?? session.docketNumber {
                    let docketNodeId = "docket_\(docket)"
                    if newNodes.contains(where: { $0.id == docketNodeId }) {
                        newConnections.append(BrainConnection(
                            id: UUID(),
                            fromId: docketNodeId,
                            toId: node.id,
                            strength: 0.8,
                            connectionType: .related,
                            color: .pink,
                            isAnimated: false
                        ))
                    }
                }
                
                nodeIndex += 1
            }
        }
        
        // 4. Suggestion nodes
        if showSuggestions {
            // Session link suggestions
            let allLinkSuggestions = sessionAnalyzer.getPendingSuggestions()
            let linkSuggestions = Array(allLinkSuggestions)
            
            // Metadata enrichment suggestions (declare before use)
            let allEnrichments = metadataIntelligence.getPendingSuggestions()
            let enrichments = Array(allEnrichments)
            
            for (i, suggestion) in linkSuggestions.enumerated() {
                let angle = angleForIndex(i, total: linkSuggestions.count, ring: 4)
                let position = positionForAngle(angle, ring: 4, totalNodes: linkSuggestions.count + enrichments.count)
                
                var node = BrainNode(
                    id: "suggestion_link_\(suggestion.id)",
                    title: "Link Session",
                    subtitle: suggestion.sessionName,
                    category: .suggestion,
                    confidence: suggestion.confidence,
                    position: position,
                    suggestionId: suggestion.id,
                    hasIssue: false,
                    isHighlighted: true
                )
                node.docketNumber = suggestion.suggestedDocketNumber
                node.sessionId = suggestion.sessionId
                node.detailData = [
                    "Session": suggestion.sessionName,
                    "Docket": suggestion.suggestedDocketNumber,
                    "Confidence": "\(Int(suggestion.confidence * 100))%",
                    "Reason": suggestion.reasoning
                ]
                newNodes.append(node)
                
                // Connect to session
                let sessionNodeId = "session_\(suggestion.sessionId)"
                if newNodes.contains(where: { $0.id == sessionNodeId }) {
                    newConnections.append(BrainConnection(
                        id: UUID(),
                        fromId: sessionNodeId,
                        toId: node.id,
                        strength: suggestion.confidence,
                        connectionType: .suggestion,
                        color: BrainNodeCategory.suggestion.color,
                        isAnimated: true
                    ))
                }
                
                nodeIndex += 1
            }
            
            // Metadata enrichment suggestions (already declared above)
            totalSuggestionsCount = linkSuggestions.count + enrichments.count
            for (i, enrichment) in enrichments.enumerated() {
                let angle = angleForIndex(i + linkSuggestions.count, total: linkSuggestions.count + enrichments.count, ring: 4)
                let position = positionForAngle(angle, ring: 4, totalNodes: linkSuggestions.count + enrichments.count)
                
                var node = BrainNode(
                    id: "suggestion_enrich_\(enrichment.id)",
                    title: "Enrich \(enrichment.fieldName)",
                    subtitle: enrichment.suggestedValue,
                    category: .suggestion,
                    confidence: enrichment.confidence,
                    position: position,
                    suggestionId: enrichment.id,
                    hasIssue: false,
                    isHighlighted: true
                )
                node.docketNumber = enrichment.docketNumber
                node.detailData = [
                    "Field": enrichment.fieldName,
                    "Current": enrichment.currentValue ?? "Empty",
                    "Suggested": enrichment.suggestedValue,
                    "Source": enrichment.source.rawValue
                ]
                newNodes.append(node)
                
                // Connect to docket
                let docketNodeId = "docket_\(enrichment.docketNumber)"
                if newNodes.contains(where: { $0.id == docketNodeId }) {
                    newConnections.append(BrainConnection(
                        id: UUID(),
                        fromId: docketNodeId,
                        toId: node.id,
                        strength: enrichment.confidence,
                        connectionType: .suggestion,
                        color: BrainNodeCategory.suggestion.color,
                        isAnimated: true
                    ))
                }
                
                nodeIndex += 1
            }
        }
        
        // 5. Conflict nodes
        if showConflicts {
            totalConflictsCount = metadataIntelligence.getUnresolvedConflicts().count
            let conflicts = Array(metadataIntelligence.getUnresolvedConflicts())
            for (i, conflict) in conflicts.enumerated() {
                let angle = angleForIndex(i, total: conflicts.count, ring: 4, offset: .pi)
                let position = positionForAngle(angle, ring: 4, totalNodes: conflicts.count)
                
                var node = BrainNode(
                    id: "conflict_\(conflict.id)",
                    title: "Conflict: \(conflict.fieldName)",
                    subtitle: "\(conflict.sources.count) sources",
                    category: .conflict,
                    confidence: 1.0 - conflict.resolutionConfidence,
                    position: position,
                    conflictId: conflict.id,
                    hasIssue: true,
                    isHighlighted: true
                )
                node.docketNumber = conflict.docketNumber
                node.detailData = [
                    "Field": conflict.fieldName,
                    "Sources": conflict.sources.map { "\($0.sourceType.rawValue): \($0.value)" }.joined(separator: ", "),
                    "Suggested": conflict.suggestedResolution ?? "None"
                ]
                newNodes.append(node)
                
                // Connect to docket
                let docketNodeId = "docket_\(conflict.docketNumber)"
                if newNodes.contains(where: { $0.id == docketNodeId }) {
                    newConnections.append(BrainConnection(
                        id: UUID(),
                        fromId: docketNodeId,
                        toId: node.id,
                        strength: 0.9,
                        connectionType: .conflict,
                        color: .red,
                        isAnimated: true
                    ))
                }
                
                nodeIndex += 1
            }
        }
        
        // 6. Rule nodes
        if showRules {
            totalRulesCount = rulesManager.rules.count
            let rules = Array(rulesManager.rules)
            for (i, rule) in rules.enumerated() {
                let angle = angleForIndex(i, total: rules.count, ring: 2, offset: .pi / 2)
                let position = positionForAngle(angle, ring: 2, totalNodes: rules.count)
                
                let node = BrainNode(
                    id: "rule_\(rule.id)",
                    title: rule.name.isEmpty ? rule.pattern : rule.name,
                    subtitle: rule.type.rawValue,
                    category: .rule,
                    confidence: rule.isEnabled ? rule.weight : 0.3,
                    position: position,
                    ruleId: rule.id,
                    hasIssue: false,
                    isHighlighted: false,
                    detailData: [
                        "Pattern": rule.pattern,
                        "Type": rule.type.rawValue,
                        "Action": rule.action.rawValue,
                        "Weight": "\(Int(rule.weight * 100))%",
                        "Enabled": rule.isEnabled ? "Yes" : "No"
                    ]
                )
                newNodes.append(node)
                
                // Connect to center
                newConnections.append(BrainConnection(
                    id: UUID(),
                    fromId: centerNode.id,
                    toId: node.id,
                    strength: rule.weight,
                    connectionType: .parentChild,
                    color: rule.isEnabled ? .green : .gray,
                    isAnimated: false
                ))
                
                nodeIndex += 1
            }
        }
        
        // 7. Tracked file nodes
        if showFiles {
            totalFilesCount = fileIntelligence.trackedFiles.count
            let files = Array(fileIntelligence.trackedFiles)
            for (i, file) in files.enumerated() {
                let angle = angleForIndex(i, total: files.count, ring: 3)
                let position = positionForAngle(angle, ring: 3, totalNodes: files.count)
                
                var node = BrainNode(
                    id: "file_\(file.id)",
                    title: file.name,
                    subtitle: file.fileType.rawValue,
                    category: .file,
                    confidence: file.validationStatus == .valid ? 0.9 : 0.5,
                    position: position,
                    docketNumber: file.docketNumber,
                    fileId: file.id,
                    hasIssue: file.validationStatus != .valid && file.validationStatus != .unknown,
                    isHighlighted: file.validationStatus == .missingDependencies || file.validationStatus == .corrupted
                )
                node.detailData = [
                    "Type": file.fileType.rawValue,
                    "Status": file.validationStatus.rawValue,
                    "Path": file.path,
                    "Docket": file.docketNumber ?? "None",
                    "Relationships": "\(file.relationships.count)"
                ]
                newNodes.append(node)
                
                // Connect to docket if linked
                if let docket = file.docketNumber {
                    let docketNodeId = "docket_\(docket)"
                    if newNodes.contains(where: { $0.id == docketNodeId }) {
                        newConnections.append(BrainConnection(
                            id: UUID(),
                            fromId: docketNodeId,
                            toId: node.id,
                            strength: 0.7,
                            connectionType: .related,
                            color: BrainNodeCategory.file.color,
                            isAnimated: false
                        ))
                    }
                }
                
                nodeIndex += 1
            }
        }
        
        // 8. File delivery nodes
        if showFileDeliveries {
            totalFileDeliveriesCount = fileIntelligence.fileDeliveries.count
            let deliveries = Array(fileIntelligence.fileDeliveries)
            for (i, delivery) in deliveries.enumerated() {
                let angle = angleForIndex(i, total: deliveries.count, ring: 4, offset: .pi / 4)
                let position = positionForAngle(angle, ring: 4, totalNodes: deliveries.count)
                
                let isComplete = delivery.completeness >= 1.0
                var node = BrainNode(
                    id: "delivery_\(delivery.id)",
                    title: delivery.emailSubject ?? "File Delivery",
                    subtitle: "\(delivery.files.count) files",
                    category: .file,
                    confidence: delivery.completeness,
                    position: position,
                    docketNumber: delivery.docketNumber,
                    hasIssue: !isComplete,
                    isHighlighted: !isComplete
                )
                node.detailData = [
                    "Files": "\(delivery.files.count)",
                    "Completeness": "\(Int(delivery.completeness * 100))%",
                    "Expected": "\(delivery.expectedFiles.count)",
                    "Received Files": "\(delivery.expectedFiles.filter { $0.isReceived }.count)",
                    "Docket": delivery.docketNumber ?? "None",
                    "Received At": delivery.receivedAt.formatted(date: .abbreviated, time: .shortened)
                ]
                newNodes.append(node)
                
                // Connect to docket if linked
                if let docket = delivery.docketNumber {
                    let docketNodeId = "docket_\(docket)"
                    if newNodes.contains(where: { $0.id == docketNodeId }) {
                        newConnections.append(BrainConnection(
                            id: UUID(),
                            fromId: docketNodeId,
                            toId: node.id,
                            strength: delivery.completeness,
                            connectionType: .related,
                            color: BrainNodeCategory.file.color,
                            isAnimated: !isComplete
                        ))
                    }
                }
                
                nodeIndex += 1
            }
        }
        
        // 9. User preference/pattern nodes
        if showUserPreferences {
            totalUserPreferencesCount = contextEngine.userPreferences.count
            let preferences = Array(contextEngine.userPreferences)
            for (i, preference) in preferences.enumerated() {
                let angle = angleForIndex(i, total: preferences.count, ring: 2, offset: .pi)
                let position = positionForAngle(angle, ring: 2, totalNodes: preferences.count)
                
                let node = BrainNode(
                    id: "preference_\(preference.id)",
                    title: preference.pattern,
                    subtitle: preference.category.rawValue,
                    category: .pattern,
                    confidence: preference.confidence,
                    position: position,
                    hasIssue: false,
                    isHighlighted: false,
                    detailData: [
                        "Category": preference.category.rawValue,
                        "Pattern": preference.pattern,
                        "Learned Value": preference.learnedValue,
                        "Occurrences": "\(preference.occurrences)",
                        "Confidence": "\(Int(preference.confidence * 100))%",
                        "Last Seen": preference.lastSeen.formatted(date: .abbreviated, time: .shortened)
                    ]
                )
                newNodes.append(node)
                
                // Connect to center
                newConnections.append(BrainConnection(
                    id: UUID(),
                    fromId: centerNode.id,
                    toId: node.id,
                    strength: preference.confidence,
                    connectionType: .parentChild,
                    color: BrainNodeCategory.pattern.color,
                    isAnimated: false
                ))
                
                nodeIndex += 1
            }
        }
        
        // 10. Rule nodes (configuration/rules)
        if showRules {
            totalRulesCount = rulesManager.rules.count
            let rules = Array(rulesManager.rules)
            for (i, rule) in rules.enumerated() {
                let angle = angleForIndex(i, total: rules.count, ring: 2, offset: .pi / 2)
                let position = positionForAngle(angle, ring: 2, totalNodes: rules.count)
                
                let node = BrainNode(
                    id: "rule_\(rule.id.uuidString)",
                    title: rule.name.isEmpty ? rule.pattern : rule.name,
                    subtitle: rule.type.rawValue,
                    category: .rule,
                    confidence: rule.weight,
                    position: position,
                    ruleId: rule.id,
                    hasIssue: !rule.isEnabled,
                    isHighlighted: false,
                    detailData: [
                        "Name": rule.name.isEmpty ? "Untitled" : rule.name,
                        "Type": rule.type.rawValue,
                        "Pattern": rule.pattern,
                        "Action": rule.action.rawValue,
                        "Weight": String(format: "%.2f", rule.weight),
                        "Enabled": rule.isEnabled ? "Yes" : "No",
                        "Description": rule.description.isEmpty ? "None" : rule.description
                    ]
                )
                newNodes.append(node)
                
                // Connect to center
                newConnections.append(BrainConnection(
                    id: UUID(),
                    fromId: centerNode.id,
                    toId: node.id,
                    strength: rule.weight,
                    connectionType: .parentChild,
                    color: BrainNodeCategory.rule.color,
                    isAnimated: false
                ))
                
                nodeIndex += 1
            }
        }
        
        // Update published state
        nodes = newNodes
        connections = newConnections
        lastRefresh = Date()
        isLoading = false
    }
    
    // MARK: - Layout Helpers
    
    private func angleForIndex(_ index: Int, total: Int, ring: Int, offset: Double = 0) -> Double {
        guard total > 0 else { return 0 }
        return (Double(index) / Double(total)) * 2 * .pi + offset
    }
    
    private func positionForAngle(_ angle: Double, ring: Int, totalNodes: Int = 1) -> CGPoint {
        // Calculate radius based on ring and number of nodes to ensure spacing
        let baseRadius: Double
        switch ring {
        case 1: baseRadius = 0.20  // Closer for important items (dockets)
        case 2: baseRadius = 0.30
        case 3: baseRadius = 0.40
        case 4: baseRadius = 0.50
        case 5: baseRadius = 0.60
        default: baseRadius = 0.35
        }
        
        // Adjust radius based on number of nodes to prevent overcrowding
        // More nodes = larger radius needed
        let nodeDensityFactor = min(Double(totalNodes) / 12.0, 2.0)  // Cap at 2x
        let radius = baseRadius * (1.0 + nodeDensityFactor * 0.15)
        
        // Clamp radius to prevent nodes from going off-screen
        let maxRadius = 0.45  // Max 45% of canvas from center
        let finalRadius = min(radius, maxRadius)
        
        return CGPoint(
            x: 0.5 + cos(angle) * finalRadius,
            y: 0.5 + sin(angle) * finalRadius
        )
    }
    
    // MARK: - Node Queries
    
    /// Get nodes for a specific docket
    func getNodesForDocket(_ docketNumber: String) -> [BrainNode] {
        return nodes.filter { $0.docketNumber == docketNumber }
    }
    
    /// Get connections for a node
    func getConnections(for nodeId: String) -> [BrainConnection] {
        return connections.filter { $0.fromId == nodeId || $0.toId == nodeId }
    }
    
    /// Get nodes by category
    func getNodes(category: BrainNodeCategory) -> [BrainNode] {
        return nodes.filter { $0.category == category }
    }
    
    /// Get nodes with issues
    func getNodesWithIssues() -> [BrainNode] {
        return nodes.filter { $0.hasIssue }
    }
    
    /// Get highlighted nodes (suggestions, conflicts)
    func getHighlightedNodes() -> [BrainNode] {
        return nodes.filter { $0.isHighlighted }
    }
}

