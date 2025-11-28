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
import CoreVideo

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
    private var isAnimating = false
    private var currentAnimationContext: NSAnimationContext?
    private var positionUpdateTimer: Timer?
    private var lastMainWindowFrame: NSRect?
    private var isMainWindowDelegate = false
    private var lastUpdateTime: CFTimeInterval = 0
    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
    private var displayLink: CVDisplayLink?
    private var lastAnimationStartTime: CFTimeInterval = 0
    private var pendingTargetOrigin: NSPoint?
    
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
            stopContinuousPositionMonitoring()
            
            // Remove delegate from main window
            if let mainWindow = mainWindow, isMainWindowDelegate {
                mainWindow.delegate = nil
                isMainWindowDelegate = false
            }
            
            lockedPosition = nil
            lastMainWindowFrame = nil
        }
    }
            
    // Mouse event monitoring removed - no longer needed for hide/show during drag
    // The notification window now follows with elastic animation instead
    
    private func updateWindowMovability() {
        guard let notificationWindow = notificationWindow else { return }
        // When locked, disable dragging (it will follow automatically)
        // When unlocked, enable dragging so user can position it independently
        notificationWindow.isMovable = !isLocked
        notificationWindow.isMovableByWindowBackground = !isLocked
    }
    
    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        stopContinuousPositionMonitoring()
        
        // Remove delegate from main window
        if let mainWindow = mainWindow, isMainWindowDelegate {
            mainWindow.delegate = nil
            isMainWindowDelegate = false
        }
        
        notificationWindow = nil
        lockedPosition = nil
        lastMainWindowFrame = nil
    }
    
    // MARK: - NSWindowDelegate Methods (for main window)
    
    func windowDidMove(_ notification: Foundation.Notification) {
        // Direct position update for smooth, responsive following
        guard isLocked, let window = notification.object as? NSWindow,
              window == mainWindow else { return }
        updateNotificationWindowPositionDirectly()
    }
    
    func windowDidResize(_ notification: Foundation.Notification) {
        // Direct position update when main window resizes
        guard isLocked, let window = notification.object as? NSWindow,
              window == mainWindow else { return }
        updateNotificationWindowPositionDirectly()
    }
    
    private func findMainWindow() {
        // Find the main content window (not the notification window)
        let allWindows = NSApplication.shared.windows
        print("🔍 NotificationWindowManager: Finding main window from \(allWindows.count) windows")
        for window in allWindows {
            print("   Window: '\(window.title)' - visible: \(window.isVisible), width: \(window.frame.width), isNotification: \(window == notificationWindow)")
        }
        
        let newMainWindow = allWindows.first { window in
            window != notificationWindow && 
            window.isVisible && 
            window.title != "Notifications" &&
            window.frame.width >= 300 // Main window is at least 300px wide
        } ?? allWindows.first { window in
            window != notificationWindow && window.isVisible
        }
        
        // If main window changed, update delegate
        if newMainWindow != mainWindow {
            print("🔄 NotificationWindowManager: Main window changed")
            // Remove delegate from old main window
            if let oldMainWindow = mainWindow, isMainWindowDelegate {
                print("   Removing delegate from old main window: \(oldMainWindow.title)")
                oldMainWindow.delegate = nil
                isMainWindowDelegate = false
            }
            
            // Set new main window and add as delegate
            mainWindow = newMainWindow
            if let mainWindow = mainWindow, isLocked {
                print("   Setting delegate for new main window: \(mainWindow.title)")
                mainWindow.delegate = self
                isMainWindowDelegate = true
                lastMainWindowFrame = mainWindow.frame
            } else {
                print("   ⚠️ New main window found but not setting delegate - isLocked: \(isLocked)")
            }
        } else if newMainWindow != nil {
            print("   ✅ Main window unchanged: \(newMainWindow!.title)")
        } else {
            print("   ❌ No main window found!")
        }
    }
    
    private func setupWindowMonitoring() {
        // Only monitor if window is locked
        guard isLocked else {
            print("🔒 NotificationWindowManager: Monitoring not set up - window is unlocked")
            return
        }
        
        print("🔒 NotificationWindowManager: Setting up window monitoring...")
        
        // Set up main window as delegate for direct frame tracking
        findMainWindow()
        if let mainWindow = mainWindow {
            print("✅ NotificationWindowManager: Found main window: \(mainWindow.title) at \(mainWindow.frame)")
            mainWindow.delegate = self
            isMainWindowDelegate = true
            lastMainWindowFrame = mainWindow.frame
            lastUpdateTime = CACurrentMediaTime()
            velocityX = 0
            velocityY = 0
            print("✅ NotificationWindowManager: Set as delegate for main window")
        } else {
            print("❌ NotificationWindowManager: Could not find main window!")
        }
        
        // Use event-driven updates (window move/resize) for smooth, efficient following
        // This avoids the overhead of continuous polling and eliminates choppiness
        setupEventBasedMonitoring()
        
        // Also set up notification-based monitoring as backup
        setupNotificationBasedMonitoring()
    }
    
    private func setupEventBasedMonitoring() {
        // Stop any continuous monitoring
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
        stopDisplayLink()
        
        // Use a high-frequency timer during window movements for smooth following
        // This provides smooth updates without the overhead of display link
        startSmoothPositionMonitoring()
    }
    
    private func startSmoothPositionMonitoring() {
        // Use a timer that runs at 60Hz for smooth following during drags
        // This is more efficient than display link but still provides smooth motion
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [self] in
                guard self.isLocked else { return }
                self.updateNotificationWindowPositionDirectly()
            }
        }
        RunLoop.main.add(positionUpdateTimer!, forMode: .common)
    }
    
    private func updateNotificationWindowPositionDirectly() {
        guard let mainWindow = mainWindow, let notificationWindow = notificationWindow, isLocked else { return }
        
        let mainFrame = mainWindow.frame
        let notificationFrame = notificationWindow.frame
        let notificationWidth = notificationFrame.width
        let targetX = mainFrame.minX - notificationWidth - 10
        let targetY = mainFrame.midY - (notificationFrame.height / 2)
        let targetOrigin = NSPoint(x: targetX, y: targetY)
        
        // Direct update - no animation for smooth, responsive following
        isProgrammaticallyMoving = true
        notificationWindow.setFrameOrigin(targetOrigin)
        lockedPosition = targetOrigin
        isProgrammaticallyMoving = false
    }
    
    private func setupNotificationBasedMonitoring() {
        // Set up notification-based monitoring as a backup/complement to delegate methods
        // This ensures we catch all window movements
        Foundation.NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)
            .sink { [weak self] notification in
                guard let self = self, let window = notification.object as? NSWindow,
                      window == self.mainWindow, self.isLocked else { return }
                self.updateNotificationWindowPositionDirectly()
            }
            .store(in: &cancellables)
        
        Foundation.NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
            .sink { [weak self] notification in
                guard let self = self, let window = notification.object as? NSWindow,
                      window == self.mainWindow, self.isLocked else { return }
                self.updateNotificationWindowPositionDirectly()
            }
            .store(in: &cancellables)
    }
    
    private func setupDisplayLink() {
        // Create display link callback
        let displayLinkCallback: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, context) -> CVReturn in
            guard let context = context else { return kCVReturnError }
            let manager = Unmanaged<NotificationWindowManager>.fromOpaque(context).takeUnretainedValue()
            
            DispatchQueue.main.async {
                manager.updatePositionFromDisplayLink()
            }
            
            return kCVReturnSuccess
        }
        
        // Create display link
        var displayLink: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        
        guard result == kCVReturnSuccess, let link = displayLink else {
            debugLog("Display link creation failed, falling back to timer")
            // Fallback to timer if display link fails
            fallbackToTimer()
            return
        }
        
        // Set callback
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, displayLinkCallback, context)
        
        // Start display link
        let startResult = CVDisplayLinkStart(link)
        if startResult == kCVReturnSuccess {
            self.displayLink = link
            debugLog("Display link started successfully")
        } else {
            debugLog("Display link start failed, falling back to timer")
            fallbackToTimer()
        }
    }
    
    private func stopDisplayLink() {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
            self.displayLink = nil
        }
    }
    
    private func fallbackToTimer() {
        // Fallback to high-frequency timer if display link isn't available
        positionUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [self] in
                self.updatePositionFromDisplayLink()
            }
        }
        RunLoop.main.add(positionUpdateTimer!, forMode: .common)
    }
    
    private func updatePositionFromDisplayLink() {
        guard isLocked else {
            if Int.random(in: 0..<120) == 0 {
                debugLog("updatePositionFromDisplayLink: not locked")
            }
            return
        }
        guard let mainWindow = mainWindow, let notificationWindow = notificationWindow else {
            if Int.random(in: 0..<120) == 0 {
                debugLog("updatePositionFromDisplayLink: missing windows - main: \(mainWindow != nil), notification: \(notificationWindow != nil)")
            }
                    return
                }
                
                // Get current main window frame directly (most reliable)
                let currentMainFrame = mainWindow.frame
                let currentTime = CACurrentMediaTime()
                
        // Initialize last frame if needed
        if lastMainWindowFrame == nil {
            lastMainWindowFrame = currentMainFrame
            lastUpdateTime = currentTime
            debugLog("updatePositionFromDisplayLink: Initialized lastMainWindowFrame")
        }
        
        // Always calculate target position and update if needed (don't require frame change)
        // This ensures the window follows even if frame detection misses small changes
                    
        // Calculate velocity if we have a previous frame
        if let lastFrame = lastMainWindowFrame {
            let timeDelta = currentTime - lastUpdateTime
            if timeDelta > 0 && lastUpdateTime > 0 {
                velocityX = (currentMainFrame.origin.x - lastFrame.origin.x) / CGFloat(timeDelta)
                velocityY = (currentMainFrame.origin.y - lastFrame.origin.y) / CGFloat(timeDelta)
                    }
                }
                
                // Update tracking variables
        lastMainWindowFrame = currentMainFrame
        lastUpdateTime = currentTime
                
                // Calculate target position
                let notificationFrame = notificationWindow.frame
                let notificationWidth = notificationFrame.width
                let targetX = currentMainFrame.minX - notificationWidth - 10
                let targetY = currentMainFrame.midY - (notificationFrame.height / 2)
                let targetOrigin = NSPoint(x: targetX, y: targetY)
                let currentOrigin = notificationWindow.frame.origin
                
        // Only update if position actually changed (with threshold to avoid jitter)
                let deltaX = abs(currentOrigin.x - targetOrigin.x)
                let deltaY = abs(currentOrigin.y - targetOrigin.y)
                
                // Adaptive threshold: smaller threshold during fast movements for responsiveness
        let velocityMagnitude = hypot(velocityX, velocityY)
        let threshold: CGFloat = velocityMagnitude > 50 ? 0.2 : 0.3  // Lower threshold for smoother updates
        
        // Debug logging
        debugLog("updatePositionFromDisplayLink: deltaX=\(String(format: "%.1f", deltaX)), deltaY=\(String(format: "%.1f", deltaY)), threshold=\(String(format: "%.1f", threshold)), velocity=\(String(format: "%.1f", velocityMagnitude))")
        debugValue("currentOrigin", currentOrigin)
        debugValue("targetOrigin", targetOrigin)
                
                if deltaX > threshold || deltaY > threshold {
            debugLog("updatePositionFromDisplayLink: Position update needed, deltaX=\(String(format: "%.1f", deltaX)), deltaY=\(String(format: "%.1f", deltaY))")
            // For very fast movements, update directly without animation for immediate response
            // For slower movements, use smooth interpolation
            if velocityMagnitude > 150 {
                // Very fast movement - update directly for immediate response
                // Cancel any existing animation
                if isAnimating && currentAnimationContext != nil {
                    currentAnimationContext?.allowsImplicitAnimation = false
                    currentAnimationContext = nil
                    isAnimating = false
                }
                // Update position directly
                isProgrammaticallyMoving = true
                notificationWindow.setFrameOrigin(targetOrigin)
                lockedPosition = targetOrigin
                isProgrammaticallyMoving = false
            } else {
                // Normal movement - use direct position updates for most movements
                // Only animate for larger movements to avoid choppiness from constant animation restarts
                let distance = hypot(deltaX, deltaY)
                
                // For most movements, update directly for smooth, responsive following
                // Only animate for larger jumps to smooth them out
                if distance < 30.0 || isAnimating {
                    // Small to medium movement - update directly for instant, smooth response
                    // This avoids the choppiness from constant animation restarts
                    if isAnimating {
                        // Cancel any ongoing animation for direct update
                        currentAnimationContext?.allowsImplicitAnimation = false
                        currentAnimationContext = nil
                        isAnimating = false
                    }
                    isProgrammaticallyMoving = true
                    notificationWindow.setFrameOrigin(targetOrigin)
                    lockedPosition = targetOrigin
                    isProgrammaticallyMoving = false
                } else {
                    // Large movement - use animation to smooth it out
                    debugLog("updatePositionFromDisplayLink: Large movement, using animation, distance=\(String(format: "%.1f", distance))")
                    pendingTargetOrigin = nil
                    updateNotificationWindowPositionSmoothly(targetOrigin: targetOrigin)
                }
            }
        } else {
            // Debug: log when we're NOT updating
            if Int.random(in: 0..<120) == 0 {
                debugLog("updatePositionFromDisplayLink: No update needed - deltaX=\(String(format: "%.1f", deltaX)), deltaY=\(String(format: "%.1f", deltaY)), threshold=\(String(format: "%.1f", threshold))")
            }
        }
    }
    
    private func stopContinuousPositionMonitoring() {
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
        stopDisplayLink()
    }
    
    private func hideNotificationWindowDuringDrag() {
        guard let notificationWindow = notificationWindow, isLocked, !isAnimating else { return }
        isAnimating = true
        
        findMainWindow()
        guard let mainWindow = mainWindow else {
            isAnimating = false
            return
        }
        
        // Keep current frame (no position or size change, just fade out)
        // Ensure window is behind main window before animation
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Animate: fade out only (no position or size animation)
        let manager = self
        // Cancel any existing animation
        currentAnimationContext?.allowsImplicitAnimation = false
        
        NSAnimationContext.runAnimationGroup({ context in
            manager.currentAnimationContext = context
            context.duration = 0.15 // Smooth animation duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Keep window behind during animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            // Only animate opacity (position and size stay the same)
            notificationWindow.animator().alphaValue = 0.0
        }) {
            // Move behind main window after animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            Task { @MainActor in
                manager.isAnimating = false
                manager.currentAnimationContext = nil
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
        
        // Calculate starting position from notification button (genie effect)
        let sidebarWidth: CGFloat = 300
        let buttonX = mainFrame.minX + (sidebarWidth / 2) - 10
        let buttonY = mainFrame.maxY - 120
        
        // Start small (genie effect)
        let startSize: CGFloat = 20
        let startFrame = NSRect(
            x: buttonX - (startSize / 2),
            y: buttonY - (startSize / 2),
            width: startSize,
            height: startSize
        )
        
        // Set initial state (small, at button location, invisible)
        notificationWindow.setFrame(startFrame, display: false)
        notificationWindow.alphaValue = 0.0
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Small delay to ensure window is ready
        let manager = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Ensure window is behind main window before animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            
            // Cancel any existing animation
            manager.currentAnimationContext?.allowsImplicitAnimation = false
            
            // Genie animation: expand from button while moving to target position
            NSAnimationContext.runAnimationGroup({ context in
                manager.currentAnimationContext = context
                context.duration = 0.3 // Genie expansion duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // Keep window behind during animation
                notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
                // Animate both position and size (genie effect)
                notificationWindow.animator().setFrame(targetFrame, display: true)
                notificationWindow.animator().alphaValue = 1.0
            }) {
                // Keep window behind main window after animation
                notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
                
                // Update locked position after animation
                Task { @MainActor in
                    manager.lockedPosition = targetFrame.origin
                    manager.isAnimating = false
                    manager.currentAnimationContext = nil
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
        if let existingWindow = notificationWindow, existingWindow.isVisible, isVisible, !isAnimating {
            // Update content if needed
            if let existingController = existingWindow.contentViewController as? NSHostingController<AnyView> {
                existingController.rootView = content
            }
            return
        }
        
        // If animating (hiding), interrupt by immediately setting to show state
        if isAnimating, let existingWindow = notificationWindow {
            // Cancel current animation by immediately setting target state
            currentAnimationContext?.allowsImplicitAnimation = false
            findMainWindow()
            if let mainWindow = mainWindow {
                let mainFrame = mainWindow.frame
                let notificationWidth: CGFloat = 400
                let notificationHeight: CGFloat = 500
                let targetX = mainFrame.minX - notificationWidth - 10
                let targetY = mainFrame.midY - (notificationHeight / 2)
                let targetFrame = NSRect(x: targetX, y: targetY, width: notificationWidth, height: notificationHeight)
                // Set frame and alpha immediately to correct position
                existingWindow.setFrame(targetFrame, display: true)
                existingWindow.alphaValue = 1.0
            }
            // Continue to show animation below (will restart from current state)
        }
        
        // If window exists but is not visible, close it first to prevent duplicates
        if let existingWindow = notificationWindow, !existingWindow.isVisible {
            existingWindow.close()
            notificationWindow = nil
            isVisible = false
        }
        
        // Allow showing even if currently animating (to interrupt hide animation)
        
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
        // This will also set up the main window delegate relationship
        print("🔧 NotificationWindowManager: Setting up window monitoring, isLocked: \(String(describing: isLocked))")
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
        
        // Calculate starting position from notification button (genie effect)
        // Button is in sidebar (300px wide), positioned near top-center
        // Estimate button position: sidebar center horizontally, ~100px from top
        let sidebarWidth: CGFloat = 300
        let buttonX = mainFrame.minX + (sidebarWidth / 2) - 10 // Center of sidebar, offset for button center
        let buttonY = mainFrame.maxY - 120 // Approximately where the notification button is
        
        // Start small (genie effect) - scale from button location
        let startSize: CGFloat = 20 // Start very small
        let startFrame = NSRect(
            x: buttonX - (startSize / 2),
            y: buttonY - (startSize / 2),
            width: startSize,
            height: startSize
        )
        
        // Set initial state (small, at button location, invisible)
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
            
            // Cancel any existing animation
            manager.currentAnimationContext?.allowsImplicitAnimation = false
            
            // Genie animation: expand from button while moving to target position
            NSAnimationContext.runAnimationGroup({ context in
                manager.currentAnimationContext = context
                context.duration = 0.3 // Genie expansion duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // Keep window behind during animation
                notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
                // Animate both position and size (genie effect)
                notificationWindow.animator().setFrame(targetFrame, display: true)
                notificationWindow.animator().alphaValue = 1.0
            }) {
                // Keep window behind main window after animation
                notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Ensure the view can become first responder
        DispatchQueue.main.async {
            notificationWindow.makeFirstResponder(notificationWindowController.view)
        }
        
                Task { @MainActor in
                    manager.isAnimating = false
                    manager.currentAnimationContext = nil
                }
            }
        }
    }
    
    func hideNotificationWindow() {
        // Ensure we're not already hiding
        guard isVisible else { return }
        
        // Stop position monitoring
        stopContinuousPositionMonitoring()
        
        guard let notificationWindow = notificationWindow else {
            // If window reference is lost but isVisible is true, reset state
            isVisible = false
            self.notificationWindow = nil
            return
        }
        
        // If animating (showing), interrupt by immediately setting to hide state
        if isAnimating {
            // Cancel current animation by immediately setting target state
            currentAnimationContext?.allowsImplicitAnimation = false
            // Keep current frame, just set alpha to 0
            notificationWindow.alphaValue = 0.0
            // Continue to hide animation below (will restart from current state)
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
        
        // Calculate target position (back to notification button - reverse genie effect)
        let mainFrame = mainWindow.frame
        
        // Button position (same as show animation)
        let sidebarWidth: CGFloat = 300
        let buttonX = mainFrame.minX + (sidebarWidth / 2) - 10
        let buttonY = mainFrame.maxY - 120
        
        // Shrink back to button location
        let endSize: CGFloat = 20
        let targetFrame = NSRect(
            x: buttonX - (endSize / 2),
            y: buttonY - (endSize / 2),
            width: endSize,
            height: endSize
        )
        
        // Ensure window is behind main window before animation
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Cancel any existing animation
        let manager = self
        currentAnimationContext?.allowsImplicitAnimation = false
        
        // Reverse genie animation: shrink back to button while moving
        NSAnimationContext.runAnimationGroup({ context in
            manager.currentAnimationContext = context
            context.duration = 0.3 // Genie shrink duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Keep window behind during animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            // Animate both position and size (genie effect) and fade out
            notificationWindow.animator().setFrame(targetFrame, display: true)
            notificationWindow.animator().alphaValue = 0.0
        }) {
            // Move behind main window and close
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            notificationWindow.close()
            
            Task { @MainActor in
                manager.notificationWindow = nil
                manager.isVisible = false
                manager.isAnimating = false
                manager.currentAnimationContext = nil
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
    
    private func updateNotificationWindowPositionSmoothly(targetOrigin: NSPoint) {
        debugLog("updateNotificationWindowPositionSmoothly: called with targetOrigin=\(targetOrigin)")
        guard let notificationWindow = notificationWindow, isLocked else {
            debugLog("updateNotificationWindowPositionSmoothly: guard failed - window: \(notificationWindow != nil), locked: \(isLocked)")
            return
        }
        
        let currentOrigin = notificationWindow.frame.origin
        let distance = hypot(targetOrigin.x - currentOrigin.x, targetOrigin.y - currentOrigin.y)
        debugValue("distance", distance)
        debugValue("currentOrigin", currentOrigin)
        debugValue("targetOrigin", targetOrigin)
        
        // For very small movements, update directly (no animation needed)
        // Increased threshold for direct updates to reduce animation overhead
        if distance < 3.0 {
            debugLog("updateNotificationWindowPositionSmoothly: Small movement, updating directly")
            isProgrammaticallyMoving = true
            notificationWindow.setFrameOrigin(targetOrigin)
            lockedPosition = targetOrigin
            isProgrammaticallyMoving = false
            debugLog("updateNotificationWindowPositionSmoothly: Direct update complete, new position: \(notificationWindow.frame.origin)")
            return
        }
        
        // For larger movements, use a very short, smooth animation
        debugLog("updateNotificationWindowPositionSmoothly: Starting animation, distance=\(String(format: "%.1f", distance))")
        isAnimating = true
        
        // Use adaptive duration based on distance
        // Keep durations very short to minimize choppiness from constant restarts
        let baseDuration: TimeInterval = 0.05  // Base duration
        let distanceFactor = min(distance / 100.0, 1.0)  // Scale up to 100px, then cap
        let duration = baseDuration + (distanceFactor * 0.05)  // Max 0.10s for larger movements
        
        let manager = self
        let startTime = CACurrentMediaTime()
        lastAnimationStartTime = startTime
        debugLog("updateNotificationWindowPositionSmoothly: Starting animation at \(startTime), duration=\(duration)")
        
        NSAnimationContext.runAnimationGroup({ context in
            manager.currentAnimationContext = context
            context.duration = duration
            // Use default timing for smoother, less choppy movement
            // The default timing provides good balance without feeling sluggish
            context.allowsImplicitAnimation = true
            
            debugLog("updateNotificationWindowPositionSmoothly: Setting frame origin via animator to \(targetOrigin)")
            
            // Get current frame and create new frame with target origin
            let currentFrame = notificationWindow.frame
            let newFrame = NSRect(origin: targetOrigin, size: currentFrame.size)
            
            // Animate the entire frame (more reliable than just origin)
            notificationWindow.animator().setFrame(newFrame, display: true)
        }) {
            let endTime = CACurrentMediaTime()
            let actualDuration = endTime - startTime
            debugLog("updateNotificationWindowPositionSmoothly: Animation completed after \(String(format: "%.3f", actualDuration))s")
            Task { @MainActor in
                // Check if there's a pending target that's different from what we just animated to
                if let pending = manager.pendingTargetOrigin, pending != targetOrigin {
                    let pendingDistance = hypot(pending.x - notificationWindow.frame.origin.x, pending.y - notificationWindow.frame.origin.y)
                    if pendingDistance > 5.0 {
                        debugLog("updateNotificationWindowPositionSmoothly: Pending target detected, continuing animation to \(pending)")
                        manager.isAnimating = false  // Reset flag so we can start new animation
                        manager.updateNotificationWindowPositionSmoothly(targetOrigin: pending)
                        return
                    }
                }
                
                // Don't correct position - trust the animation
                // Position correction was causing jumps and flickering
                manager.lockedPosition = targetOrigin
                manager.isProgrammaticallyMoving = false
                manager.isAnimating = false
                manager.currentAnimationContext = nil
                manager.pendingTargetOrigin = nil
                debugLog("updateNotificationWindowPositionSmoothly: Final position: \(notificationWindow.frame.origin), target was: \(targetOrigin)")
            }
        }
    }
    
    private func updateNotificationWindowPositionSmoothly() {
        guard let notificationWindow = notificationWindow, isLocked else { return }
        
        // Re-find main window in case it changed
        findMainWindow()
        guard let mainWindow = mainWindow else { return }
        
        let mainFrame = mainWindow.frame
        let notificationFrame = notificationWindow.frame
        let notificationWidth = notificationFrame.width
        
        // Position to the left of main window, vertically centered
        let x = mainFrame.minX - notificationWidth - 10 // 10px gap
        let y = mainFrame.midY - (notificationFrame.height / 2)
        
        let targetOrigin = NSPoint(x: x, y: y)
        updateNotificationWindowPositionSmoothly(targetOrigin: targetOrigin)
    }
    
    private func updateNotificationWindowPositionElastically() {
        debugLog("updateNotificationWindowPositionElastically() called")
        guard let notificationWindow = notificationWindow, isLocked else {
            debugLog("Guard failed - notificationWindow: \(notificationWindow != nil), isLocked: \(isLocked)")
            return
        }
        
        // Re-find main window in case it changed
        findMainWindow()
        guard let mainWindow = mainWindow else {
            debugLog("Could not find main window")
            return
        }
        
        debugLog("Main window found: \(mainWindow.title) at \(mainWindow.frame)")
        
        let mainFrame = mainWindow.frame
        let notificationFrame = notificationWindow.frame
        let notificationWidth = notificationFrame.width
        
        // Position to the left of main window, vertically centered
        let targetX = mainFrame.minX - notificationWidth - 10 // 10px gap
        let targetY = mainFrame.midY - (notificationFrame.height / 2)
        
        let targetOrigin = NSPoint(x: targetX, y: targetY)
        let currentOrigin = notificationWindow.frame.origin
        
        // Only animate if position actually changed (with small threshold to avoid jitter)
        let deltaX = abs(currentOrigin.x - targetOrigin.x)
        let deltaY = abs(currentOrigin.y - targetOrigin.y)
        debugValue("deltaX", deltaX)
        debugValue("deltaY", deltaY)
        debugValue("currentOrigin", currentOrigin)
        debugValue("targetOrigin", targetOrigin)
        
        guard deltaX > 0.5 || deltaY > 0.5 else {
            debugLog("Position change too small to animate: deltaX=\(String(format: "%.2f", deltaX)), deltaY=\(String(format: "%.2f", deltaY))")
            return
        }
        
        // Calculate velocity based on time and distance
        let currentTime = CACurrentMediaTime()
        let timeDelta = currentTime - lastUpdateTime
        if timeDelta > 0 && lastUpdateTime > 0 {
            // Estimate velocity from frame changes
            if let lastFrame = lastMainWindowFrame {
                let frameDeltaX = mainFrame.origin.x - lastFrame.origin.x
                let frameDeltaY = mainFrame.origin.y - lastFrame.origin.y
                velocityX = frameDeltaX / CGFloat(timeDelta)
                velocityY = frameDeltaY / CGFloat(timeDelta)
            }
        }
        lastUpdateTime = currentTime
        
        // Mark as programmatic move
        isProgrammaticallyMoving = true
        
        debugLog("Calling useSpringAnimation to move from \(currentOrigin) to \(targetOrigin)")
        
        // Use CASpringAnimation for true spring physics
        // This gives us better control over damping and response
        useSpringAnimation(to: targetOrigin, currentOrigin: currentOrigin)
    }
    
    private func useSpringAnimation(to targetOrigin: NSPoint, currentOrigin: NSPoint) {
        guard let notificationWindow = notificationWindow else {
            debugLog("useSpringAnimation: No notification window")
            return
        }
        
        debugLog("useSpringAnimation: Starting animation from \(currentOrigin) to \(targetOrigin)")
        
        // Cancel any existing animation context to allow smooth updates during drags
        if let existingContext = currentAnimationContext {
            debugLog("useSpringAnimation: Cancelling existing animation context")
            existingContext.allowsImplicitAnimation = false
            currentAnimationContext = nil
            isAnimating = false  // Reset flag when cancelling
        }
        
        // Calculate distance and velocity for adaptive animation
        let distance = hypot(targetOrigin.x - currentOrigin.x, targetOrigin.y - currentOrigin.y)
        let velocityMagnitude = hypot(velocityX, velocityY)
        let isMovingFast = velocityMagnitude > 50 // pixels per second threshold
        
        debugValue("distance", distance)
        debugValue("velocityMagnitude", velocityMagnitude)
        debugValue("isMovingFast", isMovingFast)
        
        // Adaptive animation parameters based on movement speed
        let duration: TimeInterval
        let timingFunction: CAMediaTimingFunction
        
        if isMovingFast {
            // Fast movement: shorter duration, more responsive, less bounce
            duration = 0.15  // Even shorter for responsiveness during drags
            // Custom timing with slight overshoot for elastic feel
            timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
        } else if distance > 100 {
            // Large movement: longer duration, more elastic
            duration = 0.3
            // More pronounced elastic bounce
            timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
        } else {
            // Small movement: balanced
            duration = 0.2
            // Moderate elastic bounce
            timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.2, 0.64, 1.0)
        }
        
        debugValue("animationDuration", duration)
        
        // Mark as animating
        isAnimating = true
        
        // Use NSAnimationContext with spring-like timing
        let manager = self
        debugLog("useSpringAnimation: Starting NSAnimationContext with duration \(duration)")
        
        // Store the target for completion handler
        let finalTarget = targetOrigin
        
        NSAnimationContext.runAnimationGroup({ context in
            manager.currentAnimationContext = context
            context.duration = duration
            context.timingFunction = timingFunction
            context.allowsImplicitAnimation = true
            
            debugLog("useSpringAnimation: Setting frame origin to \(targetOrigin) via animator")
            
            // Get current frame and create new frame with target origin
            let currentFrame = notificationWindow.frame
            let newFrame = NSRect(origin: targetOrigin, size: currentFrame.size)
            
            // Animate the entire frame (more reliable than just origin)
            notificationWindow.animator().setFrame(newFrame, display: true)
        }) {
            // Update locked position after animation
            debugLog("useSpringAnimation: Animation completed")
            Task { @MainActor in
                // Don't correct position - trust the animation
                // Position correction was causing jumps and flickering
                manager.lockedPosition = finalTarget
                manager.isProgrammaticallyMoving = false
                manager.isAnimating = false
                manager.currentAnimationContext = nil
            }
        }
    }
    
    func refreshMainWindow() {
        findMainWindow()
        updateNotificationWindowPosition()
    }
}

