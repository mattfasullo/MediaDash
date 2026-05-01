import Foundation

/// Compile-time Airtable configuration for the built-in read-only fallback token.
///
/// This token is used as a last resort when a user has no personal Airtable API key
/// and no shared team key in Keychain — e.g. a new team member who hasn't connected
/// Airtable yet but wants new-docket detection to work immediately.
///
/// HOW TO CREATE THE TOKEN:
/// 1. Go to https://airtable.com/create/tokens
/// 2. Name it "MediaDash Read-Only (Built-in)"
/// 3. Scopes: add ONLY `data.records:read`
/// 4. Access: add ONLY the specific base that contains dockets (e.g. "Grayson Dockets")
/// 5. Create token → copy and paste below
/// 6. Rebuild and ship the app
///
/// SECURITY NOTE: Never commit a real token — prefer Keychain / Settings, or a one-line file on your private
/// file share: `mediadash_airtable_readonly_token.txt` in the same folder as `mediadash_docket_cache.json`
/// (see `sharedCacheURL`). Also `~/.mediadash/airtable_readonly_token`, Info.plist `AirtableReadOnlyDocketToken`,
/// or `readOnlyDocketToken` from a private xcconfig.
enum AirtableConfig {
    /// Placed on the company server next to shared docket cache JSON (first line = PAT only).
    nonisolated static let sharedServerReadOnlyTokenFileName = "mediadash_airtable_readonly_token.txt"
    /// Real Airtable PATs are ~80 characters; shorter values are almost always placeholders or paste errors.
    /// Ignoring them lets Keychain / other fallbacks win when the team file is stale or truncated.
    nonisolated static let minimumPracticalPersonalAccessTokenLength = 40
    /// Read-only PAT for fallback docket reads. Empty in repo; optional for local/CI private builds.
    static let readOnlyDocketToken = ""

    /// Info.plist key for a read-only PAT without editing Swift (merge locally; leave empty in git).
    static let readOnlyDocketTokenInfoPlistKey = "AirtableReadOnlyDocketToken"

    /// Built-in fallback only (Keychain is handled in `SharedKeychainService`). Order: DEBUG env → local file → Info.plist → compile-time constant.
    static var effectiveReadOnlyDocketToken: String {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["AIRTABLE_READONLY_DOCKET_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        if let t = Self.tokenFromHomeMediadashFile(), !t.isEmpty { return t }
        if let plist = Bundle.main.object(forInfoDictionaryKey: readOnlyDocketTokenInfoPlistKey) as? String {
            let t = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return readOnlyDocketToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenFromHomeMediadashFile() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mediadash", isDirectory: true)
            .appendingPathComponent("airtable_readonly_token", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return firstLineToken(from: data)
    }

    /// Read-only PAT from the shared cache directory (`SyncCoordination` resolves the same folder as the docket cache).
    nonisolated static func readOnlyTokenFromSharedCacheDirectory(sharedCacheURLString: String?) -> String? {
        let trimmedIn = sharedCacheURLString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedIn.isEmpty else { return nil }

        guard let syncLockDir = SyncCoordination.syncLockDirectoryURL(sharedCacheURL: trimmedIn) else {
            return nil
        }

        let cacheDir = syncLockDir.deletingLastPathComponent()
        let tokenURL = cacheDir.appendingPathComponent(sharedServerReadOnlyTokenFileName, isDirectory: false)

        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return firstLineToken(from: data)
    }

    nonisolated private static func firstLineToken(from data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Trims whitespace/newlines, strips a leading UTF-8 BOM, and removes an accidental `Bearer ` prefix so callers can safely send `Authorization: Bearer <token>`.
    static func normalizeAirtablePersonalAccessToken(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "\u{FEFF}" {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = "Bearer "
        if s.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Airtable base and table IDs for the Grayson dockets table.
    static let docketBaseID  = "appv3o3vhhb5QokNc"
    static let docketTableID = "tblrV5JzTdRvTg4jW"

    /// Exact Airtable column names.
    static let docketNumberField = "Docket"
    static let jobNameField      = "Licensor/Project Title"
}
