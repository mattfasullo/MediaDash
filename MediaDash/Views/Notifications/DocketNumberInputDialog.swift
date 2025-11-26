import SwiftUI

struct DocketNumberInputDialog: View {
    @Binding var isPresented: Bool
    @Binding var docketNumber: String
    let jobName: String
    let onConfirm: () -> Void
    
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Enter Docket Number")
                .font(.system(size: 16, weight: .semibold))
            
            Text("Job: \(jobName)")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            
            TextField("Docket Number", text: $docketNumber)
                .textFieldStyle(.roundedBorder)
                .focused($isTextFieldFocused)
                .onSubmit {
                    confirm()
                }
            
            Text("Leave empty to auto-generate: \(generateAutoDocketNumber())")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Continue") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear {
            isTextFieldFocused = true
        }
    }
    
    private func confirm() {
        onConfirm()
        isPresented = false
    }
    
    private func generateAutoDocketNumber() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let yearSuffix = String(year).suffix(2) // Last 2 digits of year (25 for 2025, 26 for 2026)
        return "\(yearSuffix)XXX" // e.g., "25XXX", "26XXX"
    }
}

