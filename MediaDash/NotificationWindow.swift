//
//  NotificationWindow.swift
//  MediaDash
//
//  Custom window class for notification center to ensure proper event handling
//

import AppKit

class NotificationWindow: NSWindow {
    override var canBecomeKey: Bool {
        // Allow becoming key when needed for full interactivity
        return true
    }
    
    override var canBecomeMain: Bool {
        // Never become main window - this prevents stealing focus from main window
        // The main window stays as the main window, but this can still be key for input
        return false
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    // Allow the window to receive mouse events even when not key
    override var acceptsMouseMovedEvents: Bool {
        get { return true }
        set { super.acceptsMouseMovedEvents = newValue }
    }
    
    // Track mouse enter/exit to automatically make window key for seamless interaction
    private var trackingArea: NSTrackingArea?
    
    override func awakeFromNib() {
        super.awakeFromNib()
        setupMouseTracking()
    }
    
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        setupMouseTracking()
    }
    
    private func setupMouseTracking() {
        // Remove existing tracking area if any
        if let trackingArea = trackingArea, let contentView = contentView {
            contentView.removeTrackingArea(trackingArea)
        }
        
        // Create tracking area to detect mouse entry
        guard let contentView = contentView else { return }
        let options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: contentView.bounds, options: options, owner: self, userInfo: nil)
        contentView.addTrackingArea(trackingArea!)
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Automatically make window key when mouse enters for seamless interaction
        // This allows buttons and controls to work immediately without requiring a click first
        // Use async dispatch with user-interactive QoS to avoid priority inversion warnings
        if !isKeyWindow {
            DispatchQueue.main.async(qos: .userInteractive) { [weak self] in
                self?.makeKey()
            }
        }
    }
    
    // Override to handle mouse events - window will already be key from mouseEntered
    override func sendEvent(_ event: NSEvent) {
        // Process all events normally
        // The window will be key from mouseEntered, so all controls will work seamlessly
        super.sendEvent(event)
    }
}
