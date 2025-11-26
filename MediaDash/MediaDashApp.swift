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

    var body: some Scene {
        WindowGroup {
            GatekeeperView()
                .background(WindowAccessor())
                .onAppear {
                    configureAllWindows()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
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
        window.toolbar = nil
        // Set content view to extend into title bar area
        window.contentView?.wantsLayer = true
        // Remove any title bar buttons if needed (but keep them for functionality)
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // Force window to update
        window.invalidateShadow()
        // Set content layout rect to extend to top
        window.setContentBorderThickness(0, for: .minY)
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

// Helper view to configure window appearance
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
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
        window.toolbar = nil
        window.contentView?.wantsLayer = true
        window.setContentBorderThickness(0, for: .minY)
        window.invalidateShadow()
    }
}
