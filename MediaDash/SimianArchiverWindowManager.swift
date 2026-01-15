import SwiftUI
import AppKit
import Combine

@MainActor
final class SimianArchiverWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SimianArchiverWindowManager()
    
    @Published private(set) var isVisible = false
    private var archiverWindow: NSWindow?
    
    private override init() {
        super.init()
    }
    
    func show(settingsManager: SettingsManager) {
        if let existingWindow = archiverWindow {
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
        
        let rootView = SimianArchiverView(isPresented: binding)
            .environmentObject(settingsManager)
        
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Simian Archiver"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
        
        archiverWindow = window
        isVisible = true
    }
    
    func close() {
        archiverWindow?.close()
    }
    
    func windowWillClose(_ notification: Foundation.Notification) {
        isVisible = false
        archiverWindow = nil
    }
}

