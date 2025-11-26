//
//  StagingWindowManager.swift
//  MediaDash
//
//  Created for separate staging window
//

import SwiftUI
import AppKit
import Combine

@MainActor
class StagingWindowManager: ObservableObject {
    static let shared = StagingWindowManager()
    
    @Published var isVisible = false
    private var stagingWindow: NSWindow?
    private var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Find main window
        findMainWindow()
        
        // Monitor window movements
        setupWindowMonitoring()
    }
    
    private func findMainWindow() {
        // Find the main content window (not the staging window)
        // Look for the window that contains ContentView
        mainWindow = NSApplication.shared.windows.first { window in
            window != stagingWindow && 
            window.isVisible && 
            window.title != "Staging" &&
            window.frame.width >= 300 // Main window is at least 300px wide
        }
        
        // Fallback: just get the first visible window that's not staging
        if mainWindow == nil {
            mainWindow = NSApplication.shared.windows.first { window in
                window != stagingWindow && window.isVisible
            }
        }
    }
    
    private func setupWindowMonitoring() {
        // Monitor when main window moves
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)
            .sink { [weak self] notification in
                if let window = notification.object as? NSWindow,
                   window == self?.mainWindow {
                    self?.updateStagingWindowPosition()
                }
            }
            .store(in: &cancellables)
        
        // Monitor when main window resizes
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
            .sink { [weak self] notification in
                if let window = notification.object as? NSWindow,
                   window == self?.mainWindow {
                    self?.updateStagingWindowPosition()
                }
            }
            .store(in: &cancellables)
    }
    
    func showStagingWindow(content: AnyView) {
        guard !isVisible else { return }
        
        findMainWindow()
        guard mainWindow != nil else { return }
        
        // Create staging window
        let stagingWindowController = NSHostingController(rootView: content)
        stagingWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 490),
            styleMask: [.borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        
        guard let stagingWindow = stagingWindow else { return }
        
        stagingWindow.contentViewController = stagingWindowController
        stagingWindow.titlebarAppearsTransparent = true
        stagingWindow.titleVisibility = .hidden
        stagingWindow.backgroundColor = NSColor.windowBackgroundColor
        stagingWindow.isOpaque = true
        stagingWindow.hasShadow = true
        stagingWindow.level = .normal
        stagingWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        stagingWindow.isReleasedWhenClosed = false
        stagingWindow.title = "Staging"
        stagingWindow.isMovable = false // Lock it in position relative to main window
        
        // Configure window appearance similar to main window
        stagingWindow.standardWindowButton(.closeButton)?.isHidden = true
        stagingWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        stagingWindow.standardWindowButton(.zoomButton)?.isHidden = true
        
        // Make it appear as a separate window but follow main window
        stagingWindow.styleMask = [.borderless, .fullSizeContentView]
        
        // Position next to main window
        updateStagingWindowPosition()
        
        stagingWindow.makeKeyAndOrderFront(nil)
        isVisible = true
    }
    
    func hideStagingWindow() {
        guard isVisible else { return }
        stagingWindow?.close()
        stagingWindow = nil
        isVisible = false
    }
    
    func toggleStagingWindow(content: AnyView) {
        if isVisible {
            hideStagingWindow()
        } else {
            showStagingWindow(content: content)
        }
    }
    
    private func updateStagingWindowPosition() {
        guard let stagingWindow = stagingWindow else { return }
        
        // Re-find main window in case it changed
        findMainWindow()
        guard let mainWindow = mainWindow else { return }
        
        let mainFrame = mainWindow.frame
        let stagingWidth: CGFloat = 350
        let stagingHeight: CGFloat = 490
        
        // Position to the right of main window, vertically centered
        let x = mainFrame.maxX
        let y = mainFrame.midY - (stagingHeight / 2)
        
        stagingWindow.setFrame(
            NSRect(x: x, y: y, width: stagingWidth, height: stagingHeight),
            display: true
        )
    }
    
    func refreshMainWindow() {
        findMainWindow()
        updateStagingWindowPosition()
    }
}

