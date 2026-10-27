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

@objc(MediaDashFinderSyncPrincipal)
final class MediaDashFinderSyncPrincipal: FIFinderSync {
    override init() {
        super.init()
        let roots = Self.defaultWatchRoots()
        FIFinderSyncController.default().directoryURLs = roots
        Self.writeLoadHeartbeat(roots: roots)
    }

    /// Home plus each real mounted volume. `/`, `/Users`, and `/Volumes` are not valid
    /// watch roots — Finder silently drops the entire set when any of those is present.
    static func defaultWatchRoots() -> Set<URL> {
        var roots: Set<URL> = [FileManager.default.homeDirectoryForCurrentUser]
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return roots
        }
        for volume in volumes {
            let values = try? volume.resourceValues(forKeys: [.volumeIsRootFileSystemKey])
            if values?.volumeIsRootFileSystem == true { continue }
            roots.insert(volume)
        }
        return roots
    }

    private static func writeLoadHeartbeat(roots: Set<URL>) {
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kAppGroup) else {
            return
        }
        let payload: [String: Any] = [
            "loadedAt": ISO8601DateFormatter().string(from: Date()),
            "roots": roots.map(\.path).sorted()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: base.appendingPathComponent("finder-sync-loaded.json"), options: .atomic)
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

    private func selectedPaths(for menuKind: FIMenuKind) -> [String] {
        let selected = (Self.controller.selectedItemURLs() ?? []).map(\.path)
        if !selected.isEmpty { return selected }
        if menuKind == .contextualMenuForContainer, let target = Self.controller.targetedURL() {
            return [target.path]
        }
        return []
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

    private func currentSelectionPaths() -> [String] {
        let selected = (Self.controller.selectedItemURLs() ?? []).map(\.path)
        if !selected.isEmpty { return selected }
        if let target = Self.controller.targetedURL() {
            return [target.path]
        }
        return []
    }

    @objc private func arrangeFinals(_ sender: Any?) {
        writePayloadAndOpenURL(action: "arrangeFinals", paths: currentSelectionPaths())
    }

    @objc private func file(_ sender: Any?) {
        writePayloadAndOpenURL(action: "file", paths: currentSelectionPaths())
    }

    @objc private func prep(_ sender: Any?) {
        writePayloadAndOpenURL(action: "prep", paths: currentSelectionPaths())
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

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems
            || menuKind == .contextualMenuForSidebar
            || menuKind == .contextualMenuForContainer else {
            return nil
        }

        let paths = selectedPaths(for: menuKind)
        let hasSelection = !paths.isEmpty

        let menu = NSMenu(title: "")

        let fileItem = NSMenuItem(title: "01_File", action: #selector(file(_:)), keyEquivalent: "")
        fileItem.target = self
        fileItem.isEnabled = hasSelection
        menu.addItem(fileItem)
        let prepItem = NSMenuItem(title: "02_Prep", action: #selector(prep(_:)), keyEquivalent: "")
        prepItem.target = self
        prepItem.isEnabled = hasSelection
        menu.addItem(prepItem)
        let arrangeItem = NSMenuItem(title: "03_Arrange Finals", action: #selector(arrangeFinals(_:)), keyEquivalent: "")
        arrangeItem.target = self
        arrangeItem.isEnabled = hasSelection
        menu.addItem(arrangeItem)
        menu.addItem(NSMenuItem.separator())

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
        return menu
    }
}
