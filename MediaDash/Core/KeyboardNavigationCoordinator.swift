//
//  KeyboardNavigationCoordinator.swift
//  MediaDash
//
//  App-wide keyboard navigation: routes arrow keys and return to the frontmost
//  window's handler so the system never plays the "unhandled key" beep.
//

import AppKit
import SwiftUI

/// Must be used from main thread only (NSEvent monitor and SwiftUI both run on main).
final class KeyboardNavigationCoordinator {
    static let shared = KeyboardNavigationCoordinator()
    
    /// Per-window stack of handlers (top = frontmost sheet/view for that window).
    private var stackByWindow: [ObjectIdentifier: [(NSEvent) -> Bool]] = [:]
    
    private init() {}
    
    // #region agent log
    static func logDebug(location: String, message: String, data: [String: Any], hypothesisId: String) {
        let payload: [String: Any] = [
            "id": "log_\(Int(Date().timeIntervalSince1970 * 1000))_\(UUID().uuidString.prefix(8))",
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "location": location,
            "message": message,
            "data": data,
            "hypothesisId": hypothesisId
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8) else { return }
        let path = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    // #endregion
    
    /// Push a handler for the given window (e.g. when a view/sheet appears).
    func push(window: NSWindow, handler: @escaping (NSEvent) -> Bool) {
        let id = ObjectIdentifier(window)
        if stackByWindow[id] == nil {
            stackByWindow[id] = []
        }
        stackByWindow[id]?.append(handler)
    }
    
    /// Pop the top handler for the given window (e.g. when a view/sheet disappears).
    func pop(window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard stackByWindow[id]?.isEmpty == false else { return }
        stackByWindow[id]?.removeLast()
        if stackByWindow[id]?.isEmpty == true {
            stackByWindow.removeValue(forKey: id)
        }
    }
    
    /// Replace the top handler for the given window (e.g. when the view updates and the closure changes).
    func updateTopHandler(window: NSWindow, handler: @escaping (NSEvent) -> Bool) {
        let id = ObjectIdentifier(window)
        guard var stack = stackByWindow[id], !stack.isEmpty else { return }
        stack[stack.count - 1] = handler
        stackByWindow[id] = stack
    }

    /// Returns true if there is a handler for the key window (so we can avoid passing keys to system when we'll handle them).
    func hasHandlerForKeyWindow() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let id = ObjectIdentifier(window)
        guard let stack = stackByWindow[id], !stack.isEmpty else { return false }
        return true
    }
    
    /// Returns true if a menu or popover panel is likely visible (we should pass arrow/return through to the system).
    private static func hasVisibleMenuOrPopoverPanel() -> Bool {
        let keyWindow = NSApp.keyWindow
        let mainWindow = NSApp.mainWindow
        for window in NSApp.windows {
            guard window !== keyWindow, window !== mainWindow,
                  window is NSPanel, window.isVisible else { continue }
            return true
        }
        return false
    }

    /// Returns true if the key window's first responder looks like a menu/popup — we pass through so the menu gets arrow keys.
    /// Only for sheet windows: when first responder is the window itself (no specific control), pass through for in-sheet menus.
    /// We do NOT pass through for the main window root so that app-wide arrow navigation works in the main window.
    private static func isFirstResponderMenuOrPopover(in window: NSWindow?) -> Bool {
        guard let window = window, let first = window.firstResponder else { return false }
        // In sheets only: first responder is the window itself → pass through so Picker/menu in sheet gets keys
        if first === window, window !== WindowConfiguration.mainAppWindow {
            return true
        }
        var responder: NSResponder? = first
        let menuLike = ["Menu", "PopUp", "ComboBox", "Popover"]
        while let r = responder {
            let name = String(describing: type(of: r))
            if menuLike.contains(where: { name.contains($0) }) {
                return true
            }
            responder = r.nextResponder
        }
        return false
    }

    /// Try to handle the key event using only the key window's handler. Returns true if handled (caller should consume event).
    /// Does not fall back to mainAppWindow/mainWindow so that when a menu has focus (keyWindow nil or menu panel), we pass through.
    func handle(event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow else {
            // #region agent log
            KeyboardNavigationCoordinator.logDebug(
                location: "KeyboardNavigationCoordinator.swift:handle",
                message: "No handler found",
                data: [
                    "keyWindowNil": true,
                    "keyCode": Int(event.keyCode)
                ],
                hypothesisId: "H4_H5"
            )
            // #endregion
            return false
        }
        if KeyboardNavigationCoordinator.hasVisibleMenuOrPopoverPanel() {
            // #region agent log
            KeyboardNavigationCoordinator.logDebug(
                location: "KeyboardNavigationCoordinator.swift:handle",
                message: "Menu/popover visible, passing through",
                data: ["keyCode": Int(event.keyCode)],
                hypothesisId: "H1_H2_H3"
            )
            // #endregion
            return false
        }
        if KeyboardNavigationCoordinator.isFirstResponderMenuOrPopover(in: window) {
            // #region agent log
            KeyboardNavigationCoordinator.logDebug(
                location: "KeyboardNavigationCoordinator.swift:handle",
                message: "First responder is menu/popover or root, passing through",
                data: [
                    "keyCode": Int(event.keyCode),
                    "firstResponderClass": window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                ],
                hypothesisId: "H7"
            )
            // #endregion
            return false
        }
        let id = ObjectIdentifier(window)
        guard let stack = stackByWindow[id], let top = stack.last else {
            // #region agent log
            KeyboardNavigationCoordinator.logDebug(
                location: "KeyboardNavigationCoordinator.swift:handle",
                message: "No handler found",
                data: [
                    "keyWindowNil": false,
                    "keyCode": Int(event.keyCode)
                ],
                hypothesisId: "H4_H5"
            )
            // #endregion
            return false
        }
        // #region agent log
        let keyWindow = NSApp.keyWindow
        let mainWindow = NSApp.mainWindow
        var panelInfos: [[String: Any]] = []
        for w in NSApp.windows {
            guard w is NSPanel else { continue }
            panelInfos.append([
                "visible": w.isVisible,
                "isKey": w === keyWindow,
                "isMain": w === mainWindow,
                "className": String(describing: type(of: w))
            ])
        }
        KeyboardNavigationCoordinator.logDebug(
            location: "KeyboardNavigationCoordinator.swift:handle",
            message: "Window snapshot (handler about to run)",
            data: [
                "keyCode": Int(event.keyCode),
                "windowCount": NSApp.windows.count,
                "panelCount": panelInfos.count,
                "panels": panelInfos,
                "keyWindowClass": keyWindow.map { String(describing: type(of: $0)) } ?? "nil",
                "firstResponderClass": keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            ],
            hypothesisId: "H6"
        )
        // #endregion
        let handled = top(event)
        // #region agent log
        KeyboardNavigationCoordinator.logDebug(
            location: "KeyboardNavigationCoordinator.swift:handle",
            message: "Handler invoked",
            data: [
                "candidateName": "keyWindow",
                "handled": handled,
                "keyCode": Int(event.keyCode)
            ],
            hypothesisId: "H1_H2_H3"
        )
        // #endregion
        return handled
    }
    
    /// Returns true if the first responder in the key window is a text field (we should not consume arrow/return).
    static func isEditingText(in window: NSWindow?) -> Bool {
        guard let window = window, let first = window.firstResponder else { return false }
        if first is NSTextView || first is NSTextField { return true }
        if let tv = first as? NSTextView, tv.isFieldEditor { return true }
        return false
    }
}

// MARK: - SwiftUI registration

/// NSView that registers with KeyboardNavigationCoordinator when added to a window and unregisters when removed.
final class KeyboardNavRegistrationNSView: NSView {
    var registration: KeyboardNavRegistration?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window, let reg = registration {
            reg.window = window
            KeyboardNavigationCoordinator.shared.push(window: window, handler: reg.handler)
        } else {
            if let w = registration?.window {
                KeyboardNavigationCoordinator.shared.pop(window: w)
            }
            registration?.window = nil
        }
    }
}

final class KeyboardNavRegistration {
    var window: NSWindow?
    var handler: (NSEvent) -> Bool
    init(handler: @escaping (NSEvent) -> Bool) { self.handler = handler }
}

struct KeyboardNavRegistrationView: NSViewRepresentable {
    let handler: (NSEvent) -> Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }
    
    func makeNSView(context: Context) -> KeyboardNavRegistrationNSView {
        let v = KeyboardNavRegistrationNSView(frame: .zero)
        v.registration = context.coordinator.registration
        return v
    }
    
    func updateNSView(_ nsView: KeyboardNavRegistrationNSView, context: Context) {
        context.coordinator.registration.handler = handler
        if let window = nsView.window {
            KeyboardNavigationCoordinator.shared.updateTopHandler(window: window, handler: handler)
        }
    }
    
    final class Coordinator {
        let registration: KeyboardNavRegistration
        init(handler: @escaping (NSEvent) -> Bool) {
            self.registration = KeyboardNavRegistration(handler: handler)
        }
    }
}

/// View modifier to register this view's window for app-wide arrow/return handling. Use on the root of each window or sheet.
struct KeyboardNavigationHandlerModifier: ViewModifier {
    let handleKey: (NSEvent) -> Bool
    
    func body(content: Content) -> some View {
        content
            .background(KeyboardNavRegistrationView(handler: handleKey))
    }
}

extension View {
    /// Registers this view's window for app-wide keyboard navigation. The closure is called for arrow/return keys; return true to consume (no beep).
    func keyboardNavigationHandler(handleKey: @escaping (NSEvent) -> Bool) -> some View {
        modifier(KeyboardNavigationHandlerModifier(handleKey: handleKey))
    }
}
