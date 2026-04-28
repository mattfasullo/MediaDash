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
/// SECURITY NOTE: Never commit a real token — enable a read-only PAT locally via Keychain / Settings,
/// or inject at build time from a private, gitignored xcconfig (not checked in).
enum AirtableConfig {
    /// Read-only PAT for fallback docket reads. Empty in repo; optional for local/CI private builds.
    static let readOnlyDocketToken = ""

    /// Airtable base and table IDs for the Grayson dockets table.
    static let docketBaseID  = "appv3o3vhhb5QokNc"
    static let docketTableID = "tblrV5JzTdRvTg4jW"

    /// Exact Airtable column names.
    static let docketNumberField = "Docket"
    static let jobNameField      = "Licensor/Project Title"
}
