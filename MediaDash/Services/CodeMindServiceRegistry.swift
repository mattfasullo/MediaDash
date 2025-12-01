import Foundation

/// Shared registry for services that CodeMind tools need to access
/// This allows CodeMind to access app services even when created in a separate window
@MainActor
class CodeMindServiceRegistry {
    static let shared = CodeMindServiceRegistry()
    
    // Email services
    weak var gmailService: GmailService?
    weak var emailScanningService: EmailScanningService?
    
    // Data services for docket verification
    weak var metadataManager: DocketMetadataManager?
    weak var asanaCacheManager: AsanaCacheManager?
    weak var settingsManager: SettingsManager?
    
    private init() {}
    
    /// Register email-related services
    func register(gmailService: GmailService?, emailScanningService: EmailScanningService?) {
        self.gmailService = gmailService
        self.emailScanningService = emailScanningService
    }
    
    /// Register all services needed for CodeMind tools
    func registerAll(
        gmailService: GmailService?,
        emailScanningService: EmailScanningService?,
        metadataManager: DocketMetadataManager?,
        asanaCacheManager: AsanaCacheManager?,
        settingsManager: SettingsManager?
    ) {
        self.gmailService = gmailService
        self.emailScanningService = emailScanningService
        self.metadataManager = metadataManager
        self.asanaCacheManager = asanaCacheManager
        self.settingsManager = settingsManager
    }
}

