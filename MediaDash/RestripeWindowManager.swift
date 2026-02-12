//
//  RestripeWindowManager.swift
//  MediaDash
//
//  Opens the Restriping window in a separate, movable window.
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class RestripeWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RestripeWindowManager()
    
    @Published private(set) var isVisible = false
    private var restripeWindow: NSWindow?
    
    private override init() {
        super.init()
    }
    
    func show() {
        if let existingWindow = restripeWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isVisible = true
            return
        }
        
        let rootView = RestripeView()
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 650)
        
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Restriping"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
        
        restripeWindow = window
        isVisible = true
    }
    
    func close() {
        restripeWindow?.close()
    }
    
    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        restripeWindow = nil
    }
}
