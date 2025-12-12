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
        // Verify this is our window closing
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === debugWindow else {
            return
        }
        isVisible = false
        // Don't nil out the window here - let showDebugWindow handle recreation
        // Setting debugWindow = nil here was causing issues with reopening
        debugWindow = nil
    }

    func showDebugWindow() {
        // If window exists and is visible, just bring to front
        if let window = debugWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            isVisible = true
            return
        }

        // If window exists but is not visible (was closed), we need to recreate it
        // because the contentViewController may have been released
        if debugWindow != nil {
            debugWindow = nil
        }

        // Create debug window
        let debugView = CodeMindDebugView()
        let debugWindowController = NSHostingController(rootView: debugView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentViewController = debugWindowController
        window.title = "CodeMind Debug"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        // Set minimum size to prevent window from being too small
        window.minSize = NSSize(width: 600, height: 400)

        // Ensure the window content size is set properly
        window.setContentSize(NSSize(width: 800, height: 600))

        // Center window on screen
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = window.frame
            let x = screenRect.midX - (windowRect.width / 2)
            let y = screenRect.midY - (windowRect.height / 2)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        debugWindow = window
        window.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hideDebugWindow() {
        debugWindow?.close()
        // isVisible will be set to false in windowWillClose
    }

    func toggleDebugWindow() {
        if isVisible, let window = debugWindow, window.isVisible {
            hideDebugWindow()
        } else {
            showDebugWindow()
        }
    }
}

