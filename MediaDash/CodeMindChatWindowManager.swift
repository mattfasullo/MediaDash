//
//  CodeMindChatWindowManager.swift
//  MediaDash
//
//  Created for CodeMind chat as a core feature
//

import SwiftUI
import AppKit
import Combine

@MainActor
class CodeMindChatWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CodeMindChatWindowManager()
    
    @Published var isVisible = false
    private var chatWindow: NSWindow?
    
    private override init() {
        super.init()
    }
    
    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        chatWindow = nil
    }
    
    func showChatWindow() {
        guard !isVisible else {
            // Window already visible, bring to front
            chatWindow?.makeKeyAndOrderFront(nil)
            return
        }
        
        // Create chat view - it will try to access services from environment
        // If environment isn't available (standalone window), email tool won't work but chat will
        let chatView = CodeMindChatView()
        let chatWindowController = NSHostingController(rootView: chatView)
        
        // Try to inject environment objects from main window
        if let mainWindow = NSApplication.shared.windows.first(where: { $0.isMainWindow }),
           let _ = mainWindow.contentViewController as? NSHostingController<AnyView> {
            // Try to extract environment from main window's view hierarchy
            // This is tricky - for now, CodeMindChatView will use @EnvironmentObject
            // which should work if the window is created within the same view hierarchy
        }
        
        chatWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        guard let chatWindow = chatWindow else { return }
        
        chatWindow.contentViewController = chatWindowController
        chatWindow.title = "CodeMind"
        chatWindow.delegate = self
        chatWindow.isReleasedWhenClosed = false
        chatWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        chatWindow.minSize = NSSize(width: 500, height: 400)
        
        // Position window to the right of main window or center if no main window
        if let mainWindow = NSApplication.shared.windows.first(where: { $0.isMainWindow }),
           mainWindow.screen != nil {
            let mainFrame = mainWindow.frame
            let windowRect = chatWindow.frame
            let x = mainFrame.maxX + 20 // 20px gap from main window
            let y = mainFrame.maxY - windowRect.height // Align top
            chatWindow.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let mainScreen = NSScreen.main {
            // Center on screen if no main window
            let screenRect = mainScreen.visibleFrame
            let windowRect = chatWindow.frame
            let x = screenRect.midX - (windowRect.width / 2)
            let y = screenRect.midY - (windowRect.height / 2)
            chatWindow.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        chatWindow.makeKeyAndOrderFront(nil)
        isVisible = true
    }
    
    func hideChatWindow() {
        chatWindow?.close()
    }
    
    func toggleChatWindow() {
        if isVisible {
            hideChatWindow()
        } else {
            showChatWindow()
        }
    }
}

