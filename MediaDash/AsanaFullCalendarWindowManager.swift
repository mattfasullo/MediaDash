//
//  AsanaFullCalendarWindowManager.swift
//  MediaDash
//
//  Opens the full Asana calendar (2-week forward + 2-day lookback) in a separate window.
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class AsanaFullCalendarWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AsanaFullCalendarWindowManager()

    @Published private(set) var isVisible = false
    private var calendarWindow: NSWindow?

    private override init() {
        super.init()
    }

    func show(cacheManager: AsanaCacheManager, settingsManager: SettingsManager, onPrepElements: ((DocketInfo) -> Void)? = nil) {
        if let existingWindow = calendarWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isVisible = true
            return
        }

        let rootView = AsanaFullCalendarView(
            cacheManager: cacheManager,
            onClose: { [weak self] in
                self?.close()
            },
            onPrepElements: onPrepElements
        )
        .environmentObject(settingsManager)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 640)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Asana Calendar"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        calendarWindow = window
        isVisible = true
    }

    func close() {
        calendarWindow?.close()
    }

    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        calendarWindow = nil
    }
}
