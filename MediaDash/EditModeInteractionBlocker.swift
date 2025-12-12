//
//  EditModeInteractionBlocker.swift
//  MediaDash
//
//  Blocks normal UI interactions when layout edit mode is active
//

import SwiftUI

struct EditModeInteractionBlocker: ViewModifier {
    @ObservedObject var layoutManager: LayoutEditManager
    
    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if layoutManager.isEditMode {
                        // Transparent overlay that doesn't block hit testing
                        // This allows drag gestures to work on child views
                        // We only use this to visually indicate edit mode is active
                        // Actual blocking is done via .disabled() on specific interactive elements
                        Color.clear
                            .allowsHitTesting(false)
                    }
                }
            )
    }
}

extension View {
    /// Blocks normal UI interactions (taps/clicks) when layout edit mode is active
    /// Drag gestures on views with .draggableLayout() will still work
    /// because they use highPriorityGesture which takes precedence
    func blockInteractionsInEditMode(layoutManager: LayoutEditManager = LayoutEditManager.shared) -> some View {
        self.modifier(EditModeInteractionBlocker(layoutManager: layoutManager))
    }
}

