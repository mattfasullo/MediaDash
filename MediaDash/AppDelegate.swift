//
//  AppDelegate.swift
//  MediaDash
//
//  Created by Matt Fasullo on 2025-11-20.
//

import Cocoa
import SwiftUI
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    private var updaterController: SPUStandardUpdaterController!
    private var quitEventMonitor: Any?

    private var currentUpdateChannel: UpdateChannel {
        // Check if this is a dev build (MediaDash-Dev bundle ID)
        let isDevBuild = Bundle.main.bundleIdentifier == "mattfasullo.MediaDash-Dev"
        
        // Dev builds should ALWAYS use the dev channel, regardless of user settings
        // This ensures dev builds check the correct appcast
        if isDevBuild {
            return .development
        }
        
        // For production builds, respect user's channel preference
        if let settingsData = UserDefaults.standard.data(forKey: "savedProfiles"),
           let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: settingsData),
           let currentProfileName = UserDefaults.standard.string(forKey: "currentProfile"),
           let profile = profiles[currentProfileName] {
            return profile.updateChannel
        }
        return .production // Default for production builds
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Sparkle updater
        // Each app (MediaDash vs MediaDash-Dev) has its own appcast URL in Info.plist
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        
        // Set up global CMD+Q handler that works even when sheets/modals are open
        setupGlobalQuitHandler()
        
        // Configure all existing windows immediately
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                self.configureWindow(window)
            }
        }
        
        // Configure windows when they become key
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                self.configureWindow(window)
            }
        }
        
        // Configure windows when they become main
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                self.configureWindow(window)
            }
        }
    }
    
    private func setupGlobalQuitHandler() {
        // Monitor local events to catch CMD+Q even when sheets/modals are open
        // This intercepts the key event before SwiftUI can block it
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Check for CMD+Q
            if event.modifierFlags.contains(.command) && 
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                // Force quit immediately
                NSApplication.shared.terminate(nil)
                return nil // Consume the event so it doesn't propagate
            }
            return event
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up event monitor
        if let monitor = quitEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.contentView?.wantsLayer = true
        // Set content border thickness to 0 to remove any grey bar
        window.setContentBorderThickness(0, for: .minY)
        // Keep window buttons visible for functionality
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        // Force window update
        window.invalidateShadow()
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
    
    // Allow CMD+Q to quit even when modals/popups are shown
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always allow termination, even when alerts or sheets are displayed
        return .terminateNow
    }
}
