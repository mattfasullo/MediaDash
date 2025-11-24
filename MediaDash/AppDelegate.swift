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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Sparkle updater
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        
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
