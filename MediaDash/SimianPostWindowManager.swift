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

        // Popover/sheet dismissal (e.g. Video → Simian) can reclaim key on the same run loop; defer so this window wins.
        func activateSimianWindow() {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // #region agent log
            let kw = NSApp.keyWindow
            appendSimianDebugA92964(
                location: "SimianPostWindowManager.activateSimianWindow",
                message: "after makeKeyAndOrderFront",
                hypothesisId: "H1_H5",
                data: [
                    "keyWindowIsSelf": kw === window,
                    "keyWindowTitle": kw?.title ?? "nil",
                    "mainWindowTitle": NSApp.mainWindow?.title ?? "nil"
                ]
            )
            // #endregion
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

    func windowDidBecomeKey(_ notification: Foundation.Notification) {
        // #region agent log
        appendSimianDebugA92964(
            location: "SimianPostWindowManager.windowDidBecomeKey",
            message: "Simian became key",
            hypothesisId: "H1_H5",
            data: [
                "keyWindowTitle": NSApp.keyWindow?.title ?? "nil",
                "mainWindowTitle": NSApp.mainWindow?.title ?? "nil"
            ]
        )
        // #endregion
    }

    func windowDidResignKey(_ notification: Foundation.Notification) {
        // #region agent log
        appendSimianDebugA92964(
            location: "SimianPostWindowManager.windowDidResignKey",
            message: "Simian resigned key",
            hypothesisId: "H1_H5",
            data: [
                "keyWindowTitle": NSApp.keyWindow?.title ?? "nil",
                "mainWindowTitle": NSApp.mainWindow?.title ?? "nil"
            ]
        )
        // #endregion
    }
}

// MARK: - Debug session a92964
// #region agent log
private func appendSimianDebugA92964(location: String, message: String, hypothesisId: String, data: [String: Any]) {
    let path = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-a92964.log"
    let payload: [String: Any] = [
        "sessionId": "a92964",
        "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
        "location": location,
        "message": message,
        "hypothesisId": hypothesisId,
        "data": data
    ]
    guard JSONSerialization.isValidJSONObject(payload),
          let json = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: json, encoding: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let h = FileHandle(forWritingAtPath: path) else { return }
    h.seekToEndOfFile()
    h.write(Data((line + "\n").utf8))
    h.closeFile()
}
// #endregion
