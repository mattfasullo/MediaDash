import Foundation

/// Decides whether Approve can queue immediately or still needs a sheet.
enum DocketApprovalPrompt: Equatable {
    case enqueue(docketNumber: String, jobName: String)
    case requestMissingFields
    case blockedNeedsReview

    static func decide(
        requiresConfirmation: Bool?,
        docketNumber: String?,
        jobName: String?
    ) -> DocketApprovalPrompt {
        if requiresConfirmation == true {
            return .blockedNeedsReview
        }
        let number = docketNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = jobName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !number.isEmpty, number != "TBD", !name.isEmpty else {
            return .requestMissingFields
        }
        return .enqueue(docketNumber: number, jobName: name)
    }
}
