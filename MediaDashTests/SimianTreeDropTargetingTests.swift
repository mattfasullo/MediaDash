import XCTest
@testable import MediaDash

final class SimianTreeDropTargetingTests: XCTestCase {
    func testShouldDropOnFolderWhenPointerIsNearRowCenter() {
        XCTAssertTrue(SimianDropTargeting.shouldDropOnFolder(yInRow: 12, rowHeight: 24))
        XCTAssertTrue(SimianDropTargeting.shouldDropOnFolder(yInRow: 10, rowHeight: 24))
        XCTAssertTrue(SimianDropTargeting.shouldDropOnFolder(yInRow: 14, rowHeight: 24))
    }

    func testShouldNotDropOnFolderWhenPointerIsNearRowEdges() {
        XCTAssertFalse(SimianDropTargeting.shouldDropOnFolder(yInRow: 2, rowHeight: 24))
        XCTAssertFalse(SimianDropTargeting.shouldDropOnFolder(yInRow: 22, rowHeight: 24))
        XCTAssertFalse(SimianDropTargeting.shouldDropOnFolder(yInRow: 0, rowHeight: 24))
        XCTAssertFalse(SimianDropTargeting.shouldDropOnFolder(yInRow: 24, rowHeight: 24))
    }
}
