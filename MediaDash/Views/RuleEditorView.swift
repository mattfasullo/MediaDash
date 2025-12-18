import SwiftUI

/// Editor view for email parsing rules
struct RuleEditorView: View {
    @Binding var isPresented: Bool
    
    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }
    
    var body: some View {
        VStack {
            Text("Rule Editor")
                .font(.title2)
            Text("Email parsing rules are handled automatically.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            
            Button("Close") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(width: 500, height: 300)
        .padding()
    }
}
