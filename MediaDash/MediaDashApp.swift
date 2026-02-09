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
        .windowResizability(.contentMinSize) // Resizable with minimum size
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
            
            // View Menu
            CommandMenu("View") {
                DebugFeaturesToggleButton()
                
                Divider()
                
                CreateTestDocketButton()
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
    /// The main app window (set by WindowAccessor in GatekeeperView). Only this window is non-resizable.
    static weak var mainAppWindow: NSWindow?

    /// Configures a window with the standard MediaDash appearance and behavior.
    /// Main app window: not resizable. Other windows: resizable with a minimum size.
    static func configureWindow(_ window: NSWindow) {
        let isMainAppWindow = (window === mainAppWindow)
        var styleMask = window.styleMask
        if isMainAppWindow {
            styleMask.remove(.resizable)
            window.showsResizeIndicator = false
        } else {
            styleMask.insert(.resizable)
            window.showsResizeIndicator = true
        }
        window.styleMask = styleMask

        // Delegate enforces minimum size only (allows any size >= minSize)
        if window.delegate == nil || !(window.delegate is MinSizeWindowDelegate) {
            window.delegate = MinSizeWindowDelegate.shared
            MinSizeWindowDelegate.shared.registerWindow(window)
        }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        if !isMainAppWindow && !styleMask.contains(.resizable) {
            styleMask = window.styleMask
            styleMask.insert(.resizable)
            window.styleMask = styleMask
        }

        window.toolbar = nil
        window.contentView?.wantsLayer = true
        window.backgroundColor = NSColor.windowBackgroundColor
        
        // Restore standard window shadow
        window.hasShadow = true

        // Remove custom border outline
        window.contentView?.layer?.borderWidth = 0
        window.contentView?.layer?.borderColor = nil
        window.contentView?.layer?.cornerRadius = 0

        // Keep window buttons visible; hide zoom (maximize) on main window only
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        let isMainWindow = (window === NSApplication.shared.mainWindow)
        window.standardWindowButton(.zoomButton)?.isHidden = isMainWindow

        // Enable fullscreen support
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]

        // Set up fullscreen observers
        setupFullscreenObserverForDashboard(window)

        // All windows: same minimum as main window (no smaller); no maximum (infinitely resizable)
        let minSize = NSSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
        window.minSize = minSize
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Ensure current content size is at least min (don't force a fixed size)
        let current = window.frame.size
        if current.width < minSize.width || current.height < minSize.height {
            var frame = window.frame
            frame.size.width = max(current.width, minSize.width)
            frame.size.height = max(current.height, minSize.height)
            window.setFrame(frame, display: true, animate: false)
        }

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

// Window delegate that enforces minimum size only (allows resizing above minimum)
class MinSizeWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MinSizeWindowDelegate()
    private var registeredWindows: [NSWindow] = []
    
    func registerWindow(_ window: NSWindow) {
        if !registeredWindows.contains(where: { $0 === window }) {
            registeredWindows.append(window)
            window.delegate = self
        }
    }
    
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minSize = sender.minSize
        return NSSize(
            width: max(frameSize.width, minSize.width),
            height: max(frameSize.height, minSize.height)
        )
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
            
            // Set minimum size for the mode; only resize window if currently smaller
            DispatchQueue.main.async {
                if let window = NSApplication.shared.windows.first {
                    let minSize: NSSize
                    if mode == .dashboard {
                        minSize = NSSize(width: LayoutMode.dashboardMinWidth, height: LayoutMode.dashboardMinHeight)
                    } else {
                        minSize = NSSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
                    }
                    window.minSize = minSize
                    window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    var frame = window.frame
                    let needWidth = frame.size.width < minSize.width
                    let needHeight = frame.size.height < minSize.height
                    if needWidth || needHeight {
                        frame.size.width = max(frame.size.width, minSize.width)
                        frame.size.height = max(frame.size.height, minSize.height)
                        window.setFrame(frame, display: true, animate: true)
                    }
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

// MARK: - Debug Features Toggle Button

struct DebugFeaturesToggleButton: View {
    @State private var isEnabled = false
    
    var body: some View {
        Button(action: {
            toggleDebugFeatures()
            // Update state immediately after toggle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                updateState()
            }
        }) {
            Text(isEnabled ? "✓ Show Debug Features" : "Show Debug Features")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .onAppear {
            updateState()
        }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name("DebugFeaturesToggled"))) { notification in
            // Update state when notification is received
            if let newValue = notification.userInfo?["showDebugFeatures"] as? Bool {
                isEnabled = newValue
            } else {
                updateState()
            }
        }
    }
    
    private func updateState() {
        Task { @MainActor in
            isEnabled = isDebugFeaturesEnabled()
        }
    }
}

// MARK: - Create Test Docket Button

struct CreateTestDocketButton: View {
    var body: some View {
        Button("Create Test Docket Notification") {
            createTestDocketNotification()
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        // Always enabled - if you're in the View menu, debug mode is available
    }
}

// MARK: - Debug Features Helpers

/// Toggle debug features on/off
private func toggleDebugFeatures() {
    Task { @MainActor in
        let userDefaults = UserDefaults.standard
        let currentProfileKey = "currentProfile"
        let profilesKey = "savedProfiles"
        
        // Debug: Check what we have
        let profileName = userDefaults.string(forKey: currentProfileKey) ?? "Default"
        print("🔍 DebugFeatures: Profile name from UserDefaults: \(profileName)")
        
        guard let profilesData = userDefaults.data(forKey: profilesKey) else {
            print("⚠️ DebugFeatures: No profiles data found in UserDefaults")
            return
        }
        
        print("🔍 DebugFeatures: Found profiles data, size: \(profilesData.count) bytes")
        
        guard var profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData) else {
            print("⚠️ DebugFeatures: Failed to decode profiles data")
            if let jsonString = String(data: profilesData, encoding: .utf8) {
                print("   Data preview: \(String(jsonString.prefix(200)))")
            }
            return
        }
        
        print("🔍 DebugFeatures: Decoded profiles, keys: \(profiles.keys.joined(separator: ", "))")
        
        guard var currentProfile = profiles[profileName] else {
            print("⚠️ DebugFeatures: Profile '\(profileName)' not found in profiles")
            print("   Available profiles: \(profiles.keys.joined(separator: ", "))")
            // Try to use "Default" as fallback
            if let defaultProfile = profiles["Default"] {
                print("   Using 'Default' profile as fallback")
                var defaultProfile = defaultProfile
                defaultProfile.showDebugFeatures.toggle()
                profiles["Default"] = defaultProfile
                
                if let encoded = try? JSONEncoder().encode(profiles) {
                    userDefaults.set(encoded, forKey: profilesKey)
                    userDefaults.synchronize()
                    
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    
                    Foundation.NotificationCenter.default.post(
                        name: Foundation.Notification.Name("DebugFeaturesToggled"),
                        object: nil,
                        userInfo: ["showDebugFeatures": defaultProfile.showDebugFeatures]
                    )
                }
            }
            return
        }
        
        // Toggle the debug features setting
        let newValue = !currentProfile.showDebugFeatures
        currentProfile.showDebugFeatures = newValue
        profiles[profileName] = currentProfile
        
        // Save back to UserDefaults
        if let encoded = try? JSONEncoder().encode(profiles) {
            userDefaults.set(encoded, forKey: profilesKey)
            userDefaults.synchronize() // Force immediate write
            print("✅ DebugFeatures: Toggled to \(newValue)")
        } else {
            print("⚠️ DebugFeatures: Failed to encode profiles")
            return
        }
        
        // Small delay to ensure UserDefaults is written
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        
        // Post notification to update UI - include the new value in userInfo
        Foundation.NotificationCenter.default.post(
            name: Foundation.Notification.Name("DebugFeaturesToggled"),
            object: nil,
            userInfo: ["showDebugFeatures": newValue]
        )
    }
}

/// Check if debug features are enabled
private func isDebugFeaturesEnabled() -> Bool {
    let userDefaults = UserDefaults.standard
    let currentProfileKey = "currentProfile"
    let profilesKey = "savedProfiles"
    
    guard let profileName = userDefaults.string(forKey: currentProfileKey),
          let profilesData = userDefaults.data(forKey: profilesKey),
          let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData),
          let currentProfile = profiles[profileName] else {
        return false
    }
    
    return currentProfile.showDebugFeatures
}

/// Create a test docket notification via notification system
private func createTestDocketNotification() {
    print("🔔 Creating test docket notification from menu...")
    // Post a notification that DesktopLayoutView can listen to
    Foundation.NotificationCenter.default.post(
        name: Foundation.Notification.Name("CreateTestDocketNotification"),
        object: nil
    )
    print("🔔 Notification posted")
}

// Helper view to configure window appearance and handle double-click to full screen
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = TitleBarDoubleClickView()
        DispatchQueue.main.async {
            if let window = view.window {
                WindowConfiguration.mainAppWindow = window
                WindowConfiguration.configureWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-configure on update (main window only)
        DispatchQueue.main.async {
            if let window = nsView.window {
                WindowConfiguration.mainAppWindow = window
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
