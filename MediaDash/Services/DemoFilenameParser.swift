import Foundation

// MARK: - Types

enum DemoParseConfidence: String, Sendable, Equatable {
    case high
    case medium
    case low
}

/// Parsed revision / option / embedded-date signals. Higher values mean “newer” within the same round.
/// Order: `rev` → `v` → `opt` → `embeddedDateOrdinal` (see `VersionScore.precedenceCompare`).
struct VersionScore: Sendable, Hashable, Comparable {
    /// Best-effort revision index (REV3 → 3, bare `rev` / `rev1` → 1, absent → 0).
    var rev: Int
    /// `_v3`, ` v3` when clearly a version token.
    var v: Int
    /// OPT2 → 2; letter options mapped to 1…26.
    var opt: Int
    /// Best embedded date as yyyymmdd; 0 if none.
    var embeddedDateOrdinal: Int

    nonisolated static func == (lhs: VersionScore, rhs: VersionScore) -> Bool {
        lhs.rev == rhs.rev && lhs.v == rhs.v && lhs.opt == rhs.opt && lhs.embeddedDateOrdinal == rhs.embeddedDateOrdinal
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(rev)
        hasher.combine(v)
        hasher.combine(opt)
        hasher.combine(embeddedDateOrdinal)
    }

    nonisolated static func < (lhs: VersionScore, rhs: VersionScore) -> Bool {
        lhs.precedenceCompare(to: rhs) == .orderedAscending
    }

    /// Older / worse first when ascending (for sorting candidates).
    nonisolated fileprivate func precedenceCompare(to other: VersionScore) -> ComparisonResult {
        if rev != other.rev { return rev < other.rev ? .orderedAscending : .orderedDescending }
        if v != other.v { return v < other.v ? .orderedAscending : .orderedDescending }
        if opt != other.opt { return opt < other.opt ? .orderedAscending : .orderedDescending }
        if embeddedDateOrdinal != other.embeddedDateOrdinal {
            return embeddedDateOrdinal < other.embeddedDateOrdinal ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// True if this score is strictly newer than `other` (same round comparison).
    nonisolated func isNewerThan(_ other: VersionScore) -> Bool {
        precedenceCompare(to: other) == .orderedDescending
    }
}

struct DemoFilenameParseResult: Sendable, Equatable {
    /// Order-independent signature for “same demo line” across rounds (colour + client tokens; no rev/date; includes variant tail stripped elsewhere).
    let lineageKey: String
    /// Grouping key for UI (typically lineage without canonical colour).
    let familyKey: String
    /// Deliverable key (sting, OPT, duration, etc.).
    let variantKey: String
    let displayFamily: String
    let displayVariant: String
    let canonicalColorName: String?
    let versionScore: VersionScore
    let embeddedDates: [DateComponents]
    let confidence: DemoParseConfidence

    nonisolated static func == (lhs: DemoFilenameParseResult, rhs: DemoFilenameParseResult) -> Bool {
        lhs.lineageKey == rhs.lineageKey
            && lhs.familyKey == rhs.familyKey
            && lhs.variantKey == rhs.variantKey
            && lhs.displayFamily == rhs.displayFamily
            && lhs.displayVariant == rhs.displayVariant
            && lhs.canonicalColorName == rhs.canonicalColorName
            && lhs.versionScore == rhs.versionScore
            && lhs.embeddedDates == rhs.embeddedDates
            && lhs.confidence == rhs.confidence
    }
}

// MARK: - Parser

enum DemoFilenameParser {

    /// NFC-normalize, strip zero-width / BOM noise, trim.
    nonisolated static func normalizeUnicode(_ raw: String) -> String {
        let nfc = raw.precomposedStringWithCanonicalMapping
        let strippedZW = nfc.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x200B...0x200D, 0xFEFF: return false
            default: return true
            }
        }.map { String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return stripDuplicateFilenameSuffixes(strippedZW)
    }

    /// Dropbox/OneDrive-style duplicate tails (best-effort; does not change behaviour when absent).
    nonisolated private static func stripDuplicateFilenameSuffixes(_ s: String) -> String {
        var t = s
        let suffixes = [
            " conflicted copy",
            " Conflicted copy",
            " copy",
            " Copy",
            " (1)", " (2)", " (3)", " (4)", " (5)"
        ]
        for suf in suffixes where t.hasSuffix(suf) {
            t.removeLast(suf.count)
            break
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func parse(stem: String, defaultYear: Int) -> DemoFilenameParseResult {
        let normalizedStem = normalizeUnicode(stem)
        let canonicalColor = DemoTrackColorPalette.colorNameMatchingStem(normalizedStem).map { $0.uppercased() }

        let embeddedDates = extractEmbeddedDates(from: normalizedStem, defaultYear: defaultYear)
        let bestDateOrdinal = embeddedDates.compactMap { ordinal(from: $0) }.max() ?? 0

        let versionScore = buildVersionScore(stemForRegex: normalizedStem, embeddedDateOrdinal: bestDateOrdinal)

        let rawTokens = tokenize(normalizedStem)
        let (variantTokens, contentTokens) = partitionVariantTokens(rawTokens)

        var lineageSet = Set<String>()
        for t in contentTokens {
            let u = t.uppercased()
            if isDateLikeToken(t) { continue }
            if isRevOnlyToken(t) { continue }
            if u.count >= 2 { lineageSet.insert(u) }
        }
        if let c = canonicalColor {
            lineageSet.insert(c)
        }

        let lineageKey = lineageSet.sorted().joined(separator: "|")

        var familySet = lineageSet
        if let c = canonicalColor {
            familySet.remove(c)
        }
        let familyKey = familySet.sorted().joined(separator: "|")

        let variantKey = Set(variantTokens.map { $0.uppercased() }).sorted().joined(separator: "|")

        let displayFamily = makeDisplayFamily(contentTokens: contentTokens, canonicalColor: canonicalColor)
        let displayVariant = variantTokens.isEmpty ? "—" : variantTokens.joined(separator: " · ")

        let confidence = assessConfidence(
            lineageTokenCount: lineageSet.count,
            hasPaletteColor: canonicalColor != nil,
            variantCount: variantTokens.count
        )

        return DemoFilenameParseResult(
            lineageKey: lineageKey.isEmpty ? normalizedStem.uppercased() : lineageKey,
            familyKey: familyKey.isEmpty ? lineageKey : familyKey,
            variantKey: variantKey.isEmpty ? "—" : variantKey,
            displayFamily: displayFamily.isEmpty ? normalizedStem : displayFamily,
            displayVariant: displayVariant,
            canonicalColorName: canonicalColor.map { $0.capitalized },
            versionScore: versionScore,
            embeddedDates: embeddedDates,
            confidence: confidence
        )
    }

    // MARK: Tokenization

    nonisolated private static func tokenize(_ stem: String) -> [String] {
        var s = stem.replacingOccurrences(of: " - ", with: "_")
        s = s.replacingOccurrences(of: "-", with: "_")
        s = s.replacingOccurrences(of: "+", with: "_")
        let parts = s.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    nonisolated private static func partitionVariantTokens(_ tokens: [String]) -> (variant: [String], content: [String]) {
        var variant: [String] = []
        var content: [String] = []
        for t in tokens {
            if isVariantToken(t) {
                variant.append(t)
            } else {
                content.append(t)
            }
        }
        return (variant, content)
    }

    nonisolated private static func isVariantToken(_ token: String) -> Bool {
        let lower = token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("sting") { return true }
        if lower.range(of: #"^opt\d+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^option[a-z0-9]+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^\d+s$"#, options: .regularExpression) != nil { return true }
        if ["NOVOX", "VOX", "ALT", "INSTR", "INST", "MIX", "FULL", "TV", "RADIO"].contains(lower.uppercased()) { return true }
        // Same track, different bounce (instrumental / acapella / etc.) — belongs in variant, not lineage.
        if isMixDeliverableToken(lower) { return true }
        return false
    }

    /// Tokens that distinguish mix type but not “which song / colour line” (paired with `partitionVariantTokens` → lineage).
    nonisolated private static func isMixDeliverableToken(_ lower: String) -> Bool {
        guard !lower.isEmpty else { return false }
        switch lower {
        case "instrumental", "acapella", "acappella", "acapela":
            return true
        default:
            break
        }
        if lower == "a cappella" || lower.replacingOccurrences(of: " ", with: "") == "acappella" { return true }
        // Filename tails like `..._TV instrumental` (single token after trim is rare; keep bounded).
        if lower.hasSuffix("instrumental"), lower.count <= 24 { return true }
        if lower.hasPrefix("instr"), lower.hasSuffix("mental"), lower.count <= 24 { return true }
        return false
    }

    nonisolated private static func isRevOnlyToken(_ token: String) -> Bool {
        let lower = token.lowercased()
        if lower.range(of: #"^rev\d*$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^r\d{1,3}$"#, options: .regularExpression) != nil, lower.hasPrefix("r"), Int(lower.dropFirst()) != nil { return true }
        if lower.range(of: #"^rev[a-z]$"#, options: .regularExpression) != nil { return true }
        return false
    }

    nonisolated private static func isDateLikeToken(_ token: String) -> Bool {
        if token.range(of: #"(?i)^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\d{1,2}\.\d{2}$"#, options: .regularExpression) != nil {
            return true
        }
        if token.range(of: #"(?i)^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\d{1,2}$"#, options: .regularExpression) != nil {
            return true
        }
        if token.range(of: #"^\d{6,8}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    nonisolated private static func makeDisplayFamily(contentTokens: [String], canonicalColor: String?) -> String {
        let filtered = contentTokens.filter { tok in
            !isDateLikeToken(tok) && !isRevOnlyToken(tok)
        }
        guard !filtered.isEmpty else { return "" }
        return filtered.joined(separator: " ")
    }

    nonisolated private static func assessConfidence(lineageTokenCount: Int, hasPaletteColor: Bool, variantCount: Int) -> DemoParseConfidence {
        if lineageTokenCount >= 3 && hasPaletteColor { return .high }
        if lineageTokenCount >= 2 { return hasPaletteColor ? .high : .medium }
        if lineageTokenCount >= 1 { return .medium }
        return .low
    }

    // MARK: Version score from regex passes (documented order)

    nonisolated private static func buildVersionScore(stemForRegex: String, embeddedDateOrdinal: Int) -> VersionScore {
        var rev = 0
        var v = 0
        var opt = 0

        let s = stemForRegex

        // _REV\d+
        applyFirstCapture(#"_REV(\d+)"#, s) { rev = max(rev, Int($0) ?? 0) }
        // REV / rev with optional number (word-ish)
        applyFirstCapture(#"(?i)\bREV\s*(\d+)\b"#, s) { rev = max(rev, Int($0) ?? 0) }
        applyFirstCapture(#"(?i)\brev\s*(\d+)\b"#, s) { rev = max(rev, Int($0) ?? 0) }
        if (try? NSRegularExpression(pattern: #"(?i)\brev\b"#))?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            rev = max(rev, 1)
        }
        applyFirstCapture(#"(?i)_rev(\d+)_"#, s) { rev = max(rev, Int($0) ?? 0) }
        applyFirstCapture(#"(?i)_rev(\d+)\b"#, s) { rev = max(rev, Int($0) ?? 0) }

        // _v\d+ (avoid matching inside words — require non-letter before v)
        applyFirstCapture(#"(?i)[^a-zA-Z]v(\d+)\b"#, s) { v = max(v, Int($0) ?? 0) }
        applyFirstCapture(#"(?i)^v(\d+)\b"#, s) { v = max(v, Int($0) ?? 0) }

        // OPT
        applyFirstCapture(#"(?i)\bOPT\s*(\d+)\b"#, s) { opt = max(opt, Int($0) ?? 0) }
        applyFirstCapture(#"(?i)\bOPT(\d+)\b"#, s) { opt = max(opt, Int($0) ?? 0) }
        applyFirstCapture(#"(?i)\bOption\s*([A-Z0-9]+)\b"#, s) { opt = max(opt, optRank(from: $0)) }

        for tok in tokenize(s) where isRevOnlyToken(tok) {
            let low = tok.lowercased()
            if let n = Int(low.replacingOccurrences(of: "rev", with: "")) {
                rev = max(rev, n)
            } else if low.hasPrefix("rev") {
                rev = max(rev, 1)
            }
        }

        return VersionScore(rev: rev, v: v, opt: opt, embeddedDateOrdinal: embeddedDateOrdinal)
    }

    nonisolated private static func applyFirstCapture(_ pattern: String, _ string: String, onMatch: (String) -> Void) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(string.startIndex..., in: string)
        guard let m = re.firstMatch(in: string, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: string) else { return }
        onMatch(String(string[r]))
    }

    nonisolated private static func optRank(from raw: String) -> Int {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(s) { return n }
        if let c = s.uppercased().first, c.isLetter {
            return Int(c.asciiValue! - Character("A").asciiValue!) + 1
        }
        return 0
    }

    // MARK: Embedded dates

    nonisolated private static func extractEmbeddedDates(from stem: String, defaultYear: Int) -> [DateComponents] {
        var out: [DateComponents] = []
        // MMMdd.yy
        if let re = try? NSRegularExpression(pattern: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)(\d{1,2})\.(\d{2})\b"#) {
            let range = NSRange(stem.startIndex..., in: stem)
            re.enumerateMatches(in: stem, range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 4,
                      let mr = Range(match.range(at: 1), in: stem),
                      let dr = Range(match.range(at: 2), in: stem),
                      let yr = Range(match.range(at: 3), in: stem) else { return }
                let mon = String(stem[mr]).lowercased()
                guard let month = monthIndex(mon) else { return }
                let day = Int(String(stem[dr])) ?? 0
                let yy = Int(String(stem[yr])) ?? 0
                let year = 2000 + yy
                var dc = DateComponents()
                dc.year = year
                dc.month = month
                dc.day = day
                out.append(dc)
            }
        }
        // MMMdd (yearless — use defaultYear)
        if let re2 = try? NSRegularExpression(pattern: #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)(\d{1,2})\b"#) {
            let range = NSRange(stem.startIndex..., in: stem)
            re2.enumerateMatches(in: stem, range: range) { match, _, _ in
                guard let match, match.numberOfRanges >= 3,
                      let mr = Range(match.range(at: 1), in: stem),
                      let dr = Range(match.range(at: 2), in: stem) else { return }
                let mon = String(stem[mr]).lowercased()
                guard let month = monthIndex(mon) else { return }
                let day = Int(String(stem[dr])) ?? 0
                var dc = DateComponents()
                dc.year = defaultYear
                dc.month = month
                dc.day = day
                out.append(dc)
            }
        }
        return out
    }

    nonisolated private static func monthIndex(_ three: String) -> Int? {
        let m = [
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        ]
        return m[three]
    }

    nonisolated private static func ordinal(from dc: DateComponents) -> Int {
        guard let y = dc.year, let m = dc.month, let d = dc.day else { return 0 }
        return y * 10_000 + m * 100 + d
    }
}
