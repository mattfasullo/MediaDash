//
//  MediaDashApp.swift
//  MediaDash
//
//  Created by Matt Fasullo on 2025-11-18.
//

import SwiftUI
import AppKit

@main
struct MediaDashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Initialize file logger on app startup
        // This creates the log file at ~/Library/Logs/MediaDash/mediadash-debug.log
        // The AI assistant can read this file directly to debug issues
        // Skip initialization in preview/playground mode to avoid blocking
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
        let isPlayground = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] != nil
        if !isPreview && !isPlayground {
            _ = FileLogger.shared
        }
    }

    var body: some Scene {
        WindowGroup {
            GatekeeperView()
                .background(WindowAccessor())
                .onAppear {
                    configureAllWindows()
                }
        }
        .windowResizability(.contentSize) // Fixed size - no resizing
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
        .commands {
            // Override quit command to always work
            CommandGroup(replacing: .appTermination) {
                Button("Quit MediaDash") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView()
            }
            
            CommandGroup(after: .toolbar) {
                Button("CodeMind Debug Window") {
                    CodeMindDebugWindowManager.shared.toggleDebugWindow()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Toggle CodeMind Overlay") {
                    Task { @MainActor in
                        CodeMindActivityManager.shared.toggle()
                    }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Toggle Layout Edit Mode") {
                    LayoutEditManager.shared.toggleEditMode()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                
                Button("Export Layout to Desktop") {
                    if let url = LayoutEditManager.shared.exportLayoutToDesktop() {
                        // Show success notification
                        let alert = NSAlert()
                        alert.messageText = "Layout Exported"
                        alert.informativeText = "Layout exported to:\n\(url.path)"
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Export Failed"
                        alert.informativeText = "Failed to export layout. Check console for details."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                
                Divider()
                
                Button("Undo Layout Change") {
                    LayoutEditManager.shared.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                
                Button("Redo Layout Change") {
                    LayoutEditManager.shared.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                
                Divider()
                
                Button("Reset Layout to Default") {
                    let alert = NSAlert()
                    alert.messageText = "Reset Layout?"
                    alert.informativeText = "This will clear all layout changes and restore the original positions. This cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Reset")
                    alert.addButton(withTitle: "Cancel")
                    
                    if alert.runModal() == .alertFirstButtonReturn {
                        LayoutEditManager.shared.resetAllOffsets()
                        let confirmAlert = NSAlert()
                        confirmAlert.messageText = "Layout Reset"
                        confirmAlert.informativeText = "All layout changes have been cleared. Restart the app to see the original layout."
                        confirmAlert.alertStyle = .informational
                        confirmAlert.addButton(withTitle: "OK")
                        confirmAlert.runModal()
                    }
                }
            }
        }
    }
    
    private func configureAllWindows() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                WindowConfiguration.configureWindow(window)
            }
        }
    }
}

// MARK: - Centralized Window Configuration

/// Centralized window configuration to avoid code duplication
/// All window configuration should go through this struct
enum WindowConfiguration {
    /// Configures a window with the standard MediaDash appearance and behavior
    static func configureWindow(_ window: NSWindow) {
        // CRITICAL: Remove resizable flag FIRST
        var styleMask = window.styleMask
        styleMask.remove(.resizable)
        window.styleMask = styleMask
        window.showsResizeIndicator = false

        // Set window delegate to prevent resizing
        if window.delegate == nil || !(window.delegate is NonResizableWindowDelegate) {
            window.delegate = NonResizableWindowDelegate.shared
            NonResizableWindowDelegate.shared.registerWindow(window)
        }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        // Re-remove resizable after inserting fullSizeContentView
        styleMask = window.styleMask
        styleMask.remove(.resizable)
        window.styleMask = styleMask

        window.toolbar = nil
        window.contentView?.wantsLayer = true
        window.backgroundColor = NSColor.windowBackgroundColor

        // Keep window buttons visible
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false

        // Enable fullscreen support
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]

        // Set up fullscreen observers
        setupFullscreenObserverForDashboard(window)

        // Set fixed window size (compact mode by default)
        let fixedSize = NSSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.setContentSize(fixedSize)

        // Remove content border to ensure content extends fully to top
        window.setContentBorderThickness(0, for: .minY)

        // Force window to update
        window.invalidateShadow()
    }
}

// MARK: - Fullscreen Observer Management

/// Manages fullscreen observers to prevent memory leaks
/// Uses a static dictionary to track observers per window
private var fullscreenObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

/// Sets up fullscreen observers for a window, properly cleaning up any existing ones
func setupFullscreenObserverForDashboard(_ window: NSWindow) {
    let windowId = ObjectIdentifier(window)

    // Remove any existing observers for this window
    if let existingObservers = fullscreenObservers[windowId] {
        for observer in existingObservers {
            Foundation.NotificationCenter.default.removeObserver(observer)
        }
    }

    var observers: [NSObjectProtocol] = []

    // Observer for when window is about to enter fullscreen
    let willEnter = Foundation.NotificationCenter.default.addObserver(
        forName: NSWindow.willEnterFullScreenNotification,
        object: window,
        queue: .main
    ) { _ in
        switchToDashboardModeForFullscreen()
    }
    observers.append(willEnter)

    // Observer for when window enters fullscreen
    let didEnter = Foundation.NotificationCenter.default.addObserver(
        forName: NSWindow.didEnterFullScreenNotification,
        object: window,
        queue: .main
    ) { _ in
        switchToDashboardModeForFullscreen()
    }
    observers.append(didEnter)

    // Observer for when window exits fullscreen
    let willExit = Foundation.NotificationCenter.default.addObserver(
        forName: NSWindow.willExitFullScreenNotification,
        object: window,
        queue: .main
    ) { _ in
        switchToCompactMode()
    }
    observers.append(willExit)

    // Observer for when window has exited fullscreen
    let didExit = Foundation.NotificationCenter.default.addObserver(
        forName: NSWindow.didExitFullScreenNotification,
        object: window,
        queue: .main
    ) { _ in
        switchToCompactMode()
    }
    observers.append(didExit)

    // Store observers for cleanup
    fullscreenObservers[windowId] = observers
}

// Window delegate to prevent resizing
class NonResizableWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = NonResizableWindowDelegate()
    private var registeredWindows: [NSWindow] = []
    
    func registerWindow(_ window: NSWindow) {
        if !registeredWindows.contains(where: { $0 === window }) {
            registeredWindows.append(window)
            window.delegate = self
        }
    }
    
    // Prevent window from being resized - this is the key method
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Always return the current size to prevent any resizing
        return sender.frame.size
    }
}

func switchToDashboardModeForFullscreen() {
    switchWindowMode(.dashboard)
}

func switchToCompactMode() {
    switchWindowMode(.compact)
}

func switchWindowMode(_ mode: WindowMode) {
    guard let profilesData = UserDefaults.standard.data(forKey: "savedProfiles"),
          var profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData) else {
        return
    }
    let currentProfileName = UserDefaults.standard.string(forKey: "currentProfile") ?? "Default"
    if var profile = profiles[currentProfileName] {
        profile.windowMode = mode
        profiles[currentProfileName] = profile
        if let encoded = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(encoded, forKey: "savedProfiles")
            
            // Resize window to appropriate size for the mode
            DispatchQueue.main.async {
                if let window = NSApplication.shared.windows.first {
                    let targetSize: NSSize
                    if mode == .dashboard {
                        targetSize = NSSize(width: LayoutMode.dashboardDefaultWidth, height: LayoutMode.dashboardDefaultHeight)
                    } else {
                        targetSize = NSSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
                    }
                    
                    // Update window constraints
                    window.minSize = targetSize
                    window.maxSize = targetSize
                    
                    // Resize window
                    var frame = window.frame
                    frame.size = targetSize
                    window.setFrame(frame, display: true, animate: true)
                }
            }
            
            // Post notification so ContentView can update
            Foundation.NotificationCenter.default.post(
                name: Foundation.Notification.Name("windowModeChanged"),
                object: nil,
                userInfo: ["windowMode": mode]
            )
        }
    }
}

struct CheckForUpdatesView: View {
    var body: some View {
        Button("Check for Updates...") {
            // After adding Sparkle SPM package, this will work
            NSApplication.shared.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)
        }
        .keyboardShortcut("u", modifiers: [.command])
    }
}

// Helper view to configure window appearance and handle double-click to full screen
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = TitleBarDoubleClickView()
        DispatchQueue.main.async {
            if let window = view.window {
                WindowConfiguration.configureWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-configure on update
        DispatchQueue.main.async {
            if let window = nsView.window {
                WindowConfiguration.configureWindow(window)
            }
        }
    }
}

// Custom view that handles double-click on title bar area
class TitleBarDoubleClickView: NSView {
    private var originalFrame: NSRect?
    private var isMaximized = false
    private var doubleClickHandler: DoubleClickWindowHandler?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            // Store original frame when view is added to window
            originalFrame = window.frame
            
            // Set up double-click handler on the window
            setupDoubleClickHandler(window)
        }
    }
    
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // Update overlay position when view resizes
        if let window = window {
            setupDoubleClickHandler(window)
        }
    }
    
    private func setupDoubleClickHandler(_ window: NSWindow) {
        // Create or get the handler
        if doubleClickHandler == nil {
            doubleClickHandler = DoubleClickWindowHandler(window: window)
            
            // Add a transparent overlay view at the top to intercept double-clicks
            if let contentView = window.contentView {
                // Remove any existing overlay
                contentView.subviews.forEach { subview in
                    if subview is TitleBarEventInterceptorView {
                        subview.removeFromSuperview()
                    }
                }
                
                // Create overlay view for title bar area
                let titleBarHeight: CGFloat = 44
                let overlay = TitleBarEventInterceptorView(frame: NSRect(
                    x: 0,
                    y: contentView.bounds.height - titleBarHeight,
                    width: contentView.bounds.width,
                    height: titleBarHeight
                ))
                overlay.autoresizingMask = [.width, .minYMargin]
                overlay.doubleClickHandler = doubleClickHandler
                contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
            }
        } else {
            // Update existing handler's window reference
            doubleClickHandler?.window = window
            
            // Update overlay position
            if let contentView = window.contentView {
                let titleBarHeight: CGFloat = 44
                contentView.subviews.forEach { subview in
                    if let overlay = subview as? TitleBarEventInterceptorView {
                        overlay.frame = NSRect(
                            x: 0,
                            y: contentView.bounds.height - titleBarHeight,
                            width: contentView.bounds.width,
                            height: titleBarHeight
                        )
                        overlay.doubleClickHandler = doubleClickHandler
                    }
                }
            }
        }
    }
}

// View that intercepts mouse events in the title bar area
class TitleBarEventInterceptorView: NSView {
    var doubleClickHandler: DoubleClickWindowHandler?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Make view transparent but still receive mouse events
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }
    
    override func mouseDown(with event: NSEvent) {
        // Check if it's a double-click
        if event.clickCount == 2 {
            doubleClickHandler?.toggleFullScreen()
            return
        }
        
        // Pass through to next responder for normal handling
        super.mouseDown(with: event)
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

// Handler for double-click events on title bar
class DoubleClickWindowHandler: NSObject {
    weak var window: NSWindow?
    private var originalFrame: NSRect?
    private var isMaximized = false
    
    init(window: NSWindow) {
        self.window = window
        super.init()
        
        // Store original frame
        originalFrame = window.frame
        
        // Monitor window frame changes to update original frame when user manually resizes
        Foundation.NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }
    
    @objc private func windowDidResize(_ notification: Foundation.Notification) {
        // Only update original frame if we're not currently maximized
        // This allows the user to manually resize and have that become the new "original"
        if !isMaximized, let window = window {
            originalFrame = window.frame
        }
    }
    
    func toggleFullScreen() {
        guard let window = window else { return }
        
        // Use native macOS fullscreen API
        window.toggleFullScreen(nil)
    }
    
    deinit {
        Foundation.NotificationCenter.default.removeObserver(self)
    }
}
