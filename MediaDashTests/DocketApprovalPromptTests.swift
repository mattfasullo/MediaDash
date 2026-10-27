import XCTest
@testable import MediaDash

final class DocketApprovalPromptTests: XCTestCase {

    func testFilledNumberAndNameEnqueues() {
        let decision = DocketApprovalPrompt.decide(
            requiresConfirmation: false,
            docketNumber: "26150",
            jobName: "Acme"
        )
        XCTAssertEqual(decision, .enqueue(docketNumber: "26150", jobName: "Acme"))
    }

    func testMissingNumberRequestsSheet() {
        let decision = DocketApprovalPrompt.decide(
            requiresConfirmation: false,
            docketNumber: nil,
            jobName: "Acme"
        )
        XCTAssertEqual(decision, .requestMissingFields)
    }

    func testTBDNumberRequestsSheet() {
        let decision = DocketApprovalPrompt.decide(
            requiresConfirmation: false,
            docketNumber: "TBD",
            jobName: "Acme"
        )
        XCTAssertEqual(decision, .requestMissingFields)
    }

    func testEmptyJobNameRequestsSheet() {
        let decision = DocketApprovalPrompt.decide(
            requiresConfirmation: false,
            docketNumber: "26150",
            jobName: "  "
        )
        XCTAssertEqual(decision, .requestMissingFields)
    }

    func testReviewQueueIsBlocked() {
        let decision = DocketApprovalPrompt.decide(
            requiresConfirmation: true,
            docketNumber: "26150",
            jobName: "Acme"
        )
        XCTAssertEqual(decision, .blockedNeedsReview)
    }
}
