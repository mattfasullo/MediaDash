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
    private var cacheSyncStatusItem: CacheSyncStatusItem?

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
    
    func applicationWillFinishLaunching(_ notification: Foundation.Notification) {
        // Migrate keychain items BEFORE views initialize
        // This is critical after Sparkle updates where code signature changes
        // cause macOS to treat the new version as a different app
        // Running here ensures migration completes before any @StateObject
        // properties in SwiftUI views can access keychain
        KeychainService.migrateAllExistingItems()
    }

    func applicationDidFinishLaunching(_ aNotification: Foundation.Notification) {
        // #region agent log
        let logData: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "post-fix",
            "hypothesisId": "A",
            "location": "AppDelegate.swift:applicationDidFinishLaunching",
            "message": "App launch - migration starting",
            "data": [
                "timestamp": Date().timeIntervalSince1970,
                "thread": Thread.current.name ?? "main"
            ],
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let json = try? JSONSerialization.data(withJSONObject: logData),
           let jsonString = String(data: json, encoding: .utf8) {
            if let fileHandle = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                fileHandle.seekToEndOfFile()
                fileHandle.write((jsonString + "\n").data(using: .utf8)!)
                fileHandle.closeFile()
            } else {
                try? (jsonString + "\n").write(toFile: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log", atomically: true, encoding: .utf8)
            }
        }
        // #endregion
        // Keychain migration now happens in applicationWillFinishLaunching
        // which runs before SwiftUI views initialize, ensuring migration completes
        // before any @StateObject properties can access keychain
        
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
                WindowConfiguration.configureWindow(window)
            }
        }

        // Configure windows when they become key
        Foundation.NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                WindowConfiguration.configureWindow(window)
            }
        }

        // Configure windows when they become main
        Foundation.NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                WindowConfiguration.configureWindow(window)
            }
        }

        // Initialize floating progress window manager (it auto-shows/hides based on FloatingProgressManager.shared.isVisible)
        _ = FloatingProgressWindowManager.shared
        
        // Initialize cache sync status item (menu bar icon)
        Task { @MainActor in
            let cacheSyncService = CacheSyncServiceManager()
            cacheSyncService.checkStatus()
            self.cacheSyncStatusItem = CacheSyncStatusItem(cacheSyncService: cacheSyncService)
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
    
    func applicationWillTerminate(_ aNotification: Foundation.Notification) {
        // Clean up event monitor
        if let monitor = quitEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
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
