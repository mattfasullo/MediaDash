//
//  AppDelegate.swift
//  MediaDash
//
//  Created by Matt Fasullo on 2025-11-20.
//

import Cocoa
import CoreServices
import SwiftUI
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    private var updaterController: SPUStandardUpdaterController!
    private var quitEventMonitor: Any?
    // Store NotificationCenter observers for proper cleanup
    private var windowBecomeKeyObserver: NSObjectProtocol?
    private var windowBecomeMainObserver: NSObjectProtocol?

    private var currentUpdateChannel: UpdateChannel {
        // Check if this is a dev build (MediaDash-Dev bundle ID)
        let isDevBuild = Bundle.main.bundleIdentifier == "mattfasullo.MediaDash-Dev"
        
        // Dev builds should ALWAYS use the dev channel, regardless of user settings
        // This ensures dev builds check the correct appcast
        if isDevBuild {
            return .development
        }
        
        // For production builds, respect user's channel preference
        if let settingsData = UserDefaults.standard.data(forKey: "savedProfiles"),
           let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: settingsData),
           let currentProfileName = UserDefaults.standard.string(forKey: "currentProfile"),
           let profile = profiles[currentProfileName] {
            return profile.updateChannel
        }
        return .production // Default for production builds
    }
    
    func applicationWillFinishLaunching(_ notification: Foundation.Notification) {
        // Load or migrate keychain credentials blob BEFORE views initialize.
        // Legacy per-key items are merged into a single JSON blob once; then only
        // one Keychain item is used for all secrets (fewer login-keychain prompts).
        KeychainService.migrateCredentialsToBlobIfNeededAtLaunch()
    }

    func applicationDidFinishLaunching(_ aNotification: Foundation.Notification) {
        // #region agent log
        let logData: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "post-fix",
            "hypothesisId": "A",
            "location": "AppDelegate.swift:applicationDidFinishLaunching",
            "message": "App launch - migration starting",
            "data": [
                "timestamp": Date().timeIntervalSince1970,
                "thread": Thread.current.name ?? "main"
            ],
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let json = try? JSONSerialization.data(withJSONObject: logData),
           let jsonString = String(data: json, encoding: .utf8) {
            if let fileHandle = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                fileHandle.seekToEndOfFile()
                fileHandle.write((jsonString + "\n").data(using: .utf8)!)
                fileHandle.closeFile()
            } else {
                try? (jsonString + "\n").write(toFile: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log", atomically: true, encoding: .utf8)
            }
        }
        // #endregion
        // Initialize Sparkle updater
        // Each app (MediaDash vs MediaDash-Dev) has its own appcast URL in Info.plist
        updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
            updaterDelegate: nil,
                userDriverDelegate: nil
            )
        
        // Set up global CMD+Q handler that works even when sheets/modals are open
        setupGlobalQuitHandler()
        
        // Configure all existing windows immediately
        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                WindowConfiguration.configureWindow(window)
            }
        }

        // Configure windows when they become key - store observer for cleanup
        windowBecomeKeyObserver = Foundation.NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                WindowConfiguration.configureWindow(window)
            }
        }

        // Configure windows when they become main - store observer for cleanup
        windowBecomeMainObserver = Foundation.NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                WindowConfiguration.configureWindow(window)
            }
        }

        // Initialize floating progress window manager (it auto-shows/hides based on FloatingProgressManager.shared.isVisible)
        _ = FloatingProgressWindowManager.shared

        // Finder Sync is registered with Launch Services when the host app is registered.
        // Re-register on launch so the embedded .appex is discoverable (helps after copy to /Applications, etc.).
        registerEmbeddedFinderSyncWithLaunchServices()
        
        // Cache sync status item removed - sync is now handled internally by AsanaCacheManager
    }

    // #region agent log
    private static let kMediaDashAppGroup = "group.mattfasullo.MediaDash"
    /// Cursor session ingest path (main app only); Finder Sync extension cannot write here.
    private static let kMediaDashDebugLogMirrorPath = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-55b33e.log"

    private static func appendDebugNDJSONLine(_ line: String) {
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        func appendFile(atPath path: String) {
            if FileManager.default.fileExists(atPath: path) {
                if let h = FileHandle(forWritingAtPath: path) {
                    h.seekToEndOfFile()
                    h.write(payload)
                    try? h.close()
                }
            } else {
                try? payload.write(to: URL(fileURLWithPath: path))
            }
        }
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kMediaDashAppGroup)?
            .appendingPathComponent("debug-55b33e.log") {
            appendFile(atPath: groupURL.path)
        }
        appendFile(atPath: kMediaDashDebugLogMirrorPath)
    }

    private static func mediaDashDebugNDJSON(location: String, message: String, hypothesisId: String, data: [String: String] = [:]) {
        var data = data
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: kMediaDashAppGroup)?
            .appendingPathComponent("debug-55b33e.log") {
            data["groupDebugLogPath"] = groupURL.path
        }
        let dict: [String: Any] = [
            "sessionId": "55b33e",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "location": location,
            "message": message,
            "hypothesisId": hypothesisId,
            "runId": "pre-fix",
            "data": data
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: dict),
              let line = String(data: json, encoding: .utf8) else { return }
        appendDebugNDJSONLine(line)
    }
    // #endregion

    /// Registers the app bundle and embedded Finder Sync extension with Launch Services.
    /// Finder Sync does not appear in the same System Settings sheet as Apple’s Quick Actions (Rotate, Markup, …).
    /// On Sequoia, management also appears under System Settings → General → Login Items & Extensions → **File Providers** (15.2+).
    private func registerEmbeddedFinderSyncWithLaunchServices() {
        let appURL = Bundle.main.bundleURL
        LSRegisterURL(appURL as CFURL, true)
        let appex = appURL.appendingPathComponent("Contents/PlugIns/MediaDashFinderSync.appex", isDirectory: true)
        let appexExists = FileManager.default.fileExists(atPath: appex.path)
        // #region agent log
        Self.mediaDashDebugNDJSON(
            location: "AppDelegate.swift:registerEmbeddedFinderSyncWithLaunchServices",
            message: "host app registration",
            hypothesisId: "D",
            data: [
                "appPath": appURL.path,
                "appexPath": appex.path,
                "appexExists": appexExists ? "true" : "false",
                "appexBundleID": Bundle(url: appex)?.bundleIdentifier ?? ""
            ]
        )
        // #endregion
        guard appexExists else { return }
        LSRegisterURL(appex as CFURL, true)

        // Sequoia: PlugInKit often needs the appex path registered (`-a`) before `-e use` (see LucidLink / OpenInTerminal docs).
        // Order: quarantine strip → LSRegister → pluginkit -a → pluginkit -e use.
        let extensionBundleID = Bundle(url: appex)?.bundleIdentifier
        DispatchQueue.global(qos: .utility).async {
            if Self.bundleHasQuarantineAttribute(at: appURL) {
                Self.stripQuarantineFromBundle(at: appURL)
            }
            // DTS / dev forums: stale Launch Services DB can prevent Finder from loading Finder Sync even when PlugInKit exits 0.
            let lsExit = Self.runLSRegisterForceTrusted(appURL: appURL)
            // #region agent log
            Self.mediaDashDebugNDJSON(
                location: "AppDelegate.swift:runLSRegisterForceTrusted",
                message: "lsregister -f -R -trusted finished",
                hypothesisId: "D",
                data: ["terminationStatus": String(lsExit)]
            )
            // #endregion
            Self.runPlugInKitAddAndUseFinderSync(appexPath: appex.path, bundleID: extensionBundleID)
        }
    }

    /// Forces full registration of the app bundle (and embedded PlugIns) with Launch Services.
    private static func runLSRegisterForceTrusted(appURL: URL) -> Int32 {
        let tool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return -3 }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = ["-f", "-R", "-trusted", appURL.path]
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -2
        }
    }

    private static func bundleHasQuarantineAttribute(at bundleURL: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-l", bundleURL.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let listing = String(data: data, encoding: .utf8) else { return false }
            return listing.contains("com.apple.quarantine")
        } catch {
            return false
        }
    }

    /// Removes the download quarantine flag so PlugInKit / Finder can load the embedded extension.
    private static func stripQuarantineFromBundle(at bundleURL: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-dr", "com.apple.quarantine", bundleURL.path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // Ignore: insufficient privileges or attribute already cleared.
        }
    }

    /// Registers the appex with PlugInKit (`-a`) then enables it (`-e use`), matching third‑party Sequoia troubleshooting guides.
    private static func runPlugInKitAddAndUseFinderSync(appexPath: String, bundleID: String?) {
        let pk = URL(fileURLWithPath: "/usr/bin/pluginkit")
        func run(_ arguments: [String]) -> Int32 {
            let task = Process()
            task.executableURL = pk
            task.arguments = arguments
            do {
                try task.run()
                task.waitUntilExit()
                return task.terminationStatus
            } catch {
                return -1
            }
        }
        let addExit = run(["-a", appexPath])
        var useExit: Int32 = -2
        if let id = bundleID {
            useExit = run(["-e", "use", "-i", id])
        }
        // #region agent log
        mediaDashDebugNDJSON(
            location: "AppDelegate.swift:runPlugInKitAddAndUseFinderSync",
            message: "pluginkit finished",
            hypothesisId: "D",
            data: [
                "addTerminationStatus": String(addExit),
                "useTerminationStatus": String(useExit),
                "bundleID": bundleID ?? ""
            ]
        )
        // #endregion
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            _ = FinderCommandBridge.shared.handleOpenURL(url)
        }
    }
    
    private func setupGlobalQuitHandler() {
        // Single keyDown monitor: CMD+Q quit + app-wide arrow/return so the system never beeps
        quitEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // CMD+Q: quit
            if event.modifierFlags.contains(.command) &&
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApplication.shared.terminate(nil)
                return nil
            }
            let keyWindowEarly = NSApplication.shared.keyWindow
            let keyCodes: [UInt16] = [123, 124, 125, 126, 36] // left, right, down, up, return
            // #region agent log
            if keyWindowEarly?.title == "Simian", !keyCodes.contains(event.keyCode) {
                let fr = keyWindowEarly?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                appendDebugA92964Log(
                    location: "AppDelegate.swift:keyDown",
                    message: "non-arrow key while Simian is keyWindow",
                    hypothesisId: "H3_H4",
                    data: [
                        "keyCode": Int(event.keyCode),
                        "firstResponder": fr,
                        "isEditingText": KeyboardNavigationCoordinator.isEditingText(in: keyWindowEarly)
                    ]
                )
            }
            // #endregion
            // Arrow keys and return: for the main app window, pass through so SwiftUI's .onKeyPress receives them.
            // Only intercept for other windows (e.g. sheets) so we can drive list navigation there.
            if keyCodes.contains(event.keyCode) {
                let keyWindow = NSApplication.shared.keyWindow
                let isEditing = KeyboardNavigationCoordinator.isEditingText(in: keyWindow)
                if isEditing {
                    return event
                }
                let isMainWindow = (keyWindow === WindowConfiguration.mainAppWindow)
                // Try coordinator first - if it handles, use it. Otherwise pass through for .onKeyPress
                let handled = KeyboardNavigationCoordinator.shared.handle(event: event)
                // #region agent log
                let frName = keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                appendDebugA92964Log(
                    location: "AppDelegate.swift:keyDown",
                    message: "arrow/return after coordinator",
                    hypothesisId: "H1_H2_H3",
                    data: [
                        "keyCode": Int(event.keyCode),
                        "keyWindowTitle": keyWindow?.title ?? "nil",
                        "isSimianKey": keyWindow?.title == "Simian",
                        "isMainWindow": isMainWindow,
                        "firstResponder": frName,
                        "coordinatorHandled": handled
                    ]
                )
                // #endregion
                if handled {
                    // #region agent log
                    KeyboardNavigationCoordinator.logDebug(
                        location: "AppDelegate.swift:keyDown",
                        message: "Coordinator handled",
                        data: [
                            "keyCode": Int(event.keyCode),
                            "isMainWindow": isMainWindow
                        ],
                        hypothesisId: "H10"
                    )
                    // #endregion
                    return nil
                }
                if isMainWindow {
                    // #region agent log
                    KeyboardNavigationCoordinator.logDebug(
                        location: "AppDelegate.swift:keyDown",
                        message: "Main window - passing through arrow/return",
                        data: [
                            "keyCode": Int(event.keyCode),
                            "keyWindowNil": keyWindow == nil
                        ],
                        hypothesisId: "H9"
                    )
                    // #endregion
                    return event
                }
                // For non-main windows (sheets), coordinator already handled above
            }
            return event
        }
    }
    
    func applicationDidResignActive(_ notification: Foundation.Notification) {
        // Ensure debounced notification persistence is written before long background stretches
        NotificationCenter.flushPendingPersistenceIfAny()
    }

    func applicationWillTerminate(_ aNotification: Foundation.Notification) {
        NotificationCenter.flushPendingPersistenceIfAny()
        // Clean up event monitor
        if let monitor = quitEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        // Remove NotificationCenter observers
        if let observer = windowBecomeKeyObserver {
            Foundation.NotificationCenter.default.removeObserver(observer)
            windowBecomeKeyObserver = nil
        }
        if let observer = windowBecomeMainObserver {
            Foundation.NotificationCenter.default.removeObserver(observer)
            windowBecomeMainObserver = nil
        }
    }
    
    deinit {
        // Safety net: ensure observers are removed even if applicationWillTerminate isn't called
        if let observer = windowBecomeKeyObserver {
            Foundation.NotificationCenter.default.removeObserver(observer)
            windowBecomeKeyObserver = nil
        }
        if let observer = windowBecomeMainObserver {
            Foundation.NotificationCenter.default.removeObserver(observer)
            windowBecomeMainObserver = nil
        }
    }
    
    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }
    
    // Allow CMD+Q to quit even when modals/popups are shown
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always allow termination, even when alerts or sheets are displayed
        return .terminateNow
    }
}

// MARK: - Debug session a92964
// #region agent log
fileprivate func appendDebugA92964Log(location: String, message: String, hypothesisId: String, data: [String: Any]) {
    let path = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-a92964.log"
    let payload: [String: Any] = [
        "sessionId": "a92964",
        "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
        "location": location,
        "message": message,
        "hypothesisId": hypothesisId,
        "data": data
    ]
    guard JSONSerialization.isValidJSONObject(payload),
          let json = try? JSONSerialization.data(withJSONObject: payload),
          let line = String(data: json, encoding: .utf8) else { return }
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let h = FileHandle(forWritingAtPath: path) else { return }
    h.seekToEndOfFile()
    h.write(Data((line + "\n").utf8))
    h.closeFile()
}
// #endregion
