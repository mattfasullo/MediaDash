import SwiftUI
import AppKit

struct PrepSummaryView: View {
    let summary: String
    @Binding var isPresented: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Prep Summary")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Summary content
            ScrollView {
                Text(summary)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Action buttons
            HStack {
                if copied {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Copied to clipboard!")
                            .foregroundColor(.green)
                    }
                    .font(.caption)
                }

                Spacer()

                Button("Copy to Clipboard") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(summary, forType: .string)
                    copied = true

                    // Reset copied state after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

