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
        _ = FileLogger.shared
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
            }
        }
    }
    
    private func configureAllWindows() {
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                configureWindow(window)
            }
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Disable resizing - fixed size for compact mode only
        window.styleMask.remove(.resizable)
        window.toolbar = nil
        // Set content view to extend into title bar area
        window.contentView?.wantsLayer = true
        // Keep window buttons but ensure they don't affect layout
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Set fixed window size (compact mode only)
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
                configureWindow(window)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-configure on update
        DispatchQueue.main.async {
            if let window = nsView.window {
                configureWindow(window)
            }
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Disable resizing - fixed size for compact mode only
        window.styleMask.remove(.resizable)
        window.toolbar = nil
        window.contentView?.wantsLayer = true
        // Set fixed window size (compact mode only)
        let fixedSize = NSSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.setContentSize(fixedSize)
        window.setContentBorderThickness(0, for: .minY)
        window.invalidateShadow()
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
    
    override func layout() {
        super.layout()
        // Update tracking area when layout changes
        if let window = window {
            setupDoubleClickHandler(window)
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
        
        if isMaximized {
            // Restore to original frame
            if let original = originalFrame {
                window.setFrame(original, display: true, animate: true)
                isMaximized = false
            }
        } else {
            // Store current frame as original before maximizing
            originalFrame = window.frame
            
            // Maximize to screen (non-exclusive full screen)
            if let screen = window.screen {
                let screenFrame = screen.visibleFrame
                window.setFrame(screenFrame, display: true, animate: true)
                isMaximized = true
            }
        }
    }
    
    deinit {
        Foundation.NotificationCenter.default.removeObserver(self)
    }
}
