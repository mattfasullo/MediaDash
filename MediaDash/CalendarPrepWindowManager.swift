//
//  CalendarPrepWindowManager.swift
//  MediaDash
//
//  Opens Prep from Calendar in its own window (like Asana Calendar / New Dockets).
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class CalendarPrepWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CalendarPrepWindowManager()

    @Published private(set) var isVisible = false
    private var prepWindow: NSWindow?

    private override init() {
        super.init()
    }

    func show(session: DocketInfo, asanaService: AsanaService, manager: MediaManager) {
        if let existing = prepWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isVisible = true
            return
        }

        var isPresented = true
        let rootView = SessionPrepElementsSheet(
            session: session,
            asanaService: asanaService,
            manager: manager,
            isPresented: Binding(
                get: { isPresented },
                set: { new in
                    isPresented = new
                    if !new {
                        CalendarPrepWindowManager.shared.close()
                    }
                }
            )
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 680)

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Prep from Calendar — \(session.fullName)"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        prepWindow = window
        isVisible = true
    }

    func close() {
        prepWindow?.close()
    }

    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        prepWindow = nil
    }
}
