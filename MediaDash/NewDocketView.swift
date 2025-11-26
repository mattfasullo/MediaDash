import SwiftUI

struct NewDocketView: View {
    @Binding var isPresented: Bool
    @Binding var selectedDocket: String
    @ObservedObject var manager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    var onDocketCreated: (() -> Void)? = nil

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
        VStack(spacing: 20) {
            Text("New Docket")
                .font(.headline)
            
            Form {
                TextField("Number", text: $number)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .number)
                    .onSubmit {
                        focusedField = .jobName
                    }
                TextField("Job Name", text: $jobName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .jobName)
                    .onSubmit {
                        if !number.isEmpty && !jobName.isEmpty {
                            createDocket()
                        }
                    }
            }
            .frame(width: 300)
            .onAppear {
                // Focus the first field when the view appears
                focusedField = .number
            }
            
            if showValidationError {
                Text(validationMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
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
        }
        .padding()
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

