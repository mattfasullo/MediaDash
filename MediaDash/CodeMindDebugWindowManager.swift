//
//  CodeMindDebugWindowManager.swift
//  MediaDash
//
//  Created for CodeMind debug window
//

import SwiftUI
import AppKit
import Combine

@MainActor
class CodeMindDebugWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CodeMindDebugWindowManager()
    
    @Published var isVisible = false
    private var debugWindow: NSWindow?
    
    private override init() {
        super.init()
    }
    
    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        debugWindow = nil
    }
    
    func showDebugWindow() {
        guard !isVisible else {
            // Window already visible, bring to front
            debugWindow?.makeKeyAndOrderFront(nil)
            return
        }
        
        // Create debug window
        let debugView = CodeMindDebugView()
        let debugWindowController = NSHostingController(rootView: debugView)
        
        debugWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        guard let debugWindow = debugWindow else { return }
        
        debugWindow.contentViewController = debugWindowController
        debugWindow.title = "CodeMind Debug"
        debugWindow.delegate = self
        debugWindow.isReleasedWhenClosed = false
        debugWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        
        // Set minimum size to prevent window from being too small
        debugWindow.minSize = NSSize(width: 600, height: 400)
        
        // Ensure the window content size is set properly
        debugWindow.setContentSize(NSSize(width: 800, height: 600))
        
        // Center window on screen
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = debugWindow.frame
            let x = screenRect.midX - (windowRect.width / 2)
            let y = screenRect.midY - (windowRect.height / 2)
            debugWindow.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        debugWindow.makeKeyAndOrderFront(nil)
        isVisible = true
    }
    
    func hideDebugWindow() {
        debugWindow?.close()
    }
    
    func toggleDebugWindow() {
        if isVisible {
            hideDebugWindow()
        } else {
            showDebugWindow()
        }
    }
}

