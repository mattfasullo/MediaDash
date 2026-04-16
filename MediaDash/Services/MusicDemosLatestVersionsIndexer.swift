import CryptoKit
import Dispatch
import Foundation

/// Indexes `…/Y_MUSIC DEMOS/<project>/` round folders and picks the latest audio per writer × lineage × variant.
enum MusicDemosLatestVersionsIndexer {

    struct IndexScanResult: Sendable {
        let rows: [IndexedFile]
        let scanErrors: [String]
    }

    /// One on-disk file in a writer × lineage × variant group, ordered newest → oldest for UI.
    struct IndexedDemoVersion: Identifiable, Sendable {
        var id: String { fileURL.path }
        let fileURL: URL
        let roundFolderName: String
        let roundSequence: Int
        let modificationDate: Date
        let formatLabel: String
        let versionScore: VersionScore
        /// The file the indexer picked as “latest” for this group.
        let isLatestWinner: Bool
    }

    struct IndexedFile: Identifiable, Sendable {
        var id: String { "\(writerKey)|\(lineageKey)|\(variantKey)|\(fileURL.path)" }
        let writerKey: String
        let familyKey: String
        let lineageKey: String
        let variantKey: String
        let displayFamily: String
        let displayVariant: String
        let canonicalColorName: String?
        let roundFolderName: String
        let roundSequence: Int
        let fileURL: URL
        let parseConfidence: DemoParseConfidence
        let versionScore: VersionScore
        let whyLatestSummary: String
        /// Another file in the scan mapped to the same lineage key with low token overlap (possible wrong merge).
        let isLineageAmbiguous: Bool
        /// Same round + score + mtime + format but different file bytes.
        let hasContentHashConflict: Bool
        /// Every file seen for this lineage × variant, newest first (same ordering as winner selection).
        let versionsNewestFirst: [IndexedDemoVersion]

        /// Paths in `versionsNewestFirst` order (newest first).
        var contributingPaths: [String] { versionsNewestFirst.map(\.fileURL.path) }
    }

    private struct RoundInfo: Sendable {
        let sequence: Int
        let name: String
        let url: URL
        let folderModificationDate: Date?
    }

    private struct Candidate: Sendable {
        let writerKey: String
        let round: RoundInfo
        let fileURL: URL
        let modificationDate: Date
        let formatRank: Int
        let parse: DemoFilenameParseResult
        let stemUpper: String
    }

    /// - Parameters:
    ///   - scanYear: Used for yearless embedded dates in filenames (e.g. `Mar10`).
    ///   - lineageKeyOverrides: Map uppercase filename stem → forced `lineageKey` (manual merge).
    ///   - shouldCancel: Checked periodically during enumeration; return true to stop and throw `CancellationError`.
    nonisolated static func indexProjectFolder(
        _ projectFolder: URL,
        musicExtensions: [String],
        scanYear: Int,
        lineageKeyOverrides: [String: String] = [:],
        shouldCancel: (() -> Bool)? = nil
    ) throws -> IndexScanResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectFolder.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "MusicDemosLatestVersionsIndexer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Not a folder: \(projectFolder.path)"
            ])
        }

        let extSet = Set(musicExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })

        let rounds = try listRoundFolders(in: projectFolder, fm: fm)
        var scanErrors: [String] = []
        let (candidates, roundScanErrors) = try collectCandidatesParallel(
            rounds: rounds,
            extensions: extSet,
            fm: fm,
            scanYear: scanYear,
            lineageKeyOverrides: lineageKeyOverrides,
            shouldCancel: shouldCancel
        )
        scanErrors.append(contentsOf: roundScanErrors)

        let grouped = Dictionary(grouping: candidates) { c in
            "\(c.writerKey)\u{1f}|\(c.parse.lineageKey)\u{1f}|\(c.parse.variantKey)"
        }

        var ambiguousKeys = Set<String>()
        for (key, group) in grouped where group.count > 1 {
            if lineageGroupLooksAmbiguous(group) {
                ambiguousKeys.insert(key)
            }
        }

        var rows: [IndexedFile] = []
        for (key, group) in grouped {
            if shouldCancel?() == true { throw CancellationError() }
            guard let winner = pickWinner(from: group) else { continue }
            let ambiguous = ambiguousKeys.contains(key)

            let why = makeWhyLatest(winner: winner, group: group)
            let hashConflict = detectHashConflict(in: group, winner: winner, fm: fm)

            let sortedNewestFirst = group.sorted { isCandidateNewer($0, than: $1) }
            let versions: [IndexedDemoVersion] = sortedNewestFirst.map { c in
                IndexedDemoVersion(
                    fileURL: c.fileURL,
                    roundFolderName: c.round.name,
                    roundSequence: c.round.sequence,
                    modificationDate: c.modificationDate,
                    formatLabel: formatLabel(c.formatRank),
                    versionScore: c.parse.versionScore,
                    isLatestWinner: c.fileURL == winner.fileURL
                )
            }
            rows.append(IndexedFile(
                writerKey: winner.writerKey,
                familyKey: winner.parse.familyKey,
                lineageKey: winner.parse.lineageKey,
                variantKey: winner.parse.variantKey,
                displayFamily: winner.parse.displayFamily,
                displayVariant: winner.parse.displayVariant,
                canonicalColorName: winner.parse.canonicalColorName,
                roundFolderName: winner.round.name,
                roundSequence: winner.round.sequence,
                fileURL: winner.fileURL,
                parseConfidence: winner.parse.confidence,
                versionScore: winner.parse.versionScore,
                whyLatestSummary: why,
                isLineageAmbiguous: ambiguous,
                hasContentHashConflict: hashConflict,
                versionsNewestFirst: versions
            ))
        }

        rows.sort { a, b in
            if a.writerKey != b.writerKey { return a.writerKey.localizedCaseInsensitiveCompare(b.writerKey) == .orderedAscending }
            if a.familyKey != b.familyKey { return a.familyKey.localizedCaseInsensitiveCompare(b.familyKey) == .orderedAscending }
            if a.lineageKey != b.lineageKey { return a.lineageKey.localizedCaseInsensitiveCompare(b.lineageKey) == .orderedAscending }
            return a.displayVariant.localizedCaseInsensitiveCompare(b.displayVariant) == .orderedAscending
        }

        return IndexScanResult(rows: rows, scanErrors: scanErrors)
    }

    // MARK: - Winner selection

    /// Higher round wins; then filename score; then mtime; then better format (wav first).
    private nonisolated static func pickWinner(from group: [Candidate]) -> Candidate? {
        guard var best = group.first else { return nil }
        for c in group.dropFirst() {
            if isCandidateNewer(c, than: best) {
                best = c
            }
        }
        return best
    }

    private nonisolated static func isCandidateNewer(_ c: Candidate, than b: Candidate) -> Bool {
        if c.round.sequence != b.round.sequence {
            return c.round.sequence > b.round.sequence
        }
        if c.parse.versionScore != b.parse.versionScore {
            return c.parse.versionScore.isNewerThan(b.parse.versionScore)
        }
        if c.modificationDate != b.modificationDate {
            return c.modificationDate > b.modificationDate
        }
        if c.formatRank != b.formatRank {
            return c.formatRank < b.formatRank
        }
        // Deterministic tie-break (no per-file SHA256 during scan — see detectHashConflict for rare byte checks).
        return c.fileURL.path.localizedStandardCompare(b.fileURL.path) == .orderedDescending
    }

    /// Only runs SHA256 when multiple files tie on round + score + mtime + format (rare).
    private nonisolated static func detectHashConflict(in group: [Candidate], winner: Candidate, fm: FileManager) -> Bool {
        let peers = group.filter {
            $0.round.sequence == winner.round.sequence
                && $0.parse.versionScore == winner.parse.versionScore
                && $0.modificationDate == winner.modificationDate
                && $0.formatRank == winner.formatRank
        }
        guard peers.count > 1 else { return false }
        var unique = Set<Data>()
        for p in peers {
            guard let h = sha256IfSmallFile(at: p.fileURL, fm: fm) else { return false }
            unique.insert(h)
        }
        return unique.count > 1
    }

    private nonisolated static func makeWhyLatest(winner: Candidate, group: [Candidate]) -> String {
        var parts: [String] = []
        parts.append("Round \(winner.round.name) (\(winner.round.sequence))")
        let vs = winner.parse.versionScore
        if vs.rev > 0 || vs.v > 0 || vs.opt > 0 {
            var bits: [String] = []
            if vs.rev > 0 { bits.append("rev \(vs.rev)") }
            if vs.v > 0 { bits.append("v\(vs.v)") }
            if vs.opt > 0 { bits.append("opt \(vs.opt)") }
            parts.append(bits.joined(separator: ", "))
        }
        if vs.embeddedDateOrdinal > 0 {
            parts.append("embedded date \(vs.embeddedDateOrdinal)")
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        parts.append("modified \(df.string(from: winner.modificationDate))")
        parts.append(formatLabel(winner.formatRank))
        if group.count > 1 {
            parts.append("beat \(group.count - 1) other file(s) in this lineage")
        }
        return parts.joined(separator: " · ")
    }

    private nonisolated static func formatLabel(_ rank: Int) -> String {
        switch rank {
        case 0: return "WAV"
        case 1: return "AIFF"
        case 2: return "FLAC"
        case 3: return "M4A"
        case 4: return "MP3"
        default: return "audio"
        }
    }

    /// Jaccard similarity on underscore token sets (uppercased); low score ⇒ ambiguous merge.
    private nonisolated static func lineageGroupLooksAmbiguous(_ group: [Candidate]) -> Bool {
        guard group.count >= 2 else { return false }
        let sets = group.map { Set($0.stemUpper.split(separator: "_").map(String.init)) }
        var minJac = 1.0
        for i in 0..<sets.count {
            for j in (i + 1)..<sets.count {
                let a = sets[i], b = sets[j]
                let inter = Double(a.intersection(b).count)
                let union = Double(a.union(b).count)
                guard union > 0 else { continue }
                minJac = min(minJac, inter / union)
            }
        }
        return minJac < 0.35
    }

    // MARK: - Rounds & files

    /// Walks round folders in parallel (bounded) so network volumes spend less wall-clock time on large trees.
    private nonisolated static func collectCandidatesParallel(
        rounds: [RoundInfo],
        extensions: Set<String>,
        fm: FileManager,
        scanYear: Int,
        lineageKeyOverrides: [String: String],
        shouldCancel: (() -> Bool)?
    ) throws -> (candidates: [Candidate], roundErrors: [String]) {
        guard !rounds.isEmpty else { return ([], []) }
        if rounds.count == 1 {
            do {
                let found = try enumerateCandidates(
                    round: rounds[0],
                    extensions: extensions,
                    fm: fm,
                    scanYear: scanYear,
                    lineageKeyOverrides: lineageKeyOverrides,
                    shouldCancel: shouldCancel
                )
                return (found, [])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return ([], ["Round \(rounds[0].name): \(error.localizedDescription)"])
            }
        }

        let lock = NSLock()
        var out: [Candidate] = []
        var errors: [String] = []
        var cancelled = false
        let group = DispatchGroup()
        let parallelism = min(4, rounds.count)
        let sema = DispatchSemaphore(value: parallelism)

        for round in rounds {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                sema.wait()
                defer {
                    sema.signal()
                    group.leave()
                }
                do {
                    if shouldCancel?() == true { throw CancellationError() }
                    let found = try enumerateCandidates(
                        round: round,
                        extensions: extensions,
                        fm: FileManager.default,
                        scanYear: scanYear,
                        lineageKeyOverrides: lineageKeyOverrides,
                        shouldCancel: shouldCancel
                    )
                    lock.lock()
                    out.append(contentsOf: found)
                    lock.unlock()
                } catch is CancellationError {
                    lock.lock()
                    cancelled = true
                    lock.unlock()
                } catch {
                    lock.lock()
                    errors.append("Round \(round.name): \(error.localizedDescription)")
                    lock.unlock()
                }
            }
        }
        group.wait()
        if cancelled || shouldCancel?() == true { throw CancellationError() }
        return (out, errors)
    }

    private nonisolated static func listRoundFolders(in projectFolder: URL, fm: FileManager) throws -> [RoundInfo] {
        let children = try fm.contentsOfDirectory(at: projectFolder, includingPropertiesForKeys: [
            .isDirectoryKey,
            .contentModificationDateKey
        ], options: [.skipsHiddenFiles])

        var rounds: [RoundInfo] = []
        let pattern = #"^(\d+)_(.+)$"#
        let regex = try NSRegularExpression(pattern: pattern)

        for url in children {
            var isD: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isD), isD.boolValue else { continue }
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard let m = regex.firstMatch(in: name, range: range),
                  let seqRange = Range(m.range(at: 1), in: name),
                  let seq = Int(name[seqRange])
            else { continue }

            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            rounds.append(RoundInfo(sequence: seq, name: name, url: url, folderModificationDate: vals?.contentModificationDate))
        }

        rounds.sort { a, b in
            if a.sequence != b.sequence { return a.sequence > b.sequence }
            let da = a.folderModificationDate ?? .distantPast
            let db = b.folderModificationDate ?? .distantPast
            return da > db
        }
        return rounds
    }

    private nonisolated static func enumerateCandidates(
        round: RoundInfo,
        extensions: Set<String>,
        fm: FileManager,
        scanYear: Int,
        lineageKeyOverrides: [String: String],
        shouldCancel: (() -> Bool)?
    ) throws -> [Candidate] {
        guard let enumerator = fm.enumerator(
            at: round.url,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [Candidate] = []
        var fileIndex = 0
        while let item = enumerator.nextObject() as? URL {
            fileIndex += 1
            if fileIndex % 400 == 0, shouldCancel?() == true { throw CancellationError() }

            let rvKeys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
            guard let rv = try? item.resourceValues(forKeys: rvKeys) else { continue }
            let isRegular: Bool
            if let irf = rv.isRegularFile {
                isRegular = irf
            } else {
                var isDir: ObjCBool = false
                isRegular = fm.fileExists(atPath: item.path, isDirectory: &isDir) && !isDir.boolValue
            }
            guard isRegular else { continue }
            let ext = item.pathExtension.lowercased()
            guard !ext.isEmpty, extensions.contains(ext) else { continue }

            let filename = item.lastPathComponent
            let stem = (filename as NSString).deletingPathExtension
            let stemNorm = DemoFilenameParser.normalizeUnicode(stem)
            let stemKey = stemNorm.uppercased()

            var parse = DemoFilenameParser.parse(stem: stemNorm, defaultYear: scanYear)
            if let forced = lineageKeyOverrides[stemKey] {
                parse = DemoFilenameParseResult(
                    lineageKey: forced,
                    familyKey: parse.familyKey,
                    variantKey: parse.variantKey,
                    displayFamily: parse.displayFamily,
                    displayVariant: parse.displayVariant,
                    canonicalColorName: parse.canonicalColorName,
                    versionScore: parse.versionScore,
                    embeddedDates: parse.embeddedDates,
                    confidence: parse.confidence
                )
            }

            let writer = writerKey(for: item, roundRoot: round.url, filename: filename)
            let mod = rv.contentModificationDate ?? .distantPast
            let fr = formatRank(item)

            out.append(Candidate(
                writerKey: writer,
                round: round,
                fileURL: item,
                modificationDate: mod,
                formatRank: fr,
                parse: parse,
                stemUpper: stemNorm.uppercased()
            ))
        }
        return out
    }

    /// Hash only modest-sized files to avoid SMB stalls on huge stems.
    private nonisolated static func sha256IfSmallFile(at url: URL, fm: FileManager) -> Data? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        let maxBytes: Int64 = 32 * 1024 * 1024
        if size.int64Value > maxBytes { return nil }
        guard let h = try? Self.sha256(url: url) else { return nil }
        return h
    }

    private nonisolated static func sha256(url: URL) throws -> Data {
        var sha = SHA256()
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        while true {
            let chunk = h.readData(ofLength: 512 * 1024)
            if chunk.isEmpty { break }
            sha.update(data: chunk)
        }
        return Data(sha.finalize())
    }

    private nonisolated static func writerKey(for fileURL: URL, roundRoot: URL, filename: String) -> String {
        let parent = fileURL.deletingLastPathComponent().standardizedFileURL
        let roundStandard = roundRoot.standardizedFileURL
        if parent.path == roundStandard.path {
            let stem = (filename as NSString).deletingPathExtension
            if let w = writerTokenFromStem(stem) {
                return w
            }
            return "Unknown"
        }
        var firstFolder: String?
        var cur = parent
        while cur.path != roundStandard.path && cur.path.count > roundStandard.path.count {
            firstFolder = cur.lastPathComponent
            cur = cur.deletingLastPathComponent().standardizedFileURL
        }
        if let f = firstFolder, !f.isEmpty {
            return f
        }
        let stem = (filename as NSString).deletingPathExtension
        return writerTokenFromStem(stem) ?? "Unknown"
    }

    private nonisolated static func writerTokenFromStem(_ stem: String) -> String? {
        let parts = stem.split(separator: "_").map(String.init)
        guard let last = parts.last else { return nil }
        if isPlausibleWriterToken(last) { return last }
        return nil
    }

    private nonisolated static func isPlausibleWriterToken(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 24 else { return false }
        if trimmed.count >= 2 && trimmed.count <= 4, trimmed.allSatisfy({ $0.isLetter }) {
            return true
        }
        if trimmed == trimmed.uppercased(), trimmed.count >= 3, trimmed.allSatisfy({ $0.isLetter }) {
            return true
        }
        return false
    }

    private nonisolated static func formatRank(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "wav": return 0
        case "aiff", "aif": return 1
        case "flac": return 2
        case "m4a": return 3
        case "mp3": return 4
        case "aac": return 5
        default: return 99
        }
    }
}
