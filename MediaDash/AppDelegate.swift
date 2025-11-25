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
        
        // Clear Sparkle's cache to force it to re-fetch the feed
        let fileManager = FileManager.default
        let cacheURLs = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        
        if let cacheURL = cacheURLs.first {
            // Clear global Sparkle cache
            let sparkleCache = cacheURL.appendingPathComponent("org.sparkle-project.Sparkle")
            if fileManager.fileExists(atPath: sparkleCache.path) {
                try? fileManager.removeItem(at: sparkleCache)
                print("   ✓ Cleared global Sparkle cache")
            }
            
            // Clear app-specific Sparkle cache
            let bundleID = Bundle.main.bundleIdentifier ?? "mattfasullo.MediaDash"
            let appSparkleCache = cacheURL.appendingPathComponent(bundleID).appendingPathComponent("org.sparkle-project.Sparkle")
            if fileManager.fileExists(atPath: appSparkleCache.path) {
                try? fileManager.removeItem(at: appSparkleCache)
                print("   ✓ Cleared app Sparkle cache")
            }
        }
        
        // Force Sparkle to re-check with the new feed URL by recreating the updater
        // This ensures it picks up the new channel from UserDefaults
        let oldController = updaterController
        updaterController = nil
        
        // Give Sparkle time to clean up
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("   Creating new updater controller...")
            self.updaterController = SPUStandardUpdaterController(
                startingUpdater: false, // Don't auto-start, we'll check manually
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            
            print("   ✓ Updater controller created with delegate")
            
            // Now check for updates with the new feed URL
            // Give it a moment to ensure everything is initialized
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                print("   🔍 Checking for updates with new channel...")
                if let controller = self.updaterController {
                    controller.checkForUpdates(nil)
                } else {
                    print("   ❌ ERROR: Updater controller is nil!")
                }
            }
        }
    }
    
    // Allow CMD+Q to quit even when modals/popups are shown
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always allow termination, even when alerts or sheets are displayed
        return .terminateNow
    }
}
