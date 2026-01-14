//
//  NotificationPopupWindowManager.swift
//  MediaDash
//
//  Created for separate notification popup window
//

import SwiftUI
import AppKit

@MainActor
class NotificationPopupWindowManager {
    static let shared = NotificationPopupWindowManager()
    
    private var popupWindow: NSWindow?
    private var dismissTask: Task<Void, Never>?
    
    private init() {}
    
    func showPopup(notification: Notification) {
        // Close any existing popup
        hidePopup()
        
        // Create popup window
        let popupView = NotificationPopupView(
            notification: notification,
            isVisible: .constant(true)
        )
        let popupController = NSHostingController(rootView: popupView)
        
        popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 80),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        guard let popupWindow = popupWindow else { return }
        
        popupWindow.contentViewController = popupController
        popupWindow.titlebarAppearsTransparent = true
        popupWindow.titleVisibility = .hidden
        popupWindow.backgroundColor = .clear
        popupWindow.isOpaque = false
        popupWindow.hasShadow = true
        popupWindow.level = .floating // Above all windows
        
        // Add faint border to popup window
        popupWindow.contentView?.wantsLayer = true
        popupWindow.contentView?.layer?.borderWidth = 0.5
        popupWindow.contentView?.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        popupWindow.collectionBehavior = [.moveToActiveSpace, .canJoinAllSpaces]
        popupWindow.isReleasedWhenClosed = false
        popupWindow.title = "Notification Popup"
        popupWindow.isMovable = false
        popupWindow.ignoresMouseEvents = true // Allow clicks to pass through
        
        // Position at top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - 370 // 350 width + 20 padding
            let y = screenFrame.maxY - 100 // 80 height + 20 padding
            popupWindow.setFrame(
                NSRect(x: x, y: y, width: 350, height: 80),
                display: true
            )
        }
        
        // Animate in
        popupWindow.alphaValue = 0
        popupWindow.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            popupWindow.animator().alphaValue = 1.0
        }
        
        // Auto-dismiss after 4 seconds
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            hidePopup()
        }
    }
    
    func hidePopup() {
        dismissTask?.cancel()
        dismissTask = nil
        
        guard let popupWindow = popupWindow else { return }
        
        // Capture window reference for closure
        let windowToClose = popupWindow
        self.popupWindow = nil
        
        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            windowToClose.animator().alphaValue = 0.0
        }) {
            windowToClose.close()
        }
    }
}

