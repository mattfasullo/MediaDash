import AppKit

/// Finder Services fallback when Finder Sync never loads the appex.
final class MediaDashServicesProvider: NSObject {
    static let shared = MediaDashServicesProvider()

    nonisolated static func itemURLs(from pboard: NSPasteboard) -> [URL] {
        let fileURLs: [URL]
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            fileURLs = urls
        } else if let paths = pboard.propertyList(forType: .compatFilenames) as? [String] {
            fileURLs = paths.map { URL(fileURLWithPath: $0) }
        } else {
            return []
        }
        return fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func folderURLs(from pboard: NSPasteboard) -> [URL] {
        itemURLs(from: pboard).filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    @objc func arrangeFinals(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.itemURLs(from: pboard)
        FinderFocus.beginBackgroundFinderAction()
        guard !urls.isEmpty else { return }
        FinderCommandBridge.applyArrangeFinals(urls: urls, manager: nil)
    }

    @objc func file(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        enqueueForegroundJob(action: .file, pboard: pboard)
    }

    @objc func prep(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        enqueueForegroundJob(action: .prep, pboard: pboard)
    }

    private func enqueueForegroundJob(action: FinderIncomingAction, pboard: NSPasteboard) {
        let urls = Self.itemURLs(from: pboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            FinderCommandBridge.shared.enqueue(
                FinderCommandPayload(action: action, paths: urls.map(\.path))
            )
        }
    }
}

private extension NSPasteboard.PasteboardType {
    static let compatFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
}
