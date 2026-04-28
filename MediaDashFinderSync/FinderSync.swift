//
//  FinderSync.swift
//  MediaDashFinderSync
//

import Cocoa
import FinderSync
import os

/// JSON shape must match `FinderCommandPayload` in the main app.
private struct FinderHandoffPayload: Codable {
    let action: String
    let paths: [String]
}

private let kAppGroup = "group.mattfasullo.MediaDash"

// #region agent log
/// Same mirror path as `AppDelegate` so Cursor ingest file lists extension lines (appex is not sandboxed).
private let kMediaDashDebugLogMirrorPath = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-55b33e.log"

private let kInstrumentLogger = Logger(subsystem: "mattfasullo.MediaDash.FinderSync", category: "debugSession55b33e")

private func appendDebugPayload(_ payload: Data, toFilePath path: String) {
    let dirURL = URL(fileURLWithPath: path).deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: path) {
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(payload)
            try? h.close()
        }
    } else {
        try? payload.write(to: URL(fileURLWithPath: path))
    }
}

/// Primary: App Group. Secondary: mirror to repo `.cursor/` (same as main app) for one-file review.
private func mediaDashDebugNDJSON(location: String, message: String, hypothesisId: String, data: [String: String] = [:]) {
    let dict: [String: Any] = [
        "sessionId": "55b33e",
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        "location": location,
        "message": message,
        "hypothesisId": hypothesisId,
        "runId": "pre-fix",
        "data": data
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: dict),
          let line = String(data: json, encoding: .utf8) else { return }
    let payload = (line + "\n").data(using: .utf8) ?? Data()
    if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup) {
        appendDebugPayload(payload, toFilePath: base.appendingPathComponent("debug-55b33e.log").path)
    }
    appendDebugPayload(payload, toFilePath: kMediaDashDebugLogMirrorPath)
}
// #endregion

@objc(MediaDashFinderSyncPrincipal)
final class MediaDashFinderSyncPrincipal: FIFinderSync {
    override init() {
        super.init()
        // #region agent log
        let hostPath = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        let groupLog = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup)?
            .appendingPathComponent("debug-55b33e.log").path ?? ""
        mediaDashDebugNDJSON(location: "FinderSync.swift:init", message: "FinderSync extension principal initialized", hypothesisId: "A", data: ["hostAppPath": hostPath, "appexBundleID": Bundle.main.bundleIdentifier ?? "", "groupDebugLogPath": groupLog])
        kInstrumentLogger.info("FinderSync init (session 55b33e) host=\(hostPath, privacy: .public)")
        // #endregion
        // Required so Finder delivers `menuForMenuKind` / `selectedItemURLs` for items under these roots.
        // `/` is not a supported watch root; recent macOS silently drops the whole set when it's present.
        // Register user-visible roots instead; add more specific paths here as MediaDash tracks them via the App Group.
        FIFinderSyncController.default().directoryURLs = Set([
            URL(fileURLWithPath: "/Users"),
            URL(fileURLWithPath: "/Volumes")
        ])
    }

    private static var controller: FIFinderSyncController {
        FIFinderSyncController.default()
    }

    private static var urlSchemeForHostApp: String {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent() // PlugIns
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // MyApp.app
        return appURL.lastPathComponent.contains("MediaDash-Dev") ? "mediadash-dev" : "mediadash"
    }

    private func writePayloadAndOpenURL(action: String, paths: [String]) {
        guard !paths.isEmpty else { return }
        let payload = FinderHandoffPayload(action: action, paths: paths)
        guard let token = Self.writeHandoffJSON(payload) else { return }
        let scheme = Self.urlSchemeForHostApp
        guard let url = URL(string: "\(scheme)://finder?token=\(token.uuidString)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func writeHandoffJSON(_ payload: FinderHandoffPayload) -> UUID? {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup) else {
            return nil
        }
        let dir = base.appendingPathComponent("finder-pending", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let token = UUID()
        let fileURL = dir.appendingPathComponent("\(token.uuidString).json")
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            return token
        } catch {
            return nil
        }
    }

    @objc private func stage(_ sender: Any?) {
        let paths = (Self.controller.selectedItemURLs() ?? []).map(\.path)
        writePayloadAndOpenURL(action: "stage", paths: paths)
    }

    @objc private func convert(_ sender: Any?) {
        let paths = (Self.controller.selectedItemURLs() ?? []).map(\.path)
        writePayloadAndOpenURL(action: "convert", paths: paths)
    }

    @objc private func simian(_ sender: Any?) {
        let paths = (Self.controller.selectedItemURLs() ?? []).map(\.path)
        writePayloadAndOpenURL(action: "simian", paths: paths)
    }

    @objc private func audioOnly(_ sender: Any?) {
        let paths = (Self.controller.selectedItemURLs() ?? []).map(\.path)
        writePayloadAndOpenURL(action: "audioOnly", paths: paths)
    }

    @objc private func editOnSimian(_ sender: Any?) {
        let paths = (Self.controller.selectedItemURLs() ?? []).map(\.path)
        writePayloadAndOpenURL(action: "editOnSimian", paths: paths)
    }

    /// Swift imports `menuForMenuKind:` as `menu(for:)`; implementing the old name can compile but never run.
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // #region agent log
        let kindRaw = String(describing: menuKind)
        mediaDashDebugNDJSON(location: "FinderSync.swift:menu(for:)", message: "menu(for:) invoked", hypothesisId: "B", data: ["menuKind": kindRaw])
        kInstrumentLogger.info("menu(for:) kind=\(kindRaw, privacy: .public)")
        // #endregion
        // Item menu in the file list; sidebar is a separate `FIMenuKind`.
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForSidebar else {
            // #region agent log
            mediaDashDebugNDJSON(location: "FinderSync.swift:menu(for:)", message: "returning nil (menuKind not items/sidebar)", hypothesisId: "C", data: ["menuKind": kindRaw])
            // #endregion
            return nil
        }
        let menu = NSMenu(title: "")
        let stageItem = NSMenuItem(title: "File in MediaDash", action: #selector(stage(_:)), keyEquivalent: "")
        stageItem.target = self
        let convertItem = NSMenuItem(title: "Convert in MediaDash", action: #selector(convert(_:)), keyEquivalent: "")
        convertItem.target = self
        let simianItem = NSMenuItem(title: "Upload to Simian in MediaDash", action: #selector(simian(_:)), keyEquivalent: "")
        simianItem.target = self
        let editOnSimianItem = NSMenuItem(title: "Edit on Simian", action: #selector(editOnSimian(_:)), keyEquivalent: "")
        editOnSimianItem.target = self
        let audioOnlyItem = NSMenuItem(title: "Create audio only", action: #selector(audioOnly(_:)), keyEquivalent: "")
        audioOnlyItem.target = self
        menu.addItem(stageItem)
        menu.addItem(convertItem)
        menu.addItem(simianItem)
        menu.addItem(editOnSimianItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(audioOnlyItem)
        // #region agent log
        mediaDashDebugNDJSON(location: "FinderSync.swift:menu(for:)", message: "returning menu with items", hypothesisId: "B", data: ["itemCount": String(menu.items.count)])
        // #endregion
        return menu
    }

    override func beginObservingDirectory(at url: URL) {
        super.beginObservingDirectory(at: url)
        // #region agent log
        mediaDashDebugNDJSON(location: "FinderSync.swift:beginObservingDirectory", message: "beginObservingDirectory", hypothesisId: "E", data: ["url": url.path])
        // #endregion
    }
}
