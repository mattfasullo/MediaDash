import SwiftUI
import AppKit

@MainActor
final class DocketHubWindowManager: NSObject, NSWindowDelegate {
    static let shared = DocketHubWindowManager()
    
    private var hubWindow: NSWindow?
    
    private override init() {
        super.init()
    }
    
    func show(
        docket: DocketInfo,
        metadataManager: DocketMetadataManager,
        cacheManager: AsanaCacheManager,
        settingsManager: SettingsManager
    ) {
        let binding = Binding<Bool>(
            get: { [weak self] in
                self?.hubWindow != nil
            },
            set: { [weak self] newValue in
                if !newValue {
                    self?.close()
                }
            }
        )
        
        let rootView = DocketHubView(
            docket: docket,
            isPresented: binding,
            metadataManager: metadataManager,
            cacheManager: cacheManager
        )
        .environmentObject(settingsManager)
        
        // If window already exists, recreate it with new content (can't easily update NSHostingController rootView)
        if let existingWindow = hubWindow {
            existingWindow.close()
            hubWindow = nil
        }
        
        // Create new window
        let hostingController = NSHostingController(rootView: rootView)
        let contentRect = NSRect(x: 0, y: 0, width: 800, height: 750)
        
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Docket Hub: \(docket.displayNumber) - \(docket.jobName)"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 500)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        NSApp.activate(ignoringOtherApps: true)
        
        hubWindow = window
    }
    
    func close() {
        hubWindow?.close()
    }
    
    nonisolated func windowWillClose(_ notification: Foundation.Notification) {
        Task { @MainActor in
            hubWindow = nil
        }
    }
}
