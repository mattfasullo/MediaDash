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

    // Flag to track if we're being deallocated (for displayLink callback safety)
    private var isShuttingDown = false

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

            // Remove child window relationship
            if let mainWindow = mainWindow, let notificationWindow = notificationWindow {
                mainWindow.removeChildWindow(notificationWindow)
            }

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

        // Remove child window relationship
        if let mainWindow = mainWindow, let notificationWindow = notificationWindow {
            mainWindow.removeChildWindow(notificationWindow)
        }

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

        let newMainWindow = allWindows.first { window in
            window != notificationWindow &&
            window.isVisible &&
            window.title != "Notifications" &&
            window.frame.width >= 300
        } ?? allWindows.first { window in
            window != notificationWindow && window.isVisible
        }

        // If main window changed, update delegate
        if newMainWindow != mainWindow {
            if let oldMainWindow = mainWindow, isMainWindowDelegate {
                oldMainWindow.delegate = nil
                isMainWindowDelegate = false
            }

            mainWindow = newMainWindow
            if let mainWindow = mainWindow, isLocked {
                mainWindow.delegate = self
                isMainWindowDelegate = true
                lastMainWindowFrame = mainWindow.frame
            }
        }
    }
    
    private func setupWindowMonitoring() {
        // Only monitor if window is locked
        guard isLocked else {
            // Remove child window relationship when unlocked
            if let mainWindow = mainWindow, let notificationWindow = notificationWindow {
                mainWindow.removeChildWindow(notificationWindow)
            }
            return
        }

        // Set up main window as delegate for direct frame tracking
        findMainWindow()
        if let mainWindow = mainWindow, let notificationWindow = notificationWindow {
            // Make notification window a child of main window for automatic movement
            mainWindow.addChildWindow(notificationWindow, ordered: .below)
            notificationWindow.animationBehavior = .utilityWindow

            mainWindow.delegate = self
            isMainWindowDelegate = true
            lastMainWindowFrame = mainWindow.frame
            lastUpdateTime = CACurrentMediaTime()
            velocityX = 0
            velocityY = 0
        }

        // Still set up monitoring for resize events
        setupNotificationBasedMonitoring()
    }
    
    private func updateNotificationWindowPositionDirectly() {
        guard let mainWindow = mainWindow,
              let notificationWindow = notificationWindow,
              isLocked,
              !isAnimating else { return }

        let mainFrame = mainWindow.frame
        let notificationFrame = notificationWindow.frame
        let notificationWidth = notificationFrame.width
        let notificationHeight = notificationFrame.height

        let targetX = mainFrame.minX - notificationWidth - 10
        let targetY = mainFrame.midY - (notificationHeight / 2)
        let targetOrigin = NSPoint(x: targetX, y: targetY)

        // Direct update for resize events (child window handles move automatically)
        notificationWindow.setFrame(
            NSRect(origin: targetOrigin, size: notificationFrame.size),
            display: false,
            animate: false
        )
        lockedPosition = targetOrigin
    }
    
    private func setupNotificationBasedMonitoring() {
        // Only monitor resize - child window relationship handles movement automatically!
        // This is much more efficient than polling and perfectly smooth
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
        // Note: The callback uses a weak reference pattern via DispatchQueue.main.async
        // to ensure we don't access the manager if it's being deallocated
        let displayLinkCallback: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, context) -> CVReturn in
            guard let context = context else { return kCVReturnError }
            let manager = Unmanaged<NotificationWindowManager>.fromOpaque(context).takeUnretainedValue()

            // Check if we're shutting down before dispatching
            if manager.isShuttingDown {
                return kCVReturnSuccess
            }

            DispatchQueue.main.async { [weak manager] in
                guard let manager = manager, !manager.isShuttingDown else { return }
                manager.updatePositionFromDisplayLink()
            }

            return kCVReturnSuccess
        }

        // Create display link
        var displayLink: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

        guard result == kCVReturnSuccess, let link = displayLink else {
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
        } else {
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
        guard isLocked else { return }
        guard let mainWindow = mainWindow, let notificationWindow = notificationWindow else { return }

        // Get current main window frame directly (most reliable)
        let currentMainFrame = mainWindow.frame
        let currentTime = CACurrentMediaTime()
                
        // Initialize last frame if needed
        if lastMainWindowFrame == nil {
            lastMainWindowFrame = currentMainFrame
            lastUpdateTime = currentTime
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
        let threshold: CGFloat = velocityMagnitude > 50 ? 0.2 : 0.3

        if deltaX > threshold || deltaY > threshold {
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
                    pendingTargetOrigin = nil
                    updateNotificationWindowPositionSmoothly(targetOrigin: targetOrigin)
                }
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
        
        // Calculate exact position of notification button for genie effect
        // Sidebar layout: 16px padding + Logo (60px) + 4px bottom padding + 12px VStack spacing + NotificationTab
        let sidebarWidth: CGFloat = 300
        let sidebarPadding: CGFloat = 16
        let logoHeight: CGFloat = 60
        let logoBottomPadding: CGFloat = 4
        let vstackSpacing: CGFloat = 12
        let buttonHeight: CGFloat = 32 // Approx height of NotificationTabButton

        // Calculate button center position in screen coordinates
        let buttonCenterX = mainFrame.minX + sidebarWidth / 2
        let buttonCenterY = mainFrame.maxY - sidebarPadding - logoHeight - logoBottomPadding - vstackSpacing - (buttonHeight / 2)

        // Start as tiny point at button center (true genie effect)
        let startSize: CGFloat = 1
        let startFrame = NSRect(
            x: buttonCenterX - (startSize / 2),
            y: buttonCenterY - (startSize / 2),
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
            
            // Genie animation: expand from button with spring/elastic feel
            NSAnimationContext.runAnimationGroup({ context in
                manager.currentAnimationContext = context
                context.duration = 0.45 // Slightly longer for spring effect
                context.allowsImplicitAnimation = true
                // Use spring timing for elastic/bouncy feel
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 1.8, 0.7, 0.9)
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
        
        // Configure content view for proper rounded corners with transparency
        if let contentView = notificationWindow.contentView {
            contentView.wantsLayer = true
            contentView.layer?.masksToBounds = true
            contentView.layer?.cornerRadius = 12
            contentView.layer?.backgroundColor = NSColor.clear.cgColor // Ensure content view background is transparent
            
            // Create a mask to ensure only the rounded rectangle area is visible
            let maskLayer = CAShapeLayer()
            let maskPath = CGPath(roundedRect: contentView.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
            maskLayer.path = maskPath
            contentView.layer?.mask = maskLayer
            
            // Update mask when view resizes
            // Capture contentView weakly to avoid retain cycle and Sendable issues
            Foundation.NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: contentView,
                queue: OperationQueue.main
            ) { [weak contentView] _ in
                guard let contentView = contentView,
                      let mask = contentView.layer?.mask as? CAShapeLayer else { return }
                let updatedPath = CGPath(roundedRect: contentView.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
                mask.path = updatedPath
            }
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
        
        // Set initial locked position if locked
        if self.isLocked {
            lockedPosition = targetFrame.origin
        }
        
        isAnimating = true
        isVisible = true
        
        // Make window visible immediately (no delay) for instant feedback
        notificationWindow.orderFront(nil)
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Cancel any existing animation
        currentAnimationContext?.allowsImplicitAnimation = false
        
        // Genie animation: expand from button while moving to target position
        // Start animation immediately without delay for instant response
        let manager = self
        NSAnimationContext.runAnimationGroup({ context in
            manager.currentAnimationContext = context
            context.duration = 0.25 // Slightly faster animation for snappier feel
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
        
        // Calculate target position (shrink back into notification button - reverse genie)
        let mainFrame = mainWindow.frame

        // Calculate exact notification button position (same as show animation)
        let sidebarWidth: CGFloat = 300
        let sidebarPadding: CGFloat = 16
        let logoHeight: CGFloat = 60
        let logoBottomPadding: CGFloat = 4
        let vstackSpacing: CGFloat = 12
        let buttonHeight: CGFloat = 32

        let buttonCenterX = mainFrame.minX + sidebarWidth / 2
        let buttonCenterY = mainFrame.maxY - sidebarPadding - logoHeight - logoBottomPadding - vstackSpacing - (buttonHeight / 2)

        // Shrink to tiny point at button center
        let targetSize: CGFloat = 1
        let targetFrame = NSRect(
            x: buttonCenterX - (targetSize / 2),
            y: buttonCenterY - (targetSize / 2),
            width: targetSize,
            height: targetSize
        )
        
        // Ensure window is behind main window before animation
        notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
        
        // Cancel any existing animation
        let manager = self
        currentAnimationContext?.allowsImplicitAnimation = false
        
        // Reverse genie animation: shrink back into button with smooth ease
        NSAnimationContext.runAnimationGroup({ context in
            manager.currentAnimationContext = context
            context.duration = 0.35 // Slightly faster shrink
            context.allowsImplicitAnimation = true
            // Smooth ease in for collapsing effect
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Keep window behind during animation
            notificationWindow.order(.below, relativeTo: mainWindow.windowNumber)
            // Animate both position and size (reverse genie effect) and fade out
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
        // DEBUG: Commented out for performance
        // debugLog("updateNotificationWindowPositionSmoothly: called with targetOrigin=\(targetOrigin)")
        guard let notificationWindow = notificationWindow, isLocked else {
            // DEBUG: Commented out for performance
            // debugLog("updateNotificationWindowPositionSmoothly: guard failed - window: \(notificationWindow != nil), locked: \(isLocked)")
            return
        }
        
        let currentOrigin = notificationWindow.frame.origin
        let distance = hypot(targetOrigin.x - currentOrigin.x, targetOrigin.y - currentOrigin.y)
        // DEBUG: Commented out for performance
        // debugValue("distance", distance)
        // debugValue("currentOrigin", currentOrigin)
        // debugValue("targetOrigin", targetOrigin)
        
        // For very small movements, update directly (no animation needed)
        // Increased threshold for direct updates to reduce animation overhead
        if distance < 3.0 {
            // DEBUG: Commented out for performance
            // debugLog("updateNotificationWindowPositionSmoothly: Small movement, updating directly")
            isProgrammaticallyMoving = true
            notificationWindow.setFrameOrigin(targetOrigin)
            lockedPosition = targetOrigin
            isProgrammaticallyMoving = false
            // DEBUG: Commented out for performance
            // debugLog("updateNotificationWindowPositionSmoothly: Direct update complete, new position: \(notificationWindow.frame.origin)")
            return
        }
        
        // For larger movements, use a very short, smooth animation
        // DEBUG: Commented out for performance
        // debugLog("updateNotificationWindowPositionSmoothly: Starting animation, distance=\(String(format: "%.1f", distance))")
        isAnimating = true
        
        // Use adaptive duration based on distance
        // Keep durations very short to minimize choppiness from constant restarts
        let baseDuration: TimeInterval = 0.05  // Base duration
        let distanceFactor = min(distance / 100.0, 1.0)  // Scale up to 100px, then cap
        let duration = baseDuration + (distanceFactor * 0.05)  // Max 0.10s for larger movements
        
        let manager = self
        let startTime = CACurrentMediaTime()
        lastAnimationStartTime = startTime
        // DEBUG: Commented out for performance
        // debugLog("updateNotificationWindowPositionSmoothly: Starting animation at \(startTime), duration=\(duration)")
        
        NSAnimationContext.runAnimationGroup({ context in
            manager.currentAnimationContext = context
            context.duration = duration
            // Use default timing for smoother, less choppy movement
            // The default timing provides good balance without feeling sluggish
            context.allowsImplicitAnimation = true
            
            // DEBUG: Commented out for performance
            // debugLog("updateNotificationWindowPositionSmoothly: Setting frame origin via animator to \(targetOrigin)")
            
            // Get current frame and create new frame with target origin
            let currentFrame = notificationWindow.frame
            let newFrame = NSRect(origin: targetOrigin, size: currentFrame.size)
            
            // Animate the entire frame (more reliable than just origin)
            notificationWindow.animator().setFrame(newFrame, display: true)
        }) {
            let endTime = CACurrentMediaTime()
            _ = endTime - startTime
            // DEBUG: Commented out for performance
            // debugLog("updateNotificationWindowPositionSmoothly: Animation completed after \(String(format: "%.3f", actualDuration))s")
            Task { @MainActor in
                // Check if there's a pending target that's different from what we just animated to
                if let pending = manager.pendingTargetOrigin, pending != targetOrigin {
                    let pendingDistance = hypot(pending.x - notificationWindow.frame.origin.x, pending.y - notificationWindow.frame.origin.y)
                    if pendingDistance > 5.0 {
                        // DEBUG: Commented out for performance
                        // debugLog("updateNotificationWindowPositionSmoothly: Pending target detected, continuing animation to \(pending)")
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
                // DEBUG: Commented out for performance
                // debugLog("updateNotificationWindowPositionSmoothly: Final position: \(notificationWindow.frame.origin), target was: \(targetOrigin)")
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
        // DEBUG: Commented out for performance
        // debugLog("updateNotificationWindowPositionElastically() called")
        guard let notificationWindow = notificationWindow, isLocked else {
            // DEBUG: Commented out for performance
            // debugLog("Guard failed - notificationWindow: \(notificationWindow != nil), isLocked: \(isLocked)")
            return
        }
        
        // Re-find main window in case it changed
        findMainWindow()
        guard let mainWindow = mainWindow else {
            // DEBUG: Commented out for performance
            // debugLog("Could not find main window")
            return
        }
        
        // DEBUG: Commented out for performance
        // debugLog("Main window found: \(mainWindow.title) at \(mainWindow.frame)")
        
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
        // DEBUG: Commented out for performance
        // debugValue("deltaX", deltaX)
        // debugValue("deltaY", deltaY)
        // debugValue("currentOrigin", currentOrigin)
        // debugValue("targetOrigin", targetOrigin)
        
        guard deltaX > 0.5 || deltaY > 0.5 else {
            // DEBUG: Commented out for performance
            // debugLog("Position change too small to animate: deltaX=\(String(format: "%.2f", deltaX)), deltaY=\(String(format: "%.2f", deltaY))")
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
        
        // DEBUG: Commented out for performance
        // debugLog("Calling useSpringAnimation to move from \(currentOrigin) to \(targetOrigin)")
        
        // Use CASpringAnimation for true spring physics
        // This gives us better control over damping and response
        useSpringAnimation(to: targetOrigin, currentOrigin: currentOrigin)
    }
    
    private func useSpringAnimation(to targetOrigin: NSPoint, currentOrigin: NSPoint) {
        guard let notificationWindow = notificationWindow else {
            // DEBUG: Commented out for performance
            // debugLog("useSpringAnimation: No notification window")
            return
        }
        
        // DEBUG: Commented out for performance
        // debugLog("useSpringAnimation: Starting animation from \(currentOrigin) to \(targetOrigin)")
        
        // Cancel any existing animation context to allow smooth updates during drags
        if let existingContext = currentAnimationContext {
            // DEBUG: Commented out for performance
            // debugLog("useSpringAnimation: Cancelling existing animation context")
            existingContext.allowsImplicitAnimation = false
            currentAnimationContext = nil
            isAnimating = false  // Reset flag when cancelling
        }
        
        // Calculate distance and velocity for adaptive animation
        let distance = hypot(targetOrigin.x - currentOrigin.x, targetOrigin.y - currentOrigin.y)
        let velocityMagnitude = hypot(velocityX, velocityY)
        let isMovingFast = velocityMagnitude > 50 // pixels per second threshold
        
        // DEBUG: Commented out for performance
        // debugValue("distance", distance)
        // debugValue("velocityMagnitude", velocityMagnitude)
        // debugValue("isMovingFast", isMovingFast)
        
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
        
        // DEBUG: Commented out for performance
        // debugValue("animationDuration", duration)
        
        // Mark as animating
        isAnimating = true
        
        // Use NSAnimationContext with spring-like timing
        let manager = self
        // DEBUG: Commented out for performance
        // debugLog("useSpringAnimation: Starting NSAnimationContext with duration \(duration)")
        
        // Store the target for completion handler
        let finalTarget = targetOrigin
        
        NSAnimationContext.runAnimationGroup({ context in
            manager.currentAnimationContext = context
            context.duration = duration
            context.timingFunction = timingFunction
            context.allowsImplicitAnimation = true
            
            // DEBUG: Commented out for performance
            // debugLog("useSpringAnimation: Setting frame origin to \(targetOrigin) via animator")
            
            // Get current frame and create new frame with target origin
            let currentFrame = notificationWindow.frame
            let newFrame = NSRect(origin: targetOrigin, size: currentFrame.size)
            
            // Animate the entire frame (more reliable than just origin)
            notificationWindow.animator().setFrame(newFrame, display: true)
        }) {
            // Update locked position after animation
            // DEBUG: Commented out for performance
            // debugLog("useSpringAnimation: Animation completed")
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

    // MARK: - Cleanup

    /// Clean up all resources. Call this before the manager is deallocated.
    func cleanup() {
        isShuttingDown = true

        // Stop display link first (prevents callback from accessing freed memory)
        stopDisplayLink()

        // Invalidate timer
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil

        // Clear all cancellables
        cancellables.removeAll()

        // Remove child window relationship
        if let mainWindow = mainWindow, let notificationWindow = notificationWindow {
            mainWindow.removeChildWindow(notificationWindow)
        }

        // Remove delegate from main window
        if let mainWindow = mainWindow, isMainWindowDelegate {
            mainWindow.delegate = nil
            isMainWindowDelegate = false
        }

        // Close notification window
        notificationWindow?.close()
        notificationWindow = nil
        isVisible = false
    }
}

