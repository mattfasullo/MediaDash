import SwiftUI
import Foundation

struct SimianProjectCreationDialog: View {
    @Binding var isPresented: Bool
    @ObservedObject var simianService: SimianService
    @ObservedObject var settingsManager: SettingsManager
    
    let initialDocketNumber: String
    let initialJobName: String
    let sourceEmail: String? // Email sender to auto-match as project manager
    let initialProjectManager: String? // Pre-selected project manager from notification
    let isSimianEnabled: Bool // Whether Simian project will be created
    let onConfirm: (String, String, String?, String?) -> Void
    
    @State private var docketNumber: String
    @State private var jobName: String
    @State private var selectedProjectManagerEmail: String? // Store email instead of SimianUser
    @State private var selectedTemplate: SimianTemplate?
    @State private var templates: [SimianTemplate] = []
    @State private var isLoadingTemplates = false
    @State private var templatesLoadError: String?
    
    @FocusState private var focusedField: Field?
    
    enum Field {
        case docketNumber
        case jobName
    }
    
    init(
        isPresented: Binding<Bool>,
        simianService: SimianService,
        settingsManager: SettingsManager,
        initialDocketNumber: String,
        initialJobName: String,
        sourceEmail: String? = nil,
        initialProjectManager: String? = nil,
        isSimianEnabled: Bool = true,
        onConfirm: @escaping (String, String, String?, String?) -> Void
    ) {
        self._isPresented = isPresented
        self.simianService = simianService
        self.settingsManager = settingsManager
        self.initialDocketNumber = initialDocketNumber
        self.initialJobName = initialJobName
        self.sourceEmail = sourceEmail
        self.initialProjectManager = initialProjectManager
        self.isSimianEnabled = isSimianEnabled
        self.onConfirm = onConfirm
        
        // Initialize state with initial values
        _docketNumber = State(initialValue: initialDocketNumber)
        _jobName = State(initialValue: initialJobName)
        // Initialize project manager with the pre-selected value if provided
        _selectedProjectManagerEmail = State(initialValue: initialProjectManager)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Create Project")
                .font(.system(size: 18, weight: .semibold))
                .padding(.top, 8)
            
            VStack(alignment: .leading, spacing: 16) {
                // Docket Number
                VStack(alignment: .leading, spacing: 4) {
                    Text("Docket Number")
                        .font(.system(size: 13, weight: .medium))
                    TextField("Docket Number", text: $docketNumber)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .docketNumber)
                        .onSubmit {
                            focusedField = .jobName
                        }
                }
                
                // Job Name (Project Name)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Name")
                        .font(.system(size: 13, weight: .medium))
                    TextField("Project Name", text: $jobName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .jobName)
                }
                
                // Project Manager Dropdown (only show if Simian is enabled)
                if isSimianEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project Manager")
                            .font(.system(size: 13, weight: .medium))
                        
                        if settingsManager.currentSettings.simianProjectManagers.isEmpty {
                            Text("No project managers configured. Add them in Settings > Simian Integration.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else {
                            Picker("Project Manager", selection: $selectedProjectManagerEmail) {
                                Text("None (will use email sender)").tag(nil as String?)
                                ForEach(settingsManager.currentSettings.simianProjectManagers.filter { !$0.isEmpty }, id: \.self) { email in
                                    Text(email)
                                        .tag(email as String?)
                                }
                            }
                            .pickerStyle(.menu)
                            Text("Simian will match the email to an existing user when creating the project.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                    }
                    
                    // Project Template Dropdown (only show if Simian is enabled)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Project Template")
                            .font(.system(size: 13, weight: .medium))
                        
                        if isLoadingTemplates {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading templates...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        } else if let error = templatesLoadError {
                            Text("Error loading templates: \(error)")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                        } else {
                            Picker("Project Template", selection: $selectedTemplate) {
                                Text("None").tag(nil as SimianTemplate?)
                                ForEach(templates) { template in
                                    Text(template.name)
                                        .tag(template as SimianTemplate?)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
            }
            .frame(width: 400)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    print("🔔 SimianProjectCreationDialog: User cancelled")
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create Project") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(jobName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 450)
        .onAppear {
            // Only load Simian-specific data if Simian is enabled
            if isSimianEnabled {
                loadTemplates()
                
                // If project manager is already set from notification, use it
                // Otherwise, try to auto-match sourceEmail to a project manager from settings
                if selectedProjectManagerEmail == nil, let sourceEmail = sourceEmail, !sourceEmail.isEmpty {
                    let emailAddress = extractEmailAddress(from: sourceEmail)
                    print("🔍 SimianProjectCreationDialog: Attempting to match email sender: \(emailAddress)")
                    
                    // Find matching email in settings list (case-insensitive)
                    if let matchingEmail = settingsManager.currentSettings.simianProjectManagers.first(where: { $0.lowercased() == emailAddress.lowercased() }) {
                        selectedProjectManagerEmail = matchingEmail
                        print("✅ SimianProjectCreationDialog: Auto-selected project manager: \(matchingEmail)")
                    } else {
                        print("⚠️ SimianProjectCreationDialog: Email sender '\(emailAddress)' not in project managers list")
                    }
                } else if let initialPM = initialProjectManager {
                    print("✅ SimianProjectCreationDialog: Using pre-selected project manager: \(initialPM)")
                }
            }
            if docketNumber.isEmpty {
                focusedField = .docketNumber
            } else if jobName.isEmpty {
                focusedField = .jobName
            }
        }
    }
    
    /// Extract email address from sourceEmail string (handles "Name <email@example.com>" format)
    private func extractEmailAddress(from sourceEmail: String) -> String {
        // Check if it's in format "Name <email@example.com>"
        if let regex = try? NSRegularExpression(pattern: #"<([^>]+)>"#, options: []),
           let match = regex.firstMatch(in: sourceEmail, range: NSRange(sourceEmail.startIndex..., in: sourceEmail)),
           match.numberOfRanges >= 2 {
            let emailRange = Range(match.range(at: 1), in: sourceEmail)!
            return String(sourceEmail[emailRange]).trimmingCharacters(in: .whitespaces)
        }
        
        // If no angle brackets, check if it's just an email
        if let regex = try? NSRegularExpression(pattern: #"([^\s<>]+@[^\s<>]+)"#, options: []),
           let match = regex.firstMatch(in: sourceEmail, range: NSRange(sourceEmail.startIndex..., in: sourceEmail)),
           match.numberOfRanges >= 2 {
            let emailRange = Range(match.range(at: 1), in: sourceEmail)!
            return String(sourceEmail[emailRange]).trimmingCharacters(in: .whitespaces)
        }
        
        // Fallback: return as-is (might already be just an email)
        return sourceEmail.trimmingCharacters(in: .whitespaces)
    }
    
    private func loadTemplates() {
        isLoadingTemplates = true
        templatesLoadError = nil
        
        Task {
            do {
                let fetchedTemplates = try await simianService.getTemplates()
                await MainActor.run {
                    templates = fetchedTemplates
                    // Optionally set default template from settings if it matches
                    if let defaultTemplateId = settingsManager.currentSettings.simianProjectTemplate,
                       let defaultTemplate = fetchedTemplates.first(where: { $0.id == defaultTemplateId }) {
                        selectedTemplate = defaultTemplate
                    }
                    isLoadingTemplates = false
                }
            } catch {
                await MainActor.run {
                    templatesLoadError = error.localizedDescription
                    print("⚠️ Failed to load templates: \(error.localizedDescription)")
                    isLoadingTemplates = false
                }
            }
        }
    }
    
    private func confirm() {
        print("🔔 SimianProjectCreationDialog.confirm() called")
        print("   docketNumber: \(docketNumber)")
        print("   jobName: \(jobName)")
        print("   selectedProjectManagerEmail: \(selectedProjectManagerEmail ?? "nil")")
        print("   selectedTemplate: \(selectedTemplate?.name ?? "nil")")
        
        let templateId = selectedTemplate?.id
        // Pass email address - Simian will match it to a user
        // The onConfirm callback signature expects String? for manager, which can be email or user ID
        let managerEmail = selectedProjectManagerEmail
        print("   Calling onConfirm with managerEmail: \(managerEmail ?? "nil"), templateId: \(templateId ?? "nil")")
        onConfirm(docketNumber, jobName, managerEmail, templateId)
        isPresented = false
    }
}

