import Foundation
import Combine

// MARK: - Context Engine Models

/// Represents an email thread with related messages
struct EmailThread: Identifiable, Equatable {
    let id: String
    let subject: String
    var messages: [EmailThreadMessage]
    var docketNumber: String?
    var classificationType: ClassificationType?
    var lastUpdated: Date
    var confidence: Double
    
    enum ClassificationType: String, Codable {
        case newDocket = "New Docket"
        case fileDelivery = "File Delivery"
        case followUp = "Follow Up"
        case unknown = "Unknown"
    }
    
    static func == (lhs: EmailThread, rhs: EmailThread) -> Bool {
        lhs.id == rhs.id
    }
}

struct EmailThreadMessage: Identifiable, Equatable, Codable {
    let id: String
    let subject: String
    let from: String
    let date: Date
    let snippet: String?
    var isClassified: Bool
    var classificationResult: String?
}

/// Tracks docket lifecycle stages
struct DocketLifecycle: Identifiable, Equatable {
    let id: String
    let docketNumber: String
    let jobName: String?
    var stage: LifecycleStage
    var stageHistory: [StageTransition]
    var lastUpdated: Date
    var confidence: Double
    var relatedEmailIds: [String]
    var relatedFileIds: [String]
    
    enum LifecycleStage: String, Codable, CaseIterable {
        case announced = "Announced"        // New docket email received
        case created = "Created"            // Docket folder created
        case filesReceived = "Files Received" // File delivery received
        case inProgress = "In Progress"     // Work in progress
        case prepped = "Prepped"           // Prep completed
        case completed = "Completed"       // Fully done
        case archived = "Archived"         // Archived
        
        var color: String {
            switch self {
            case .announced: return "yellow"
            case .created: return "blue"
            case .filesReceived: return "cyan"
            case .inProgress: return "orange"
            case .prepped: return "purple"
            case .completed: return "green"
            case .archived: return "gray"
            }
        }
    }
    
    struct StageTransition: Codable, Equatable {
        let from: LifecycleStage?
        let to: LifecycleStage
        let timestamp: Date
        let trigger: String? // What caused the transition
    }
    
    static func == (lhs: DocketLifecycle, rhs: DocketLifecycle) -> Bool {
        lhs.id == rhs.id
    }
}

/// Tracks learned user preferences
struct UserPreference: Identifiable, Codable, Equatable {
    let id: UUID
    let category: PreferenceCategory
    let pattern: String
    let learnedValue: String
    var occurrences: Int
    var confidence: Double
    var lastSeen: Date
    
    enum PreferenceCategory: String, Codable, CaseIterable {
        case senderTreatment = "Sender Treatment"
        case subjectPattern = "Subject Pattern"
        case fileOrganization = "File Organization"
        case metadataDefault = "Metadata Default"
        case workflowPreference = "Workflow Preference"
    }
}

// MARK: - Context Engine

/// Background engine that understands email threads, docket lifecycles, and user preferences
@MainActor
class CodeMindContextEngine: ObservableObject {
    static let shared = CodeMindContextEngine()
    
    // Published state for BrainView
    @Published private(set) var emailThreads: [EmailThread] = []
    @Published private(set) var docketLifecycles: [DocketLifecycle] = []
    @Published private(set) var userPreferences: [UserPreference] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var lastAnalysisDate: Date?
    
    // Internal tracking
    private var threadMap: [String: EmailThread] = [:] // threadId -> thread
    private var docketMap: [String: DocketLifecycle] = [:] // docketNumber -> lifecycle
    private var preferenceStorage: URL
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let codeMindDir = appSupport.appendingPathComponent("CodeMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: codeMindDir, withIntermediateDirectories: true)
        self.preferenceStorage = codeMindDir.appendingPathComponent("user_preferences.json")
        
        loadPreferences()
    }
    
    // MARK: - Email Thread Tracking
    
    /// Track an email and update thread relationships
    func trackEmail(
        emailId: String,
        threadId: String?,
        subject: String,
        from: String,
        date: Date,
        snippet: String?,
        classificationResult: String?,
        docketNumber: String?
    ) {
        let effectiveThreadId = threadId ?? generateThreadId(subject: subject, from: from)
        
        let message = EmailThreadMessage(
            id: emailId,
            subject: subject,
            from: from,
            date: date,
            snippet: snippet,
            isClassified: classificationResult != nil,
            classificationResult: classificationResult
        )
        
        if var existingThread = threadMap[effectiveThreadId] {
            // Update existing thread
            if !existingThread.messages.contains(where: { $0.id == emailId }) {
                existingThread.messages.append(message)
                existingThread.messages.sort { $0.date < $1.date }
            }
            existingThread.lastUpdated = Date()
            
            // Update classification if we have new info
            if let result = classificationResult {
                if result.contains("docket") || result.contains("Docket") {
                    existingThread.classificationType = .newDocket
                } else if result.contains("file") || result.contains("File") {
                    existingThread.classificationType = .fileDelivery
                }
            }
            
            if let docket = docketNumber {
                existingThread.docketNumber = docket
            }
            
            threadMap[effectiveThreadId] = existingThread
        } else {
            // Create new thread
            var classificationType: EmailThread.ClassificationType = .unknown
            if let result = classificationResult {
                if result.contains("docket") || result.contains("Docket") {
                    classificationType = .newDocket
                } else if result.contains("file") || result.contains("File") {
                    classificationType = .fileDelivery
                }
            }
            
            let newThread = EmailThread(
                id: effectiveThreadId,
                subject: cleanSubjectForThread(subject),
                messages: [message],
                docketNumber: docketNumber,
                classificationType: classificationType,
                lastUpdated: Date(),
                confidence: 0.8
            )
            threadMap[effectiveThreadId] = newThread
        }
        
        // Update published state
        emailThreads = Array(threadMap.values).sorted { $0.lastUpdated > $1.lastUpdated }
        
        // If we have a docket, update lifecycle
        if let docket = docketNumber {
            updateDocketLifecycle(docketNumber: docket, trigger: "email_received", emailId: emailId)
        }
        
        CodeMindLogger.shared.log(.debug, "Tracked email in thread", category: .general, metadata: [
            "threadId": effectiveThreadId,
            "emailId": emailId,
            "threadSize": "\(threadMap[effectiveThreadId]?.messages.count ?? 0)"
        ])
    }
    
    /// Get related emails for a thread
    func getRelatedEmails(for emailId: String) -> [EmailThreadMessage] {
        for thread in threadMap.values {
            if thread.messages.contains(where: { $0.id == emailId }) {
                return thread.messages.filter { $0.id != emailId }
            }
        }
        return []
    }
    
    /// Get thread for an email
    func getThread(for emailId: String) -> EmailThread? {
        return threadMap.values.first { $0.messages.contains(where: { $0.id == emailId }) }
    }
    
    // MARK: - Docket Lifecycle Tracking
    
    /// Update docket lifecycle based on events
    func updateDocketLifecycle(
        docketNumber: String,
        jobName: String? = nil,
        trigger: String,
        emailId: String? = nil,
        fileId: String? = nil
    ) {
        if var existing = docketMap[docketNumber] {
            // Determine new stage based on trigger
            let newStage = determineStage(current: existing.stage, trigger: trigger)
            
            if newStage != existing.stage {
                let transition = DocketLifecycle.StageTransition(
                    from: existing.stage,
                    to: newStage,
                    timestamp: Date(),
                    trigger: trigger
                )
                existing.stageHistory.append(transition)
                existing.stage = newStage
            }
            
            if let email = emailId, !existing.relatedEmailIds.contains(email) {
                existing.relatedEmailIds.append(email)
            }
            if let file = fileId, !existing.relatedFileIds.contains(file) {
                existing.relatedFileIds.append(file)
            }
            
            existing.lastUpdated = Date()
            if let name = jobName, existing.jobName == nil {
                existing = DocketLifecycle(
                    id: existing.id,
                    docketNumber: existing.docketNumber,
                    jobName: name,
                    stage: existing.stage,
                    stageHistory: existing.stageHistory,
                    lastUpdated: existing.lastUpdated,
                    confidence: existing.confidence,
                    relatedEmailIds: existing.relatedEmailIds,
                    relatedFileIds: existing.relatedFileIds
                )
            }
            
            docketMap[docketNumber] = existing
        } else {
            // Create new lifecycle
            let initialStage = determineStage(current: nil, trigger: trigger)
            let lifecycle = DocketLifecycle(
                id: UUID().uuidString,
                docketNumber: docketNumber,
                jobName: jobName,
                stage: initialStage,
                stageHistory: [
                    DocketLifecycle.StageTransition(
                        from: nil,
                        to: initialStage,
                        timestamp: Date(),
                        trigger: trigger
                    )
                ],
                lastUpdated: Date(),
                confidence: 0.8,
                relatedEmailIds: emailId.map { [$0] } ?? [],
                relatedFileIds: fileId.map { [$0] } ?? []
            )
            docketMap[docketNumber] = lifecycle
        }
        
        // Update published state
        docketLifecycles = Array(docketMap.values).sorted { $0.lastUpdated > $1.lastUpdated }
        
        CodeMindLogger.shared.log(.debug, "Updated docket lifecycle", category: .general, metadata: [
            "docket": docketNumber,
            "stage": docketMap[docketNumber]?.stage.rawValue ?? "unknown",
            "trigger": trigger
        ])
    }
    
    /// Get lifecycle for a docket
    func getLifecycle(for docketNumber: String) -> DocketLifecycle? {
        return docketMap[docketNumber]
    }
    
    // MARK: - User Preference Learning
    
    /// Learn a user preference from an action
    func learnPreference(
        category: UserPreference.PreferenceCategory,
        pattern: String,
        value: String
    ) {
        let existingIndex = userPreferences.firstIndex {
            $0.category == category && $0.pattern == pattern
        }
        
        if let index = existingIndex {
            var pref = userPreferences[index]
            if pref.learnedValue == value {
                pref.occurrences += 1
                pref.confidence = min(1.0, pref.confidence + 0.05)
            } else {
                // User chose different value, reduce confidence
                pref.confidence = max(0.1, pref.confidence - 0.1)
            }
            pref.lastSeen = Date()
            userPreferences[index] = pref
        } else {
            let newPref = UserPreference(
                id: UUID(),
                category: category,
                pattern: pattern,
                learnedValue: value,
                occurrences: 1,
                confidence: 0.6,
                lastSeen: Date()
            )
            userPreferences.append(newPref)
        }
        
        savePreferences()
        
        CodeMindLogger.shared.log(.debug, "Learned preference", category: .general, metadata: [
            "category": category.rawValue,
            "pattern": pattern,
            "value": value
        ])
    }
    
    /// Get learned preference for a pattern
    func getPreference(category: UserPreference.PreferenceCategory, pattern: String) -> String? {
        let pref = userPreferences.first {
            $0.category == category && $0.pattern == pattern && $0.confidence >= 0.5
        }
        return pref?.learnedValue
    }
    
    /// Get all preferences with high confidence
    func getStrongPreferences() -> [UserPreference] {
        return userPreferences.filter { $0.confidence >= 0.7 }
    }
    
    // MARK: - Analysis
    
    /// Run full context analysis (called periodically or on demand)
    func runAnalysis() async {
        isAnalyzing = true
        
        // Clean up old threads (older than 30 days with no activity)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        threadMap = threadMap.filter { $0.value.lastUpdated > cutoffDate }
        
        // Update thread confidences based on classification history
        for (key, var thread) in threadMap {
            let classifiedCount = thread.messages.filter { $0.isClassified }.count
            let totalCount = thread.messages.count
            thread.confidence = totalCount > 0 ? Double(classifiedCount) / Double(totalCount) : 0.5
            threadMap[key] = thread
        }
        
        // Decay old preferences
        for i in userPreferences.indices {
            let daysSinceLastSeen = Calendar.current.dateComponents(
                [.day],
                from: userPreferences[i].lastSeen,
                to: Date()
            ).day ?? 0
            
            if daysSinceLastSeen > 30 {
                userPreferences[i].confidence = max(0.1, userPreferences[i].confidence - 0.1)
            }
        }
        
        // Remove very low confidence preferences
        userPreferences = userPreferences.filter { $0.confidence >= 0.2 }
        
        // Update published state
        emailThreads = Array(threadMap.values).sorted { $0.lastUpdated > $1.lastUpdated }
        docketLifecycles = Array(docketMap.values).sorted { $0.lastUpdated > $1.lastUpdated }
        
        lastAnalysisDate = Date()
        isAnalyzing = false
        
        savePreferences()
        
        CodeMindLogger.shared.log(.info, "Context analysis complete", category: .general, metadata: [
            "threads": "\(emailThreads.count)",
            "dockets": "\(docketLifecycles.count)",
            "preferences": "\(userPreferences.count)"
        ])
    }
    
    // MARK: - Helpers
    
    private func generateThreadId(subject: String, from: String) -> String {
        let cleanSubject = cleanSubjectForThread(subject)
        return "\(cleanSubject.hashValue)_\(from.hashValue)"
    }
    
    private func cleanSubjectForThread(_ subject: String) -> String {
        var clean = subject
        // Remove Re:, Fwd:, etc.
        let prefixes = ["Re:", "RE:", "Fwd:", "FWD:", "Fw:", "FW:"]
        for prefix in prefixes {
            while clean.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return clean
    }
    
    private func determineStage(current: DocketLifecycle.LifecycleStage?, trigger: String) -> DocketLifecycle.LifecycleStage {
        switch trigger {
        case "email_received", "new_docket_email":
            return current ?? .announced
        case "folder_created", "docket_created":
            return .created
        case "file_delivery", "files_received":
            return (current == .created || current == .announced) ? .filesReceived : (current ?? .filesReceived)
        case "work_started":
            return .inProgress
        case "prep_completed":
            return .prepped
        case "job_completed":
            return .completed
        case "archived":
            return .archived
        default:
            return current ?? .announced
        }
    }
    
    private func loadPreferences() {
        guard FileManager.default.fileExists(atPath: preferenceStorage.path) else { return }
        
        do {
            let data = try Data(contentsOf: preferenceStorage)
            userPreferences = try JSONDecoder().decode([UserPreference].self, from: data)
            CodeMindLogger.shared.log(.debug, "Loaded \(userPreferences.count) preferences", category: .general)
        } catch {
            CodeMindLogger.shared.log(.warning, "Failed to load preferences: \(error)", category: .general)
        }
    }
    
    private func savePreferences() {
        do {
            let data = try JSONEncoder().encode(userPreferences)
            try data.write(to: preferenceStorage)
        } catch {
            CodeMindLogger.shared.log(.warning, "Failed to save preferences: \(error)", category: .general)
        }
    }
}

