import SwiftUI

struct JobNameEditDialog: View {
    @Binding var isPresented: Bool
    @Binding var jobName: String
    let docketNumber: String?
    let onConfirm: (String) -> Void
    
    @FocusState private var isTextFieldFocused: Bool
    @State private var editedJobName: String
    
    init(isPresented: Binding<Bool>, jobName: Binding<String>, docketNumber: String?, onConfirm: @escaping (String) -> Void) {
        self._isPresented = isPresented
        self._jobName = jobName
        self.docketNumber = docketNumber
        self.onConfirm = onConfirm
        self._editedJobName = State(initialValue: jobName.wrappedValue)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Job Name")
                .font(.system(size: 16, weight: .semibold))
            
            if let docketNumber = docketNumber {
                Text("Docket: \(docketNumber)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            
            TextField("Job Name", text: $editedJobName)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit {
                    confirm()
                }
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400, height: 200)
        .onAppear {
            // Focus the text field when dialog appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextFieldFocused = true
            }
        }
    }
    
    private func confirm() {
        let trimmed = editedJobName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        isPresented = false
    }
}

