import XCTest
@testable import MediaDash

final class KeychainBlobCodecTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let secrets = [
            "gmail_access_token": "a",
            "simian_password": "b",
            "airtable_api_key": "c"
        ]
        let payload = KeychainCredentialsBlob.makePayload(secrets: secrets)
        let data = try XCTUnwrap(KeychainCredentialsBlob.encode(payload))
        let decoded = try XCTUnwrap(KeychainCredentialsBlob.decode(data))
        XCTAssertEqual(decoded.secrets, secrets)
        XCTAssertEqual(decoded.schemaVersion, KeychainCredentialsBlob.currentSchemaVersion)
    }

    func testEmptySecretsRoundTrip() throws {
        let payload = KeychainCredentialsBlob.makePayload(secrets: [:])
        let data = try XCTUnwrap(KeychainCredentialsBlob.encode(payload))
        let decoded = try XCTUnwrap(KeychainCredentialsBlob.decode(data))
        XCTAssertEqual(decoded.secrets, [:])
    }

    func testMergeSemanticsLikeKeychainStore() {
        var secrets: [String: String] = ["k1": "v1", "k2": "v2"]
        secrets["k1"] = "updated"
        XCTAssertEqual(secrets["k1"], "updated")
        secrets.removeValue(forKey: "k2")
        XCTAssertNil(secrets["k2"])
        XCTAssertEqual(secrets.count, 1)
    }

    func testAllCredentialKeyNamesIncludesAirtable() {
        let names = KeychainCredentialsBlob.allCredentialKeyNames
        XCTAssertTrue(names.contains("airtable_api_key"))
        XCTAssertTrue(names.contains("airtable_shared_api_key"))
    }
}
