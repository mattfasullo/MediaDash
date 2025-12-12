//
//  DraggableLayoutModifier.swift
//  MediaDash
//
//  Created for visual layout editing
//

import SwiftUI

// MARK: - Draggable Layout Modifier

struct DraggableLayoutModifier: ViewModifier {
    let viewId: String
    @ObservedObject var layoutManager: LayoutEditManager
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    
    func body(content: Content) -> some View {
        let currentOffset = layoutManager.getOffset(for: viewId) ?? .zero
        let totalOffset = CGSize(
            width: currentOffset.width + dragOffset.width,
            height: currentOffset.height + dragOffset.height
        )
        
        return content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: ViewSizeKey.self, value: geometry.size)
                }
            )
            .overlay(
                Group {
                    if layoutManager.isEditMode {
                        EditModeOverlay(
                            viewId: viewId,
                            isSelected: layoutManager.selectedViewId == viewId
                        )
                    }
                }
            )
            .offset(
                x: totalOffset.width,
                y: totalOffset.height
            )
            .modifier(
                ConditionalDragGestureModifier(
                    isEditMode: layoutManager.isEditMode,
                    viewId: viewId,
                    layoutManager: layoutManager,
                    dragOffset: $dragOffset,
                    isDragging: $isDragging
                )
            )
    }
}

// MARK: - Edit Mode Overlay

struct EditModeOverlay: View {
    let viewId: String
    let isSelected: Bool
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Very transparent outline - only visible when selected
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    
                    // Very small, transparent corner indicators
                    ForEach(0..<4) { index in
                        let positions: [(CGFloat, CGFloat)] = [
                            (0, 0),                    // Top-left
                            (geometry.size.width, 0),  // Top-right
                            (0, geometry.size.height), // Bottom-left
                            (geometry.size.width, geometry.size.height) // Bottom-right
                        ]
                        
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 6, height: 6)
                            .position(x: positions[index].0, y: positions[index].1)
                    }
                    
                    // Very transparent center indicator
                    Circle()
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 12, height: 12)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    
                    // Small, transparent view ID label
                    Text(viewId)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.blue.opacity(0.4))
                        .padding(3)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(3)
                        .position(x: geometry.size.width / 2, y: -12)
                } else {
                    // Even more transparent for non-selected views
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.blue.opacity(0.05), lineWidth: 0.5)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Preference Key

struct ViewSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - Conditional Drag Gesture Modifier

struct ConditionalDragGestureModifier: ViewModifier {
    let isEditMode: Bool
    let viewId: String
    let layoutManager: LayoutEditManager
    @Binding var dragOffset: CGSize
    @Binding var isDragging: Bool
    
    func body(content: Content) -> some View {
        if isEditMode {
            content
                .onTapGesture {
                    layoutManager.selectedViewId = viewId
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            dragOffset = value.translation
                            layoutManager.selectedViewId = viewId
                        }
                        .onEnded { value in
                            // Update the stored offset - defer to avoid publishing during view updates
                            let currentOffset = layoutManager.getOffset(for: viewId) ?? .zero
                            let newOffset = CGSize(
                                width: currentOffset.width + value.translation.width,
                                height: currentOffset.height + value.translation.height
                            )
                            // setOffset already defers internally, so we can call it directly
                            layoutManager.setOffset(newOffset, for: viewId)
                            dragOffset = .zero
                            isDragging = false
                        }
                )
        } else {
            content
        }
    }
}

// MARK: - View Extension

extension View {
    /// Makes a view draggable in layout edit mode
    /// - Parameter viewId: Unique identifier for this view
    /// - Parameter layoutManager: The layout edit manager (optional, uses shared instance by default)
    func draggableLayout(
        id viewId: String,
        layoutManager: LayoutEditManager = LayoutEditManager.shared
    ) -> some View {
        self.modifier(DraggableLayoutModifier(viewId: viewId, layoutManager: layoutManager))
    }
}

