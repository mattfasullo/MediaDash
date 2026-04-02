import Foundation

/// JSON payload stored in a single Keychain generic-password item (`mediadash_credentials_blob_v1`).
/// All logical credential keys match the legacy per-account `kSecAttrAccount` strings.
enum KeychainCredentialsBlob {
    static let blobAccountName = "mediadash_credentials_blob_v1"
    static let currentSchemaVersion = 1

    /// Every `kSecAttrAccount` string the app may store under `com.mediadash.keychain`.
    static let allCredentialKeyNames: [String] = [
        "gmail_access_token",
        "gmail_refresh_token",
        "gmail_shared_access_token",
        "gmail_shared_refresh_token",
        "asana_access_token",
        "asana_refresh_token",
        "asana_shared_access_token",
        "asana_shared_refresh_token",
        "simian_username",
        "simian_password",
        "simian_shared_username",
        "simian_shared_password",
        "airtable_api_key",
        "airtable_shared_api_key"
    ]

    struct Payload: Codable, Equatable {
        var schemaVersion: Int
        var secrets: [String: String]
    }

    static func makePayload(secrets: [String: String]) -> Payload {
        Payload(schemaVersion: currentSchemaVersion, secrets: secrets)
    }

    static func encode(_ payload: Payload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    static func decode(_ data: Data) -> Payload? {
        try? JSONDecoder().decode(Payload.self, from: data)
    }
}
