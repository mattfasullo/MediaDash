import SwiftUI
import AppKit
import Combine

@MainActor
final class SettingsWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    
    @Published private(set) var isVisible = false
    private var settingsWindow: NSWindow?
    
    private override init() {
        super.init()
    }
    
    func show(settingsManager: SettingsManager, sessionManager: SessionManager) {
        if let existingWindow = settingsWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isVisible = true
            return
        }
        
        let binding = Binding<Bool>(
            get: { [weak self] in
                self?.isVisible ?? false
            },
            set: { [weak self] newValue in
                if !newValue {
                    self?.close()
                }
            }
        )
        
        let rootView = SettingsView(settingsManager: settingsManager, isPresented: binding)
            .environmentObject(sessionManager)
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
        
        settingsWindow = window
        isVisible = true
    }
    
    func close() {
        settingsWindow?.close()
    }
    
    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        settingsWindow = nil
    }
}
