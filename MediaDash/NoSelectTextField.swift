import SwiftUI
import AppKit

// MARK: - Custom TextField with Selection Control

class NoSelectNSTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // Move cursor to end without selecting text
        if let editor = currentEditor() {
            editor.selectedRange = NSRange(location: stringValue.count, length: 0)
        }
        return result
    }
}

struct NoSelectTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onTextChange: () -> Void

    func makeNSView(context: Context) -> NoSelectNSTextField {
        let textField = NoSelectNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.font = .systemFont(ofSize: 20)
        textField.isBordered = false
        textField.focusRingType = .none
        textField.backgroundColor = .clear
        return textField
    }

    func updateNSView(_ nsView: NoSelectNSTextField, context: Context) {
        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled

        // Only update text if it's actually different
        if nsView.stringValue != text {
            nsView.stringValue = text

            // Only adjust cursor position when text changes and editor is active
            if let editor = nsView.currentEditor(), text.count > 0 {
                let expectedRange = NSRange(location: text.count, length: 0)
                if editor.selectedRange != expectedRange {
                    editor.selectedRange = expectedRange
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoSelectTextField

        init(_ parent: NoSelectTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
                parent.onTextChange()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handle Enter key
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }

            // Let arrow keys pass through to SwiftUI handlers
            // This allows navigation and folder cycling to work
            if commandSelector == #selector(NSResponder.moveUp(_:)) ||
               commandSelector == #selector(NSResponder.moveDown(_:)) ||
               commandSelector == #selector(NSResponder.moveLeft(_:)) ||
               commandSelector == #selector(NSResponder.moveRight(_:)) {
                return false  // Don't consume, let it bubble up
            }

            // Let delete/backspace pass through
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) ||
               commandSelector == #selector(NSResponder.deleteForward(_:)) {
                return false  // Don't consume, let it bubble up
            }

            return false  // Don't consume other commands
        }
    }
}

