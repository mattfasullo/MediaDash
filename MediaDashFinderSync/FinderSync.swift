//
//  FinderSync.swift
//  MediaDashFinderSync
//

import Cocoa
import FinderSync

/// JSON shape must match `FinderCommandPayload` in the main app.
private struct FinderHandoffPayload: Codable {
    let action: String
    let paths: [String]
}

private let kAppGroup = "group.mattfasullo.MediaDash"

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // Required so Finder delivers `menuForMenuKind` / `selectedItemURLs` for items under these roots.
        // A sandboxed extension often cannot register `/`, which hides all MediaDash items — match host app (no sandbox).
        FIFinderSyncController.default().directoryURLs = Set([
            URL(fileURLWithPath: "/"),
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

    func menuForMenuKind(_ menuKind: FIMenuKind) -> NSMenu? {
        // Right‑click on file(s) in a Finder window.
        guard menuKind == .contextualMenuForItems else { return nil }
        let menu = NSMenu(title: "")
        let stageItem = NSMenuItem(title: "File in MediaDash", action: #selector(stage(_:)), keyEquivalent: "")
        stageItem.target = self
        let convertItem = NSMenuItem(title: "Convert in MediaDash", action: #selector(convert(_:)), keyEquivalent: "")
        convertItem.target = self
        let simianItem = NSMenuItem(title: "Upload to Simian in MediaDash", action: #selector(simian(_:)), keyEquivalent: "")
        simianItem.target = self
        let audioOnlyItem = NSMenuItem(title: "Create audio only", action: #selector(audioOnly(_:)), keyEquivalent: "")
        audioOnlyItem.target = self
        menu.addItem(stageItem)
        menu.addItem(convertItem)
        menu.addItem(simianItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(audioOnlyItem)
        return menu
    }
}
