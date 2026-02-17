//
//  SimianPostWindowManager.swift
//  MediaDash
//
//  Opens the Post to Simian window: search Simian, pick project/folder, choose local folder.
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
        window.title = "Post to Simian"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        simianPostWindow = window
        isVisible = true
    }

    func close() {
        simianPostWindow?.close()
    }

    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        simianPostWindow = nil
    }
}
