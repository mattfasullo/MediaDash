//
//  AppDelegate.swift
//  MediaDash
//
//  Created by Matt Fasullo on 2025-11-20.
//

import Cocoa
import SwiftUI
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?
    private var quitEventMonitor: Any?

    private var currentUpdateChannel: UpdateChannel {
        if let settingsData = UserDefaults.standard.data(forKey: "savedProfiles"),
           let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: settingsData),
           let currentProfileName = UserDefaults.standard.string(forKey: "currentProfile"),
           let profile = profiles[currentProfileName] {
            return profile.updateChannel
        }
        return .production // Default
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Sparkle updater with delegate to support channel switching
        // Delayed initialization to ensure app is ready
        DispatchQueue.main.async {
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self, // Set delegate here
                userDriverDelegate: nil
            )
        }
        
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

    // MARK: - SPUUpdaterDelegate
    func feedURL(for updater: SPUUpdater) -> URL? {
        let channel = currentUpdateChannel
        guard let url = URL(string: channel.feedURL) else {
            print("❌ Invalid feed URL for channel: \(channel.displayName)")
            return URL(string: UpdateChannel.production.feedURL) // Fallback to production
        }
        print("ℹ️ Sparkle checking feed URL: \(url.absoluteString) (Channel: \(channel.displayName))")
        print("   Current app version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))")
        return url
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        guard let updater = updaterController else {
            print("⚠️ Updater not initialized yet")
            return
        }
        updater.checkForUpdates(sender)
    }
    
    func resetUpdaterForChannelChange() {
        print("🔄 Resetting updater for channel change...")
        let channel = currentUpdateChannel
        print("   New channel: \(channel.displayName)")
        print("   Feed URL: \(channel.feedURL)")
        
        // Force Sparkle to re-check with the new feed URL by recreating the updater
        // This ensures it picks up the new channel from UserDefaults
        guard let oldController = updaterController else {
            print("⚠️ No updater controller to reset")
            return
        }
        
        // Stop the old updater
        oldController.updater.stop()
        
        // Recreate with the new channel (will read from UserDefaults via delegate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            print("   Creating new updater controller...")
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            
            // Now check for updates with the new feed URL
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("   Checking for updates with new channel...")
                self.updaterController?.checkForUpdates(nil)
            }
        }
    }
    
    // Allow CMD+Q to quit even when modals/popups are shown
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always allow termination, even when alerts or sheets are displayed
        return .terminateNow
    }
}
