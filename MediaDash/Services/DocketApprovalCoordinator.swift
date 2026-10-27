import Foundation

enum DocketApprovalProcessError: LocalizedError {
    case missingServices
    case notificationMissing
    case workPicture(String)
    case simian(String)
    case multiple([String])

    var errorDescription: String? {
        switch self {
        case .missingServices:
            return "Approval is not configured yet"
        case .notificationMissing:
            return "Notification is no longer available"
        case .workPicture(let message):
            return message
        case .simian(let message):
            return message
        case .multiple(let parts):
            return parts.joined(separator: " • ")
        }
    }
}

/// Runs Work Picture + Simian creation for queued new-docket approvals.
@MainActor
final class DocketApprovalCoordinator {
    static let shared = DocketApprovalCoordinator()

    private weak var notificationCenter: NotificationCenter?
    private weak var emailScanningService: EmailScanningService?
    private weak var mediaManager: MediaManager?
    private weak var settingsManager: SettingsManager?
    private weak var simianService: SimianService?

    private var historyNotes: [UUID: String] = [:]
    private var didConfigureQueue = false

    private init() {}

    func configure(
        notificationCenter: NotificationCenter,
        emailScanningService: EmailScanningService,
        mediaManager: MediaManager,
        settingsManager: SettingsManager,
        simianService: SimianService
    ) {
        self.notificationCenter = notificationCenter
        self.emailScanningService = emailScanningService
        self.mediaManager = mediaManager
        self.settingsManager = settingsManager
        self.simianService = simianService

        guard !didConfigureQueue else { return }
        didConfigureQueue = true

        let queue = DocketApprovalQueue.shared
        queue.processor = { [weak self] job, progress in
            guard let self else { return .failure(DocketApprovalProcessError.missingServices) }
            return await self.process(job, progress: progress)
        }
        queue.onJobFinished = { [weak self] id, result in
            self?.handleJobFinished(id: id, result: result)
        }
    }

    func enqueue(
        notificationId: UUID,
        docketNumber: String,
        jobName: String,
        projectManager: String? = nil,
        template: String? = nil
    ) {
        DocketApprovalQueue.shared.enqueue(
            DocketApprovalJob(
                notificationId: notificationId,
                docketNumber: docketNumber,
                jobName: jobName,
                projectManager: projectManager,
                template: template
            )
        )
    }

    private func process(
        _ job: DocketApprovalJob,
        progress: DocketApprovalQueue.ProgressHandler
    ) async -> Result<Void, Error> {
        guard let notificationCenter,
              let emailScanningService,
              let settingsManager,
              let simianService else {
            return .failure(DocketApprovalProcessError.missingServices)
        }
        guard var updatedNotification = notificationCenter.notifications.first(where: { $0.id == job.notificationId }) else {
            return .failure(DocketApprovalProcessError.notificationMissing)
        }
        guard updatedNotification.requiresDocketConfirmation != true else {
            return .failure(DocketApprovalProcessError.notificationMissing)
        }

        notificationCenter.applyApprovalUpdate(
            id: job.notificationId,
            docketNumber: job.docketNumber,
            jobName: job.jobName
        )
        if let current = notificationCenter.notifications.first(where: { $0.id == job.notificationId }) {
            updatedNotification = current
        }

        let shouldCreateSimian = !updatedNotification.isInSimian &&
            (updatedNotification.shouldCreateSimianJob ||
             (settingsManager.currentSettings.simianEnabled && simianService.isConfigured))
        let shouldCreateWorkPicture = updatedNotification.shouldCreateWorkPicture && !updatedNotification.isInWorkPicture

        let playAddingSound = settingsManager.currentSettings.resolvedSoundDocketAddingEnabled
        let playAddedSound = settingsManager.currentSettings.resolvedSoundDocketAddedEnabled
        let addingVolume = settingsManager.currentSettings.resolvedSoundDocketAddingVolume
        let addedVolume = settingsManager.currentSettings.resolvedSoundDocketAddedVolume
        DocketAddSounds.startLoading(enabled: playAddingSound, volume: addingVolume)

        var workPictureError: Error?
        var simianError: Error?
        var simianAlreadyExisted = false

        if shouldCreateWorkPicture {
            do {
                await progress("Creating Work Picture folder...", 0.25)
                try await emailScanningService.createDocketFromNotification(
                    updatedNotification,
                    effectiveDocketNumber: job.docketNumber,
                    effectiveJobName: job.jobName
                )
                if let current = notificationCenter.notifications.first(where: { $0.id == job.notificationId }) {
                    notificationCenter.applyApprovalUpdate(
                        id: current.id,
                        isInWorkPicture: true,
                        workPictureCreatedByUs: true
                    )
                }
            } catch {
                workPictureError = error
                notificationCenter.add(
                    Notification(
                        type: .error,
                        title: "Work Picture Creation Failed",
                        message: error.localizedDescription
                    )
                )
            }
        }

        if shouldCreateSimian {
            configureSimianIfNeeded()
            do {
                await progress("Checking for existing Simian project...", 0.45)
                let projectAlreadyExists = try await simianService.projectExists(
                    docketNumber: job.docketNumber,
                    jobName: job.jobName
                )
                if projectAlreadyExists {
                    simianAlreadyExisted = true
                    if notificationCenter.notifications.contains(where: { $0.id == job.notificationId }) {
                        notificationCenter.applyApprovalUpdate(
                            id: job.notificationId,
                            isInSimian: true,
                            simianCreatedByUs: false
                        )
                    }
                } else {
                    await progress("Creating Simian project...", 0.7)
                    try await simianService.createJob(
                        docketNumber: job.docketNumber,
                        jobName: job.jobName,
                        projectManager: job.projectManager,
                        projectTemplate: job.template ?? settingsManager.currentSettings.simianProjectTemplate
                    )
                    if notificationCenter.notifications.contains(where: { $0.id == job.notificationId }) {
                        notificationCenter.applyApprovalUpdate(
                            id: job.notificationId,
                            isInSimian: true,
                            simianCreatedByUs: true
                        )
                    }
                }
            } catch {
                simianError = error
                notificationCenter.add(
                    Notification(
                        type: .error,
                        title: "Simian Project Creation Failed",
                        message: error.localizedDescription
                    )
                )
            }
        }

        DocketAddSounds.stopLoading()

        let wpOK = !shouldCreateWorkPicture || workPictureError == nil
        let simOK = !shouldCreateSimian || simianError == nil
        let attemptedCreation = shouldCreateWorkPicture || shouldCreateSimian

        if attemptedCreation && wpOK && simOK {
            DocketAddSounds.playDocketAdded(enabled: playAddedSound, volume: addedVolume)
        }

        if let current = notificationCenter.notifications.first(where: { $0.id == job.notificationId }) {
            await markEmailAsReadIfNeeded(current, emailScanningService: emailScanningService)
            if let emailId = current.emailId, attemptedCreation && wpOK && simOK {
                var details: [String: String] = [:]
                if shouldCreateWorkPicture && workPictureError == nil {
                    details["createdWorkPicture"] = "true"
                }
                if shouldCreateSimian && simianError == nil {
                    details["createdSimianJob"] = "true"
                }
                details["docketNumber"] = job.docketNumber
                EmailFeedbackTracker.shared.recordInteraction(
                    emailId: emailId,
                    type: .approved,
                    details: details.isEmpty ? nil : details
                )
            }
        }

        var historyParts: [String] = []
        if shouldCreateWorkPicture {
            historyParts.append(workPictureError == nil ? "Created in Work Picture" : "Work Picture failed")
        }
        if shouldCreateSimian {
            if simianError != nil {
                historyParts.append("Simian failed")
            } else if simianAlreadyExisted {
                historyParts.append("Already in Simian")
            } else {
                historyParts.append("Created in Simian")
            }
        }
        historyNotes[job.notificationId] = historyParts.isEmpty ? "Approved" : historyParts.joined(separator: " • ")

        if wpOK && simOK {
            await progress("Done", 1)
            return .success(())
        }

        var parts: [String] = []
        if let workPictureError { parts.append(workPictureError.localizedDescription) }
        if let simianError { parts.append(simianError.localizedDescription) }
        if parts.count > 1 {
            return .failure(DocketApprovalProcessError.multiple(parts))
        }
        if workPictureError != nil {
            return .failure(DocketApprovalProcessError.workPicture(parts[0]))
        }
        return .failure(DocketApprovalProcessError.simian(parts.first ?? "Approval failed"))
    }

    private func handleJobFinished(id: UUID, result: Result<Void, Error>) {
        switch result {
        case .success:
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.finishSuccessfulJob(id)
            }
        case .failure:
            historyNotes.removeValue(forKey: id)
        }
    }

    private func finishSuccessfulJob(_ id: UUID) {
        let note = historyNotes.removeValue(forKey: id) ?? "Approved"
        if let notificationCenter,
           let notification = notificationCenter.notifications.first(where: { $0.id == id }) {
            notificationCenter.markAsCompleted(notification, historyNote: note)
        }
        DocketApprovalQueue.shared.clearSucceeded(id)
    }

    private func configureSimianIfNeeded() {
        guard let settingsManager, let simianService else { return }
        let settings = settingsManager.currentSettings
        if let baseURL = settings.simianAPIBaseURL, !baseURL.isEmpty {
            simianService.setBaseURL(baseURL)
            if let username = SharedKeychainService.getSimianUsername(),
               let password = SharedKeychainService.getSimianPassword() {
                simianService.setCredentials(username: username, password: password)
            }
        }
    }

    private func markEmailAsReadIfNeeded(
        _ notification: Notification,
        emailScanningService: EmailScanningService
    ) async {
        guard let emailId = notification.emailId else { return }
        do {
            try await emailScanningService.gmailService.markAsRead(messageId: emailId)
        } catch {
            print("📧 DocketApprovalCoordinator: Failed to mark email \(emailId) as read: \(error.localizedDescription)")
        }
    }
}
