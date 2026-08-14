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

/// Serial queue for new-docket approval (Work Picture + Simian) so the UI stays usable.
@MainActor
final class DocketApprovalQueue: ObservableObject {
    static let shared = DocketApprovalQueue()

    @Published private(set) var states: [UUID: DocketApprovalJobState] = [:]
    @Published private(set) var activeLabel: String?
    @Published private(set) var activeMessage: String = ""
    @Published private(set) var activeFraction: Double = 0
    @Published private(set) var queuedCount: Int = 0

    typealias ProgressHandler = @MainActor (String, Double) -> Void
    typealias Processor = (DocketApprovalJob, ProgressHandler) async -> Result<Void, Error>

    var processor: Processor?
    var onJobFinished: ((UUID, Result<Void, Error>) -> Void)?

    private var pending: [DocketApprovalJob] = []
    private var isPumping = false

    var isBannerVisible: Bool {
        activeLabel != nil || queuedCount > 0
    }

    func state(for id: UUID) -> DocketApprovalJobState? {
        states[id]
    }

    func isBusy(_ id: UUID) -> Bool {
        switch states[id] {
        case .queued, .inProgress:
            return true
        default:
            return false
        }
    }

    func enqueue(_ job: DocketApprovalJob) {
        if isBusy(job.notificationId) { return }
        pending.append(job)
        states[job.notificationId] = .queued
        queuedCount = pending.count
        Task { await pump() }
    }

    func clearSucceeded(_ id: UUID) {
        if case .succeeded = states[id] {
            states.removeValue(forKey: id)
        }
    }

    private func pump() async {
        guard !isPumping else { return }
        isPumping = true
        defer { isPumping = false }

        while !pending.isEmpty {
            let job = pending.removeFirst()
            queuedCount = pending.count
            activeLabel = job.docketLabel
            activeMessage = "Starting…"
            activeFraction = 0.05
            states[job.notificationId] = .inProgress(message: activeMessage, fraction: activeFraction)
            await Task.yield()

            let progress: ProgressHandler = { [weak self] message, fraction in
                self?.activeMessage = message
                self?.activeFraction = fraction
                self?.states[job.notificationId] = .inProgress(message: message, fraction: fraction)
            }

            let result: Result<Void, Error>
            if let processor {
                result = await processor(job, progress)
            } else {
                result = .failure(DocketApprovalQueueError.noProcessor)
            }

            switch result {
            case .success:
                states[job.notificationId] = .succeeded
                activeFraction = 1
                activeMessage = "Done"
            case .failure(let error):
                states[job.notificationId] = .failed(error.localizedDescription)
            }
            onJobFinished?(job.notificationId, result)
            activeLabel = nil
            activeMessage = ""
            activeFraction = 0
        }
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
