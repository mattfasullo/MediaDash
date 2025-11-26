//
//  NotificationWindow.swift
//  MediaDash
//
//  Custom window class for notification center to ensure proper event handling
//

import AppKit

class NotificationWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
}

