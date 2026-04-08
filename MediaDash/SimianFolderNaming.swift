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
