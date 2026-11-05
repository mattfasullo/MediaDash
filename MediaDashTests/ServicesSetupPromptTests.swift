import XCTest
@testable import MediaDash

final class ServicesSetupPromptTests: XCTestCase {

    func testDisabledGmailDoesNotPromptWhenDetectionIsAirtable() {
        let shows = ServicesSetupPromptBuilder.shouldShowPrompt(
            gmail: status(name: "Gmail", isEnabled: false, needsSetup: false, isApplicable: false),
            asana: connected("Asana"),
            simian: connected("Simian"),
            dontShowAgain: false
        )
        XCTAssertFalse(shows)
    }

    func testEmailModeStillPromptsWhenGmailIsDisabled() {
        let shows = ServicesSetupPromptBuilder.shouldShowPrompt(
            gmail: status(name: "Gmail", isEnabled: false, needsSetup: true, isApplicable: true),
            asana: connected("Asana"),
            simian: connected("Simian"),
            dontShowAgain: false
        )
        XCTAssertTrue(shows)
    }

    func testDontShowAgainSuppressesDisabledIntegrations() {
        let shows = ServicesSetupPromptBuilder.shouldShowPrompt(
            gmail: status(name: "Gmail", isEnabled: false, needsSetup: true, isApplicable: true),
            asana: status(name: "Asana", isEnabled: false, needsSetup: true, isApplicable: true),
            simian: connected("Simian"),
            dontShowAgain: true
        )
        XCTAssertFalse(shows)
    }

    func testProducerIgnoresDisabledSimian() {
        let shows = ServicesSetupPromptBuilder.shouldShowPrompt(
            gmail: status(name: "Gmail", isEnabled: false, needsSetup: false, isApplicable: false),
            asana: connected("Asana"),
            simian: status(name: "Simian", isEnabled: false, needsSetup: true, isApplicable: true),
            dontShowAgain: false,
            isProducer: true
        )
        XCTAssertFalse(shows)
    }

    private func connected(_ name: String) -> ServiceSetupStatus {
        status(name: name, isEnabled: true, needsSetup: false, isApplicable: true, isConnected: true)
    }

    private func status(
        name: String,
        isEnabled: Bool,
        needsSetup: Bool,
        isApplicable: Bool,
        isConnected: Bool = false
    ) -> ServiceSetupStatus {
        ServiceSetupStatus(
            name: name,
            icon: "circle",
            isEnabled: isEnabled,
            isConnected: isConnected,
            needsSetup: needsSetup,
            isApplicable: isApplicable,
            disabledFunctions: []
        )
    }
}
