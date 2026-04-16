//
//  SimianFolderNaming.swift
//  MediaDash
//
//  Pure helpers for Simian folder names (not @MainActor — safe for tests and background use).
//

import Foundation

enum SimianFolderNaming {
    /// Regex for folder names like `01_Name` or `123_Name` (same as loose-file date folders `01_Apr01.26`).
    private static let numberedFolderPrefixRegex = try? NSRegularExpression(pattern: "^([0-9]{1,3})_(.+)$")

    /// Collect numeric prefixes from sibling folder names (e.g. `01_Foo` → 1).
    static func numberedPrefixValues(from folderNames: [String]) -> Set<Int> {
        folderNames.reduce(into: Set<Int>()) { result, name in
            guard let re = numberedFolderPrefixRegex,
                  let match = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let numRange = Range(match.range(at: 1), in: name),
                  let num = Int(name[numRange]) else { return }
            result.insert(num)
        }
    }

    /// Simian “main” category folders: loose file uploads get a dated `NN_MmmDD.yy` subfolder.
    static let looseFileAutoNestParentFolderNames: Set<String> = [
        "POSTINGS", "PICTURE", "FINALS", "MUSIC", "SESSIONS"
    ]

    /// Whether the destination folder name should trigger auto-nesting of loose files into `NN_MmmDD.yy`.
    static func shouldAutoNestLooseFiles(inDestinationFolderNamed name: String?) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return false }
        let upper = name.uppercased()
        return looseFileAutoNestParentFolderNames.contains(upper)
    }

    /// Resolve destination folder name for auto-nesting checks.
    /// Prefers explicit drop target name; otherwise falls back to current folder name
    /// (when dropping into the current directory) and then to a cached lookup.
    static func effectiveDestinationFolderName(
        providedName: String?,
        folderId: String?,
        currentFolderId: String?,
        currentFolderName: String?,
        cachedFolderName: String?
    ) -> String? {
        if let explicit = providedName?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        guard let folderId else { return nil }
        if folderId == currentFolderId,
           let current = currentFolderName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !current.isEmpty {
            return current
        }
        if let cached = cachedFolderName?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            return cached
        }
        return nil
    }

    /// Next sibling folder name `NN_MmmDD.yy` (e.g. `04_Apr01.26`) using the same index rules as `nextNumberedFolderName`.
    static func nextDateStampedLooseFileFolderName(existingFolderNames: [String], date: Date = Date(), timeZone: TimeZone? = nil) -> String {
        let existingNumbers = numberedPrefixValues(from: existingFolderNames)
        let nextNum = existingNumbers.isEmpty ? 1 : (existingNumbers.max() ?? 0) + 1
        let suffix = looseFileDateFolderSuffix(for: date, timeZone: timeZone)
        return String(format: "%02d_%@", nextNum, suffix)
    }

    static func looseFileDateFolderSuffix(for date: Date, timeZone: TimeZone? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone ?? TimeZone.current
        f.dateFormat = "MMMdd.yy"
        return f.string(from: date)
    }

    /// Trailing date stamp for file/folder labels: `_Apr08.26` (same calendar piece as loose-file folders, with a leading underscore).
    static func simianDateStampSuffix(for date: Date = Date(), timeZone: TimeZone? = nil) -> String {
        "_" + looseFileDateFolderSuffix(for: date, timeZone: timeZone)
    }

    /// `true` when the name stem already ends with `_Mmmdd.yy` or `_MmmD.yy` (e.g. `_Apr8.26`, `_Apr08.26`).
    static func stemHasSimianDateSuffix(_ stem: String) -> Bool {
        guard let re = simianDateStemSuffixRegex else { return false }
        let range = NSRange(stem.startIndex..., in: stem)
        return re.firstMatch(in: stem, options: [], range: range) != nil
    }

    /// Returns a new full file/folder label with today’s stamp appended before any extension, or `nil` if the stem already has a Simian date suffix.
    static func fullLabelByAppendingDateStamp(_ fullLabel: String, date: Date = Date(), timeZone: TimeZone? = nil) -> String? {
        // `NSString.pathExtension` treats `.26` in `…_Apr08.26` as extension `26`, so the “stem” no longer ends in
        // `_Apr08.26` and we’d append again → `…_Apr08.26.26`. Split using `stemAndExtensionPreservingDateYear` first.
        let (stem, ext) = stemAndExtensionPreservingDateYear(in: fullLabel)
        guard !stemHasSimianDateSuffix(stem) else { return nil }
        let suffix = simianDateStampSuffix(for: date, timeZone: timeZone)
        if ext.isEmpty { return stem + suffix }
        return stem + suffix + "." + ext
    }

    /// Append `_MMMdd.yy` before the real extension, or replace a trailing “similar” date segment with the canonical stamp for that calendar day.
    /// Uses `referenceDate`’s calendar year when the parsed label has no year. Returns the new full label (may equal input when already canonical).
    static func fullLabelByAddingOrNormalizingSimianDate(
        _ fullLabel: String,
        referenceDate: Date = Date(),
        timeZone: TimeZone? = nil
    ) -> String {
        let (stem, ext) = stemAndExtensionPreservingDateYear(in: fullLabel)
        let tz = timeZone ?? TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let refYear = cal.component(.year, from: referenceDate)
        if let parsed = parseTrailingSimianDateStemSuffix(stem, referenceYear: refYear) {
            let canonical = canonicalSimianDateStampSuffix(month: parsed.month, day: parsed.day, year: parsed.year, timeZone: tz)
            let newStem = stem.replacingCharacters(in: parsed.range, with: canonical)
            return joinStemAndExtension(stem: newStem, ext: ext)
        }
        let suffix = simianDateStampSuffix(for: referenceDate, timeZone: tz)
        if ext.isEmpty { return stem + suffix }
        return stem + suffix + "." + ext
    }

    /// Split stem / extension for appending a date. A final component that is exactly two digits is treated as the `yy`
    /// in `_Mmmdd.yy`, not a file extension (so `…_Apr08.26` stays one stem). Real extensions like `.mov` still split normally.
    private static func stemAndExtensionPreservingDateYear(in fullLabel: String) -> (stem: String, ext: String) {
        let ns = fullLabel as NSString
        let ext = ns.pathExtension
        if ext.isEmpty { return (fullLabel, "") }
        if ext.count == 2, ext.allSatisfy(\.isNumber) {
            return (fullLabel, "")
        }
        return ((ns.deletingPathExtension as String), ext)
    }

    private static let simianDateStemSuffixRegex = try? NSRegularExpression(
        pattern: #"_([A-Za-z]{3})(\d{1,2})\.(\d{2})$"#,
        options: []
    )

    /// `_NOV.13.26` — extra dot between month letters and day.
    private static let trailingDateExtraDotRegex = try? NSRegularExpression(
        pattern: #"_([A-Za-z]{3,4})\.(\d{1,2})\.(\d{2})$"#,
        options: []
    )
    /// `_Apr9.26`, `_Sept9.26` — month letters immediately before day.
    private static let trailingDateCompactRegex = try? NSRegularExpression(
        pattern: #"_([A-Za-z]{3,4})(\d{1,2})\.(\d{2})$"#,
        options: []
    )
    /// `_Sep22`, `_Sept22` — no year; use `referenceDate`’s year when applying.
    private static let trailingDateNoYearRegex = try? NSRegularExpression(
        pattern: #"_([A-Za-z]{3,4})(\d{1,2})$"#,
        options: []
    )

    private struct ParsedTrailingDate {
        let range: Range<String.Index>
        let month: Int
        let day: Int
        let year: Int
    }

    /// Trailing `_…` date on `stem` (end only): extra-dot (`_NOV.13.26`), compact (`_Apr9.26`), then month+day without year (`_Sep22`) using `referenceYear`.
    private static func parseTrailingSimianDateStemSuffix(_ stem: String, referenceYear: Int) -> ParsedTrailingDate? {
        let full = NSRange(stem.startIndex..., in: stem)
        if let re = trailingDateExtraDotRegex,
           let m = re.firstMatch(in: stem, options: [], range: full),
           let monthStr = Range(m.range(at: 1), in: stem).map({ String(stem[$0]) }),
           let dayStr = Range(m.range(at: 2), in: stem).map({ String(stem[$0]) }),
           let yyStr = Range(m.range(at: 3), in: stem).map({ String(stem[$0]) }),
           let month = monthIndex(fromAbbrev: monthStr),
           let day = Int(dayStr), let yy = Int(yyStr),
           let range = Range(m.range, in: stem) {
            let year = 2000 + yy
            if isValidCalendarDay(year: year, month: month, day: day) {
                return ParsedTrailingDate(range: range, month: month, day: day, year: year)
            }
        }
        if let re = trailingDateCompactRegex,
           let m = re.firstMatch(in: stem, options: [], range: full),
           let monthStr = Range(m.range(at: 1), in: stem).map({ String(stem[$0]) }),
           let dayStr = Range(m.range(at: 2), in: stem).map({ String(stem[$0]) }),
           let yyStr = Range(m.range(at: 3), in: stem).map({ String(stem[$0]) }),
           let month = monthIndex(fromAbbrev: monthStr),
           let day = Int(dayStr), let yy = Int(yyStr),
           let range = Range(m.range, in: stem) {
            let year = 2000 + yy
            if isValidCalendarDay(year: year, month: month, day: day) {
                return ParsedTrailingDate(range: range, month: month, day: day, year: year)
            }
        }
        if let re = trailingDateNoYearRegex,
           let m = re.firstMatch(in: stem, options: [], range: full),
           let monthStr = Range(m.range(at: 1), in: stem).map({ String(stem[$0]) }),
           let dayStr = Range(m.range(at: 2), in: stem).map({ String(stem[$0]) }),
           let month = monthIndex(fromAbbrev: monthStr),
           let day = Int(dayStr),
           let range = Range(m.range, in: stem),
           isValidCalendarDay(year: referenceYear, month: month, day: day) {
            return ParsedTrailingDate(range: range, month: month, day: day, year: referenceYear)
        }
        return nil
    }

    private static func canonicalSimianDateStampSuffix(month: Int, day: Int, year: Int, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else {
            return simianDateStampSuffix(for: Date(), timeZone: timeZone)
        }
        return simianDateStampSuffix(for: date, timeZone: timeZone)
    }

    private static func isValidCalendarDay(year: Int, month: Int, day: Int) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let d = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return c.year == year && c.month == month && c.day == day
    }

    /// Maps English month abbreviations (incl. `SEPT`, `NOV`, etc.) to 1...12.
    private static func monthIndex(fromAbbrev raw: String) -> Int? {
        switch raw.uppercased() {
        case "JAN": return 1
        case "FEB": return 2
        case "MAR": return 3
        case "APR": return 4
        case "MAY": return 5
        case "JUN": return 6
        case "JUL": return 7
        case "AUG": return 8
        case "SEP", "SEPT": return 9
        case "OCT": return 10
        case "NOV": return 11
        case "DEC": return 12
        default: return nil
        }
    }

    private static func joinStemAndExtension(stem: String, ext: String) -> String {
        if ext.isEmpty { return stem }
        return stem + "." + ext
    }

    /// Get the next folder number in sequence for numbered folders (01_, 02_, 03_, etc.)
    /// Only applies numbering when the destination already has numbered folders.
    static func nextNumberedFolderName(existingFolderNames: [String], sourceFolderName: String) -> String {
        let existingNumbers = numberedPrefixValues(from: existingFolderNames)
        guard !existingNumbers.isEmpty else {
            return sourceFolderName
        }
        let nextNum = (existingNumbers.max() ?? 0) + 1
        let prefix = String(format: "%02d_", nextNum)
        let baseName: String
        if let re = numberedFolderPrefixRegex,
           let match = re.firstMatch(in: sourceFolderName, range: NSRange(sourceFolderName.startIndex..., in: sourceFolderName)),
           let restRange = Range(match.range(at: 2), in: sourceFolderName) {
            baseName = String(sourceFolderName[restRange])
        } else {
            baseName = sourceFolderName
        }
        return prefix + baseName
    }
}
