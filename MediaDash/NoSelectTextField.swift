import SwiftUI
import AppKit

// MARK: - Custom TextField with Selection Control

class NoSelectNSTextField: NSTextField {
    var onSpecialKeyDown: ((NSEvent) -> Bool)?
    /// Fired when this control becomes or resigns first responder (tracks AppKit focus reliably vs. delegate text events).
    var onNativeFirstResponderChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // Move cursor to end without selecting text
        if let editor = currentEditor() {
            editor.selectedRange = NSRange(location: stringValue.count, length: 0)
        }
        if result {
            onNativeFirstResponderChange?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onNativeFirstResponderChange?(false)
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if onSpecialKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

struct NoSelectTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onTextChange: () -> Void
    var onMoveUp: (() -> Bool)? = nil
    var onMoveDown: (() -> Bool)? = nil
    var onTab: (() -> Bool)? = nil
    /// Fires when this field becomes the key editor (AppKit focus). SwiftUI `@FocusState` is not wired for `NSViewRepresentable`.
    var onEditingBegan: (() -> Void)? = nil
    var onEditingEnded: (() -> Void)? = nil
    var onNativeFirstResponderChange: ((Bool) -> Void)? = nil

    private static let debugLogPath = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-simian-keyfocus.log"

    private static func logDebug(_ message: String) {
        if FileManager.default.fileExists(atPath: debugLogPath) == false {
            _ = FileManager.default.createFile(atPath: debugLogPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: debugLogPath) else { return }
        handle.seekToEndOfFile()
        if let data = "\(message)\n".data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    }

    func makeNSView(context: Context) -> NoSelectNSTextField {
        let textField = NoSelectNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.font = .systemFont(ofSize: 20)
        textField.isBordered = false
        textField.focusRingType = .none
        textField.backgroundColor = .clear
        textField.onNativeFirstResponderChange = { isKey in
            NoSelectTextField.logDebug("nativeFR isKey=\(isKey)")
            context.coordinator.parent.onNativeFirstResponderChange?(isKey)
        }
        textField.onSpecialKeyDown = { event in
            switch event.keyCode {
            case 126: // up
                let handled = context.coordinator.parent.onMoveUp?() ?? false
                NoSelectTextField.logDebug("keyDown up handled=\(handled)")
                return handled
            case 125: // down
                let handled = context.coordinator.parent.onMoveDown?() ?? false
                NoSelectTextField.logDebug("keyDown down handled=\(handled)")
                return handled
            case 48: // tab / shift-tab
                let handled = context.coordinator.parent.onTab?() ?? false
                NoSelectTextField.logDebug("keyDown tab handled=\(handled) shift=\(event.modifierFlags.contains(.shift))")
                return handled
            default:
                return false
            }
        }
        return textField
    }

    func updateNSView(_ nsView: NoSelectNSTextField, context: Context) {
        // Keep coordinator callbacks in sync with latest SwiftUI state/closures.
        context.coordinator.parent = self
        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled
        nsView.onNativeFirstResponderChange = { isKey in
            NoSelectTextField.logDebug("nativeFR isKey=\(isKey)")
            context.coordinator.parent.onNativeFirstResponderChange?(isKey)
        }
        nsView.onSpecialKeyDown = { event in
            switch event.keyCode {
            case 126: // up
                let handled = context.coordinator.parent.onMoveUp?() ?? false
                NoSelectTextField.logDebug("keyDown up handled=\(handled)")
                return handled
            case 125: // down
                let handled = context.coordinator.parent.onMoveDown?() ?? false
                NoSelectTextField.logDebug("keyDown down handled=\(handled)")
                return handled
            case 48: // tab / shift-tab
                let handled = context.coordinator.parent.onTab?() ?? false
                NoSelectTextField.logDebug("keyDown tab handled=\(handled) shift=\(event.modifierFlags.contains(.shift))")
                return handled
            default:
                return false
            }
        }

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

        func controlTextDidChange(_ obj: Foundation.Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
                parent.onTextChange()
            }
        }

        @objc func controlTextDidBeginEditing(_ obj: Foundation.Notification) {
            parent.onEditingBegan?()
        }

        @objc func controlTextDidEndEditing(_ obj: Foundation.Notification) {
            parent.onEditingEnded?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handle Enter key
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }

            // Optional explicit handlers for list navigation from search field.
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                let handled = parent.onMoveUp?() ?? false
                NoSelectTextField.logDebug("doCommand moveUp handled=\(handled)")
                return handled
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                let handled = parent.onMoveDown?() ?? false
                NoSelectTextField.logDebug("doCommand moveDown handled=\(handled)")
                return handled
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) ||
               commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                let handled = parent.onTab?() ?? false
                NoSelectTextField.logDebug("doCommand tab handled=\(handled)")
                return handled
            }

            // Let left/right arrows pass through normally.
            if commandSelector == #selector(NSResponder.moveLeft(_:)) ||
               commandSelector == #selector(NSResponder.moveRight(_:)) {
                return false
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

