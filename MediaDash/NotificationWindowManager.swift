//
//  NotificationWindowManager.swift
//  MediaDash
//
//  Created for separate notification center window
//

import SwiftUI
import AppKit
import Combine
import QuartzCore

@MainActor
class NotificationWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = NotificationWindowManager()
    
    @Published var isVisible = false
    @Published var isLocked: Bool = true // Whether window follows main window
    private var notificationWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var lockedPosition: NSPoint?
    private var isProgrammaticallyMoving = false
    private var isMainWindowDragging = false
    private var dragEndTimer: Timer?
    private var isAnimating = false
    private var mouseEventMonitor: Any?
    private var isMouseDownOnTitleBar = false
    
    private override init() {
        super.init()
        // Find main window
        findMainWindow()
        
        // Monitor window movements
        setupWindowMonitoring()
        
        // Monitor app activation to restore notification window
        setupAppActivationMonitoring()
    }
    
    private func setupAppActivationMonitoring() {
        // Monitor when app becomes active (after being minimized/restored)
        Foundation.NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // Restore notification window if it should be visible
                self.restoreNotificationWindowIfNeeded()
            }
            .store(in: &cancellables)
        
        // Monitor when main window becomes main again
        Foundation.NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let window = notification.object as? NSWindow,
                   window == self.mainWindow {
                    // Restore notification window if it should be visible
                    self.restoreNotificationWindowIfNeeded()
                }
            }
            .store(in: &cancellables)
    }
    
    private func restoreNotificationWindowIfNeeded() {
        guard isVisible, let notificationWindow = notificationWindow else { return }
        findMainWindow()
        guard let mainWindow = mainWindow else { return }
        
        // Small delay to ensure main window is fully restored
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Ensure window is visible
            if !notificationWindow.isVisible {
                notificationWindow.orderFront(nil)
            }
            
            // Re-order behind main window
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            
            // Update position in case main window moved
            if self.isLocked {
                self.updateNotificationWindowPositionSmoothly()
            }
            
            // Ensure alpha is correct (in case it got reset)
            if notificationWindow.alphaValue < 1.0 && !self.isAnimating {
                notificationWindow.alphaValue = 1.0
            }
        }
    }
    
    func setLocked(_ locked: Bool) {
        isLocked = locked
        updateWindowMovability()
        
        if locked {
            // Re-enable monitoring if it was disabled
            setupWindowMonitoring()
            // Update position to follow main window
            updateNotificationWindowPositionSmoothly()
            // Store locked position
            if let window = notificationWindow {
                lockedPosition = window.frame.origin
            }
        } else {
            // Cancel monitoring when unlocked
            cancellables.removeAll()
            lockedPosition = nil
            stopMouseEventMonitoring()
        }
    }
    
    private func startMouseEventMonitoring() {
        // Stop any existing monitor
        stopMouseEventMonitoring()
        
        // Monitor mouse events to detect title bar drag
        let manager = self
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            guard manager.isLocked else { return event }
            
            manager.findMainWindow()
            guard let mainWindow = manager.mainWindow,
                  let eventWindow = event.window,
                  eventWindow == mainWindow else { return event }
            
            // Get mouse location in window coordinates
            let mouseLocation = event.locationInWindow
            let windowHeight = mainWindow.frame.height
            
            // Check if mouse is in title bar area (top ~30 pixels of window)
            let titleBarHeight: CGFloat = 30
            let isInTitleBar = mouseLocation.y >= (windowHeight - titleBarHeight)
            
            if event.type == .leftMouseDown && isInTitleBar {
                // Mouse pressed down on title bar - hide notification center
                if !manager.isMouseDownOnTitleBar && manager.isVisible {
                    manager.isMouseDownOnTitleBar = true
                    manager.hideNotificationWindowDuringDrag()
                }
            } else if event.type == .leftMouseUp {
                // Mouse released - show notification center if it was hidden due to title bar drag
                if manager.isMouseDownOnTitleBar {
                    manager.isMouseDownOnTitleBar = false
                    // Show window - if hide animation is running, it will be interrupted
                    // Use a small delay to ensure any in-progress hide animation can be properly interrupted
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        // Only show if window still exists and is locked
                        if manager.isLocked, manager.notificationWindow != nil {
                            manager.showNotificationWindowAfterDrag()
                        }
                    }
                }
            }
            
            return event
        }
    }
    
    private func stopMouseEventMonitoring() {
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        isMouseDownOnTitleBar = false
    }
    
    private func updateWindowMovability() {
        guard let notificationWindow = notificationWindow else { return }
        // When locked, disable dragging (it will follow automatically)
        // When unlocked, enable dragging so user can position it independently
        notificationWindow.isMovable = !isLocked
        notificationWindow.isMovableByWindowBackground = !isLocked
    }
    
    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        notificationWindow = nil
        lockedPosition = nil
        dragEndTimer?.invalidate()
        dragEndTimer = nil
        stopMouseEventMonitoring()
    }
    
    private func findMainWindow() {
        // Find the main content window (not the notification window)
        mainWindow = NSApplication.shared.windows.first { window in
            window != notificationWindow && 
            window.isVisible && 
            window.title != "Notifications" &&
            window.frame.width >= 300 // Main window is at least 300px wide
        }
        
        // Fallback: just get the first visible window that's not notification window
        if mainWindow == nil {
            mainWindow = NSApplication.shared.windows.first { window in
                window != notificationWindow && window.isVisible
            }
        }
    }
    
    private func setupWindowMonitoring() {
        // Only monitor if window is locked
        guard isLocked else { return }
        
        // Start monitoring mouse events for title bar drag detection
        startMouseEventMonitoring()
        
        // Monitor main window movements for smooth following
        Foundation.NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)
            .sink { [weak self] (notification: Foundation.Notification) in
                guard let self = self, self.isLocked, !self.isAnimating else { return }
                if let window = notification.object as? NSWindow,
                   window == self.mainWindow {
                    self.updateNotificationWindowPositionSmoothly()
                }
            }
            .store(in: &cancellables)
        
        // Monitor when main window resizes
        Foundation.NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
            .sink { [weak self] (notification: Foundation.Notification) in
                guard let self = self, self.isLocked else { return }
                if let window = notification.object as? NSWindow,
                   window == self.mainWindow {
                    self.updateNotificationWindowPositionSmoothly()
                    // Update locked position
                    if let notifWindow = self.notificationWindow {
                        self.lockedPosition = notifWindow.frame.origin
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func hideNotificationWindowDuringDrag() {
        guard let notificationWindow = notificationWindow, isLocked, !isAnimating else { return }
        isAnimating = true
        
        findMainWindow()
        guard let mainWindow = mainWindow else {
            isAnimating = false
            return
        }
        
        // Calculate target position (shrink towards notification button tab)
        let mainFrame = mainWindow.frame
        
        // Position of notification button (in sidebar below logo)
        // Sidebar layout: Logo (60px) + padding (4px) + spacing (12px) + button
        // Top of window in screen coordinates (macOS uses bottom-left origin)
        let windowTop = mainFrame.minY + mainFrame.height
        let logoHeight: CGFloat = 60
        let logoBottomPadding: CGFloat = 4
        let vstackSpacing: CGFloat = 12
        let buttonHeight: CGFloat = 30 // Approximate button height
        // Button is in sidebar, centered horizontally in sidebar
        // Sidebar is 300px wide, button is full width minus padding (16px each side)
        let sidebarWidth: CGFloat = 300
        let sidebarPadding: CGFloat = 16
        // Button Y: below logo with spacing
        let buttonY = windowTop - logoHeight - logoBottomPadding - vstackSpacing - (buttonHeight / 2)
        
        // Shrink back to button's actual size
        let targetWidth: CGFloat = sidebarWidth - sidebarPadding * 2
        let targetHeight: CGFloat = buttonHeight
        
        let targetFrame = NSRect(
            x: mainFrame.minX + sidebarPadding, // Left edge of button
            y: buttonY - targetHeight / 2, // Center on button
            width: targetWidth,
            height: targetHeight
        )
        
        // Ensure window is behind main window before animation
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Animate genie effect: fade out and shrink
        let manager = self
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Keep window behind during animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            notificationWindow.animator().alphaValue = 0.0
            notificationWindow.animator().setFrame(targetFrame, display: true)
        }) {
            // Move behind main window after animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            Task { @MainActor in
                manager.isAnimating = false
            }
        }
    }
    
    private func showNotificationWindowAfterDrag() {
        guard let notificationWindow = notificationWindow, isLocked else { return }
        // Allow showing even if animating (to interrupt hide animation)
        isAnimating = true
        
        // Get target position (normal size)
        findMainWindow()
        guard let mainWindow = mainWindow else {
            isAnimating = false
            return
        }
        
        let mainFrame = mainWindow.frame
        let notificationWidth: CGFloat = 400
        let notificationHeight: CGFloat = 500
        let targetX = mainFrame.minX - notificationWidth - 10
        let targetY = mainFrame.midY - (notificationHeight / 2)
        
        let targetFrame = NSRect(
            x: targetX,
            y: targetY,
            width: notificationWidth,
            height: notificationHeight
        )
        
        // Start from notification button position (genie effect)
        // Position of notification button (in sidebar below logo)
        // Sidebar layout: Logo (60px) + padding (4px) + spacing (12px) + button
        // Top of window in screen coordinates (macOS uses bottom-left origin)
        let windowTop = mainFrame.minY + mainFrame.height
        let logoHeight: CGFloat = 60
        let logoBottomPadding: CGFloat = 4
        let vstackSpacing: CGFloat = 12
        let buttonHeight: CGFloat = 30 // Approximate button height
        // Button is in sidebar, centered horizontally in sidebar
        // Sidebar is 300px wide, button is full width minus padding (16px each side)
        let sidebarWidth: CGFloat = 300
        let sidebarPadding: CGFloat = 16
        // Button Y: below logo with spacing
        let buttonY = windowTop - logoHeight - logoBottomPadding - vstackSpacing - (buttonHeight / 2)
        
        // Start from button's actual size (full width of sidebar minus padding)
        let startWidth: CGFloat = sidebarWidth - sidebarPadding * 2
        let startHeight: CGFloat = buttonHeight
        
        let startFrame = NSRect(
            x: mainFrame.minX + sidebarPadding, // Left edge of button
            y: buttonY - startHeight / 2, // Center on button
            width: startWidth,
            height: startHeight
        )
        
        // Set initial state
        notificationWindow.setFrame(startFrame, display: false)
        notificationWindow.alphaValue = 0.0
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Small delay to ensure window is ready
        let manager = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Ensure window is behind main window before animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            
            // Animate genie effect: fade in and expand
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // Keep window behind during animation
                notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
                notificationWindow.animator().alphaValue = 1.0
                notificationWindow.animator().setFrame(targetFrame, display: true)
            }) {
                // Keep window behind main window after animation
                notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
                
                // Update locked position after animation
                Task { @MainActor in
                    manager.lockedPosition = targetFrame.origin
                    manager.isAnimating = false
                }
            }
        }
    }
    
    func showNotificationWindow(content: AnyView, isLocked: Bool? = nil) {
        // Check if any notification window already exists (in case of duplicates)
        let existingNotificationWindows = NSApplication.shared.windows.filter { window in
            window.title == "Notifications" || window.isKind(of: NotificationWindow.self)
        }
        
        // Close any duplicate notification windows
        for window in existingNotificationWindows {
            if window != notificationWindow {
                window.close()
            }
        }
        
        // If window already exists and is visible, just update content and return
        if let existingWindow = notificationWindow, existingWindow.isVisible, isVisible {
            // Update content if needed
            if let existingController = existingWindow.contentViewController as? NSHostingController<AnyView> {
                existingController.rootView = content
            }
            return
        }
        
        // If window exists but is not visible, close it first to prevent duplicates
        if let existingWindow = notificationWindow {
            existingWindow.close()
            notificationWindow = nil
            isVisible = false
        }
        
        guard !isVisible, !isAnimating else { return }
        
        // Set lock state if provided, otherwise use current state
        if let locked = isLocked {
            self.isLocked = locked
        }
        
        // Cancel any existing monitoring before setting up new one
        cancellables.removeAll()
        
        findMainWindow()
        guard let mainWindow = mainWindow else { return }
        
        // Create notification window
        let notificationWindowController = NSHostingController(rootView: content)
        notificationWindow = NotificationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        guard let notificationWindow = notificationWindow else { return }
        
        notificationWindow.contentViewController = notificationWindowController
        notificationWindow.titlebarAppearsTransparent = true
        notificationWindow.titleVisibility = .hidden
        notificationWindow.backgroundColor = .clear // Transparent background for rounded corners
        notificationWindow.isOpaque = false // Allow transparency for rounded corners
        notificationWindow.hasShadow = true
        notificationWindow.level = .normal
        notificationWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        notificationWindow.isReleasedWhenClosed = false
        notificationWindow.title = "Notifications"
        notificationWindow.acceptsMouseMovedEvents = true
        notificationWindow.ignoresMouseEvents = false
        notificationWindow.delegate = self
        
        // Configure content view for proper rounded corners
        if let contentView = notificationWindow.contentView {
            contentView.wantsLayer = true
            contentView.layer?.masksToBounds = true
            contentView.layer?.cornerRadius = 12
        }
        
        // Set movability based on lock state
        updateWindowMovability()
        
        // Configure window appearance
        notificationWindow.standardWindowButton(.closeButton)?.isHidden = true
        notificationWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        notificationWindow.standardWindowButton(.zoomButton)?.isHidden = true
        
        // Make it appear as a separate window
        notificationWindow.styleMask = [.borderless, .fullSizeContentView]
        
        // Setup window monitoring based on lock state
        setupWindowMonitoring()
        
        // Calculate target position (normal size)
        let mainFrame = mainWindow.frame
        let notificationWidth: CGFloat = 400
        let notificationHeight: CGFloat = 500
        let targetX = mainFrame.minX - notificationWidth - 10
        let targetY = mainFrame.midY - (notificationHeight / 2)
        
        let targetFrame = NSRect(
            x: targetX,
            y: targetY,
            width: notificationWidth,
            height: notificationHeight
        )
        
        // Calculate start position (notification button position - genie effect)
        // Position of notification button (in sidebar below logo)
        // Sidebar layout: Logo (60px) + padding (4px) + spacing (12px) + button
        // Top of window in screen coordinates (macOS uses bottom-left origin)
        let windowTop = mainFrame.minY + mainFrame.height
        let logoHeight: CGFloat = 60
        let logoBottomPadding: CGFloat = 4
        let vstackSpacing: CGFloat = 12
        let buttonHeight: CGFloat = 30 // Approximate button height
        // Button is in sidebar, centered horizontally in sidebar
        // Sidebar is 300px wide, button is full width minus padding (16px each side)
        let sidebarWidth: CGFloat = 300
        let sidebarPadding: CGFloat = 16
        // Button Y: below logo with spacing
        let buttonY = windowTop - logoHeight - logoBottomPadding - vstackSpacing - (buttonHeight / 2)
        
        // Start from button's actual size (full width of sidebar minus padding)
        let startWidth: CGFloat = sidebarWidth - sidebarPadding * 2
        let startHeight: CGFloat = buttonHeight
        
        let startFrame = NSRect(
            x: mainFrame.minX + sidebarPadding, // Left edge of button
            y: buttonY - startHeight / 2, // Center on button
            width: startWidth,
            height: startHeight
        )
        
        // Set initial state (button size, invisible, behind main window)
        notificationWindow.setFrame(startFrame, display: false)
        notificationWindow.alphaValue = 0.0
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Set initial locked position if locked
        if self.isLocked {
            lockedPosition = targetFrame.origin
        }
        
        isAnimating = true
        isVisible = true
        
        // Small delay to ensure window is ready
        let manager = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Ensure window is behind main window before animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            
            // Animate flying out effect: fade in, expand and move from button position to final position
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // Keep window behind during animation
                notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
                notificationWindow.animator().alphaValue = 1.0
                notificationWindow.animator().setFrame(targetFrame, display: true)
            }) {
                // Keep window behind main window after animation
                notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Ensure the view can become first responder
        DispatchQueue.main.async {
            notificationWindow.makeFirstResponder(notificationWindowController.view)
        }
        
                Task { @MainActor in
                    manager.isAnimating = false
                }
            }
        }
    }
    
    func hideNotificationWindow() {
        // Ensure we're not already hiding
        guard isVisible else { return }
        
        guard let notificationWindow = notificationWindow, !isAnimating else {
            // If window reference is lost but isVisible is true, reset state
            isVisible = false
            self.notificationWindow = nil
            return
        }
        isAnimating = true
        
        findMainWindow()
        guard let mainWindow = mainWindow else {
            notificationWindow.close()
            self.notificationWindow = nil
        isVisible = false
            isAnimating = false
            return
        }
        
        // Calculate target position (shrink towards notification button)
        let mainFrame = mainWindow.frame
        let logoHeight: CGFloat = 60
        let logoBottomPadding: CGFloat = 4
        let vstackSpacing: CGFloat = 12
        let workspaceLabelHeight: CGFloat = 30
        let workspaceLabelVerticalPadding: CGFloat = 6
        
        // Top of window in screen coordinates
        let windowTop = mainFrame.minY + mainFrame.height
        
        // Position of notification button
        let buttonX = mainFrame.minX + 25
        let buttonY = windowTop - logoHeight - logoBottomPadding - vstackSpacing - workspaceLabelVerticalPadding - (workspaceLabelHeight / 2)
        
        let targetWidth: CGFloat = 12
        let targetHeight: CGFloat = 12
        
        let targetFrame = NSRect(
            x: buttonX - targetWidth / 2,
            y: buttonY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
        
        // Ensure window is behind main window before animation
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Animate genie effect: fade out and shrink
        let manager = self
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Keep window behind during animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            notificationWindow.animator().alphaValue = 0.0
            notificationWindow.animator().setFrame(targetFrame, display: true)
        }) {
            // Move behind main window and close
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            notificationWindow.close()
            
            Task { @MainActor in
                manager.notificationWindow = nil
                manager.isVisible = false
                manager.isAnimating = false
            }
        }
    }
    
    func toggleNotificationWindow(content: AnyView) {
        if isVisible {
            hideNotificationWindow()
        } else {
            showNotificationWindow(content: content)
        }
    }
    
    private func updateNotificationWindowPosition() {
        guard let notificationWindow = notificationWindow else { return }
        
        // Re-find main window in case it changed
        findMainWindow()
        guard let mainWindow = mainWindow else { return }
        
        let mainFrame = mainWindow.frame
        let notificationFrame = notificationWindow.frame
        let notificationWidth = notificationFrame.width
        let notificationHeight = notificationFrame.height
        
        // Position to the left of main window, vertically centered
        let x = mainFrame.minX - notificationWidth - 10
        let y = mainFrame.midY - (notificationHeight / 2)
        
        // Only update position, keep current size
        notificationWindow.setFrame(
            NSRect(x: x, y: y, width: notificationWidth, height: notificationHeight),
            display: true
        )
    }
    
    private func updateNotificationWindowPositionSmoothly() {
        guard let notificationWindow = notificationWindow, isLocked, !isAnimating else { return }
        
        // Re-find main window in case it changed
        findMainWindow()
        guard let mainWindow = mainWindow else { return }
        
        let mainFrame = mainWindow.frame
        let notificationFrame = notificationWindow.frame
        let notificationWidth = notificationFrame.width
        
        // Position to the left of main window, vertically centered
        let x = mainFrame.minX - notificationWidth - 10 // 10px gap
        let y = mainFrame.midY - (notificationFrame.height / 2)
        
        // Use setFrameOrigin for more efficient updates (only moves origin, not full frame)
        // This is faster and smoother than setFrame
        let newOrigin = NSPoint(x: x, y: y)
        
        // Mark as programmatic move to avoid triggering drag detection
        isProgrammaticallyMoving = true
        notificationWindow.setFrameOrigin(newOrigin)
        // Update locked position
        lockedPosition = newOrigin
        
        // Reset flag after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.isProgrammaticallyMoving = false
        }
    }
    
    func refreshMainWindow() {
        findMainWindow()
        updateNotificationWindowPosition()
    }
}

