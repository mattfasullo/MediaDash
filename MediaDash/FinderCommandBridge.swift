//
//  FinderCommandBridge.swift
//  MediaDash
//
//  Queues Finder / URL-scheme commands until an editor session can apply them.
//

import AppKit
import Foundation

extension Foundation.Notification.Name {
    /// Posted on MainActor; userInfo: none (ContentView sets showVideoConverterSheet = true).
    static let mediaDashOpenVideoConverterSheet = Foundation.Notification.Name("mediaDashOpenVideoConverterSheet")

    /// New Finder / URL commands were queued; `AuthenticatedRootView` applies when UI is ready.
    static let mediaDashFinderCommandsPending = Foundation.Notification.Name("mediaDashFinderCommandsPending")
}

/// Actions delivered from Finder Sync or `mediadash://` URLs.
enum FinderIncomingAction: String, Codable, Sendable {
    case stage
    case convert
    case simian
    case audioOnly
}

/// JSON payload written by the Finder Sync extension (App Group) or parsed from URLs.
struct FinderCommandPayload: Codable, Sendable {
    let action: FinderIncomingAction
    let paths: [String]
}

@MainActor
final class FinderCommandBridge {
    static let shared = FinderCommandBridge()

    /// Shared with MediaDashFinderSync extension (must match entitlements).
    static let appGroupIdentifier = "group.mattfasullo.MediaDash"

    private let queueLock = NSLock()
    private var pendingPayloads: [FinderCommandPayload] = []

    private init() {}

    /// URL scheme for this build (prod vs MediaDash-Dev.app).
    static var primaryURLScheme: String {
        Bundle.main.bundleIdentifier == "mattfasullo.MediaDash-Dev" ? "mediadash-dev" : "mediadash"
    }

    // MARK: - Enqueue

    /// Handle `mediadash://` / `mediadash-dev://` URLs from the OS.
    func handleOpenURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "mediadash" || scheme == "mediadash-dev" else {
            return false
        }

        let host = (url.host ?? "").lowercased()
        if host == "finder" || host.isEmpty {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let tokenItem = components.queryItems?.first(where: { $0.name == "token" }),
               let tokenStr = tokenItem.value,
               let token = UUID(uuidString: tokenStr) {
                if let payload = loadPayloadFromSharedContainer(token: token) {
                    enqueue(payload)
                    return true
                }
            }
        }

        // Fallback: tiny selections via query (no token file)
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let actionItem = components.queryItems?.first(where: { $0.name == "action" })?.value,
           let action = FinderIncomingAction(rawValue: actionItem) {
            let paths = components.queryItems?.filter { $0.name == "path" }.compactMap(\.value) ?? []
            if !paths.isEmpty {
                enqueue(FinderCommandPayload(action: action, paths: paths))
                return true
            }
        }

        return false
    }

    func enqueue(_ payload: FinderCommandPayload) {
        queueLock.lock()
        pendingPayloads.append(payload)
        queueLock.unlock()
        Foundation.NotificationCenter.default.post(name: .mediaDashFinderCommandsPending, object: nil)
    }

    /// Drop all queued commands (e.g. Producer session).
    func clearPending() {
        queueLock.lock()
        pendingPayloads.removeAll()
        queueLock.unlock()
    }

    // MARK: - Apply (editor session only)

    /// Run queued commands using staging / Simian / video UI. Call after splash when `MediaManager` is ready.
    func applyPendingCommands(
        manager: MediaManager,
        settingsManager: SettingsManager,
        sessionManager: SessionManager
    ) {
        queueLock.lock()
        let batch = pendingPayloads
        pendingPayloads.removeAll()
        queueLock.unlock()

        guard !batch.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)

        for payload in batch {
            let urls = payload.paths.compactMap { path -> URL? in
                if path.isEmpty { return nil }
                return URL(fileURLWithPath: path)
            }
            guard !urls.isEmpty else { continue }

            switch payload.action {
            case .stage:
                manager.addFilesFromExternalURLs(urls)
            case .convert:
                manager.addFilesFromExternalURLs(urls)
                if manager.videoConverter == nil {
                    manager.videoConverter = VideoConverterManager()
                }
                Foundation.NotificationCenter.default.post(name: .mediaDashOpenVideoConverterSheet, object: nil)
            case .simian:
                manager.addFilesFromExternalURLs(urls)
                SimianPostWindowManager.shared.show(
                    settingsManager: settingsManager,
                    sessionManager: sessionManager,
                    manager: manager
                )
            case .audioOnly:
                AudioOnlyExportService.run(urls: urls)
            }
        }
    }

    // MARK: - Shared container (token files)

    private func finderPendingDirectory() -> URL? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) else {
            return nil
        }
        let dir = base.appendingPathComponent("finder-pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func loadPayloadFromSharedContainer(token: UUID) -> FinderCommandPayload? {
        guard let dir = finderPendingDirectory() else { return nil }
        let fileURL = dir.appendingPathComponent("\(token.uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(FinderCommandPayload.self, from: data)
    }
}
