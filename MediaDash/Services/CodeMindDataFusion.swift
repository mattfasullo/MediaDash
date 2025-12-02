import Foundation
import Combine

// MARK: - Data Fusion Models

/// Unified intelligence about a docket from all sources
struct UnifiedDocketIntelligence: Identifiable, Equatable {
    let id: String // docketNumber
    let docketNumber: String
    var jobName: String?
    var client: String?
    var status: DocketStatus
    var lifecycleStage: DocketLifecycle.LifecycleStage?
    var completeness: CompletenessInfo
    var sources: [DataSourceInfo]
    var conflicts: [String] // Field names with conflicts
    var suggestions: [SuggestionSummary]
    var lastUpdated: Date
    var confidenceScore: Double
    
    enum DocketStatus: String, Codable {
        case healthy = "Healthy"
        case hasConflicts = "Has Conflicts"
        case incomplete = "Incomplete"
        case needsAttention = "Needs Attention"
        
        var priority: Int {
            switch self {
            case .healthy: return 0
            case .incomplete: return 1
            case .hasConflicts: return 2
            case .needsAttention: return 3
            }
        }
    }
    
    struct CompletenessInfo: Codable, Equatable {
        var hasMetadata: Bool
        var hasFiles: Bool
        var hasSession: Bool
        var hasEmails: Bool
        var overallScore: Double // 0.0 to 1.0
    }
    
    struct DataSourceInfo: Codable, Equatable {
        let source: String // "email", "asana", "filesystem", "session"
        let lastUpdated: Date
        let confidence: Double
        let itemCount: Int
    }
    
    struct SuggestionSummary: Identifiable, Codable, Equatable {
        let id: UUID
        let type: SuggestionType
        let description: String
        let priority: Int
        
        enum SuggestionType: String, Codable {
            case metadataEnrichment = "Metadata Enrichment"
            case conflictResolution = "Conflict Resolution"
            case sessionLink = "Session Link"
            case missingFile = "Missing File"
            case incompleteDelivery = "Incomplete Delivery"
        }
    }
    
    static func == (lhs: UnifiedDocketIntelligence, rhs: UnifiedDocketIntelligence) -> Bool {
        lhs.id == rhs.id
    }
}

/// Cross-source data conflict
struct DataConflict: Identifiable, Equatable {
    let id: UUID
    let docketNumber: String
    let conflictType: ConflictType
    let description: String
    var sources: [ConflictSourceInfo]
    var suggestedResolution: String?
    var isResolved: Bool
    var resolvedValue: String?
    
    enum ConflictType: String, Codable {
        case metadataDiscrepancy = "Metadata Discrepancy"
        case duplicateDocket = "Duplicate Docket"
        case orphanedFiles = "Orphaned Files"
        case missingLink = "Missing Link"
    }
    
    struct ConflictSourceInfo: Codable, Equatable {
        let source: String
        let value: String
        let confidence: Double
    }
    
    static func == (lhs: DataConflict, rhs: DataConflict) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Data Fusion Engine

/// Combines data from all intelligence engines into unified docket intelligence
@MainActor
class CodeMindDataFusion: ObservableObject {
    static let shared = CodeMindDataFusion()
    
    // Published state for BrainView
    @Published private(set) var unifiedIntelligence: [UnifiedDocketIntelligence] = []
    @Published private(set) var dataConflicts: [DataConflict] = []
    @Published private(set) var docketsNeedingAttention: [UnifiedDocketIntelligence] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var lastFusionDate: Date?
    
    // References to other engines (injected via shared instances)
    private var contextEngine: CodeMindContextEngine { CodeMindContextEngine.shared }
    private var fileIntelligence: CodeMindFileIntelligence { CodeMindFileIntelligence.shared }
    private var metadataIntelligence: CodeMindMetadataIntelligence { CodeMindMetadataIntelligence.shared }
    private var sessionAnalyzer: CodeMindSessionAnalyzer { CodeMindSessionAnalyzer.shared }
    
    // Internal state
    private var intelligenceMap: [String: UnifiedDocketIntelligence] = [:] // docketNumber -> intelligence
    
    private init() {}
    
    // MARK: - Data Fusion
    
    /// Run full data fusion across all sources
    func runFusion() async {
        isAnalyzing = true
        
        // Collect all known dockets from all sources
        var allDockets = Set<String>()
        
        // From context engine (docket lifecycles)
        for lifecycle in contextEngine.docketLifecycles {
            allDockets.insert(lifecycle.docketNumber)
        }
        
        // From email threads with docket numbers
        for thread in contextEngine.emailThreads {
            if let docket = thread.docketNumber {
                allDockets.insert(docket)
            }
        }
        
        // From file intelligence
        for file in fileIntelligence.trackedFiles {
            if let docket = file.docketNumber {
                allDockets.insert(docket)
            }
        }
        
        // From file deliveries
        for delivery in fileIntelligence.fileDeliveries {
            if let docket = delivery.docketNumber {
                allDockets.insert(docket)
            }
        }
        
        // From metadata sources
        for source in metadataIntelligence.metadataSources {
            allDockets.insert(source.docketNumber)
        }
        
        // From sessions
        for session in sessionAnalyzer.detectedSessions {
            if let docket = session.docketNumber ?? session.linkedDocketNumber {
                allDockets.insert(docket)
            }
        }
        
        // Build unified intelligence for each docket
        var newConflicts: [DataConflict] = []
        
        for docketNumber in allDockets {
            let (intelligence, conflicts) = buildUnifiedIntelligence(for: docketNumber)
            intelligenceMap[docketNumber] = intelligence
            newConflicts.append(contentsOf: conflicts)
        }
        
        // Update published state
        unifiedIntelligence = Array(intelligenceMap.values).sorted { 
            // Sort by status priority (needs attention first), then by last updated
            if $0.status.priority != $1.status.priority {
                return $0.status.priority > $1.status.priority
            }
            return $0.lastUpdated > $1.lastUpdated
        }
        
        // Merge new conflicts with existing (avoid duplicates)
        for conflict in newConflicts {
            if !dataConflicts.contains(where: { 
                $0.docketNumber == conflict.docketNumber && 
                $0.conflictType == conflict.conflictType && 
                !$0.isResolved 
            }) {
                dataConflicts.append(conflict)
            }
        }
        
        // Update dockets needing attention
        docketsNeedingAttention = unifiedIntelligence.filter { 
            $0.status == .needsAttention || $0.status == .hasConflicts 
        }
        
        lastFusionDate = Date()
        isAnalyzing = false
        
        CodeMindLogger.shared.log(.info, "Data fusion complete", category: .general, metadata: [
            "docketCount": "\(allDockets.count)",
            "conflicts": "\(dataConflicts.filter { !$0.isResolved }.count)",
            "needsAttention": "\(docketsNeedingAttention.count)"
        ])
    }
    
    /// Build unified intelligence for a specific docket
    private func buildUnifiedIntelligence(for docketNumber: String) -> (UnifiedDocketIntelligence, [DataConflict]) {
        var sources: [UnifiedDocketIntelligence.DataSourceInfo] = []
        var conflicts: [DataConflict] = []
        var suggestions: [UnifiedDocketIntelligence.SuggestionSummary] = []
        var conflictFields: [String] = []
        
        // Gather from context engine
        let lifecycle = contextEngine.getLifecycle(for: docketNumber)
        let relatedThreads = contextEngine.emailThreads.filter { $0.docketNumber == docketNumber }
        
        if !relatedThreads.isEmpty {
            sources.append(UnifiedDocketIntelligence.DataSourceInfo(
                source: "email",
                lastUpdated: relatedThreads.map { $0.lastUpdated }.max() ?? Date(),
                confidence: relatedThreads.map { $0.confidence }.max() ?? 0.5,
                itemCount: relatedThreads.count
            ))
        }
        
        // Gather from file intelligence
        let files = fileIntelligence.getFiles(for: docketNumber)
        let deliveries = fileIntelligence.getDeliveries(for: docketNumber)
        
        if !files.isEmpty || !deliveries.isEmpty {
            sources.append(UnifiedDocketIntelligence.DataSourceInfo(
                source: "filesystem",
                lastUpdated: files.map { $0.lastAnalyzed }.max() ?? Date(),
                confidence: 0.9,
                itemCount: files.count
            ))
        }
        
        // Check for incomplete deliveries
        let incompleteDeliveries = deliveries.filter { $0.completeness < 1.0 }
        for delivery in incompleteDeliveries {
            suggestions.append(UnifiedDocketIntelligence.SuggestionSummary(
                id: UUID(),
                type: .incompleteDelivery,
                description: "Delivery '\(delivery.emailSubject ?? "Unknown")' is \(Int(delivery.completeness * 100))% complete",
                priority: 2
            ))
        }
        
        // Check for missing file dependencies
        let filesWithMissing = files.filter { file in
            file.relationships.contains { $0.status == .missing }
        }
        for file in filesWithMissing {
            let missingCount = file.relationships.filter { $0.status == .missing }.count
            suggestions.append(UnifiedDocketIntelligence.SuggestionSummary(
                id: UUID(),
                type: .missingFile,
                description: "'\(file.name)' has \(missingCount) missing dependencies",
                priority: 3
            ))
        }
        
        // Gather from metadata intelligence
        let metadataSources = metadataIntelligence.getSources(for: docketNumber)
        let fusedMetadata = metadataIntelligence.getFusedMetadata(for: docketNumber)
        
        if !metadataSources.isEmpty {
            for source in metadataSources {
                sources.append(UnifiedDocketIntelligence.DataSourceInfo(
                    source: source.sourceType.rawValue.lowercased(),
                    lastUpdated: source.lastUpdated,
                    confidence: source.confidence,
                    itemCount: source.fields.count
                ))
            }
        }
        
        // Check for metadata conflicts
        let metadataConflicts = metadataIntelligence.conflicts.filter { 
            $0.docketNumber == docketNumber && !$0.isResolved 
        }
        for conflict in metadataConflicts {
            conflictFields.append(conflict.fieldName)
            suggestions.append(UnifiedDocketIntelligence.SuggestionSummary(
                id: UUID(),
                type: .conflictResolution,
                description: "Conflict in '\(conflict.fieldName)': \(conflict.sources.count) different values",
                priority: 2
            ))
            
            // Create data conflict
            conflicts.append(DataConflict(
                id: UUID(),
                docketNumber: docketNumber,
                conflictType: .metadataDiscrepancy,
                description: "Field '\(conflict.fieldName)' has conflicting values",
                sources: conflict.sources.map { 
                    DataConflict.ConflictSourceInfo(
                        source: $0.sourceType.rawValue,
                        value: $0.value,
                        confidence: $0.confidence
                    )
                },
                suggestedResolution: conflict.suggestedResolution,
                isResolved: false,
                resolvedValue: nil
            ))
        }
        
        // Check for metadata enrichment suggestions
        let enrichments = metadataIntelligence.enrichmentSuggestions.filter { 
            $0.docketNumber == docketNumber && !$0.isApplied 
        }
        for enrichment in enrichments {
            suggestions.append(UnifiedDocketIntelligence.SuggestionSummary(
                id: enrichment.id,
                type: .metadataEnrichment,
                description: "Enrich '\(enrichment.fieldName)' with '\(enrichment.suggestedValue)'",
                priority: 1
            ))
        }
        
        // Gather from session analyzer
        let sessions = sessionAnalyzer.getSessions(for: docketNumber)
        
        if !sessions.isEmpty {
            sources.append(UnifiedDocketIntelligence.DataSourceInfo(
                source: "session",
                lastUpdated: sessions.map { $0.lastAnalyzed }.max() ?? Date(),
                confidence: 0.85,
                itemCount: sessions.count
            ))
        }
        
        // Check for session link suggestions
        let linkSuggestions = sessionAnalyzer.linkSuggestions.filter { 
            $0.suggestedDocketNumber == docketNumber && !$0.isApproved && !$0.isRejected 
        }
        for suggestion in linkSuggestions {
            suggestions.append(UnifiedDocketIntelligence.SuggestionSummary(
                id: suggestion.id,
                type: .sessionLink,
                description: "Link session '\(suggestion.sessionName)' to this docket",
                priority: 1
            ))
        }
        
        // Calculate completeness
        let completeness = UnifiedDocketIntelligence.CompletenessInfo(
            hasMetadata: !fusedMetadata.isEmpty,
            hasFiles: !files.isEmpty,
            hasSession: !sessions.isEmpty,
            hasEmails: !relatedThreads.isEmpty,
            overallScore: calculateOverallCompleteness(
                hasMetadata: !fusedMetadata.isEmpty,
                hasFiles: !files.isEmpty,
                hasSession: !sessions.isEmpty,
                hasEmails: !relatedThreads.isEmpty
            )
        )
        
        // Determine status
        let status: UnifiedDocketIntelligence.DocketStatus
        if !conflictFields.isEmpty || !metadataConflicts.isEmpty {
            status = .hasConflicts
        } else if completeness.overallScore < 0.5 {
            status = .incomplete
        } else if !suggestions.isEmpty && suggestions.contains(where: { $0.priority >= 2 }) {
            status = .needsAttention
        } else {
            status = .healthy
        }
        
        // Calculate confidence score
        let confidenceScore = sources.isEmpty ? 0.5 : sources.map { $0.confidence }.reduce(0, +) / Double(sources.count)
        
        let intelligence = UnifiedDocketIntelligence(
            id: docketNumber,
            docketNumber: docketNumber,
            jobName: fusedMetadata["jobName"],
            client: fusedMetadata["client"],
            status: status,
            lifecycleStage: lifecycle?.stage,
            completeness: completeness,
            sources: sources,
            conflicts: conflictFields,
            suggestions: suggestions.sorted { $0.priority > $1.priority },
            lastUpdated: Date(),
            confidenceScore: confidenceScore
        )
        
        return (intelligence, conflicts)
    }
    
    private func calculateOverallCompleteness(
        hasMetadata: Bool,
        hasFiles: Bool,
        hasSession: Bool,
        hasEmails: Bool
    ) -> Double {
        var score = 0.0
        var weights = 0.0
        
        // Metadata is most important (40%)
        weights += 0.4
        if hasMetadata { score += 0.4 }
        
        // Files are important (30%)
        weights += 0.3
        if hasFiles { score += 0.3 }
        
        // Sessions are nice to have (20%)
        weights += 0.2
        if hasSession { score += 0.2 }
        
        // Emails are helpful (10%)
        weights += 0.1
        if hasEmails { score += 0.1 }
        
        return score / weights
    }
    
    // MARK: - Conflict Resolution
    
    /// Resolve a data conflict
    func resolveConflict(conflictId: UUID, chosenValue: String, chosenSource: String) {
        guard let index = dataConflicts.firstIndex(where: { $0.id == conflictId }) else { return }
        
        var conflict = dataConflicts[index]
        conflict.isResolved = true
        conflict.resolvedValue = chosenValue
        dataConflicts[index] = conflict
        
        CodeMindLogger.shared.log(.info, "Resolved data conflict", category: .general, metadata: [
            "docket": conflict.docketNumber,
            "type": conflict.conflictType.rawValue,
            "chosenSource": chosenSource
        ])
        
        // Re-run fusion for this docket
        Task {
            await runFusion()
        }
    }
    
    // MARK: - Queries
    
    /// Get unified intelligence for a docket
    func getIntelligence(for docketNumber: String) -> UnifiedDocketIntelligence? {
        return intelligenceMap[docketNumber]
    }
    
    /// Get all dockets with a specific status
    func getDockets(with status: UnifiedDocketIntelligence.DocketStatus) -> [UnifiedDocketIntelligence] {
        return unifiedIntelligence.filter { $0.status == status }
    }
    
    /// Get unresolved conflicts
    func getUnresolvedConflicts() -> [DataConflict] {
        return dataConflicts.filter { !$0.isResolved }
    }
    
    /// Get all suggestions across all dockets
    func getAllSuggestions() -> [(docketNumber: String, suggestion: UnifiedDocketIntelligence.SuggestionSummary)] {
        return unifiedIntelligence.flatMap { intel in
            intel.suggestions.map { (intel.docketNumber, $0) }
        }.sorted { $0.suggestion.priority > $1.suggestion.priority }
    }
    
    /// Search dockets
    func searchDockets(query: String) -> [UnifiedDocketIntelligence] {
        let lowerQuery = query.lowercased()
        return unifiedIntelligence.filter { intel in
            intel.docketNumber.contains(lowerQuery) ||
            (intel.jobName?.lowercased().contains(lowerQuery) ?? false) ||
            (intel.client?.lowercased().contains(lowerQuery) ?? false)
        }
    }
    
    // MARK: - State Management
    
    /// Clear all data
    func clearAll() {
        intelligenceMap.removeAll()
        dataConflicts.removeAll()
        unifiedIntelligence.removeAll()
        docketsNeedingAttention.removeAll()
    }
}

