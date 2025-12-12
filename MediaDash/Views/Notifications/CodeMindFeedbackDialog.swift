import SwiftUI

struct CodeMindFeedbackDialog: View {
    @Binding var isPresented: Bool
    @Binding var correction: String
    @Binding var comment: String
    let onSubmit: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Provide Feedback to CodeMind")
                .font(.system(size: 16, weight: .semibold))
            
            Text("Help CodeMind learn from this mistake. Your feedback will be shared with the team to improve classification accuracy.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("What was wrong? (Optional)")
                    .font(.system(size: 12, weight: .medium))
                
                TextField("e.g., This was actually a file delivery, not a new docket", text: $correction, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Additional comments (Optional)")
                    .font(.system(size: 12, weight: .medium))
                
                TextField("Any other feedback...", text: $comment, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Submit Feedback") {
                    onSubmit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 220)
    }
}

