//
//  SimianPostWindowManager.swift
//  MediaDash
//
//  Opens the Simian window: search projects, pick folder, choose local folder and post.
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class SimianPostWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SimianPostWindowManager()

    @Published private(set) var isVisible = false
    private var simianPostWindow: NSWindow?

    private override init() {
        super.init()
    }

    func show(settingsManager: SettingsManager, sessionManager: SessionManager, manager: MediaManager) {
        // Always open a fresh window: close existing one if present so state is reset
        if let existingWindow = simianPostWindow {
            existingWindow.close()
            simianPostWindow = nil
        }

        let rootView = SimianPostView()
            .environmentObject(settingsManager)
            .environmentObject(sessionManager)
            .environmentObject(manager)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 620)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Simian"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        simianPostWindow = window
        isVisible = true

        // Popover/sheet dismissal (e.g. Portal → Simian) can reclaim key on the same run loop; defer so this window wins.
        func activateSimianWindow() {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        activateSimianWindow()
        DispatchQueue.main.async {
            activateSimianWindow()
            DispatchQueue.main.async(execute: activateSimianWindow)
        }
    }

    func close() {
        simianPostWindow?.close()
    }

    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        simianPostWindow = nil
    }
}
