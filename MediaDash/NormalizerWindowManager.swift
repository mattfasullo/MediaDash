//
//  NormalizerWindowManager.swift
//  MediaDash
//
//  Auxiliary window for staging files and LUFS normalization.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class NormalizerWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = NormalizerWindowManager()

    @Published private(set) var isVisible = false
    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isVisible = true
            return
        }

        let rootView = NormalizerView()
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 480)

        let w = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "LUFS Normalizer"
        w.contentView = hostingView
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        window = w
        isVisible = true
    }

    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        window = nil
    }
}
