import AppKit
import SwiftUI
import Combine

@MainActor
class CacheSyncStatusItem: ObservableObject {
    private var statusItem: NSStatusItem?
    private let cacheSyncService: CacheSyncServiceManager
    private var timer: Timer?
    private var refreshObserver: NSObjectProtocol?
    
    init(cacheSyncService: CacheSyncServiceManager) {
        self.cacheSyncService = cacheSyncService
        setupStatusItem()
        startMonitoring()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else { return }
        
        button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Cache Sync")
        button.image?.isTemplate = true
        button.toolTip = "MediaDash Cache Sync Service"
        
        // Create menu
        updateMenu()
    }
    
    private func updateMenu() {
        let menu = NSMenu()
        
        // Status item
        let statusText: String
        if cacheSyncService.isRunning {
            statusText = "Status: Running"
        } else if cacheSyncService.isInstalled {
            statusText = "Status: Stopped"
        } else {
            statusText = "Status: Not Installed"
        }
        
        let statusMenuItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Start/Stop items
        if !cacheSyncService.isInstalled {
            let installItem = NSMenuItem(title: "Install & Start Service", action: #selector(installService), keyEquivalent: "")
            installItem.target = self
            menu.addItem(installItem)
        } else {
            let startItem = NSMenuItem(title: "Start Service", action: #selector(startService), keyEquivalent: "")
            startItem.target = self
            startItem.isEnabled = !cacheSyncService.isRunning
            menu.addItem(startItem)
            
            let stopItem = NSMenuItem(title: "Stop Service", action: #selector(stopService), keyEquivalent: "")
            stopItem.target = self
            stopItem.isEnabled = cacheSyncService.isRunning
            menu.addItem(stopItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // View logs
        let viewLogsItem = NSMenuItem(title: "View Logs", action: #selector(viewLogs), keyEquivalent: "")
        viewLogsItem.target = self
        menu.addItem(viewLogsItem)
        
        // Open Settings
        let settingsItem = NSMenuItem(title: "Open Settings", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        statusItem?.menu = menu
        
        // Update button appearance
        updateButtonAppearance()
    }
    
    private func updateButtonAppearance() {
        guard let button = statusItem?.button else { return }
        
        if cacheSyncService.isRunning {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Cache Sync Running")
            if #available(macOS 10.14, *) {
                button.contentTintColor = .systemGreen
            }
        } else if cacheSyncService.isInstalled {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Cache Sync Stopped")
            if #available(macOS 10.14, *) {
                button.contentTintColor = .systemOrange
            }
        } else {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Cache Sync Not Installed")
            if #available(macOS 10.14, *) {
                button.contentTintColor = .systemGray
            }
        }
    }
    
    private func startMonitoring() {
        // Update every 30 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.cacheSyncService.checkStatus()
                self.updateMenu()
            }
        }
        
        // Listen for refresh notifications
        refreshObserver = Foundation.NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RefreshCacheSyncStatus"),
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] (_: Foundation.Notification) in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.cacheSyncService.checkStatus()
                self.updateMenu()
            }
        }
    }
    
    @objc private func installService() {
        Task {
            // Check if active elsewhere first
            // We need to get the cache path from settings, but we don't have direct access here
            // For now, just try to install
            guard let scriptPath = cacheSyncService.findSyncScript() else {
                let alert = NSAlert()
                alert.messageText = "Script Not Found"
                alert.informativeText = "Could not find sync_shared_cache.sh. Please ensure it's accessible."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            
            await cacheSyncService.installAndStart(scriptPath: scriptPath)
            updateMenu()
        }
    }
    
    @objc private func startService() {
        cacheSyncService.start()
        updateMenu()
    }
    
    @objc private func stopService() {
        cacheSyncService.stop()
        updateMenu()
    }
    
    @objc private func viewLogs() {
        let logPath = "/tmp/mediadash-cache-sync.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else {
            let alert = NSAlert()
            alert.messageText = "Log File Not Found"
            alert.informativeText = "The log file doesn't exist yet. It will be created when the service runs."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    @objc private func openSettings() {
        // Post notification to open settings
        Foundation.NotificationCenter.default.post(name: NSNotification.Name("OpenSettings"), object: nil)
    }
    
    func refresh() {
        cacheSyncService.checkStatus()
        updateMenu()
    }
    
    deinit {
        timer?.invalidate()
        if let observer = refreshObserver {
            Foundation.NotificationCenter.default.removeObserver(observer)
        }
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}

