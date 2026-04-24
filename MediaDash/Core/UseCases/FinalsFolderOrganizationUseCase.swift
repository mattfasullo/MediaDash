import Foundation

// MARK: - Classification

enum FinalsCategory: Equatable {
    case fullMix(deliverable: String?)  // deliverable = "TV", "WEB", etc.; nil means flat under Fullmixes
    case mixout
    case qtReference
    case unclassified
}

/// Pure, stateless classifier. All matching is case-insensitive.
enum FinalsClassifier {

    // Stem tokens — longest variants first so "SFXOnly" wins over "SFX"
    static let mixoutTokens: [String] = [
        "DialOnly", "SyncOnly", "SFXOnly", "MusicOnly",
        "SyncMix", "MusicMix", "AmbMix", "SFXMix", "DialMix",
        "Dial", "Sync", "SFX", "Music", "Amb", "Bed",
        "VoxOnly", "Vox", "MxOnly",
    ]

    // Mix-type tokens (suffix signals full mix)
    static let fullMixTokens: [String] = ["Fullmix", "FM"]

    // Deliverable / format tokens that can precede the mix label
    static let deliverableTokens: [String] = [
        "TV", "WEB", "DGTL", "Digital", "Broadcast", "OTT",
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mxf", "avi", "mkv", "prores",
    ]

    /// Classify a filename. Returns (category, cleaned basename with Pro Tools _NN removed).
    static func classify(filename: String) -> (category: FinalsCategory, cleanedBasename: String) {
        let fileURL = URL(fileURLWithPath: filename)
        let ext = fileURL.pathExtension.lowercased()
        let rawBasename = fileURL.deletingPathExtension().lastPathComponent
        let cleaned = stripProToolsSuffix(rawBasename)
        let upper = cleaned.uppercased()

        // 1. Video → QT reference
        if videoExtensions.contains(ext) {
            return (.qtReference, cleaned)
        }

        // 2. Full mix check
        for mixToken in fullMixTokens {
            if containsToken(upper, token: mixToken.uppercased()) {
                let deliverable = detectDeliverable(in: upper, before: mixToken.uppercased())
                return (.fullMix(deliverable: deliverable), cleaned)
            }
        }

        // 3. Mixout (stem) — trailing _Token and/or any segment that names a stem (SyncMix, …, or "SFX"/"Music"/…)
        if hasTrailingMixoutStem(upper) || anySegmentIndicatesMixout(upper) {
            return (.mixout, cleaned)
        }

        return (.unclassified, cleaned)
    }

    // MARK: Helpers

    /// Remove a trailing `_<digits-only>` Pro Tools export suffix.
    static func stripProToolsSuffix(_ basename: String) -> String {
        if let range = basename.range(of: #"_\d+$"#, options: .regularExpression) {
            return String(basename[..<range.lowerBound])
        }
        return basename
    }

    /// Token is present when bounded by `_`, start-of-string, or end-of-string.
    private static func containsToken(_ upper: String, token: String) -> Bool {
        let bounds = ["_\(token)_", "_\(token)", "\(token)_"]
        for b in bounds where upper.contains(b) { return true }
        return upper == token
    }

    /// Stem token must appear as the final segment: `_TOKEN` at end or the whole name.
    private static func hasSuffixToken(_ upper: String, token: String) -> Bool {
        upper.hasSuffix("_\(token)") || upper == token
    }

    private static func hasTrailingMixoutStem(_ upper: String) -> Bool {
        for stemToken in mixoutTokens {
            if hasSuffixToken(upper, token: stemToken.uppercased()) { return true }
        }
        return false
    }

    /// True if any underscore-separated segment names a stem (engineers use mid-name tokens like `SyncMix`, not only `_SFX` at end).
    private static func anySegmentIndicatesMixout(_ upper: String) -> Bool {
        let tokensByLength = mixoutTokens.map { $0.uppercased() }.sorted { $0.count > $1.count }
        let parts = upper.split(separator: "_").map { String($0).uppercased() }
        for u in parts where !u.isEmpty {
            if u == "FM" || u.contains("FULLMIX") { continue }
            for t in tokensByLength {
                if u == t { return true }
                if u.hasSuffix(t), t.count >= 4 { return true }
            }
            // Broad substring cues (full-mix already ruled out on whole basename)
            if u.contains("SFX") { return true }
            if u.contains("MUSIC") { return true }
            if u.contains("AMB") { return true }
            if u.contains("DIAL") { return true }
            if u.contains("BED") { return true }
            if u.contains("VOX") { return true }
            if u == "MX" || u.contains("MXONLY") { return true }
            if u.contains("SYNC") {
                if u == "ASYNC" { continue }
                if u.hasPrefix("ASYNC") { continue }
                return true
            }
        }
        return false
    }

    /// Find the deliverable token (e.g. "TV", "WEB") in the part before the mix label.
    private static func detectDeliverable(in upper: String, before mixToken: String) -> String? {
        guard let mixRange = upper.range(of: mixToken) else { return nil }
        let prefix = String(upper[..<mixRange.lowerBound])
        for d in deliverableTokens where containsToken(prefix, token: d.uppercased()) {
            return d.uppercased()
        }
        return nil
    }
}

// MARK: - Move plan types

struct FinalsMoveItem {
    let source: URL
    let destination: URL
}

struct FinalsMoveConflict {
    let source: URL
    let destination: URL
}

struct FinalsMoveError: LocalizedError {
    let conflicts: [FinalsMoveConflict]
    var errorDescription: String? {
        let names = conflicts.map { $0.destination.lastPathComponent }.joined(separator: "\n  ")
        return "Cannot arrange finals: \(conflicts.count) conflict(s):\n  \(names)"
    }
}

struct FinalsMovePreview {
    let fullMixes: [FinalsMoveItem]
    let mixouts: [FinalsMoveItem]
    let qtReferences: [FinalsMoveItem]
    let unclassified: [URL]

    var allItems: [FinalsMoveItem] { fullMixes + mixouts + qtReferences }
    var isEmpty: Bool { allItems.isEmpty }
}

// MARK: - Use case

struct FinalsFolderOrganizationUseCase {

    enum Buckets {
        static let fullmixes = "01_Fullmixes"
        static let mixouts   = "02_Mixouts"
        static let qt        = "03_Quicktime References"
    }

    /// Build a dry-run preview without touching disk.
    static func buildPlan(root: URL) -> FinalsMovePreview {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return FinalsMovePreview(fullMixes: [], mixouts: [], qtReferences: [], unclassified: [])
        }

        // Paths already inside destination buckets — skip them during re-runs
        let destRoots: [String] = [
            root.appendingPathComponent(Buckets.fullmixes).path,
            root.appendingPathComponent(Buckets.mixouts).path,
            root.appendingPathComponent(Buckets.qt).path,
        ]

        var fullMixes: [FinalsMoveItem] = []
        var mixouts: [FinalsMoveItem] = []
        var qtRefs: [FinalsMoveItem] = []
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
                    dir = root.appendingPathComponent(Buckets.fullmixes).appendingPathComponent(d)
                } else {
                    dir = root.appendingPathComponent(Buckets.fullmixes)
                }
                fullMixes.append(FinalsMoveItem(source: fileURL, destination: dir.appendingPathComponent(newFilename)))
            case .mixout:
                mixouts.append(FinalsMoveItem(
                    source: fileURL,
                    destination: root.appendingPathComponent(Buckets.mixouts).appendingPathComponent(newFilename)
                ))
            case .qtReference:
                qtRefs.append(FinalsMoveItem(
                    source: fileURL,
                    destination: root.appendingPathComponent(Buckets.qt).appendingPathComponent(newFilename)
                ))
            case .unclassified:
                unclassified.append(fileURL)
            }
        }

        return FinalsMovePreview(fullMixes: fullMixes, mixouts: mixouts, qtReferences: qtRefs, unclassified: unclassified)
    }

    /// Detect name collisions; returns empty array when safe to proceed.
    static func detectConflicts(in preview: FinalsMovePreview) -> [FinalsMoveConflict] {
        let fm = FileManager.default
        return preview.allItems.compactMap { item in
            fm.fileExists(atPath: item.destination.path)
                ? FinalsMoveConflict(source: item.source, destination: item.destination)
                : nil
        }
    }

    /// Apply the plan: creates destination directories, then moves files.
    /// Throws `FinalsMoveError` on conflicts or a filesystem error on I/O failure.
    static func execute(preview: FinalsMovePreview) throws {
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
