import Foundation
import Combine
import SwiftUI

/// Types of CodeMind activities that can be tracked
enum CodeMindActivity: Identifiable {
    case classifying(emailSubject: String)
    case classified(emailSubject: String, type: String, confidence: Double, verified: Bool, reasoning: String?)
    case verifying(docketNumber: String)
    case verified(docketNumber: String, source: String, found: Bool)
    case scanning(query: String)
    case scanComplete(count: Int)
    case learning(pattern: String)
    case anomalyDetected(description: String, severity: String)
    case error(message: String)
    case idle

    var id: UUID { UUID() }
    
    var icon: String {
        switch self {
        case .classifying: return "brain"
        case .classified: return "checkmark.circle.fill"
        case .verifying: return "magnifyingglass"
        case .verified: return "checkmark.seal.fill"
        case .scanning: return "envelope.badge"
        case .scanComplete: return "tray.full.fill"
        case .learning: return "lightbulb.fill"
        case .anomalyDetected: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .idle: return "circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .classifying: return .blue
        case .classified(_, _, let conf, _, _): return conf >= 0.8 ? .green : (conf >= 0.6 ? .yellow : .orange)
        case .verifying: return .purple
        case .verified(_, _, let found): return found ? .green : .orange
        case .scanning: return .blue
        case .scanComplete: return .green
        case .learning: return .yellow
        case .anomalyDetected(_, let severity): 
            return severity == "high" ? .red : (severity == "medium" ? .orange : .yellow)
        case .error: return .red
        case .idle: return .gray.opacity(0.5)
        }
    }
    
    var title: String {
        switch self {
        case .classifying: return "Classifying"
        case .classified: return "Classified"
        case .verifying: return "Verifying"
        case .verified: return "Verified"
        case .scanning: return "Scanning"
        case .scanComplete: return "Scan Complete"
        case .learning: return "Learning"
        case .anomalyDetected: return "Anomaly"
        case .error: return "Error"
        case .idle: return "Idle"
        }
    }
    
    var detail: String {
        switch self {
        case .classifying(let subject):
            return "'\(subject.prefix(40))...'"
        case .classified(let subject, let type, let conf, let verified, _):
            let confStr = String(format: "%.0f%%", conf * 100)
            let verifiedStr = verified ? " ✓" : ""
            return "\(type) • \(confStr)\(verifiedStr) • '\(subject.prefix(30))...'"
        case .verifying(let docket):
            return "Docket #\(docket)"
        case .verified(let docket, let source, let found):
            return found ? "#\(docket) found in \(source)" : "#\(docket) not found"
        case .scanning(let query):
            return query.prefix(50).description
        case .scanComplete(let count):
            return "\(count) email\(count == 1 ? "" : "s") processed"
        case .learning(let pattern):
            return "Pattern: \(pattern.prefix(40))"
        case .anomalyDetected(let desc, _):
            return desc.prefix(50).description
        case .error(let message):
            // Show full error message for server connection issues (up to 100 chars)
            if message.localizedCaseInsensitiveContains("server") || 
               message.localizedCaseInsensitiveContains("cannot access") ||
               message.localizedCaseInsensitiveContains("not connected") {
                return message.prefix(100).description
            }
            return message.prefix(50).description
        case .idle:
            return "Waiting for activity"
        }
    }
    
    var isActive: Bool {
        switch self {
        case .classifying, .verifying, .scanning: return true
        default: return false
        }
    }

    /// Returns the reasoning/explanation for classifications
    var reasoning: String? {
        switch self {
        case .classified(_, _, _, _, let reason):
            return reason
        default:
            return nil
        }
    }
}

/// Timestamped activity record
struct ActivityRecord: Identifiable {
    let id = UUID()
    let activity: CodeMindActivity
    let timestamp: Date
    var opacity: Double = 1.0
}

/// Detail level for the activity overlay
enum ActivityDetailLevel: String, CaseIterable, Codable {
    case minimal = "minimal"
    case medium = "medium"
    case detailed = "detailed"
    
    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .medium: return "Medium"
        case .detailed: return "Detailed"
        }
    }
    
    var description: String {
        switch self {
        case .minimal: return "Subtle pulses and indicators"
        case .medium: return "Brief activity summaries"
        case .detailed: return "Full activity stream"
        }
    }
}

/// Manages CodeMind activity tracking for the overlay
@MainActor
class CodeMindActivityManager: ObservableObject {
    static let shared = CodeMindActivityManager()
    
    @Published var isEnabled: Bool = false
    @Published var detailLevel: ActivityDetailLevel = .medium
    @Published var currentActivity: CodeMindActivity = .idle
    @Published var recentActivities: [ActivityRecord] = []
    @Published var isActive: Bool = false
    @Published var totalClassifications: Int = 0
    @Published var averageConfidence: Double = 0
    
    private let maxRecentActivities = 50
    private var confidenceSum: Double = 0
    private var classificationCount: Int = 0
    
    private init() {
        // Settings will be synced from AppSettings via syncWithSettings()
    }
    
    // MARK: - Settings
    
    /// Sync with AppSettings (call when settings change)
    func syncWithSettings(_ settings: AppSettings) {
        isEnabled = settings.codeMindOverlayEnabled
        if let level = ActivityDetailLevel(rawValue: settings.codeMindOverlayDetailLevel) {
            detailLevel = level
        }
    }
    
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }
    
    func setDetailLevel(_ level: ActivityDetailLevel) {
        detailLevel = level
    }
    
    /// Toggle the overlay on/off
    func toggle() {
        isEnabled.toggle()
    }
    
    // MARK: - Activity Recording
    
    func recordActivity(_ activity: CodeMindActivity) {
        currentActivity = activity
        isActive = activity.isActive
        
        let record = ActivityRecord(activity: activity, timestamp: Date())
        recentActivities.insert(record, at: 0)
        
        // Track classification stats
        if case .classified(_, _, let conf, _, _) = activity {
            totalClassifications += 1
            classificationCount += 1
            confidenceSum += conf
            averageConfidence = confidenceSum / Double(classificationCount)
        }
        
        // Trim old activities
        if recentActivities.count > maxRecentActivities {
            recentActivities = Array(recentActivities.prefix(maxRecentActivities))
        }
        
        // Auto-clear active state after a delay if idle
        if !activity.isActive {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                if !self.currentActivity.isActive {
                    self.isActive = false
                }
            }
        }
    }
    
    func clearActivities() {
        recentActivities = []
        currentActivity = .idle
        isActive = false
    }
    
    // MARK: - Convenience Methods
    
    func startClassifying(subject: String) {
        recordActivity(.classifying(emailSubject: subject))
    }
    
    func finishClassifying(subject: String, type: String, confidence: Double, verified: Bool, reasoning: String? = nil) {
        recordActivity(.classified(emailSubject: subject, type: type, confidence: confidence, verified: verified, reasoning: reasoning))
    }
    
    func startVerifying(docket: String) {
        recordActivity(.verifying(docketNumber: docket))
    }
    
    func finishVerifying(docket: String, source: String, found: Bool) {
        recordActivity(.verified(docketNumber: docket, source: source, found: found))
    }
    
    func startScanning(query: String) {
        recordActivity(.scanning(query: query))
    }
    
    func finishScanning(count: Int) {
        recordActivity(.scanComplete(count: count))
    }
    
    func recordLearning(pattern: String) {
        recordActivity(.learning(pattern: pattern))
    }
    
    func recordAnomaly(description: String, severity: String) {
        recordActivity(.anomalyDetected(description: description, severity: severity))
    }
    
    func recordError(message: String) {
        recordActivity(.error(message: message))
    }
}

