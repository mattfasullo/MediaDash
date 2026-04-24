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

    // MARK: - First responder (deferred; avoid work during `NSViewRepresentable.updateNSView`)

    /// Non-zero when SwiftUI last requested focus for this control (bumped in `updateNSView`).
    var mediadash_scheduledFocusToken: Int = 0
    /// True if we need another `perform` pass because `window` was nil the last time we tried to focus.
    private var mediadash_focusRetryAfterWindow: Bool = false

    private static let mediadash_applyFocusSel = #selector(mediadash_applyScheduledFirstResponder)
    private static let mediadash_applyBlurSel = #selector(mediadash_applyScheduledResign)

    /// AppKit’s usual pattern: leave the current run-loop item (and SwiftUI’s update pass) first.
    /// `makeFirstResponder` can still report Hang Risk for internal main→default-QoS waits; this minimizes it.
    func mediadash_scheduleFirstResponder() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: Self.mediadash_applyFocusSel, object: nil)
        perform(Self.mediadash_applyFocusSel, with: nil, afterDelay: 0, inModes: [.common])
    }

    @objc private func mediadash_applyScheduledFirstResponder() {
        guard mediadash_scheduledFocusToken > 0 else { return }
        guard let w = window else {
            mediadash_focusRetryAfterWindow = true
            return
        }
        mediadash_focusRetryAfterWindow = false
        if w.firstResponder === self { return }
        _ = w.makeFirstResponder(self)
    }

    func mediadash_scheduleResignIfKey() {
        mediadash_focusRetryAfterWindow = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: Self.mediadash_applyFocusSel, object: nil)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: Self.mediadash_applyBlurSel, object: nil)
        perform(Self.mediadash_applyBlurSel, with: nil, afterDelay: 0, inModes: [.common])
    }

    @objc private func mediadash_applyScheduledResign() {
        guard window?.firstResponder === self || currentEditor() != nil else { return }
        _ = resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, mediadash_focusRetryAfterWindow, mediadash_scheduledFocusToken > 0 {
            mediadash_scheduleFirstResponder()
        }
    }
}

struct NoSelectTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onTextChange: () -> Void
    /// Parameter is whether Shift is held (for range selection in lists).
    var onMoveUp: ((Bool) -> Bool)? = nil
    var onMoveDown: ((Bool) -> Bool)? = nil
    var onTab: (() -> Bool)? = nil
    /// Fires when this field becomes the key editor (AppKit focus). SwiftUI `@FocusState` is not wired for `NSViewRepresentable`.
    var onEditingBegan: (() -> Void)? = nil
    var onEditingEnded: (() -> Void)? = nil
    var onNativeFirstResponderChange: ((Bool) -> Void)? = nil
    /// Increment to request keyboard focus on the NSTextField (SwiftUI `.focused` does not apply to AppKit representables).
    var focusRequestToken: Int = 0
    /// Increment to resign first responder on the NSTextField without `makeFirstResponder(nil)` (which leaves `NSWindow` as FR).
    var blurRequestToken: Int = 0

    private static let debugLogPath = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-simian-keyfocus.log"
    /// Serial utility-QoS queue so log I/O never blocks the main (User-interactive) thread
    /// and can’t priority-invert with AppKit field/text work (Xcode Hang Risk diagnostic).
    private static let debugLogQueue = DispatchQueue(label: "mediadash.NoSelectTextField.log",
                                                     qos: .utility)
    /// One-shot availability check; if the log dir isn’t writable on this machine, stay a no-op.
    private static let debugLogAvailable: Bool = {
        let dir = (debugLogPath as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue
            && FileManager.default.isWritableFile(atPath: dir)
    }()

    private static func logDebug(_ message: String) {
        guard debugLogAvailable else { return }
        debugLogQueue.async {
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
                let shift = event.modifierFlags.contains(.shift)
                let handled = context.coordinator.parent.onMoveUp?(shift) ?? false
                NoSelectTextField.logDebug("keyDown up handled=\(handled)")
                return handled
            case 125: // down
                let shift = event.modifierFlags.contains(.shift)
                let handled = context.coordinator.parent.onMoveDown?(shift) ?? false
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
                let shift = event.modifierFlags.contains(.shift)
                let handled = context.coordinator.parent.onMoveUp?(shift) ?? false
                NoSelectTextField.logDebug("keyDown up handled=\(handled)")
                return handled
            case 125: // down
                let shift = event.modifierFlags.contains(.shift)
                let handled = context.coordinator.parent.onMoveDown?(shift) ?? false
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

        if focusRequestToken > 0, focusRequestToken != context.coordinator.lastAppliedFocusRequestToken {
            context.coordinator.lastAppliedFocusRequestToken = focusRequestToken
            nsView.mediadash_scheduledFocusToken = focusRequestToken
            // Do not call `makeFirstResponder` in this `update` pass. Use
            // `NSObject.perform(_:afterDelay:inModes:)` so first-responder work runs
            // after the current run-loop event (out of the SwiftUI update stack). If
            // the view has no `window` yet, `viewDidMoveToWindow` re-schedules.
            nsView.mediadash_scheduleFirstResponder()
        }

        if blurRequestToken > 0, blurRequestToken != context.coordinator.lastAppliedBlurRequestToken {
            context.coordinator.lastAppliedBlurRequestToken = blurRequestToken
            nsView.mediadash_scheduleResignIfKey()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoSelectTextField
        var lastAppliedFocusRequestToken: Int = 0
        var lastAppliedBlurRequestToken: Int = 0

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
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                let handled = parent.onMoveUp?(shift) ?? false
                NoSelectTextField.logDebug("doCommand moveUp handled=\(handled)")
                return handled
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                let handled = parent.onMoveDown?(shift) ?? false
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

