import Foundation
import SwiftUI
import Combine

/// Navigation manager for opening CodeMind Brain view and navigating to specific thoughts
@MainActor
class CodeMindBrainNavigator: ObservableObject {
    static let shared = CodeMindBrainNavigator()
    
    /// Target to navigate to when brain view opens
    @Published var pendingNavigation: NavigationTarget?
    
    /// Whether the brain view should be shown
    @Published var shouldShowBrainView = false
    
    private init() {}
    
    enum NavigationTarget: Equatable {
        case classificationById(UUID)
        case classificationBySubject(String)
        case ruleById(UUID)
        case createRuleForEmail(subject: String, from: String?, classificationType: String?)
        
        static func == (lhs: NavigationTarget, rhs: NavigationTarget) -> Bool {
            switch (lhs, rhs) {
            case (.classificationById(let a), .classificationById(let b)):
                return a == b
            case (.classificationBySubject(let a), .classificationBySubject(let b)):
                return a == b
            case (.ruleById(let a), .ruleById(let b)):
                return a == b
            case (.createRuleForEmail(let s1, let f1, let t1), .createRuleForEmail(let s2, let f2, let t2)):
                return s1 == s2 && f1 == f2 && t1 == t2
            default:
                return false
            }
        }
    }
    
    /// Navigate to a specific classification by its ID
    func navigateToClassification(id: UUID) {
        pendingNavigation = .classificationById(id)
        openBrainView()
    }
    
    /// Navigate to a classification by email subject
    func navigateToClassification(subject: String) {
        pendingNavigation = .classificationBySubject(subject)
        openBrainView()
    }
    
    /// Navigate to a specific rule
    func navigateToRule(id: UUID) {
        pendingNavigation = .ruleById(id)
        openBrainView()
    }
    
    /// Open brain view to create a new rule based on an email
    func createRuleForEmail(subject: String, from: String?, classificationType: String?) {
        pendingNavigation = .createRuleForEmail(subject: subject, from: from, classificationType: classificationType)
        openBrainView()
    }
    
    /// Open the brain view (via debug window)
    func openBrainView() {
        shouldShowBrainView = true
        // Trigger the debug window manager to open
        CodeMindDebugWindowManager.shared.showDebugWindow()
    }
    
    /// Clear pending navigation after it's been handled
    func clearPendingNavigation() {
        pendingNavigation = nil
    }
}

// MARK: - Notification Context Menu Actions

/// Represents actions available from notification context menus
enum NotificationContextAction: String, CaseIterable {
    case viewInMindMap = "View in MindMap"
    case createRule = "Create Classification Rule"
    case markCorrect = "Mark as Correct"
    case markIncorrect = "Mark as Incorrect"
    
    var icon: String {
        switch self {
        case .viewInMindMap: return "brain"
        case .createRule: return "plus.circle"
        case .markCorrect: return "checkmark.circle"
        case .markIncorrect: return "xmark.circle"
        }
    }
}

/// Helper to generate context menu for notifications
struct NotificationContextMenuBuilder {
    
    /// Build context menu items for a classification notification
    @MainActor
    static func contextMenu(
        for subject: String,
        from: String?,
        classificationType: String?,
        classificationId: UUID?
    ) -> some View {
        Group {
            Button {
                if let id = classificationId {
                    CodeMindBrainNavigator.shared.navigateToClassification(id: id)
                } else {
                    CodeMindBrainNavigator.shared.navigateToClassification(subject: subject)
                }
            } label: {
                Label("View in MindMap", systemImage: "brain")
            }
            
            Button {
                CodeMindBrainNavigator.shared.createRuleForEmail(
                    subject: subject,
                    from: from,
                    classificationType: classificationType
                )
            } label: {
                Label("Create Rule from This", systemImage: "plus.circle")
            }
            
            Divider()
            
            Button {
                // Record positive feedback
                if let id = classificationId {
                    Task { @MainActor in
                        CodeMindClassificationHistory.shared.addFeedback(
                            recordId: id,
                            rating: 5,
                            wasCorrect: true,
                            correction: nil
                        )
                    }
                }
            } label: {
                Label("Mark as Correct", systemImage: "checkmark.circle")
            }
            
            Button {
                // Record negative feedback and open for correction
                if let id = classificationId {
                    Task { @MainActor in
                        CodeMindClassificationHistory.shared.addFeedback(
                            recordId: id,
                            rating: 1,
                            wasCorrect: false,
                            correction: nil
                        )
                    }
                }
                // Also open brain view to let them create a correcting rule
                CodeMindBrainNavigator.shared.createRuleForEmail(
                    subject: subject,
                    from: from,
                    classificationType: classificationType
                )
            } label: {
                Label("Mark as Incorrect", systemImage: "xmark.circle")
            }
        }
    }
}

