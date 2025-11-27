import SwiftUI
import AppKit

// MARK: - Onboarding Step

enum OnboardingStep: Int, CaseIterable {
    case welcome = 0
    case serverPath = 1
    case docketSource = 2
    case integrations = 3
    case complete = 4
    
    var title: String {
        switch self {
        case .welcome: return "Welcome to MediaDash"
        case .serverPath: return "Configure Your Workspace"
        case .docketSource: return "Connect Your Dockets"
        case .integrations: return "Optional Integrations"
        case .complete: return "You're All Set!"
        }
    }
    
    var subtitle: String {
        switch self {
        case .welcome: return "Professional media management, streamlined"
        case .serverPath: return "Set up your server paths"
        case .docketSource: return "Choose where your docket data lives"
        case .integrations: return "Supercharge your workflow"
        case .complete: return "Start managing your media"
        }
    }
    
    var icon: String {
        switch self {
        case .welcome: return "sparkles"
        case .serverPath: return "folder.badge.gearshape"
        case .docketSource: return "doc.text.magnifyingglass"
        case .integrations: return "link.circle"
        case .complete: return "checkmark.seal.fill"
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @ObservedObject var settingsManager: SettingsManager
    
    @State private var currentStep: OnboardingStep = .welcome
    @State private var serverBasePath: String = ""
    @State private var sessionsBasePath: String = ""
    @State private var selectedDocketSource: DocketSource = .csv
    @State private var enableGmail: Bool = false
    @State private var enableAsana: Bool = false
    @State private var isPathValid: Bool? = nil
    @State private var isSessionsPathValid: Bool? = nil
    @State private var animateContent: Bool = false
    
    private let accentGradient = LinearGradient(
        colors: [Color.blue, Color.purple],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    var body: some View {
        ZStack {
            // Background
            backgroundView
            
            // Content
            VStack(spacing: 0) {
                // Progress indicator
                progressIndicator
                    .padding(.top, 40)
                
                Spacer()
                
                // Step content
                stepContent
                    .opacity(animateContent ? 1 : 0)
                    .offset(y: animateContent ? 0 : 20)
                
                Spacer()
                
                // Navigation buttons
                navigationButtons
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 60)
        }
        .frame(width: 700, height: 550)
        .onAppear {
            // Load current settings
            serverBasePath = settingsManager.currentSettings.serverBasePath
            sessionsBasePath = settingsManager.currentSettings.sessionsBasePath
            selectedDocketSource = settingsManager.currentSettings.docketSource
            
            withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
                animateContent = true
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundView: some View {
        ZStack {
            // Base dark gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            
            // Subtle accent orbs
            Circle()
                .fill(Color.blue.opacity(0.08))
                .frame(width: 400, height: 400)
                .blur(radius: 100)
                .offset(x: -200, y: -150)
            
            Circle()
                .fill(Color.purple.opacity(0.06))
                .frame(width: 300, height: 300)
                .blur(radius: 80)
                .offset(x: 200, y: 150)
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Progress Indicator
    
    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                if step != .complete {
                    Capsule()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: step == currentStep ? 32 : 12, height: 6)
                        .animation(.spring(response: 0.3), value: currentStep)
                }
            }
        }
    }
    
    // MARK: - Step Content
    
    @ViewBuilder
    private var stepContent: some View {
        VStack(spacing: 32) {
            // Icon
            ZStack {
                Circle()
                    .fill(accentGradient.opacity(0.15))
                    .frame(width: 100, height: 100)
                
                Image(systemName: currentStep.icon)
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(accentGradient)
            }
            
            // Title & Subtitle
            VStack(spacing: 12) {
                Text(currentStep.title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                
                Text(currentStep.subtitle)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            
            // Step-specific content
            stepSpecificContent
        }
    }
    
    @ViewBuilder
    private var stepSpecificContent: some View {
        switch currentStep {
        case .welcome:
            welcomeContent
        case .serverPath:
            serverPathContent
        case .docketSource:
            docketSourceContent
        case .integrations:
            integrationsContent
        case .complete:
            completeContent
        }
    }
    
    // MARK: - Welcome Content
    
    private var welcomeContent: some View {
        VStack(spacing: 24) {
            HStack(spacing: 40) {
                FeatureCard(
                    icon: "tray.2.fill",
                    title: "Smart Staging",
                    description: "Drag & drop files for intelligent organization"
                )
                
                FeatureCard(
                    icon: "film.stack",
                    title: "Video Conversion",
                    description: "Convert to ProRes Proxy with one click"
                )
                
                FeatureCard(
                    icon: "bell.badge.fill",
                    title: "Email Alerts",
                    description: "Get notified of new dockets automatically"
                )
            }
        }
        .padding(.top, 20)
    }
    
    // MARK: - Server Path Content
    
    private var serverPathContent: some View {
        VStack(spacing: 24) {
            // Server Base Path
            PathInputField(
                label: "Server Base Path",
                placeholder: "/Volumes/Server/Media",
                path: $serverBasePath,
                isValid: $isPathValid,
                helpText: "The root folder where your media projects are stored"
            )
            
            // Sessions Path
            PathInputField(
                label: "Pro Tools Sessions Path",
                placeholder: "/Volumes/Server/Sessions",
                path: $sessionsBasePath,
                isValid: $isSessionsPathValid,
                helpText: "Where your Pro Tools session files are stored"
            )
        }
        .frame(width: 500)
    }
    
    // MARK: - Docket Source Content
    
    private var docketSourceContent: some View {
        VStack(spacing: 20) {
            ForEach(DocketSource.allCases, id: \.self) { source in
                DocketSourceCard(
                    source: source,
                    isSelected: selectedDocketSource == source,
                    action: { selectedDocketSource = source }
                )
            }
        }
        .frame(width: 450)
    }
    
    // MARK: - Integrations Content
    
    private var integrationsContent: some View {
        VStack(spacing: 20) {
            IntegrationToggle(
                icon: "envelope.fill",
                title: "Gmail Integration",
                description: "Scan emails for new docket notifications",
                isEnabled: $enableGmail,
                color: .red
            )
            
            IntegrationToggle(
                icon: "checklist",
                title: "Asana Integration",
                description: "Sync dockets from your Asana workspace",
                isEnabled: $enableAsana,
                color: .orange
            )
            
            Text("You can configure these integrations later in Settings")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(width: 450)
    }
    
    // MARK: - Complete Content
    
    private var completeContent: some View {
        VStack(spacing: 16) {
            Text("🎉")
                .font(.system(size: 60))
            
            Text("MediaDash is ready to use")
                .font(.headline)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 8) {
                SummaryRow(label: "Server Path", value: serverBasePath.isEmpty ? "Not set" : shortenPath(serverBasePath))
                SummaryRow(label: "Docket Source", value: selectedDocketSource.displayName)
                if enableGmail {
                    SummaryRow(label: "Gmail", value: "Enabled (configure in Settings)")
                }
                if enableAsana {
                    SummaryRow(label: "Asana", value: "Enabled (configure in Settings)")
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)
        }
        .frame(width: 400)
    }
    
    // MARK: - Navigation Buttons
    
    private var navigationButtons: some View {
        HStack(spacing: 16) {
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation(.spring(response: 0.4)) {
                        animateContent = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let previousStep = OnboardingStep(rawValue: currentStep.rawValue - 1) {
                            currentStep = previousStep
                        }
                        withAnimation(.spring(response: 0.4)) {
                            animateContent = true
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            Spacer()
            
            if currentStep == .complete {
                Button("Get Started") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button(currentStep == .integrations ? "Finish Setup" : "Continue") {
                    advanceStep()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
    
    // MARK: - Actions
    
    private func advanceStep() {
        // Save settings for current step
        saveCurrentStepSettings()
        
        withAnimation(.spring(response: 0.4)) {
            animateContent = false
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) {
                currentStep = nextStep
            }
            withAnimation(.spring(response: 0.4)) {
                animateContent = true
            }
        }
    }
    
    private func saveCurrentStepSettings() {
        var settings = settingsManager.currentSettings
        
        switch currentStep {
        case .serverPath:
            settings.serverBasePath = serverBasePath
            settings.sessionsBasePath = sessionsBasePath
        case .docketSource:
            settings.docketSource = selectedDocketSource
        case .integrations:
            settings.gmailEnabled = enableGmail
            if enableAsana {
                settings.docketSource = .asana
            }
        default:
            break
        }
        
        settingsManager.currentSettings = settings
        settingsManager.saveCurrentProfile()
    }
    
    private func completeOnboarding() {
        saveCurrentStepSettings()
        
        withAnimation(.easeOut(duration: 0.3)) {
            hasCompletedOnboarding = true
        }
    }
    
    private func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count > 3 {
            return "/.../" + components.suffix(2).joined(separator: "/")
        }
        return path
    }
}

// MARK: - Supporting Views

struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.blue)
            
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 140, height: 120)
        .padding()
        .background(Color.gray.opacity(0.08))
        .cornerRadius(16)
    }
}

struct PathInputField: View {
    let label: String
    let placeholder: String
    @Binding var path: String
    @Binding var isValid: Bool?
    let helpText: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                
                Spacer()
                
                if let valid = isValid {
                    Image(systemName: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(valid ? .green : .red)
                        .font(.system(size: 14))
                }
            }
            
            HStack {
                TextField(placeholder, text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: path) { _, newValue in
                        validatePath(newValue)
                    }
                
                Button("Browse...") {
                    selectFolder()
                }
                .buttonStyle(.bordered)
            }
            
            Text(helpText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func validatePath(_ path: String) {
        guard !path.isEmpty else {
            isValid = nil
            return
        }
        
        var isDirectory: ObjCBool = false
        isValid = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select \(label)"
        
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            validatePath(path)
        }
    }
}

struct DocketSourceCard: View {
    let source: DocketSource
    let isSelected: Bool
    let action: () -> Void
    
    private var icon: String {
        switch source {
        case .asana: return "checklist"
        case .csv: return "tablecells"
        case .server: return "server.rack"
        }
    }
    
    private var description: String {
        switch source {
        case .asana: return "Sync dockets from Asana projects"
        case .csv: return "Import from a CSV spreadsheet file"
        case .server: return "Scan folders on your server directly"
        }
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .frame(width: 40)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .blue : .gray.opacity(0.4))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

struct IntegrationToggle: View {
    let icon: String
    let title: String
    let description: String
    @Binding var isEnabled: Bool
    let color: Color
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(16)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

struct SummaryRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(
        hasCompletedOnboarding: .constant(false),
        settingsManager: SettingsManager()
    )
}

