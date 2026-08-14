import XCTest
@testable import MediaDash

@MainActor
final class DocketApprovalQueueTests: XCTestCase {

    private var queue: DocketApprovalQueue!

    override func setUp() {
        super.setUp()
        queue = DocketApprovalQueue()
    }

    func testEnqueueReachesSucceeded() async {
        let id = UUID()
        queue.processor = { _, _ in .success(()) }
        queue.enqueue(Self.job(id: id, jobName: "Acme"))

        await waitUntil {
            if case .succeeded = self.queue.state(for: id) { return true }
            return false
        }
        XCTAssertFalse(queue.isBusy(id))
        XCTAssertFalse(queue.isBannerVisible)
    }

    func testProcessesTwoJobsSerially() async {
        let first = UUID()
        let second = UUID()
        var order: [UUID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?

        queue.processor = { job, _ in
            order.append(job.notificationId)
            if job.notificationId == first {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    releaseFirst = cont
                }
            }
            return .success(())
        }

        queue.enqueue(Self.job(id: first, jobName: "A"))
        queue.enqueue(Self.job(id: second, jobName: "B"))

        await waitUntil { order.count == 1 }
        XCTAssertEqual(order, [first])
        XCTAssertEqual(queue.queuedCount, 1)
        XCTAssertTrue(queue.isBusy(second))
        XCTAssertTrue(queue.isBannerVisible)
        XCTAssertEqual(queue.activeLabel, "26124_A")

        releaseFirst?.resume()

        await waitUntil { order.count == 2 }
        XCTAssertEqual(order, [first, second])
        await waitUntil { self.queue.queuedCount == 0 && self.queue.activeLabel == nil }
    }

    func testDuplicateEnqueueWhileBusyIsIgnored() async {
        let id = UUID()
        var runs = 0
        var release: CheckedContinuation<Void, Never>?
        queue.processor = { _, _ in
            runs += 1
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                release = cont
            }
            return .success(())
        }

        let job = Self.job(id: id, jobName: "Acme")
        queue.enqueue(job)
        queue.enqueue(job)
        await waitUntil { runs == 1 }
        XCTAssertEqual(runs, 1)
        release?.resume()
        await waitUntil {
            if case .succeeded = self.queue.state(for: id) { return true }
            return false
        }
        XCTAssertEqual(runs, 1)
    }

    func testFailureRecordsMessage() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "Simian timeout" }
        }
        let id = UUID()
        queue.processor = { _, _ in .failure(Boom()) }
        queue.enqueue(Self.job(id: id, jobName: "X"))
        await waitUntil {
            if case .failed = self.queue.state(for: id) { return true }
            return false
        }
        if case .failed(let message) = queue.state(for: id) {
            XCTAssertEqual(message, "Simian timeout")
        } else {
            XCTFail("expected failed")
        }
        XCTAssertFalse(queue.isBusy(id))
    }

    func testProgressHandlerUpdatesState() async {
        let id = UUID()
        queue.processor = { _, progress in
            await progress("Creating Work Picture folder...", 0.4)
            return .success(())
        }
        queue.enqueue(Self.job(id: id, jobName: "Acme"))
        await waitUntil {
            if case .succeeded = self.queue.state(for: id) { return true }
            return false
        }
        XCTAssertNil(queue.activeLabel)
    }

    func testAllowsRetryAfterFailure() async {
        let id = UUID()
        var runs = 0
        queue.processor = { _, _ in
            runs += 1
            if runs == 1 { return .failure(DocketApprovalQueueError.noProcessor) }
            return .success(())
        }
        let job = Self.job(id: id, jobName: "Acme")
        queue.enqueue(job)
        await waitUntil {
            if case .failed = self.queue.state(for: id) { return true }
            return false
        }
        queue.enqueue(job)
        await waitUntil {
            if case .succeeded = self.queue.state(for: id) { return true }
            return false
        }
        XCTAssertEqual(runs, 2)
    }

    private static func job(id: UUID, jobName: String) -> DocketApprovalJob {
        DocketApprovalJob(notificationId: id, docketNumber: "26124", jobName: jobName)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: @escaping () -> Bool
    ) async {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("timed out waiting for condition")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
