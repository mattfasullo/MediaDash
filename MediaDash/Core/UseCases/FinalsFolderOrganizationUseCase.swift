import Foundation

// MARK: - Classification

enum FinalsCategory: Equatable, Sendable {
    case fullMix(deliverable: String?)
    case mixout
    case qtReference
    case unclassified
}

// MARK: - File-level constants
// Project default isolation is MainActor, so mark these explicitly nonisolated
// so the nonisolated classifier/use-case functions below can reference them.

// Known announcer / stem labels (reference; classification is full-mix vs QT vs everything-else → mixout).
nonisolated private let _mixoutTokens: [String] = [
    "DialOnly", "SyncOnly", "SFXOnly", "MusicOnly",
    "SyncMix", "MusicMix", "AmbMix", "SFXMix", "DialMix", "AnncrMix", "Anncr",
    "Dial", "Sync", "SFX", "Music", "Amb", "Bed",
    "VoxOnly", "Vox", "MxOnly",
]
/// Full-mix markers (case-insensitive). Anything else that is not a QT ref is treated as a mixout.
nonisolated private let _fullMixTokens: [String] = ["Fullmix", "FullMix", "FM"]
nonisolated private let _deliverableTokens: [String] = [
    "TV", "WEB", "DGTL", "Digital", "Broadcast", "OTT",
]
nonisolated private let _videoExtensions: Set<String> = [
    "mov", "mp4", "m4v", "mxf", "avi", "mkv", "prores",
]

nonisolated private let _bucketFullmixes = "01_Fullmixes"
nonisolated private let _bucketMixouts   = "02_Mixouts"
nonisolated private let _bucketQt        = "03_Quicktime References"

// MARK: - Classifier

/// Pure, stateless classifier. All matching is case-insensitive.
/// **Quicktime** (by extension) → reference bucket. **Full mix** if `FM`, `Fullmix`, or `FullMix` appears as a bounded token.
/// Otherwise → **mixout** (catch-all for Finals stems).
nonisolated enum FinalsClassifier {

    static var mixoutTokens:    [String]    { _mixoutTokens }
    static var fullMixTokens:   [String]    { _fullMixTokens }
    static var deliverableTokens: [String]  { _deliverableTokens }
    static var videoExtensions: Set<String> { _videoExtensions }

    /// Classify a filename. Returns (category, cleaned basename with Pro Tools _NN removed).
    nonisolated static func classify(filename: String) -> (category: FinalsCategory, cleanedBasename: String) {
        let fileURL = URL(fileURLWithPath: filename)
        let ext = fileURL.pathExtension.lowercased()
        let rawBasename = fileURL.deletingPathExtension().lastPathComponent
        let cleaned = stripProToolsSuffix(rawBasename)
        let upper = cleaned.uppercased()

        if _videoExtensions.contains(ext) {
            return (.qtReference, cleaned)
        }

        for mixToken in _fullMixTokens {
            if containsToken(upper, token: mixToken.uppercased()) {
                let deliverable = detectDeliverable(in: upper, before: mixToken.uppercased())
                return (.fullMix(deliverable: deliverable), cleaned)
            }
        }

        // Catch-all: in Finals workflow, stems that are not full mixes / not reference video → mixouts.
        return (.mixout, cleaned)
    }

    nonisolated static func stripProToolsSuffix(_ basename: String) -> String {
        if let range = basename.range(of: #"_\d+$"#, options: .regularExpression) {
            return String(basename[..<range.lowerBound])
        }
        return basename
    }

    nonisolated private static func containsToken(_ upper: String, token: String) -> Bool {
        let bounds = ["_\(token)_", "_\(token)", "\(token)_"]
        for b in bounds where upper.contains(b) { return true }
        return upper == token
    }

    nonisolated private static func detectDeliverable(in upper: String, before mixToken: String) -> String? {
        guard let mixRange = upper.range(of: mixToken) else { return nil }
        let prefix = String(upper[..<mixRange.lowerBound])
        for d in _deliverableTokens where containsToken(prefix, token: d.uppercased()) {
            return d.uppercased()
        }
        return nil
    }
}

// MARK: - Move plan types

struct FinalsMoveItem: Sendable {
    let source: URL
    let destination: URL
}

struct FinalsMoveConflict: Sendable {
    let source: URL
    let destination: URL
}

struct FinalsMoveError: LocalizedError, Sendable {
    let conflicts: [FinalsMoveConflict]
    var errorDescription: String? {
        let names = conflicts.map { $0.destination.lastPathComponent }.joined(separator: "\n  ")
        return "Cannot arrange finals: \(conflicts.count) conflict(s):\n  \(names)"
    }
}

nonisolated struct FinalsMovePreview: Sendable {
    let fullMixes: [FinalsMoveItem]
    let mixouts: [FinalsMoveItem]
    let qtReferences: [FinalsMoveItem]
    let unclassified: [URL]

    var allItems: [FinalsMoveItem] { fullMixes + mixouts + qtReferences }
    var isEmpty: Bool { fullMixes.isEmpty && mixouts.isEmpty && qtReferences.isEmpty }
}

// MARK: - Use case

nonisolated struct FinalsFolderOrganizationUseCase {

    enum Buckets {
        static var fullmixes: String { _bucketFullmixes }
        static var mixouts:   String { _bucketMixouts }
        static var qt:        String { _bucketQt }
    }

    nonisolated static func buildPlan(root: URL) -> FinalsMovePreview {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return FinalsMovePreview(fullMixes: [], mixouts: [], qtReferences: [], unclassified: [])
        }

        let destRoots: [String] = [
            root.appendingPathComponent(_bucketFullmixes).path,
            root.appendingPathComponent(_bucketMixouts).path,
            root.appendingPathComponent(_bucketQt).path,
        ]

        var fullMixes: [FinalsMoveItem] = []
        var mixouts:   [FinalsMoveItem] = []
        var qtRefs:    [FinalsMoveItem] = []
        var unclassified: [URL] = []

        for case let fileURL as URL in enumerator {
            guard let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  vals.isRegularFile == true else { continue }
            let path = fileURL.path
            if destRoots.contains(where: { path.hasPrefix($0 + "/") || path == $0 }) { continue }

            let (category, cleanedBasename) = FinalsClassifier.classify(filename: fileURL.lastPathComponent)
            let ext = fileURL.pathExtension
            let newFilename = ext.isEmpty ? cleanedBasename : "\(cleanedBasename).\(ext)"

            switch category {
            case .fullMix(let deliverable):
                let dir: URL
                if let d = deliverable {
                    dir = root.appendingPathComponent(_bucketFullmixes).appendingPathComponent(d)
                } else {
                    dir = root.appendingPathComponent(_bucketFullmixes)
                }
                fullMixes.append(FinalsMoveItem(source: fileURL, destination: dir.appendingPathComponent(newFilename)))
            case .mixout:
                mixouts.append(FinalsMoveItem(
                    source: fileURL,
                    destination: root.appendingPathComponent(_bucketMixouts).appendingPathComponent(newFilename)
                ))
            case .qtReference:
                qtRefs.append(FinalsMoveItem(
                    source: fileURL,
                    destination: root.appendingPathComponent(_bucketQt).appendingPathComponent(newFilename)
                ))
            case .unclassified:
                unclassified.append(fileURL)
            }
        }

        return FinalsMovePreview(fullMixes: fullMixes, mixouts: mixouts, qtReferences: qtRefs, unclassified: unclassified)
    }

    nonisolated static func detectConflicts(in preview: FinalsMovePreview) -> [FinalsMoveConflict] {
        let fm = FileManager.default
        return preview.allItems.compactMap { item in
            fm.fileExists(atPath: item.destination.path)
                ? FinalsMoveConflict(source: item.source, destination: item.destination)
                : nil
        }
    }

    nonisolated static func execute(preview: FinalsMovePreview) throws {
        let conflicts = detectConflicts(in: preview)
        guard conflicts.isEmpty else { throw FinalsMoveError(conflicts: conflicts) }

        let fm = FileManager.default
        let dirs = Set(preview.allItems.map { $0.destination.deletingLastPathComponent() })
        for dir in dirs where !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for item in preview.allItems {
            try fm.moveItem(at: item.source, to: item.destination)
        }
    }
}
