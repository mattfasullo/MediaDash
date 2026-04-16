import Foundation

/// Maps raw Music Demos folder names (e.g. `BG ~ Stems Only`) onto canonical writer tokens (`BG`) using the team writer library and Settings composer maps.
enum MusicDemosWriterResolver {

    /// Folder tokens longest-first so `BG` wins over `B` when prefix-matching.
    static func knownFolderTokensLongestFirst(
        serverWriters: [(name: String, folderName: String)],
        composerInitials: [String: String]?,
        displayNameForInitials: [String: String]?
    ) -> [String] {
        var collected: [String] = []
        for w in serverWriters {
            let f = w.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !f.isEmpty { collected.append(f) }
        }
        let mergedCI = AppSettings.defaultComposerInitials.merging(composerInitials ?? [:]) { _, user in user }
        for (_, folder) in mergedCI {
            let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !f.isEmpty { collected.append(f) }
        }
        let mergedDN = AppSettings.defaultDisplayNameForInitials.merging(displayNameForInitials ?? [:]) { _, user in user }
        for (folder, _) in mergedDN {
            let f = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !f.isEmpty { collected.append(f) }
        }
        var seen = Set<String>()
        var unique: [String] = []
        for f in collected {
            let k = f.lowercased()
            if seen.insert(k).inserted { unique.append(f) }
        }
        return unique.sorted { $0.count > $1.count }
    }

    /// Resolves a disk folder label to one canonical token when it matches the writer library (exact or `TOKEN ~ …` / `TOKEN - …`).
    static func canonicalFolder(raw: String, tokens: [String]) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return raw }
        let lower = t.lowercased()
        for f in tokens {
            if lower == f.lowercased() { return f }
        }
        for f in tokens {
            let fl = f.lowercased()
            if lower.hasPrefix(fl + " ~") || lower.hasPrefix(fl + " –") || lower.hasPrefix(fl + " -") {
                return f
            }
        }
        return t
    }

    /// Display name for sidebar: profile **displayNameForInitials** overrides (edits in Tools) win, then server roster, then default maps, then composer inverse, else the token.
    static func displayName(
        canonicalFolder: String,
        serverWriters: [(name: String, folderName: String)],
        settings: AppSettings
    ) -> String {
        let userDisp = settings.displayNameForInitials ?? [:]
        if let n = userDisp[canonicalFolder] { return n }
        if let pair = userDisp.first(where: { $0.key.caseInsensitiveCompare(canonicalFolder) == .orderedSame }) {
            return pair.value
        }
        if let w = serverWriters.first(where: { $0.folderName.caseInsensitiveCompare(canonicalFolder) == .orderedSame }) {
            return w.name
        }
        let disp = AppSettings.defaultDisplayNameForInitials.merging(userDisp) { _, user in user }
        if let n = disp[canonicalFolder] { return n }
        if let pair = disp.first(where: { $0.key.caseInsensitiveCompare(canonicalFolder) == .orderedSame }) {
            return pair.value
        }
        let initials = AppSettings.defaultComposerInitials.merging(settings.composerInitials ?? [:]) { _, user in user }
        if let (name, _) = initials.first(where: { $0.value.caseInsensitiveCompare(canonicalFolder) == .orderedSame }) {
            return name
        }
        return canonicalFolder
    }
}
