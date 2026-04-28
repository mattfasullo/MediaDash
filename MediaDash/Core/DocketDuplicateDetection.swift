import Foundation

/// Helpers for matching docket numbers against Work Picture folder names and Simian project names (number-only; job name may differ).
enum DocketDuplicateDetection {
    /// Strips optional `-XX` country suffix; returns the leading numeric docket string (e.g. `26150` from `26150-US`).
    static func baseNumericDocketString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dashIndex = trimmed.firstIndex(of: "-"),
           dashIndex > trimmed.startIndex,
           let suffixStart = trimmed.index(dashIndex, offsetBy: 1, limitedBy: trimmed.endIndex),
           trimmed.distance(from: suffixStart, to: trimmed.endIndex) >= 2,
           trimmed.distance(from: suffixStart, to: trimmed.endIndex) <= 3,
           trimmed[suffixStart...].allSatisfy({ $0.isLetter }) {
            return String(trimmed[..<dashIndex])
        }
        return trimmed
    }

    /// True if `candidate` starts with `{base}` or `{base}-XX` and then either ends or continues with a common delimiter.
    /// Delimiters supported after the docket token: `_`, `-`, or a space.
    private static func hasMatchingDocketPrefix(_ candidate: String, base: String, caseInsensitive: Bool) -> Bool {
        guard !base.isEmpty else { return false }
        let name = caseInsensitive ? candidate.lowercased() : candidate
        let normalizedBase = caseInsensitive ? base.lowercased() : base
        let pattern = "^" + NSRegularExpression.escapedPattern(for: normalizedBase) + "(?:-[a-z]{1,3})?(?:$|[_\\s-])"
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return false
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.firstMatch(in: name, options: [], range: range) != nil
    }

    /// True if any Work Picture folder name starts with `{base}_` or `{base}-XX_` (job name may differ).
    static func workPictureContainsDocketNumber(_ rawDocketNumber: String, dockets: [String]) -> Bool {
        let base = baseNumericDocketString(rawDocketNumber)
        return dockets.contains { hasMatchingDocketPrefix($0, base: base, caseInsensitive: true) }
    }

    /// True if any Simian project name starts with `{base}_` or `{base}-XX_` (job name may differ).
    static func simianProjectListContainsDocketNumber(_ rawDocketNumber: String, projectNames: [String]) -> Bool {
        let base = baseNumericDocketString(rawDocketNumber)
        return projectNames.contains { hasMatchingDocketPrefix($0, base: base, caseInsensitive: true) }
    }
}
