//
//  FloatingProgressWindowManager.swift
//  MediaDash
//
//  Floating circular progress indicator that stays on top of all windows
//

import SwiftUI
import AppKit
import Combine
import Foundation

// MARK: - Progress State

/// Represents the current operation being tracked
enum ProgressOperation: Equatable {
    case filing(docket: String)
    case prepping(docket: String)
    case filingAndPrepping(docket: String)
    case converting(filename: String)
    case organizing
    case idle

    var displayName: String {
        switch self {
        case .filing: return "Filing"
        case .prepping: return "Prepping"
        case .filingAndPrepping: return "Filing & Prepping"
        case .converting: return "Converting"
        case .organizing: return "Organizing"
        case .idle: return "Ready"
        }
    }

    var detail: String {
        switch self {
        case .filing(let docket): return docket
        case .prepping(let docket): return docket
        case .filingAndPrepping(let docket): return docket
        case .converting(let filename): return filename
        case .organizing: return "Stems & Files"
        case .idle: return ""
        }
    }

    var color: Color {
        switch self {
        case .filing: return .blue
        case .prepping: return .green
        case .filingAndPrepping: return .purple
        case .converting: return .orange
        case .organizing: return .cyan
        case .idle: return .gray
        }
    }

    var icon: String {
        switch self {
        case .filing: return "doc.on.doc"
        case .prepping: return "folder.badge.gearshape"
        case .filingAndPrepping: return "square.stack.3d.up"
        case .converting: return "film"
        case .organizing: return "folder"
        case .idle: return "checkmark.circle"
        }
    }

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

// MARK: - Floating Progress Manager

@MainActor
class FloatingProgressManager: ObservableObject {
    static let shared = FloatingProgressManager()

    @Published var isVisible: Bool = false
    @Published var progress: Double = 0.0
    @Published var operation: ProgressOperation = .idle
    @Published var statusMessage: String = ""
    @Published var currentFile: String = ""
    @Published var filesProcessed: Int = 0
    @Published var totalFiles: Int = 0

    // Bytes tracking
    @Published var bytesCopied: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var transferRate: Double = 0.0 // bytes per second

    // For calculating transfer rate
    private var lastBytesCopied: Int64 = 0
    private var lastRateUpdateTime: Date = Date()
    private var recentRates: [Double] = [] // Rolling average
    private let maxRateSamples = 5

    private init() {}

    func startOperation(_ operation: ProgressOperation, totalFiles: Int = 0, totalBytes: Int64 = 0) {
        self.operation = operation
        self.progress = 0.0
        self.filesProcessed = 0
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
        self.bytesCopied = 0
        self.transferRate = 0.0
        self.lastBytesCopied = 0
        self.lastRateUpdateTime = Date()
        self.recentRates = []
        self.statusMessage = operation.displayName
        self.isVisible = true
    }

    func updateProgress(_ progress: Double, message: String? = nil, currentFile: String? = nil) {
        self.progress = min(1.0, max(0.0, progress))
        if let message = message {
            self.statusMessage = message
        }
        if let file = currentFile {
            self.currentFile = file
        }
    }

    func updateBytes(copied: Int64, total: Int64? = nil) {
        self.bytesCopied = copied
        if let total = total {
            self.totalBytes = total
        }

        // Calculate transfer rate using rolling average
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRateUpdateTime)

        // Only update rate every 200ms to smooth out fluctuations
        if elapsed >= 0.2 {
            let bytesDelta = copied - lastBytesCopied
            if bytesDelta > 0 && elapsed > 0 {
                let instantRate = Double(bytesDelta) / elapsed

                // Add to rolling average
                recentRates.append(instantRate)
                if recentRates.count > maxRateSamples {
                    recentRates.removeFirst()
                }

                // Calculate average
                transferRate = recentRates.reduce(0, +) / Double(recentRates.count)
            }

            lastBytesCopied = copied
            lastRateUpdateTime = now
        }

        // Update progress based on bytes if we have total
        if totalBytes > 0 {
            progress = Double(copied) / Double(totalBytes)
        }
    }

    func incrementFile() {
        filesProcessed += 1
        if totalFiles > 0 {
            progress = Double(filesProcessed) / Double(totalFiles)
        }
    }

    func complete(message: String = "Done!") {
        self.progress = 1.0
        self.statusMessage = message
        self.transferRate = 0.0

        // Hide after a delay
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self.progress >= 1.0 {
                self.hide()
            }
        }
    }

    func hide() {
        self.isVisible = false
        self.operation = .idle
        self.progress = 0.0
        self.statusMessage = ""
        self.currentFile = ""
        self.filesProcessed = 0
        self.totalFiles = 0
        self.bytesCopied = 0
        self.totalBytes = 0
        self.transferRate = 0.0
        self.recentRates = []
    }

    func cancel() {
        self.statusMessage = "Cancelled"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.hide()
        }
    }

    // MARK: - Formatting Helpers

    var formattedBytesCopied: String {
        ByteCountFormatter.string(fromByteCount: bytesCopied, countStyle: .file)
    }

    var formattedTotalBytes: String {
        ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    var formattedTransferRate: String {
        if transferRate <= 0 {
            return "—"
        }
        let bytesPerSecond = Int64(transferRate)
        let formatted = ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file)
        return "\(formatted)/s"
    }
}

// MARK: - Window Delegate

class FloatingProgressWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = FloatingProgressWindowDelegate()

    func windowShouldBecomeKey(_ window: NSWindow) -> Bool {
        // Floating progress windows don't need to be key windows
        return false
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // Constrain window size to screen bounds
        guard let screen = sender.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return frameSize
        }

        let visibleFrame = screen.visibleFrame
        let maxWidth = visibleFrame.width
        let maxHeight = visibleFrame.height

        // Ensure window doesn't exceed screen bounds
        let constrainedWidth = min(frameSize.width, maxWidth)
        let constrainedHeight = min(frameSize.height, maxHeight)

        return NSSize(width: constrainedWidth, height: constrainedHeight)
    }

    func windowDidResize(_ notification: Foundation.Notification) {
        // After resize, ensure window is still within bounds
        guard let window = notification.object as? NSWindow else { return }
        Task { @MainActor in
            FloatingProgressWindowManager.shared.constrainWindowToScreen(window)
        }
    }
}

// MARK: - Window Manager

@MainActor
class FloatingProgressWindowManager {
    static let shared = FloatingProgressWindowManager()

    private var progressWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Initializing...
        // Observe visibility changes
        FloatingProgressManager.shared.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                if isVisible {
                    self?.showWindow()
                } else {
                    self?.hideWindow()
                }
            }
            .store(in: &cancellables)
        // Initialized
    }

    private func showWindow() {
        guard progressWindow == nil else {
            progressWindow?.orderFrontRegardless()
            return
        }

        // Creating new progress window
        let progressView = FloatingProgressView()
            .environmentObject(FloatingProgressManager.shared)
        let hostingController = NSHostingController(rootView: progressView)

        progressWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        guard let window = progressWindow else { return }

        window.contentViewController = hostingController
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.level = .floating
        
        // Add faint border to progress window
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.borderWidth = 0.5
        window.contentView?.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.title = "Progress"
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false // Allow interaction for dragging
        
        // Set delegate to prevent window from becoming key and constrain resizing
        window.delegate = FloatingProgressWindowDelegate.shared
        
        // Monitor window moves to keep it within bounds
        Foundation.NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: OperationQueue.main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [self] in
                self.constrainWindowToScreen(window)
            }
        }

        // Position at bottom-right of screen
        positionWindow()

        // Ensure window is visible - use orderFrontRegardless to ensure visibility even when app isn't active
        window.alphaValue = 0
        window.orderFrontRegardless()
        
        // Window created
        
        // Animate in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        } completionHandler: {
            // Ensure window stays visible after animation
            window.orderFrontRegardless()
            // Animation complete
        }
    }

    private func hideWindow() {
        guard let window = progressWindow else { return }

        // Remove notification observer
        Foundation.NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: window)

        let windowToClose = window
        progressWindow = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            windowToClose.animator().alphaValue = 0.0
        }) {
            windowToClose.close()
        }
    }

    private func positionWindow() {
        guard let window = progressWindow else {
            // No window to position
            return
        }

        // Find the screen that contains the main window or use main screen
        let mainWindow = NSApplication.shared.windows.first { $0.isMainWindow }
        let screen = mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        
        guard let screen = screen else {
            // No screen found
            return
        }

        // Use visibleFrame to account for menu bar and dock
        let screenFrame = screen.visibleFrame
        let padding: CGFloat = 20
        let windowWidth = window.frame.width
        let windowHeight = window.frame.height
        
        // Calculate position: bottom-right corner
        var x = screenFrame.maxX - windowWidth - padding
        var y = screenFrame.minY + padding
        
        // Ensure window is fully on-screen with padding
        // Clamp X: window must be fully visible horizontally
        x = max(screenFrame.minX + padding, min(x, screenFrame.maxX - windowWidth - padding))
        
        // Clamp Y: window must be fully visible vertically
        let maxY = screenFrame.maxY - windowHeight - padding
        let minY = screenFrame.minY + padding
        y = max(minY, min(y, maxY))

        // Positioning window
        window.setFrameOrigin(NSPoint(x: x, y: y))
        
        // Force window to be visible and on top
        window.orderFrontRegardless()
        
        // Final constraint check to ensure it's within bounds
        constrainWindowToScreen(window)
    }

    func constrainWindowToScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        
        let screenFrame = screen.visibleFrame
        let padding: CGFloat = 20
        var frame = window.frame
        
        // Ensure window is fully within screen bounds
        let minX = screenFrame.minX + padding
        let maxX = screenFrame.maxX - frame.width - padding
        let minY = screenFrame.minY + padding
        let maxY = screenFrame.maxY - frame.height - padding
        
        // Clamp position
        frame.origin.x = max(minX, min(frame.origin.x, maxX))
        frame.origin.y = max(minY, min(frame.origin.y, maxY))
        
        // If window is still too large for screen, shrink it
        if frame.width > screenFrame.width - (padding * 2) {
            frame.size.width = screenFrame.width - (padding * 2)
            frame.origin.x = screenFrame.minX + padding
        }
        if frame.height > screenFrame.height - (padding * 2) {
            frame.size.height = screenFrame.height - (padding * 2)
            frame.origin.y = screenFrame.minY + padding
        }
        
        // Only update if position changed
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }
}

// MARK: - SwiftUI View

struct FloatingProgressView: View {
    @EnvironmentObject var manager: FloatingProgressManager

    var body: some View {
        circularView
    }

    // MARK: - Circular View

    private var circularView: some View {
        ZStack {
            // Background
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )

            // Progress ring background
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 4)
                .padding(6)

            // Progress ring
            Circle()
                .trim(from: 0, to: manager.progress)
                .stroke(
                    manager.operation.color,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(6)
                .animation(.linear(duration: 0.2), value: manager.progress)

            // Icon or percentage
            if manager.progress < 1.0 {
                Image(systemName: manager.operation.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(manager.operation.color)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.green)
            }
        }
        .frame(width: 56, height: 56)
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Preview

#Preview {
    FloatingProgressView()
        .environmentObject(FloatingProgressManager.shared)
        .onAppear {
            FloatingProgressManager.shared.startOperation(.prepping(docket: "12345"), totalFiles: 10)
            FloatingProgressManager.shared.updateProgress(0.45, message: "Copying files...", currentFile: "Toyota_30s_Master.mov")
        }
}
