import Foundation

/// Finder / URL-scheme Arrange Finals: classify and move immediately, no confirmation sheet.
nonisolated enum FinalsFinderArrange: Equatable, Sendable {
    case skippedNotDirectory
    case empty
    case arranged(fileCount: Int, folderName: String)
    case failed(String)

    struct PreparedRoots: Equatable, Sendable {
        let roots: [URL]
        let moveFailures: [String]
    }

    nonisolated static func datedFolderName(for date: Date = Date()) -> String {
        FolderNamingService.standardDateString(date)
    }

    /// Folders stay as-is. Loose files are moved into a same-day `Oct26.26` folder in their parent.
    nonisolated static func prepareRoots(from urls: [URL], now: Date = Date()) -> PreparedRoots {
        let fm = FileManager.default
        var roots: [URL] = []
        var moveFailures: [String] = []
        var filesByParent: [String: [URL]] = [:]

        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                roots.append(url)
            } else {
                filesByParent[url.deletingLastPathComponent().path, default: []].append(url)
            }
        }

        let dateName = datedFolderName(for: now)
        for (parentPath, files) in filesByParent {
            let dest = URL(fileURLWithPath: parentPath).appendingPathComponent(dateName)
            do {
                if !fm.fileExists(atPath: dest.path) {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                }
                for file in files {
                    let target = dest.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: target.path) {
                        moveFailures.append(file.lastPathComponent)
                        continue
                    }
                    do {
                        try fm.moveItem(at: file, to: target)
                    } catch {
                        moveFailures.append("\(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                roots.append(dest)
            } catch {
                moveFailures.append(error.localizedDescription)
            }
        }

        var seen = Set<String>()
        let unique = roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return PreparedRoots(roots: unique, moveFailures: moveFailures)
    }

    nonisolated static func run(url: URL) -> FinalsFinderArrange {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return .skippedNotDirectory
        }

        let preview = FinalsFolderOrganizationUseCase.buildPlan(root: url)
        guard !preview.isEmpty else { return .empty }

        do {
            try FinalsFolderOrganizationUseCase.execute(preview: preview)
            return .arranged(fileCount: preview.allItems.count, folderName: url.lastPathComponent)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    nonisolated static func runAll(urls: [URL], now: Date = Date()) -> (results: [FinalsFinderArrange], moveFailures: [String], arrangedURLs: [URL]) {
        let prepared = prepareRoots(from: urls, now: now)
        var results: [FinalsFinderArrange] = []
        var arrangedURLs: [URL] = []
        for root in prepared.roots {
            let result = run(url: root)
            results.append(result)
            if case .arranged = result {
                arrangedURLs.append(root)
            }
        }
        return (results, prepared.moveFailures, arrangedURLs)
    }
}
