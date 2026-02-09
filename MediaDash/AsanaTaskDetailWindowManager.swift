//
//  AsanaTaskDetailWindowManager.swift
//  MediaDash
//
//  Opens the Asana task detail in a separate, resizable window so size stays
//  consistent and the user can drag and resize it.
//

import SwiftUI
import AppKit

@MainActor
final class AsanaTaskDetailWindowManager: NSObject, NSWindowDelegate {
    static let shared = AsanaTaskDetailWindowManager()

    private var taskWindow: NSWindow?
    private var onDismiss: (() -> Void)?

    private override init() {
        super.init()
    }

    func show(
        item: TaskDetailSheetItem,
        asanaService: AsanaService,
        config: AppConfig?,
        settingsManager: SettingsManager,
        cacheManager: AsanaCacheManager,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss

        let rootView = AsanaTaskDetailView(
            taskGid: item.taskGid,
            taskName: item.taskName,
            asanaService: asanaService,
            onDismiss: { [weak self] in
                self?.close()
            },
            config: config,
            settingsManager: settingsManager,
            cacheManager: cacheManager
        )
        .environmentObject(settingsManager)

        let hostingController = NSHostingController(rootView: rootView)
        let contentRect = NSRect(x: 0, y: 0, width: 720, height: 620)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = item.taskName ?? "Task"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 400)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        taskWindow = window
    }

    func close() {
        taskWindow?.close()
    }

    nonisolated func windowWillClose(_ notification: Foundation.Notification) {
        Task { @MainActor in
            onDismiss?()
            onDismiss = nil
            taskWindow = nil
        }
    }
}
