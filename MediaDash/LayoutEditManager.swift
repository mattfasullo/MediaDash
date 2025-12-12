//
//  LayoutEditManager.swift
//  MediaDash
//
//  Created for visual layout editing
//

import SwiftUI
import AppKit
import Foundation
import Combine

// MARK: - Layout Configuration

struct LayoutConfig: Codable {
    var viewPositions: [String: CGPoint] = [:]
    var viewOffsets: [String: CGSize] = [:]
    var viewFrames: [String: CGRect] = [:]
    var spacings: [String: CGFloat] = [:]
    
    static let empty = LayoutConfig()
}

// MARK: - Layout Edit Manager

class LayoutEditManager: ObservableObject {
    static let shared = LayoutEditManager()
    
    @Published var isEditMode: Bool = false {
        didSet {
            if !isEditMode {
                // Don't auto-save - user must export to save changes
                // This allows experimentation without permanent changes
            }
        }
    }
    
    @Published var layoutConfig: LayoutConfig = LayoutConfig.empty
    @Published var selectedViewId: String? = nil
    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false
    
    private var undoStack: [LayoutConfig] = []
    private var redoStack: [LayoutConfig] = []
    private let maxHistorySize = 50
    
    private init() {
        // Don't load saved layout - start fresh each time
        // User must export to save changes
        layoutConfig = LayoutConfig.empty
        undoStack.append(layoutConfig)
    }
    
    // MARK: - Position Management
    
    func setPosition(_ position: CGPoint, for viewId: String) {
        layoutConfig.viewPositions[viewId] = position
    }
    
    func getPosition(for viewId: String) -> CGPoint? {
        return layoutConfig.viewPositions[viewId]
    }
    
    func setOffset(_ offset: CGSize, for viewId: String) {
        // Defer updates to avoid publishing during view updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Save state for undo before making changes
            self.saveStateForUndo()
            self.layoutConfig.viewOffsets[viewId] = offset
            self.updateUndoRedoState()
        }
    }
    
    func moveOffset(_ delta: CGSize, for viewId: String) {
        // Defer updates to avoid publishing during view updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Save state for undo before making changes
            self.saveStateForUndo()
            let currentOffset = self.layoutConfig.viewOffsets[viewId] ?? .zero
            self.layoutConfig.viewOffsets[viewId] = CGSize(
                width: currentOffset.width + delta.width,
                height: currentOffset.height + delta.height
            )
            self.updateUndoRedoState()
        }
    }
    
    func getOffset(for viewId: String) -> CGSize? {
        return layoutConfig.viewOffsets[viewId]
    }
    
    func setFrame(_ frame: CGRect, for viewId: String) {
        layoutConfig.viewFrames[viewId] = frame
    }
    
    func getFrame(for viewId: String) -> CGRect? {
        return layoutConfig.viewFrames[viewId]
    }
    
    // MARK: - Persistence (Export Only - No Auto-Save)
    
    func clearLayout() {
        layoutConfig = LayoutConfig.empty
        undoStack = [LayoutConfig.empty]
        redoStack.removeAll()
        updateUndoRedoState()
        print("✅ [LayoutEdit] Layout cleared - all offsets reset")
    }
    
    func resetAllOffsets() {
        // Reset all offsets to zero
        layoutConfig.viewOffsets.removeAll()
        undoStack = [LayoutConfig.empty]
        redoStack.removeAll()
        updateUndoRedoState()
        print("✅ [LayoutEdit] All offsets reset to zero")
    }
    
    // MARK: - Export
    
    func exportLayout(to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(layoutConfig)
            try data.write(to: url)
            print("✅ [LayoutEdit] Layout exported to \(url.path)")
            return true
        } catch {
            print("❌ [LayoutEdit] Failed to export layout: \(error)")
            return false
        }
    }
    
    func exportLayoutToDesktop() -> URL? {
        guard let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "mediadash_layout_\(formatter.string(from: Date())).json"
        let fileURL = desktopURL.appendingPathComponent(filename)
        
        if exportLayout(to: fileURL) {
            return fileURL
        }
        return nil
    }
    
    // MARK: - Undo/Redo
    
    private func saveStateForUndo() {
        // Only save if state actually changed
        if let last = undoStack.last, last.viewOffsets == layoutConfig.viewOffsets {
            return
        }
        
        undoStack.append(layoutConfig)
        if undoStack.count > maxHistorySize {
            undoStack.removeFirst()
        }
        // Clear redo stack when new action is performed
        redoStack.removeAll()
        updateUndoRedoState()
    }
    
    private func updateUndoRedoState() {
        canUndo = undoStack.count > 1
        canRedo = !redoStack.isEmpty
    }
    
    func undo() {
        guard undoStack.count > 1 else { return }
        
        // Move current state to redo stack
        redoStack.append(layoutConfig)
        if redoStack.count > maxHistorySize {
            redoStack.removeFirst()
        }
        
        // Restore previous state
        undoStack.removeLast()
        layoutConfig = undoStack.last ?? LayoutConfig.empty
        updateUndoRedoState()
    }
    
    func redo() {
        guard !redoStack.isEmpty else { return }
        
        // Save current state to undo stack
        undoStack.append(layoutConfig)
        if undoStack.count > maxHistorySize {
            undoStack.removeFirst()
        }
        
        // Restore from redo stack
        layoutConfig = redoStack.removeLast()
        updateUndoRedoState()
    }
    
    // MARK: - Toggle
    
    func toggleEditMode() {
        isEditMode.toggle()
        if isEditMode {
            // Reset undo/redo when entering edit mode
            undoStack = [layoutConfig]
            redoStack.removeAll()
            updateUndoRedoState()
        }
    }
}

// MARK: - Environment Key

struct LayoutEditManagerKey: EnvironmentKey {
    static let defaultValue = LayoutEditManager.shared
}

extension EnvironmentValues {
    var layoutEditManager: LayoutEditManager {
        get { self[LayoutEditManagerKey.self] }
        set { self[LayoutEditManagerKey.self] = newValue }
    }
}

