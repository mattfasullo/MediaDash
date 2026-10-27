import Foundation
import Combine

struct DocketApprovalJob: Equatable {
    let notificationId: UUID
    let docketNumber: String
    let jobName: String
    let projectManager: String?
    let template: String?

    var docketLabel: String { "\(docketNumber)_\(jobName)" }

    init(
        notificationId: UUID,
        docketNumber: String,
        jobName: String,
        projectManager: String? = nil,
        template: String? = nil
    ) {
        self.notificationId = notificationId
        self.docketNumber = docketNumber
        self.jobName = jobName
        self.projectManager = projectManager
        self.template = template
    }
}

enum DocketApprovalJobState: Equatable {
    case queued
    case inProgress(message: String, fraction: Double)
    case succeeded
    case failed(String)
}

struct DocketApprovalSnapshot: Equatable {
    var states: [UUID: DocketApprovalJobState] = [:]
    var activeLabel: String?
    var activeMessage: String = ""
    var activeFraction: Double = 0
    var queuedCount: Int = 0
}

/// Serial queue for new-docket approval (Work Picture + Simian) so the UI stays usable.
@MainActor
final class DocketApprovalQueue: ObservableObject {
    static let shared = DocketApprovalQueue()

    @Published private(set) var snapshot = DocketApprovalSnapshot()

    var states: [UUID: DocketApprovalJobState] { snapshot.states }
    var activeLabel: String? { snapshot.activeLabel }
    var activeMessage: String { snapshot.activeMessage }
    var activeFraction: Double { snapshot.activeFraction }
    var queuedCount: Int { snapshot.queuedCount }

    typealias ProgressHandler = @MainActor (String, Double) -> Void
    typealias Processor = (DocketApprovalJob, ProgressHandler) async -> Result<Void, Error>

    var processor: Processor?
    var onJobFinished: ((UUID, Result<Void, Error>) -> Void)?

    private var pending: [DocketApprovalJob] = []
    private var isPumping = false

    var isBannerVisible: Bool {
        snapshot.activeLabel != nil || snapshot.queuedCount > 0
    }

    func state(for id: UUID) -> DocketApprovalJobState? {
        snapshot.states[id]
    }

    func isBusy(_ id: UUID) -> Bool {
        switch snapshot.states[id] {
        case .queued, .inProgress:
            return true
        default:
            return false
        }
    }

    func enqueue(_ job: DocketApprovalJob) {
        if isBusy(job.notificationId) { return }
        pending.append(job)
        updateSnapshot { snap in
            snap.states[job.notificationId] = .queued
            snap.queuedCount = pending.count
        }
        Task { await pump() }
    }

    func clearSucceeded(_ id: UUID) {
        if case .succeeded = snapshot.states[id] {
            updateSnapshot { snap in
                snap.states.removeValue(forKey: id)
            }
        }
    }

    private func pump() async {
        guard !isPumping else { return }
        isPumping = true
        defer { isPumping = false }

        while !pending.isEmpty {
            let job = pending.removeFirst()
            updateSnapshot { snap in
                snap.queuedCount = pending.count
                snap.activeLabel = job.docketLabel
                snap.activeMessage = "Starting…"
                snap.activeFraction = 0.05
                snap.states[job.notificationId] = .inProgress(message: "Starting…", fraction: 0.05)
            }
            await Task.yield()

            let progress: ProgressHandler = { [weak self] message, fraction in
                self?.updateSnapshot { snap in
                    snap.activeMessage = message
                    snap.activeFraction = fraction
                    snap.states[job.notificationId] = .inProgress(message: message, fraction: fraction)
                }
            }

            let result: Result<Void, Error>
            if let processor {
                result = await processor(job, progress)
            } else {
                result = .failure(DocketApprovalQueueError.noProcessor)
            }

            switch result {
            case .success:
                updateSnapshot { snap in
                    snap.states[job.notificationId] = .succeeded
                    snap.activeFraction = 1
                    snap.activeMessage = "Done"
                }
            case .failure(let error):
                updateSnapshot { snap in
                    snap.states[job.notificationId] = .failed(error.localizedDescription)
                }
            }
            onJobFinished?(job.notificationId, result)
            updateSnapshot { snap in
                snap.activeLabel = nil
                snap.activeMessage = ""
                snap.activeFraction = 0
            }
        }
    }

    private func updateSnapshot(_ mutate: (inout DocketApprovalSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        snapshot = next
    }
}

enum DocketApprovalQueueError: LocalizedError {
    case noProcessor

    var errorDescription: String? {
        switch self {
        case .noProcessor: return "Approval processor is not configured"
        }
    }
}
