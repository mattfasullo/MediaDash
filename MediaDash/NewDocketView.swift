import SwiftUI

struct NewDocketView: View {
    @Binding var isPresented: Bool
    @Binding var selectedDocket: String
    @ObservedObject var manager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    var onDocketCreated: (() -> Void)? = nil
    var initialDocketNumber: String? = nil
    var initialJobName: String? = nil

    @State private var number = ""
    @State private var jobName = ""
    @State private var showValidationError = false
    @State private var validationMessage = ""
    @FocusState private var focusedField: Field?

    enum Field {
        case number
        case jobName
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Create New Folder")
                .font(.headline)
                .padding(.top, 8)
            
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Docket Number")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("", text: $number)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .number)
                        .onSubmit {
                            focusedField = .jobName
                        }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Job Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("", text: $jobName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .jobName)
                        .onSubmit {
                            if !number.isEmpty && !jobName.isEmpty {
                                createDocket()
                            }
                        }
                }
            }
            .frame(width: 280)
            .onAppear {
                // Set initial values when view appears - do this first
                print("NewDocketView onAppear - initialDocketNumber: \(initialDocketNumber ?? "nil"), initialJobName: \(initialJobName ?? "nil")")
                if let initialNumber = initialDocketNumber {
                    number = initialNumber
                    print("Set number to: \(number)")
                }
                if let initialName = initialJobName {
                    jobName = initialName
                    print("Set jobName to: \(jobName)")
                }
                // Focus the first empty field when the view appears
                if number.isEmpty {
                    focusedField = .number
                } else if jobName.isEmpty {
                    focusedField = .jobName
                } else {
                    focusedField = .number
                }
            }
            .onChange(of: initialDocketNumber) { oldValue, newValue in
                // Update when initial value changes (e.g., when pre-filled from Asana)
                print("onChange initialDocketNumber: oldValue=\(oldValue ?? "nil"), newValue=\(newValue ?? "nil")")
                if let newValue = newValue, newValue != number {
                    number = newValue
                    print("Updated number to: \(number)")
                }
            }
            .onChange(of: initialJobName) { oldValue, newValue in
                // Update when initial value changes (e.g., when pre-filled from Asana)
                print("onChange initialJobName: oldValue=\(oldValue ?? "nil"), newValue=\(newValue ?? "nil")")
                if let newValue = newValue, newValue != jobName {
                    jobName = newValue
                    print("Updated jobName to: \(jobName)")
                }
            }
            
            if showValidationError {
                Text(validationMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.horizontal, 4)
            }
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
                    createDocket()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number.isEmpty || jobName.isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(idealWidth: 320, idealHeight: 200)
        .fixedSize(horizontal: true, vertical: true)
    }

    private func createDocket() {
        // Validate inputs
        guard !number.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Docket number cannot be empty"
            showValidationError = true
            return
        }

        guard !jobName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Job name cannot be empty"
            showValidationError = true
            return
        }

        let docketName = "\(number)_\(jobName)"

        // Check if docket already exists
        if manager.dockets.contains(docketName) {
            validationMessage = "A docket with this name already exists"
            showValidationError = true
            return
        }

        // Create the docket folder on disk
        let config = AppConfig(settings: settingsManager.currentSettings)
        let paths = config.getPaths()
        
        // Verify parent directory exists before creating docket folder
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.workPic.path) else {
            validationMessage = "Work Picture folder path does not exist:\n\(paths.workPic.path)\n\nPlease check your settings and make sure the server is connected."
            showValidationError = true
            return
        }
        
        let docketFolder = paths.workPic.appendingPathComponent(docketName)

        // Only create the docket folder, not parent directories
        // Parent directory (paths.workPic) must already exist
        do {
            try FileManager.default.createDirectory(at: docketFolder, withIntermediateDirectories: false)
            selectedDocket = docketName
            manager.refreshDockets() // Refresh to show the new docket
            isPresented = false

            // Call the callback if provided
            if let callback = onDocketCreated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    callback()
                }
            }
        } catch {
            validationMessage = "Failed to create docket folder: \(error.localizedDescription)\n\nPath: \(docketFolder.path)"
            showValidationError = true
        }
    }
}

