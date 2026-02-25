//
//  AsanaTaskDetailWindowManager.swift
//  MediaDash
//
//  Opens the Asana task detail in a separate, resizable window so size stays
//  consistent and the user can drag and resize it.
//  Re-opening the same task brings the existing window to front instead of duplicating.
//

import SwiftUI
import AppKit

private struct TaskWindowInfo {
    let window: NSWindow
    var onDismiss: (() -> Void)?
}

@MainActor
final class AsanaTaskDetailWindowManager: NSObject, NSWindowDelegate {
    static let shared = AsanaTaskDetailWindowManager()

    private var windowsByTaskGid: [String: TaskWindowInfo] = [:]

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
        let gid = item.taskGid

        // If we already have a window for this task, bring it to front instead of opening a duplicate.
        if let info = windowsByTaskGid[gid] {
            info.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = AsanaTaskDetailView(
            taskGid: item.taskGid,
            taskName: item.taskName,
            asanaService: asanaService,
            onDismiss: { [weak self] in
                self?.close(taskGid: gid)
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
        window.identifier = NSUserInterfaceItemIdentifier(gid)
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 400)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        windowsByTaskGid[gid] = TaskWindowInfo(window: window, onDismiss: onDismiss)
    }

    func close(taskGid: String? = nil) {
        if let gid = taskGid {
            windowsByTaskGid[gid]?.window.close()
        } else {
            windowsByTaskGid.values.forEach { $0.window.close() }
        }
    }

    nonisolated func windowWillClose(_ notification: Foundation.Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            let gid = window.identifier?.rawValue
            if let gid = gid, let info = self.windowsByTaskGid[gid] {
                info.onDismiss?()
                self.windowsByTaskGid.removeValue(forKey: gid)
            }
        }
    }
}
