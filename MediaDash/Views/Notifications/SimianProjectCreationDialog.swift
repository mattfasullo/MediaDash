import SwiftUI
import Foundation

struct SimianProjectCreationDialog: View {
    @Binding var isPresented: Bool
    @ObservedObject var simianService: SimianService
    @ObservedObject var settingsManager: SettingsManager
    
    let initialDocketNumber: String
    let initialJobName: String
    let isSimianEnabled: Bool // Whether Simian project will be created
    let onConfirm: (String, String, String?, String?) -> Void
    
    @State private var docketNumber: String
    @State private var jobName: String
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
        isSimianEnabled: Bool = true,
        onConfirm: @escaping (String, String, String?, String?) -> Void
    ) {
        self._isPresented = isPresented
        self.simianService = simianService
        self.settingsManager = settingsManager
        self.initialDocketNumber = initialDocketNumber
        self.initialJobName = initialJobName
        self.isSimianEnabled = isSimianEnabled
        self.onConfirm = onConfirm
        
        // Initialize state with initial values
        _docketNumber = State(initialValue: initialDocketNumber)
        _jobName = State(initialValue: initialJobName)
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
                
                // Project Template Dropdown (only show if Simian is enabled)
                if isSimianEnabled {
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
            }
            if docketNumber.isEmpty {
                focusedField = .docketNumber
            } else if jobName.isEmpty {
                focusedField = .jobName
            }
        }
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
        print("   selectedTemplate: \(selectedTemplate?.name ?? "nil")")
        
        let templateId = selectedTemplate?.id
        onConfirm(docketNumber, jobName, nil, templateId)
        isPresented = false
    }
}

