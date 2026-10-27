import XCTest
@testable import MediaDash

final class SimianTreeDropTargetingTests: XCTestCase {
    func testShouldDropOnFolderWhenPointerIsNearRowCenter() {
        XCTAssertTrue(SimianDropTargeting.shouldDropOnFolder(yInRow: 12, rowHeight: 24))
        XCTAssertTrue(SimianDropTargeting.shouldDropOnFolder(yInRow: 10, rowHeight: 24))
        XCTAssertTrue(SimianDropTargeting.shouldDropOnFolder(yInRow: 14, rowHeight: 24))
    }

    func testInsertedOrderPlacesFileBetweenFolders() {
        let current = ["f-1", "f-2", "file-a", "file-b"]
        let moved = SimianListOrdering.insertedOrder(currentIds: current, movingIds: ["file-a"], childIndex: 1)
        XCTAssertEqual(moved, ["f-1", "file-a", "f-2", "file-b"])
    }

    func testInsertedOrderCanPlaceARowAfterTheLastItem() {
        let current = ["file-a", "file-b", "f-1"]
        let moved = SimianListOrdering.insertedOrder(currentIds: current, movingIds: ["file-a"], childIndex: 3)
        XCTAssertEqual(moved, ["file-b", "f-1", "file-a"])
    }

    func testInsertedOrderAccountsForDraggedRowsStillInTheList() {
        let current = ["f-1", "f-2", "file-a", "file-b"]
        let moved = SimianListOrdering.insertedOrder(currentIds: current, movingIds: ["f-1"], childIndex: 3)
        XCTAssertEqual(moved, ["f-2", "file-a", "f-1", "file-b"])
    }

    func testReconciledOrderKeepsMixedOrderAndAppendsNewItems() {
        let order = SimianListOrdering.reconciled(
            saved: ["file-a", "f-1", "file-gone"],
            folderIds: ["1", "2"],
            fileIds: ["a", "b"]
        )
        XCTAssertEqual(order, ["file-a", "f-1", "f-2", "file-b"])
    }

    func testLinkSortMovesMatchThePublicLinkTopToBottom() {
        let moves = SimianListOrdering.linkSortMoves(
            parentFolderId: "45725",
            orderedTreeIds: ["file-179254", "file-179253", "f-45726"]
        )
        XCTAssertEqual(moves.map(\.moveNode), ["f_179254", "f_179253", "c_45726"])
        XCTAssertEqual(moves.map(\.position), [0, 1, 2])
        XCTAssertTrue(moves.allSatisfy { $0.parentNode == "c_45725" })
    }

    func testLinkSortMovesUseTheProjectRootWhenTheParentIsMissing() {
        let moves = SimianListOrdering.linkSortMoves(parentFolderId: nil, orderedTreeIds: ["f-1", "file-"])
        XCTAssertEqual(moves.map(\.moveNode), ["c_1"])
        XCTAssertEqual(moves.first?.parentNode, "c_1000000")
        XCTAssertEqual(moves.first?.position, 0)
    }

    func testReconciledOrderDefaultsToFoldersThenFiles() {
        XCTAssertEqual(
            SimianListOrdering.reconciled(saved: nil, folderIds: ["1"], fileIds: ["a"]),
            ["f-1", "file-a"]
        )
    }

    func testUnifiedRenameKeepsLabelAndFileNameIdentical() {
        XCTAssertEqual(
            SimianListOrdering.unifiedRenameName(typed: "Final Cut", currentTitle: "Song", currentFileName: "song_final.wav"),
            "Final Cut.wav"
        )
        XCTAssertEqual(
            SimianListOrdering.unifiedRenameName(typed: "Final Cut.mp3", currentTitle: "Song", currentFileName: "song_final.wav"),
            "Final Cut.mp3"
        )
    }

    func testSiblingInsertLandsAfterTheLastRowBelowItsTopBand() {
        XCTAssertEqual(
            SimianDropTargeting.siblingInsertChildIndex(yInRow: 20, rowHeight: 24, siblingIndex: 4, isLastSibling: true),
            5
        )
        XCTAssertEqual(
            SimianDropTargeting.siblingInsertChildIndex(yInRow: 8, rowHeight: 24, siblingIndex: 4, isLastSibling: true),
            5
        )
        XCTAssertEqual(
            SimianDropTargeting.siblingInsertChildIndex(yInRow: 2, rowHeight: 24, siblingIndex: 4, isLastSibling: true),
            4
        )
    }

    func testSiblingInsertAfterAMiddleRowUsesOnlyTheBottomBand() {
        XCTAssertEqual(
            SimianDropTargeting.siblingInsertChildIndex(yInRow: 20, rowHeight: 24, siblingIndex: 1, isLastSibling: false),
            2
        )
        XCTAssertEqual(
            SimianDropTargeting.siblingInsertChildIndex(yInRow: 8, rowHeight: 24, siblingIndex: 1, isLastSibling: false),
            1
        )
    }

    func testShouldNotDropOnFolderWhenPointerIsNearRowEdges() {
        XCTAssertFalse(SimianDropTargeting.shouldDropOnFolder(yInRow: 2, rowHeight: 24))
        XCTAssertFalse(SimianDropTargeting.shouldDropOnFolder(yInRow: 22, rowHeight: 24))
        XCTAssertFalse(SimianDropTargeting.shouldDropOnFolder(yInRow: 0, rowHeight: 24))
        XCTAssertFalse(SimianDropTargeting.shouldDropOnFolder(yInRow: 24, rowHeight: 24))
    }
}
