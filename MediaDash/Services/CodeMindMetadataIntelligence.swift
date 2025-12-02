import Foundation
import Combine

// MARK: - Metadata Intelligence Models

/// Represents metadata from a specific source
struct MetadataSource: Identifiable, Equatable {
    let id: String
    let sourceType: SourceType
    let docketNumber: String
    var fields: [String: MetadataField]
    var lastUpdated: Date
    var confidence: Double
    
    enum SourceType: String, Codable, CaseIterable {
        case asana = "Asana"
        case email = "Email"
        case filesystem = "Filesystem"
        case manual = "Manual Entry"
        case inferred = "Inferred"
        
        var priority: Int {
            switch self {
            case .manual: return 5 // Highest - user explicitly set
            case .asana: return 4
            case .email: return 3
            case .filesystem: return 2
            case .inferred: return 1 // Lowest
            }
        }
    }
    
    struct MetadataField: Codable, Equatable {
        let key: String
        var value: String
        var confidence: Double
        var extractedAt: Date
    }
    
    static func == (lhs: MetadataSource, rhs: MetadataSource) -> Bool {
        lhs.id == rhs.id
    }
}

/// Represents a conflict between metadata sources
struct MetadataConflict: Identifiable, Equatable {
    let id: UUID
    let docketNumber: String
    let fieldName: String
    var sources: [ConflictSource]
    var suggestedResolution: String?
    var resolutionConfidence: Double
    var isResolved: Bool
    var resolvedValue: String?
    var resolvedAt: Date?
    
    struct ConflictSource: Codable, Equatable {
        let sourceType: MetadataSource.SourceType
        let value: String
        let confidence: Double
    }
    
    static func == (lhs: MetadataConflict, rhs: MetadataConflict) -> Bool {
        lhs.id == rhs.id
    }
}

/// Represents an enrichment suggestion
struct MetadataEnrichment: Identifiable, Equatable {
    let id: UUID
    let docketNumber: String
    let fieldName: String
    let currentValue: String?
    let suggestedValue: String
    let source: MetadataSource.SourceType
    let confidence: Double
    let reasoning: String
    var isApplied: Bool
    var appliedAt: Date?
    
    static func == (lhs: MetadataEnrichment, rhs: MetadataEnrichment) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Metadata Intelligence Engine

/// Background engine that enriches metadata, detects conflicts, and suggests improvements
@MainActor
class CodeMindMetadataIntelligence: ObservableObject {
    static let shared = CodeMindMetadataIntelligence()
    
    // Published state for BrainView
    @Published private(set) var metadataSources: [MetadataSource] = []
    @Published private(set) var conflicts: [MetadataConflict] = []
    @Published private(set) var enrichmentSuggestions: [MetadataEnrichment] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var lastAnalysisDate: Date?
    
    // Internal tracking
    private var sourcesByDocket: [String: [MetadataSource]] = [:] // docketNumber -> sources
    
    private init() {}
    
    // MARK: - Metadata Collection
    
    /// Add metadata from Asana
    func addAsanaMetadata(
        docketNumber: String,
        jobName: String?,
        projectName: String?,
        customFields: [String: String]?
    ) {
        var fields: [String: MetadataSource.MetadataField] = [:]
        
        if let job = jobName, !job.isEmpty {
            fields["jobName"] = MetadataSource.MetadataField(
                key: "jobName",
                value: job,
                confidence: 0.95,
                extractedAt: Date()
            )
        }
        
        if let project = projectName, !project.isEmpty {
            fields["project"] = MetadataSource.MetadataField(
                key: "project",
                value: project,
                confidence: 0.9,
                extractedAt: Date()
            )
        }
        
        if let custom = customFields {
            for (key, value) in custom where !value.isEmpty {
                fields[key] = MetadataSource.MetadataField(
                    key: key,
                    value: value,
                    confidence: 0.85,
                    extractedAt: Date()
                )
            }
        }
        
        let source = MetadataSource(
            id: "asana_\(docketNumber)",
            sourceType: .asana,
            docketNumber: docketNumber,
            fields: fields,
            lastUpdated: Date(),
            confidence: 0.9
        )
        
        addSource(source)
    }
    
    /// Add metadata extracted from email
    func addEmailMetadata(
        docketNumber: String,
        jobName: String?,
        client: String?,
        agency: String?,
        producer: String?,
        extractedFrom: String // email subject or body snippet
    ) {
        var fields: [String: MetadataSource.MetadataField] = [:]
        
        if let job = jobName, !job.isEmpty {
            fields["jobName"] = MetadataSource.MetadataField(
                key: "jobName",
                value: job,
                confidence: 0.8,
                extractedAt: Date()
            )
        }
        
        if let client = client, !client.isEmpty {
            fields["client"] = MetadataSource.MetadataField(
                key: "client",
                value: client,
                confidence: 0.75,
                extractedAt: Date()
            )
        }
        
        if let agency = agency, !agency.isEmpty {
            fields["agency"] = MetadataSource.MetadataField(
                key: "agency",
                value: agency,
                confidence: 0.7,
                extractedAt: Date()
            )
        }
        
        if let producer = producer, !producer.isEmpty {
            fields["producer"] = MetadataSource.MetadataField(
                key: "producer",
                value: producer,
                confidence: 0.7,
                extractedAt: Date()
            )
        }
        
        let source = MetadataSource(
            id: "email_\(docketNumber)_\(Date().timeIntervalSince1970)",
            sourceType: .email,
            docketNumber: docketNumber,
            fields: fields,
            lastUpdated: Date(),
            confidence: 0.75
        )
        
        addSource(source)
    }
    
    /// Add metadata from filesystem (folder structure, file names)
    func addFilesystemMetadata(
        docketNumber: String,
        folderPath: String,
        inferredJobName: String?,
        inferredYear: String?
    ) {
        var fields: [String: MetadataSource.MetadataField] = [:]
        
        if let job = inferredJobName, !job.isEmpty {
            fields["jobName"] = MetadataSource.MetadataField(
                key: "jobName",
                value: job,
                confidence: 0.6,
                extractedAt: Date()
            )
        }
        
        if let year = inferredYear, !year.isEmpty {
            fields["year"] = MetadataSource.MetadataField(
                key: "year",
                value: year,
                confidence: 0.8,
                extractedAt: Date()
            )
        }
        
        fields["folderPath"] = MetadataSource.MetadataField(
            key: "folderPath",
            value: folderPath,
            confidence: 1.0,
            extractedAt: Date()
        )
        
        let source = MetadataSource(
            id: "filesystem_\(docketNumber)",
            sourceType: .filesystem,
            docketNumber: docketNumber,
            fields: fields,
            lastUpdated: Date(),
            confidence: 0.65
        )
        
        addSource(source)
    }
    
    /// Add manually entered metadata
    func addManualMetadata(
        docketNumber: String,
        fields: [String: String]
    ) {
        var metadataFields: [String: MetadataSource.MetadataField] = [:]
        
        for (key, value) in fields where !value.isEmpty {
            metadataFields[key] = MetadataSource.MetadataField(
                key: key,
                value: value,
                confidence: 1.0, // Manual = highest confidence
                extractedAt: Date()
            )
        }
        
        let source = MetadataSource(
            id: "manual_\(docketNumber)",
            sourceType: .manual,
            docketNumber: docketNumber,
            fields: metadataFields,
            lastUpdated: Date(),
            confidence: 1.0
        )
        
        addSource(source)
    }
    
    private func addSource(_ source: MetadataSource) {
        var sources = sourcesByDocket[source.docketNumber] ?? []
        
        // Update existing source of same type or add new
        if let existingIndex = sources.firstIndex(where: { $0.sourceType == source.sourceType }) {
            // Merge fields
            var existing = sources[existingIndex]
            for (key, field) in source.fields {
                existing.fields[key] = field
            }
            existing.lastUpdated = Date()
            sources[existingIndex] = existing
        } else {
            sources.append(source)
        }
        
        sourcesByDocket[source.docketNumber] = sources
        updatePublishedState()
        
        // Check for conflicts
        detectConflicts(for: source.docketNumber)
        
        // Generate enrichment suggestions
        generateEnrichmentSuggestions(for: source.docketNumber)
    }
    
    // MARK: - Conflict Detection
    
    /// Detect conflicts between metadata sources for a docket
    private func detectConflicts(for docketNumber: String) {
        guard let sources = sourcesByDocket[docketNumber], sources.count > 1 else { return }
        
        // Collect all field keys across sources
        var fieldValues: [String: [(MetadataSource.SourceType, String, Double)]] = [:] // field -> [(source, value, confidence)]
        
        for source in sources {
            for (key, field) in source.fields {
                var values = fieldValues[key] ?? []
                values.append((source.sourceType, field.value, field.confidence))
                fieldValues[key] = values
            }
        }
        
        // Find fields with conflicting values
        var newConflicts: [MetadataConflict] = []
        
        for (fieldName, values) in fieldValues {
            let uniqueValues = Set(values.map { $0.1.lowercased().trimmingCharacters(in: .whitespaces) })
            
            if uniqueValues.count > 1 {
                // We have a conflict
                let conflictSources = values.map { source, value, confidence in
                    MetadataConflict.ConflictSource(
                        sourceType: source,
                        value: value,
                        confidence: confidence
                    )
                }
                
                // Suggest resolution based on highest priority source
                let sortedSources = conflictSources.sorted { $0.sourceType.priority > $1.sourceType.priority }
                let suggested = sortedSources.first?.value
                let suggestionConfidence = sortedSources.first?.confidence ?? 0.5
                
                let conflict = MetadataConflict(
                    id: UUID(),
                    docketNumber: docketNumber,
                    fieldName: fieldName,
                    sources: conflictSources,
                    suggestedResolution: suggested,
                    resolutionConfidence: suggestionConfidence,
                    isResolved: false,
                    resolvedValue: nil,
                    resolvedAt: nil
                )
                
                // Check if this conflict already exists
                let existingConflict = conflicts.first {
                    $0.docketNumber == docketNumber && $0.fieldName == fieldName && !$0.isResolved
                }
                
                if existingConflict == nil {
                    newConflicts.append(conflict)
                }
            }
        }
        
        // Add new conflicts
        conflicts.append(contentsOf: newConflicts)
        
        if !newConflicts.isEmpty {
            CodeMindLogger.shared.log(.info, "Detected metadata conflicts", category: .general, metadata: [
                "docket": docketNumber,
                "conflictCount": "\(newConflicts.count)"
            ])
        }
    }
    
    /// Resolve a conflict with user's chosen value
    func resolveConflict(conflictId: UUID, chosenValue: String) {
        guard let index = conflicts.firstIndex(where: { $0.id == conflictId }) else { return }
        
        var conflict = conflicts[index]
        conflict.isResolved = true
        conflict.resolvedValue = chosenValue
        conflict.resolvedAt = Date()
        conflicts[index] = conflict
        
        // Add as manual metadata to prevent future conflicts
        addManualMetadata(
            docketNumber: conflict.docketNumber,
            fields: [conflict.fieldName: chosenValue]
        )
        
        CodeMindLogger.shared.log(.info, "Resolved metadata conflict", category: .general, metadata: [
            "docket": conflict.docketNumber,
            "field": conflict.fieldName,
            "value": chosenValue
        ])
    }
    
    // MARK: - Enrichment Suggestions
    
    /// Generate enrichment suggestions for a docket
    private func generateEnrichmentSuggestions(for docketNumber: String) {
        guard let sources = sourcesByDocket[docketNumber] else { return }
        
        // Get current metadata from manual/highest priority source
        let manualSource = sources.first { $0.sourceType == .manual }
        let currentFields = manualSource?.fields ?? [:]
        
        // Look for fields that exist in other sources but not in current
        var newSuggestions: [MetadataEnrichment] = []
        
        let importantFields = ["jobName", "client", "agency", "producer", "project"]
        
        for fieldName in importantFields {
            // Skip if we already have this field with high confidence
            if let current = currentFields[fieldName], current.confidence >= 0.9 {
                continue
            }
            
            // Find best value from other sources
            var bestValue: (String, MetadataSource.SourceType, Double)? = nil
            
            for source in sources where source.sourceType != .manual {
                if let field = source.fields[fieldName] {
                    if bestValue == nil || field.confidence > bestValue!.2 {
                        bestValue = (field.value, source.sourceType, field.confidence)
                    }
                }
            }
            
            if let (value, sourceType, confidence) = bestValue, confidence >= 0.6 {
                let currentValue = currentFields[fieldName]?.value
                
                // Only suggest if different from current
                if currentValue?.lowercased() != value.lowercased() {
                    let enrichment = MetadataEnrichment(
                        id: UUID(),
                        docketNumber: docketNumber,
                        fieldName: fieldName,
                        currentValue: currentValue,
                        suggestedValue: value,
                        source: sourceType,
                        confidence: confidence,
                        reasoning: "Found in \(sourceType.rawValue) with \(Int(confidence * 100))% confidence",
                        isApplied: false,
                        appliedAt: nil
                    )
                    
                    // Check if similar suggestion already exists
                    let existingSuggestion = enrichmentSuggestions.first {
                        $0.docketNumber == docketNumber &&
                        $0.fieldName == fieldName &&
                        $0.suggestedValue == value &&
                        !$0.isApplied
                    }
                    
                    if existingSuggestion == nil {
                        newSuggestions.append(enrichment)
                    }
                }
            }
        }
        
        enrichmentSuggestions.append(contentsOf: newSuggestions)
        
        if !newSuggestions.isEmpty {
            CodeMindLogger.shared.log(.debug, "Generated enrichment suggestions", category: .general, metadata: [
                "docket": docketNumber,
                "suggestionCount": "\(newSuggestions.count)"
            ])
        }
    }
    
    /// Apply an enrichment suggestion
    func applyEnrichment(enrichmentId: UUID) {
        guard let index = enrichmentSuggestions.firstIndex(where: { $0.id == enrichmentId }) else { return }
        
        var enrichment = enrichmentSuggestions[index]
        
        // Add as manual metadata
        addManualMetadata(
            docketNumber: enrichment.docketNumber,
            fields: [enrichment.fieldName: enrichment.suggestedValue]
        )
        
        enrichment.isApplied = true
        enrichment.appliedAt = Date()
        enrichmentSuggestions[index] = enrichment
        
        CodeMindLogger.shared.log(.info, "Applied enrichment suggestion", category: .general, metadata: [
            "docket": enrichment.docketNumber,
            "field": enrichment.fieldName,
            "value": enrichment.suggestedValue
        ])
    }
    
    /// Dismiss an enrichment suggestion
    func dismissEnrichment(enrichmentId: UUID) {
        enrichmentSuggestions.removeAll { $0.id == enrichmentId }
    }
    
    // MARK: - Queries
    
    /// Get all metadata for a docket (fused from all sources)
    func getFusedMetadata(for docketNumber: String) -> [String: String] {
        guard let sources = sourcesByDocket[docketNumber] else { return [:] }
        
        var fused: [String: (String, Double, Int)] = [:] // field -> (value, confidence, priority)
        
        // Sort by priority (highest first)
        let sortedSources = sources.sorted { $0.sourceType.priority > $1.sourceType.priority }
        
        for source in sortedSources {
            for (key, field) in source.fields {
                if let existing = fused[key] {
                    // Only replace if higher confidence AND higher priority
                    if source.sourceType.priority > existing.2 ||
                       (source.sourceType.priority == existing.2 && field.confidence > existing.1) {
                        fused[key] = (field.value, field.confidence, source.sourceType.priority)
                    }
                } else {
                    fused[key] = (field.value, field.confidence, source.sourceType.priority)
                }
            }
        }
        
        return fused.mapValues { $0.0 }
    }
    
    /// Get sources for a docket
    func getSources(for docketNumber: String) -> [MetadataSource] {
        return sourcesByDocket[docketNumber] ?? []
    }
    
    /// Get unresolved conflicts
    func getUnresolvedConflicts() -> [MetadataConflict] {
        return conflicts.filter { !$0.isResolved }
    }
    
    /// Get pending enrichment suggestions
    func getPendingSuggestions() -> [MetadataEnrichment] {
        return enrichmentSuggestions.filter { !$0.isApplied }
    }
    
    // MARK: - Analysis
    
    /// Run full metadata analysis
    func runAnalysis() async {
        isAnalyzing = true
        
        // Re-detect conflicts for all dockets
        for docketNumber in sourcesByDocket.keys {
            detectConflicts(for: docketNumber)
            generateEnrichmentSuggestions(for: docketNumber)
        }
        
        // Clean up old resolved conflicts (older than 7 days)
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        conflicts.removeAll { conflict in
            if conflict.isResolved, let resolvedAt = conflict.resolvedAt {
                return resolvedAt < cutoff
            }
            return false
        }
        
        // Clean up applied suggestions (older than 7 days)
        enrichmentSuggestions.removeAll { suggestion in
            if suggestion.isApplied, let appliedAt = suggestion.appliedAt {
                return appliedAt < cutoff
            }
            return false
        }
        
        lastAnalysisDate = Date()
        isAnalyzing = false
        
        CodeMindLogger.shared.log(.info, "Metadata analysis complete", category: .general, metadata: [
            "docketCount": "\(sourcesByDocket.count)",
            "conflicts": "\(getUnresolvedConflicts().count)",
            "suggestions": "\(getPendingSuggestions().count)"
        ])
    }
    
    // MARK: - State Management
    
    private func updatePublishedState() {
        metadataSources = sourcesByDocket.values.flatMap { $0 }
    }
    
    /// Clear all data
    func clearAll() {
        sourcesByDocket.removeAll()
        conflicts.removeAll()
        enrichmentSuggestions.removeAll()
        updatePublishedState()
    }
}

