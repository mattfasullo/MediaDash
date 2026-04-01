import XCTest
@testable import MediaDash

final class GmailModelsTests: XCTestCase {

    /// Metadata-style `messages.get` responses omit large bodies but include ids and labelIds.
    func testGmailMessageDecodesMetadataShape() throws {
        let json = """
        {"id":"abc123","threadId":"thread1","labelIds":["UNREAD","Label_1"],"snippet":"Hello","internalDate":"1700000000000"}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let message = try JSONDecoder().decode(GmailMessage.self, from: data)
        XCTAssertEqual(message.id, "abc123")
        XCTAssertEqual(message.threadId, "thread1")
        XCTAssertEqual(message.labelIds, ["UNREAD", "Label_1"])
        XCTAssertEqual(message.snippet, "Hello")
    }
}
