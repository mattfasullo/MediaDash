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

    /// True if any Work Picture folder name starts with `{base}_` (case-sensitive match on prefix; base is normalized).
    static func workPictureContainsDocketNumber(_ rawDocketNumber: String, dockets: [String]) -> Bool {
        let base = baseNumericDocketString(rawDocketNumber)
        guard !base.isEmpty else { return false }
        let prefix = base + "_"
        return dockets.contains { $0.hasPrefix(prefix) }
    }

    /// True if any Simian project name starts with `{base}_` (job name may differ).
    static func simianProjectListContainsDocketNumber(_ rawDocketNumber: String, projectNames: [String]) -> Bool {
        let base = baseNumericDocketString(rawDocketNumber)
        guard !base.isEmpty else { return false }
        let prefix = base.lowercased() + "_"
        return projectNames.contains { $0.lowercased().hasPrefix(prefix) }
    }
}
