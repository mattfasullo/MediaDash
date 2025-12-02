import Foundation
import Combine

// MARK: - Session Analysis Models

/// Represents a detected ProTools or DAW session
struct DetectedSession: Identifiable, Equatable {
    let id: String
    let path: String
    let name: String
    let sessionType: SessionType
    var docketNumber: String?
    var linkedDocketNumber: String? // User-confirmed link
    var structure: SessionStructure?
    var completenessScore: Double
    var issues: [SessionIssue]
    var lastAnalyzed: Date
    
    enum SessionType: String, Codable, CaseIterable {
        case proTools = "Pro Tools"
        case omf = "OMF"
        case aaf = "AAF"
        case unknown = "Unknown"
        
        static func from(extension ext: String) -> SessionType {
            switch ext.lowercased() {
            case "ptx", "ptf", "pts":
                return .proTools
            case "omf":
                return .omf
            case "aaf":
                return .aaf
            default:
                return .unknown
            }
        }
    }
    
    struct SessionStructure: Codable, Equatable {
        var audioFileCount: Int
        var expectedAudioFiles: Int?
        var trackCount: Int?
        var duration: Double? // In seconds
        var sampleRate: Int?
        var bitDepth: Int?
        var hasVideo: Bool
        var containsStems: Bool
        var containsMix: Bool
    }
    
    struct SessionIssue: Identifiable, Codable, Equatable {
        let id: UUID
        let type: IssueType
        let description: String
        let severity: Severity
        var isResolved: Bool
        
        enum IssueType: String, Codable {
            case missingAudio = "Missing Audio"
            case brokenLinks = "Broken Links"
            case incompleteStems = "Incomplete Stems"
            case noMix = "No Mix Found"
            case corruptedSession = "Corrupted Session"
            case versionMismatch = "Version Mismatch"
        }
        
        enum Severity: String, Codable {
            case critical = "Critical"
            case warning = "Warning"
            case info = "Info"
        }
    }
    
    static func == (lhs: DetectedSession, rhs: DetectedSession) -> Bool {
        lhs.id == rhs.id
    }
}

/// Represents a suggestion to link a session to a docket
struct SessionLinkSuggestion: Identifiable, Equatable {
    let id: UUID
    let sessionId: String
    let sessionName: String
    let sessionPath: String
    let suggestedDocketNumber: String
    let suggestedJobName: String?
    let confidence: Double
    let reasoning: String
    var isApproved: Bool
    var isRejected: Bool
    var approvedAt: Date?
    
    static func == (lhs: SessionLinkSuggestion, rhs: SessionLinkSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Session Analyzer Engine

/// Background engine that analyzes ProTools sessions and suggests docket links
@MainActor
class CodeMindSessionAnalyzer: ObservableObject {
    static let shared = CodeMindSessionAnalyzer()
    
    // Published state for BrainView
    @Published private(set) var detectedSessions: [DetectedSession] = []
    @Published private(set) var linkSuggestions: [SessionLinkSuggestion] = []
    @Published private(set) var sessionsWithIssues: [DetectedSession] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var lastAnalysisDate: Date?
    
    // Internal tracking
    private var sessionMap: [String: DetectedSession] = [:] // path -> session
    
    // Session file extensions to detect
    private let sessionExtensions = ["ptx", "ptf", "pts", "omf", "aaf"]
    
    private init() {}
    
    // MARK: - Session Detection
    
    /// Scan a directory for sessions
    func scanDirectory(_ directoryPath: String, docketNumber: String? = nil) async -> [DetectedSession] {
        isAnalyzing = true
        
        var foundSessions: [DetectedSession] = []
        let fm = FileManager.default
        let directoryURL = URL(fileURLWithPath: directoryPath)
        
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            isAnalyzing = false
            return []
        }
        
        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            
            if sessionExtensions.contains(ext) {
                let session = await analyzeSession(at: fileURL.path, suggestedDocket: docketNumber)
                foundSessions.append(session)
                sessionMap[fileURL.path] = session
            }
        }
        
        updatePublishedState()
        isAnalyzing = false
        
        CodeMindLogger.shared.log(.info, "Directory scan complete", category: .general, metadata: [
            "path": directoryPath,
            "sessionsFound": "\(foundSessions.count)"
        ])
        
        return foundSessions
    }
    
    /// Analyze a specific session file
    func analyzeSession(at path: String, suggestedDocket: String? = nil) async -> DetectedSession {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let sessionType = DetectedSession.SessionType.from(extension: ext)
        
        let id = "\(path.hashValue)"
        
        // Analyze session structure
        let structure = await analyzeSessionStructure(at: path, type: sessionType)
        
        // Detect issues
        let issues = await detectSessionIssues(at: path, type: sessionType, structure: structure)
        
        // Calculate completeness score
        let completeness = calculateCompletenessScore(structure: structure, issues: issues)
        
        // Try to infer docket from path/name
        let inferredDocket = suggestedDocket ?? inferDocketFromPath(path)
        
        let session = DetectedSession(
            id: id,
            path: path,
            name: name,
            sessionType: sessionType,
            docketNumber: inferredDocket,
            linkedDocketNumber: nil,
            structure: structure,
            completenessScore: completeness,
            issues: issues,
            lastAnalyzed: Date()
        )
        
        sessionMap[path] = session
        
        // Generate link suggestion if we inferred a docket
        if let docket = inferredDocket {
            generateLinkSuggestion(for: session, docket: docket)
        }
        
        updatePublishedState()
        
        CodeMindLogger.shared.log(.debug, "Analyzed session", category: .general, metadata: [
            "name": name,
            "type": sessionType.rawValue,
            "completeness": String(format: "%.0f%%", completeness * 100),
            "issues": "\(issues.count)"
        ])
        
        return session
    }
    
    /// Track a session (when a session file is detected during file operations)
    func trackSession(path: String, docketNumber: String?) async {
        _ = await analyzeSession(at: path, suggestedDocket: docketNumber)
    }
    
    // MARK: - Session Analysis
    
    private func analyzeSessionStructure(at path: String, type: DetectedSession.SessionType) async -> DetectedSession.SessionStructure {
        let sessionDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fm = FileManager.default
        
        // Count audio files in session directory
        var audioFileCount = 0
        var hasVideo = false
        var containsStems = false
        var containsMix = false
        
        let audioExtensions = ["wav", "aif", "aiff", "mp3", "m4a"]
        let videoExtensions = ["mov", "mp4", "mxf", "avi"]
        
        if let contents = try? fm.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil) {
            for file in contents {
                let ext = file.pathExtension.lowercased()
                let name = file.lastPathComponent.lowercased()
                
                if audioExtensions.contains(ext) {
                    audioFileCount += 1
                    
                    // Check for stems
                    if name.contains("stem") || name.contains("_st_") {
                        containsStems = true
                    }
                    
                    // Check for mix
                    if name.contains("mix") || name.contains("_mx_") || name.contains("master") {
                        containsMix = true
                    }
                }
                
                if videoExtensions.contains(ext) {
                    hasVideo = true
                }
            }
        }
        
        // Check "Audio Files" subfolder (common in ProTools)
        let audioFilesDir = sessionDir.appendingPathComponent("Audio Files")
        if fm.fileExists(atPath: audioFilesDir.path) {
            if let contents = try? fm.contentsOfDirectory(at: audioFilesDir, includingPropertiesForKeys: nil) {
                for file in contents {
                    let ext = file.pathExtension.lowercased()
                    if audioExtensions.contains(ext) {
                        audioFileCount += 1
                    }
                }
            }
        }
        
        return DetectedSession.SessionStructure(
            audioFileCount: audioFileCount,
            expectedAudioFiles: nil, // Would need session parsing to determine
            trackCount: nil,
            duration: nil,
            sampleRate: nil,
            bitDepth: nil,
            hasVideo: hasVideo,
            containsStems: containsStems,
            containsMix: containsMix
        )
    }
    
    private func detectSessionIssues(
        at path: String,
        type: DetectedSession.SessionType,
        structure: DetectedSession.SessionStructure?
    ) async -> [DetectedSession.SessionIssue] {
        var issues: [DetectedSession.SessionIssue] = []
        let fm = FileManager.default
        
        // Check if session file exists and is readable
        guard fm.fileExists(atPath: path) else {
            issues.append(DetectedSession.SessionIssue(
                id: UUID(),
                type: .corruptedSession,
                description: "Session file not found",
                severity: .critical,
                isResolved: false
            ))
            return issues
        }
        
        // Check file size
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64,
           size < 1000 {
            issues.append(DetectedSession.SessionIssue(
                id: UUID(),
                type: .corruptedSession,
                description: "Session file appears to be corrupted (too small)",
                severity: .critical,
                isResolved: false
            ))
        }
        
        // Check for missing audio (if we have structure info)
        if let structure = structure {
            if structure.audioFileCount == 0 {
                issues.append(DetectedSession.SessionIssue(
                    id: UUID(),
                    type: .missingAudio,
                    description: "No audio files found in session directory",
                    severity: .warning,
                    isResolved: false
                ))
            }
            
            // Check for stems
            if !structure.containsStems {
                issues.append(DetectedSession.SessionIssue(
                    id: UUID(),
                    type: .incompleteStems,
                    description: "No stem files detected",
                    severity: .info,
                    isResolved: false
                ))
            }
            
            // Check for mix
            if !structure.containsMix {
                issues.append(DetectedSession.SessionIssue(
                    id: UUID(),
                    type: .noMix,
                    description: "No mix file detected",
                    severity: .info,
                    isResolved: false
                ))
            }
        }
        
        return issues
    }
    
    private func calculateCompletenessScore(
        structure: DetectedSession.SessionStructure?,
        issues: [DetectedSession.SessionIssue]
    ) -> Double {
        var score = 1.0
        
        // Deduct for issues
        for issue in issues {
            switch issue.severity {
            case .critical:
                score -= 0.4
            case .warning:
                score -= 0.2
            case .info:
                score -= 0.05
            }
        }
        
        // Bonus for having stems and mix
        if let structure = structure {
            if structure.containsStems {
                score += 0.1
            }
            if structure.containsMix {
                score += 0.1
            }
        }
        
        return max(0, min(1.0, score))
    }
    
    // MARK: - Docket Linking
    
    /// Infer docket number from file path
    private func inferDocketFromPath(_ path: String) -> String? {
        // Look for 5-digit patterns that could be docket numbers
        let patterns = [
            "\\b(\\d{5})\\b", // Plain 5-digit number
            "\\b(\\d{5})-?US\\b", // Docket with -US suffix
            "\\b(\\d{5})_", // Docket followed by underscore
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(path.startIndex..., in: path)
                if let match = regex.firstMatch(in: path, range: range),
                   let captureRange = Range(match.range(at: 1), in: path) {
                    return String(path[captureRange])
                }
            }
        }
        
        return nil
    }
    
    /// Infer job name from file path
    private func inferJobNameFromPath(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents
        
        // Look for folder name that might be job name (after docket folder)
        for (i, component) in components.enumerated() {
            // If this is a docket folder, next might be job name
            if let regex = try? NSRegularExpression(pattern: "^\\d{5}", options: []),
               regex.firstMatch(in: component, range: NSRange(component.startIndex..., in: component)) != nil {
                if i + 1 < components.count {
                    let next = components[i + 1]
                    // Skip common folder names
                    let skipNames = ["PREP", "WP", "Audio Files", "Video", "Bounces", "Session"]
                    if !skipNames.contains(where: { next.uppercased().contains($0.uppercased()) }) {
                        return next
                    }
                }
            }
        }
        
        return nil
    }
    
    /// Generate a link suggestion for a session
    private func generateLinkSuggestion(for session: DetectedSession, docket: String) {
        // Check if suggestion already exists
        let existing = linkSuggestions.first {
            $0.sessionId == session.id && $0.suggestedDocketNumber == docket && !$0.isApproved && !$0.isRejected
        }
        
        guard existing == nil else { return }
        
        let jobName = inferJobNameFromPath(session.path)
        
        let suggestion = SessionLinkSuggestion(
            id: UUID(),
            sessionId: session.id,
            sessionName: session.name,
            sessionPath: session.path,
            suggestedDocketNumber: docket,
            suggestedJobName: jobName,
            confidence: 0.75, // Base confidence for path-based inference
            reasoning: "Docket number \(docket) found in file path",
            isApproved: false,
            isRejected: false,
            approvedAt: nil
        )
        
        linkSuggestions.append(suggestion)
        
        CodeMindLogger.shared.log(.debug, "Generated link suggestion", category: .general, metadata: [
            "session": session.name,
            "docket": docket
        ])
    }
    
    /// Approve a link suggestion
    func approveLinkSuggestion(suggestionId: UUID) {
        guard let index = linkSuggestions.firstIndex(where: { $0.id == suggestionId }) else { return }
        
        var suggestion = linkSuggestions[index]
        suggestion.isApproved = true
        suggestion.approvedAt = Date()
        linkSuggestions[index] = suggestion
        
        // Update the session with the linked docket
        if var session = sessionMap.values.first(where: { $0.id == suggestion.sessionId }) {
            session.linkedDocketNumber = suggestion.suggestedDocketNumber
            sessionMap[session.path] = session
            updatePublishedState()
        }
        
        // Update docket lifecycle
        CodeMindContextEngine.shared.updateDocketLifecycle(
            docketNumber: suggestion.suggestedDocketNumber,
            jobName: suggestion.suggestedJobName,
            trigger: "session_linked"
        )
        
        CodeMindLogger.shared.log(.info, "Approved session link", category: .general, metadata: [
            "session": suggestion.sessionName,
            "docket": suggestion.suggestedDocketNumber
        ])
    }
    
    /// Reject a link suggestion
    func rejectLinkSuggestion(suggestionId: UUID) {
        guard let index = linkSuggestions.firstIndex(where: { $0.id == suggestionId }) else { return }
        
        var suggestion = linkSuggestions[index]
        suggestion.isRejected = true
        linkSuggestions[index] = suggestion
        
        CodeMindLogger.shared.log(.debug, "Rejected session link suggestion", category: .general, metadata: [
            "session": suggestion.sessionName,
            "docket": suggestion.suggestedDocketNumber
        ])
    }
    
    // MARK: - Queries
    
    /// Get sessions for a docket
    func getSessions(for docketNumber: String) -> [DetectedSession] {
        return detectedSessions.filter {
            $0.docketNumber == docketNumber || $0.linkedDocketNumber == docketNumber
        }
    }
    
    /// Get session by path
    func getSession(path: String) -> DetectedSession? {
        return sessionMap[path]
    }
    
    /// Get pending link suggestions
    func getPendingSuggestions() -> [SessionLinkSuggestion] {
        return linkSuggestions.filter { !$0.isApproved && !$0.isRejected }
    }
    
    /// Get sessions with critical issues
    func getSessionsWithCriticalIssues() -> [DetectedSession] {
        return detectedSessions.filter { session in
            session.issues.contains { $0.severity == .critical && !$0.isResolved }
        }
    }
    
    // MARK: - State Management
    
    private func updatePublishedState() {
        detectedSessions = Array(sessionMap.values).sorted { $0.lastAnalyzed > $1.lastAnalyzed }
        sessionsWithIssues = detectedSessions.filter { !$0.issues.isEmpty }
    }
    
    /// Clear all data
    func clearAll() {
        sessionMap.removeAll()
        linkSuggestions.removeAll()
        updatePublishedState()
    }
}

