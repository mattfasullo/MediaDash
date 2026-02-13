//
//  DownloadPromptManager.swift
//  MediaDash
//
//  Watches the Downloads folder and shows a top-right popup asking if the user
//  wants to stage the downloaded file in MediaDash.
//

import SwiftUI
import AppKit
import Foundation

/// Notification when user chooses an action for a downloaded file.
/// userInfo["url"] = URL of the file to add to staging.
/// userInfo["intent"] = optional String: "file" | "prep" | "demo" — which flow to start after staging.
enum DownloadPromptNotification {
    static let addToStaging = Foundation.Notification.Name("MediaDashAddDownloadToStaging")
}

final class DownloadPromptManager {
    static let shared = DownloadPromptManager()
    
    private var checkTimer: Timer?
    private var promptedPaths: Set<String> = []
    private var popupWindow: NSWindow?
    private let checkInterval: TimeInterval = 2.5
    private let fileMaxAge: TimeInterval = 20  // Only prompt for files modified in last 20 sec
    private let downloadExtensionsToSkip = ["crdownload", "part", "download", "tmp", "temp"]
    
    private init() {}
    
    func startWatching() {
        guard checkTimer == nil else { return }
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkDownloadsFolder()
        }
        checkTimer?.tolerance = 0.5
        RunLoop.main.add(checkTimer!, forMode: .common)
    }
    
    func stopWatching() {
        checkTimer?.invalidate()
        checkTimer = nil
        hidePopup()
    }
    
    private var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }
    
    private func checkDownloadsFolder() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.checkDownloadsFolder() }
            return
        }
        guard let downloadsURL = downloadsDirectory else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: downloadsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        
        let now = Date()
        let cutoff = now.addingTimeInterval(-fileMaxAge)
        
        let candidates = contents.compactMap { url -> (URL, Date)? in
            let path = url.path
            let ext = (path as NSString).pathExtension.lowercased()
            guard downloadExtensionsToSkip.contains(ext) == false else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mod = values.contentModificationDate,
                  mod >= cutoff else { return nil }
            return (url, mod)
        }
        
        guard let newest = candidates.sorted(by: { $0.1 > $1.1 }).first else { return }
        let path = newest.0.path
        guard !promptedPaths.contains(path) else { return }
        
        promptedPaths.insert(path)
        showPopup(fileURL: newest.0)
    }
    
    private func showPopup(fileURL: URL) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.showPopup(fileURL: fileURL) }
            return
        }
        hidePopup()
        
        let filename = fileURL.lastPathComponent
        let urlToSend = fileURL
        let view = DownloadPromptView(
            filename: filename,
            onSelect: { [weak self] intent in
                self?.hidePopup()
                var userInfo: [String: Any] = ["url": urlToSend]
                if let intent = intent {
                    userInfo["intent"] = intent
                }
                Foundation.NotificationCenter.default.post(
                    name: DownloadPromptNotification.addToStaging,
                    object: nil as Any?,
                    userInfo: userInfo
                )
            },
            onDismiss: { [weak self] in
                self?.hidePopup()
            }
        )
        let controller = NSHostingController(rootView: view)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isOpaque = true
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.isReleasedWhenClosed = false
        window.title = "MediaDash Download"
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false
        
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let margin: CGFloat = 20
            let w: CGFloat = 340
            let h: CGFloat = 130
            let x = screenFrame.maxX - w - margin
            let y = screenFrame.maxY - h - margin
            window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }
        
        popupWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    
    private func hidePopup() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.hidePopup() }
            return
        }
        popupWindow?.close()
        popupWindow = nil
    }
    
    deinit {
        // Safety net: ensure timer is invalidated if manager is deallocated
        checkTimer?.invalidate()
        checkTimer = nil
        hidePopup()
    }
}

// MARK: - Popup view

private struct DownloadPromptView: View {
    let filename: String
    /// intent: "file" | "prep" | "demo" — which flow to start. Nil = just stage.
    let onSelect: (String?) -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What is this?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
            Text(filename)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Button("File") {
                    onSelect("file")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Stage and file to Work Picture")
                Button("Prep") {
                    onSelect("prep")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Stage and select a session to prep")
                Button("Demo") {
                    onSelect("demo")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Stage and associate with a Demos task")
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
