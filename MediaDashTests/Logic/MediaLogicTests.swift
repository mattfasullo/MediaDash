import XCTest
@testable import MediaDash

final class MediaLogicTests: XCTestCase {

    func testLevenshteinDistance() {
        XCTAssertEqual(MediaLogic.levenshteinDistance("test", "test"), 0)
        XCTAssertEqual(MediaLogic.levenshteinDistance("test", "tets"), 2)
        XCTAssertEqual(MediaLogic.levenshteinDistance("kitten", "sitting"), 3)
    }
    
}

