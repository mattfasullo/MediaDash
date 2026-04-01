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
