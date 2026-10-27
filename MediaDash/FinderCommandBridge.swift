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

    /// Arrange Finals finished; userInfo `paths` is `[String]` of folder paths to refresh in staging.
    static let mediaDashRefreshStagedFolders = Foundation.Notification.Name("mediaDashRefreshStagedFolders")

    /// Finder File / Prep: show docket sheet. userInfo `action` is `file` or `prep`, `paths` is `[String]`.
    static let mediaDashFinderFileOrPrep = Foundation.Notification.Name("mediaDashFinderFileOrPrep")
}

/// Keep Arrange Finals in the background: bounce activation back to Finder.
enum FinderFocus {
    static var restoreFinderAfterActivation = false

    nonisolated static func shouldActivateApp(for batch: [FinderCommandPayload]) -> Bool {
        batch.contains { $0.action != .arrangeFinals }
    }

    static func beginBackgroundFinderAction() {
        restoreFinderAfterActivation = true
        activateFinder()
    }

    static func activateFinder() {
        NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" })?
            .activate(options: [.activateIgnoringOtherApps])
    }

    static func handleDidBecomeActive() {
        guard restoreFinderAfterActivation else { return }
        activateFinder()
    }

    static func handleDidResignActive() {
        restoreFinderAfterActivation = false
    }
}

/// Actions delivered from Finder Sync or `mediadash://` URLs.
nonisolated enum FinderIncomingAction: String, Codable, Sendable {
    case stage
    case convert
    case simian
    case audioOnly
    case editOnSimian
    case arrangeFinals
    case file
    case prep
}

/// JSON payload written by the Finder Sync extension (App Group) or parsed from URLs.
nonisolated struct FinderCommandPayload: Codable, Sendable {
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

    /// Remove and return queued payloads. Used by `applyPendingCommands` and tests.
    func dequeuePending() -> [FinderCommandPayload] {
        queueLock.lock()
        let batch = pendingPayloads
        pendingPayloads.removeAll()
        queueLock.unlock()
        return batch
    }

    /// Run queued commands using staging / Simian / video UI. Call after splash when `MediaManager` is ready.
    func applyPendingCommands(
        manager: MediaManager,
        settingsManager: SettingsManager,
        sessionManager: SessionManager
    ) {
        let batch = dequeuePending()

        guard !batch.isEmpty else { return }

        if FinderFocus.shouldActivateApp(for: batch) {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            FinderFocus.beginBackgroundFinderAction()
        }

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
            case .editOnSimian:
                Task {
                    await Self.openFoldersOnSimian(urls: urls, settingsManager: settingsManager)
                }
            case .arrangeFinals:
                Self.applyArrangeFinals(urls: urls, manager: manager)
            case .file, .prep:
                Foundation.NotificationCenter.default.post(
                    name: .mediaDashFinderFileOrPrep,
                    object: nil,
                    userInfo: [
                        "action": payload.action.rawValue,
                        "paths": payload.paths
                    ]
                )
            }
        }
    }

    static func applyArrangeFinals(urls: [URL], manager: MediaManager?) {
        Task.detached(priority: .userInitiated) {
            let prepared = FinalsFinderArrange.prepareRoots(from: urls)
            var arranged: [FinalsFinderArrange] = []
            var failures: [String] = prepared.moveFailures
            var emptyNames: [String] = []
            var arrangedURLs: [URL] = []

            for root in prepared.roots {
                switch FinalsFinderArrange.run(url: root) {
                case .skippedNotDirectory:
                    continue
                case .empty:
                    emptyNames.append(root.lastPathComponent)
                case .arranged(let fileCount, let folderName):
                    arranged.append(.arranged(fileCount: fileCount, folderName: folderName))
                    arrangedURLs.append(root)
                case .failed(let message):
                    failures.append("\(root.lastPathComponent): \(message)")
                }
            }

            await MainActor.run {
                if !arrangedURLs.isEmpty {
                    if let manager {
                        for url in arrangedURLs {
                            manager.refreshStagedFolder(url: url)
                        }
                    }
                    Foundation.NotificationCenter.default.post(
                        name: .mediaDashRefreshStagedFolders,
                        object: nil,
                        userInfo: ["paths": arrangedURLs.map(\.path)]
                    )
                }

                if !failures.isEmpty {
                    NotificationService.shared.showBanner(
                        title: "Arrange Finals Failed",
                        body: failures.joined(separator: "\n")
                    )
                }

                if arranged.isEmpty, failures.isEmpty, !emptyNames.isEmpty {
                    NotificationService.shared.showBanner(
                        title: "Arrange Finals",
                        body: "No classifiable files in \(emptyNames.joined(separator: ", "))"
                    )
                } else if !arranged.isEmpty {
                    let total = arranged.reduce(0) { sum, item in
                        if case .arranged(let count, _) = item { return sum + count }
                        return sum
                    }
                    let names = arranged.compactMap { item -> String? in
                        if case .arranged(_, let name) = item { return name }
                        return nil
                    }
                    NotificationService.shared.showBanner(
                        title: "Finals arranged",
                        body: "Moved \(total) file\(total == 1 ? "" : "s") in \(names.joined(separator: ", "))"
                    )
                }

                FinderFocus.beginBackgroundFinderAction()
            }
        }
    }

    // MARK: - Edit on Simian

    /// Look up each URL's folder name in the Simian project list and open the best match in the browser.
    private static func openFoldersOnSimian(urls: [URL], settingsManager: SettingsManager) async {
        let service = SimianService()
        do {
            let projects = try await service.getProjectList()
            for url in urls {
                let folderURL = isDirectory(url) ? url : url.deletingLastPathComponent()
                let folderName = folderURL.lastPathComponent
                if let match = bestSimianProject(for: folderName, in: projects),
                   let webURL = SimianService.folderLinkURL(projectId: match.id, folderId: nil) {
                    _ = await MainActor.run { NSWorkspace.shared.open(webURL) }
                } else {
                    // Fallback: open the Simian projects list
                    let fallback = URL(string: "https://graysonmusic.gosimian.com/simian/projects")!
                    _ = await MainActor.run { NSWorkspace.shared.open(fallback) }
                }
            }
        } catch {
            let fallback = URL(string: "https://graysonmusic.gosimian.com/simian/projects")!
            _ = await MainActor.run { NSWorkspace.shared.open(fallback) }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Returns the first project whose name contains the folder name (case-insensitive),
    /// or falls back to the first project whose name shares the leading numeric docket portion.
    private static func bestSimianProject(for folderName: String, in projects: [SimianProject]) -> SimianProject? {
        let lower = folderName.lowercased()
        if let exact = projects.first(where: { $0.name.lowercased() == lower }) { return exact }
        if let contains = projects.first(where: { $0.name.lowercased().contains(lower) }) { return contains }
        // Try matching by numeric prefix (docket number)
        let numeric = lower.prefix(while: { $0.isNumber })
        guard !numeric.isEmpty else { return nil }
        return projects.first(where: { $0.name.lowercased().hasPrefix(numeric) })
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
