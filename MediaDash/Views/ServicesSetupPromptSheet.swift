import SwiftUI

// MARK: - Service Setup State

struct ServiceSetupStatus {
    let name: String
    let icon: String
    let isEnabled: Bool
    let isConnected: Bool
    let needsSetup: Bool
    let disabledFunctions: [String]
}

// MARK: - Services Setup Prompt Sheet

/// Shown on app launch when Gmail, Asana, or Simian are disabled and/or not connected.
/// Users can open Settings to enable/connect, or decline and see a warning about what won't work.
struct ServicesSetupPromptSheet: View {
    @Binding var isPresented: Bool
    var onOpenSettings: () -> Void
    @AppStorage("servicesPromptDontShowAgain") private var dontShowAgain = false
    
    let gmailStatus: ServiceSetupStatus
    let asanaStatus: ServiceSetupStatus
    let simianStatus: ServiceSetupStatus
    
    private var servicesNeedingSetup: [ServiceSetupStatus] {
        [gmailStatus, asanaStatus, simianStatus].filter { $0.needsSetup }
    }
    
    private var hasAnyNeedingSetup: Bool {
        !servicesNeedingSetup.isEmpty
    }
    
    private var declineWarningMessage: String {
        var parts: [String] = []
        for service in servicesNeedingSetup {
            parts.append("• \(service.name): \(service.disabledFunctions.joined(separator: "; "))")
        }
        return "Without these connections, the following won't work:\n\n" + parts.joined(separator: "\n\n")
    }
    
    @State private var showDeclineWarning = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("Review Integrations")
                    .font(.system(size: 20, weight: .semibold))
                Text("Some integrations are disabled or not connected. Enable and connect them to get the full experience.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)
            
            // Service list
            VStack(alignment: .leading, spacing: 12) {
                serviceRow(gmailStatus)
                serviceRow(asanaStatus)
                serviceRow(simianStatus)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            
            // Don't show again
            HStack {
                Toggle("Don't show this again", isOn: $dontShowAgain)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            
            Spacer(minLength: 24)
            
            // Buttons
            HStack(spacing: 12) {
                Button("Not Now") {
                    if hasAnyNeedingSetup {
                        showDeclineWarning = true
                    } else {
                        isPresented = false
                    }
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Open Settings") {
                    isPresented = false
                    onOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 420, height: 480)
        .alert("What Won't Work", isPresented: $showDeclineWarning) {
            Button("OK") {
                isPresented = false
            }
        } message: {
            Text(declineWarningMessage)
        }
    }
    
    @ViewBuilder
    private func serviceRow(_ status: ServiceSetupStatus) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(status.needsSetup ? Color.orange.opacity(0.2) : Color.green.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: status.icon)
                    .font(.system(size: 18))
                    .foregroundColor(status.needsSetup ? .orange : .green)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(status.name)
                        .font(.system(size: 14, weight: .medium))
                    if !status.isEnabled {
                        Text("Disabled")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    } else if status.needsSetup {
                        Text("Not connected")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    } else if status.isEnabled {
                        Text("Connected")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    } else {
                        Text("Disabled")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                if status.needsSetup && !status.disabledFunctions.isEmpty {
                    Text(status.disabledFunctions.joined(separator: "; "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(10)
    }
}

// MARK: - Status Builder

enum ServicesSetupPromptBuilder {
    
    /// Build connection status for all three services.
    static func buildStatus(
        settings: AppSettings,
        simianService: SimianService
    ) -> (gmail: ServiceSetupStatus, asana: ServiceSetupStatus, simian: ServiceSetupStatus) {
        let gmail = ServiceSetupStatus(
            name: "Gmail",
            icon: "envelope.fill",
            isEnabled: settings.gmailEnabled,
            isConnected: settings.gmailEnabled && (SharedKeychainService.getGmailAccessToken() != nil && !(SharedKeychainService.getGmailAccessToken() ?? "").isEmpty),
            needsSetup: !settings.gmailEnabled || (settings.gmailEnabled && !(SharedKeychainService.getGmailAccessToken() != nil && !(SharedKeychainService.getGmailAccessToken() ?? "").isEmpty)),
            disabledFunctions: [
                "Email scanning for new dockets",
                "File delivery notifications",
                "Grabbed indicator for media files"
            ]
        )
        
        let asanaConnected = SharedKeychainService.getAsanaAccessToken() != nil
        let asanaEnabled = settings.docketSource == .asana
        let asana = ServiceSetupStatus(
            name: "Asana",
            icon: "checklist",
            isEnabled: asanaEnabled,
            isConnected: asanaEnabled && asanaConnected,
            needsSetup: !asanaEnabled || (asanaEnabled && !asanaConnected),
            disabledFunctions: [
                "Docket and job list sync",
                "Job info in prep flow",
                "Asana task creation"
            ]
        )
        
        // Simian credentials live in Keychain (SharedKeychainService), not in AppSettings
        let simianHasCredentials = SharedKeychainService.getSimianUsername() != nil && SharedKeychainService.getSimianPassword() != nil
        let simianHasBaseURL = (settings.simianAPIBaseURL ?? "").isEmpty == false
        let simian = ServiceSetupStatus(
            name: "Simian",
            icon: "archivebox.fill",
            isEnabled: settings.simianEnabled,
            isConnected: settings.simianEnabled && simianHasBaseURL && simianHasCredentials,
            needsSetup: !settings.simianEnabled || 
                (settings.simianEnabled && (!simianHasBaseURL || !simianHasCredentials)),
            disabledFunctions: [
                "Simian project creation from notifications"
            ]
        )
        
        return (gmail, asana, simian)
    }
    
    /// Returns true if we should show the prompt.
    /// Rules:
    /// - Always prompt when any integration is disabled (Simian is ignored for producer accounts).
    /// - Prompt for missing connections unless user selected "Don't show again".
    /// - When `isProducer` is true, Simian is not required and won't trigger the prompt.
    static func shouldShowPrompt(
        settings: AppSettings,
        simianService: SimianService,
        dontShowAgain: Bool,
        isProducer: Bool = false
    ) -> Bool {
        let (gmail, asana, simian) = buildStatus(settings: settings, simianService: simianService)
        let simianMatters = !isProducer
        let hasDisabledIntegrations = !gmail.isEnabled || !asana.isEnabled || (simianMatters && !simian.isEnabled)
        if hasDisabledIntegrations {
            return true
        }

        guard !dontShowAgain else { return false }
        return gmail.needsSetup || asana.needsSetup || (simianMatters && simian.needsSetup)
    }
}
