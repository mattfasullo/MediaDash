import Foundation
import AppKit
import Combine

/// Manages the automatic cache sync service (launchd daemon)
@MainActor
class CacheSyncServiceManager: ObservableObject {
    @Published var isInstalled = false
    @Published var isRunning = false
    @Published var isActiveElsewhere = false
    @Published var installationError: String?
    @Published var isInstalling = false
    @Published var statusMessage: String = ""
    
    private let serviceLabel = "com.mediadash.cache-sync"
    private let plistName = "com.mediadash.cache-sync.plist"
    
    /// Check service status
    func checkStatus() {
        // Check if plist exists
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(plistName)
        
        isInstalled = FileManager.default.fileExists(atPath: plistPath.path)
        
        // Check if service is loaded/running on this device
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list", serviceLabel]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            // If exit code is 0, service is loaded
            isRunning = (task.terminationStatus == 0)
        } catch {
            isRunning = false
        }
        
        // Check if service is active elsewhere by checking cache file updates
        checkIfActiveElsewhere()
        
        updateStatusMessage()
    }
    
    /// Check if the cache sync service is active on another device
    /// by checking if the shared cache is being updated regularly
    private func checkIfActiveElsewhere() {
        // This will be called with the shared cache URL from settings
        // For now, we'll check a common location
        let defaultCachePath = "/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache/mediadash_docket_cache.json"
        
        guard FileManager.default.fileExists(atPath: defaultCachePath) else {
            isActiveElsewhere = false
            return
        }
        
        // Check file modification time
        if let attributes = try? FileManager.default.attributesOfItem(atPath: defaultCachePath),
           let modDate = attributes[.modificationDate] as? Date {
            let age = Date().timeIntervalSince(modDate)
            
            // If cache was updated in the last 45 minutes (within sync interval + buffer),
            // it's likely being updated by another device
            if age < 45 * 60 {
                // Also check if it's NOT running on this device
                if !isRunning {
                    isActiveElsewhere = true
                    return
                }
            }
        }
        
        isActiveElsewhere = false
    }
    
    /// Check if active elsewhere using a specific cache path
    func checkIfActiveElsewhere(cachePath: String?) {
        guard let cachePath = cachePath, !cachePath.isEmpty else {
            isActiveElsewhere = false
            return
        }
        
        // Resolve to actual file path
        let fileURL: URL
        if cachePath.hasPrefix("file://") {
            fileURL = URL(string: cachePath) ?? URL(fileURLWithPath: cachePath.replacingOccurrences(of: "file://", with: ""))
        } else {
            fileURL = URL(fileURLWithPath: cachePath)
        }
        
        // If it's a directory, append filename
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
        
        guard exists else {
            isActiveElsewhere = false
            return
        }
        
        let actualPath: String
        if isDirectory.boolValue {
            actualPath = fileURL.appendingPathComponent("mediadash_docket_cache.json").path
        } else {
            actualPath = fileURL.path
        }
        
        guard FileManager.default.fileExists(atPath: actualPath) else {
            isActiveElsewhere = false
            return
        }
        
        // Check file modification time
        if let attributes = try? FileManager.default.attributesOfItem(atPath: actualPath),
           let modDate = attributes[.modificationDate] as? Date {
            let age = Date().timeIntervalSince(modDate)
            
            // If cache was updated in the last 45 minutes and NOT running on this device,
            // it's likely being updated by another device
            if age < 45 * 60 && !isRunning {
                isActiveElsewhere = true
                return
            }
        }
        
        isActiveElsewhere = false
    }
    
    private func updateStatusMessage() {
        if isInstalling {
            statusMessage = "Installing service..."
        } else if isRunning {
            statusMessage = "Service is running on this device"
        } else if isActiveElsewhere {
            statusMessage = "Service is already active on another device"
        } else if isInstalled {
            statusMessage = "Service is installed but not running"
        } else {
            statusMessage = "Service is not installed"
        }
    }
    
    /// Install and start the service
    /// - Parameters:
    ///   - scriptPath: Path to the sync script
    ///   - workspaceID: Optional Asana workspace ID from MediaDash settings
    ///   - projectID: Optional Asana project ID from MediaDash settings
    func installAndStart(scriptPath: String, workspaceID: String? = nil, projectID: String? = nil) async {
        // Check if already active elsewhere first
        if isActiveElsewhere {
            installationError = "Cache sync service is already active on another device. Only one instance should be running at a time."
            return
        }
        
        // Check if already running on this device
        if isRunning {
            installationError = "Service is already running on this device."
            return
        }
        
        isInstalling = true
        installationError = nil
        
        defer {
            isInstalling = false
            checkStatus()
        }
        
        do {
            // Make script executable
            let chmodTask = Process()
            chmodTask.launchPath = "/bin/chmod"
            chmodTask.arguments = ["+x", scriptPath]
            try chmodTask.run()
            chmodTask.waitUntilExit()
            
            if chmodTask.terminationStatus != 0 {
                throw CacheSyncError.scriptNotExecutable
            }
            
            // Create plist content with settings
            let plistContent = createPlistContent(scriptPath: scriptPath, workspaceID: workspaceID, projectID: projectID)
            
            // Write plist to LaunchAgents
            let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents")
            
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            
            let plistPath = launchAgentsDir.appendingPathComponent(plistName)
            try plistContent.write(to: plistPath, atomically: true, encoding: .utf8)
            
            // Load the service
            let loadTask = Process()
            loadTask.launchPath = "/bin/launchctl"
            loadTask.arguments = ["load", plistPath.path]
            
            // Set up error pipe
            let errorPipe = Pipe()
            loadTask.standardError = errorPipe
            
            try loadTask.run()
            loadTask.waitUntilExit()
            
            if loadTask.terminationStatus != 0 {
                // Get error output if available
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "Unknown error (exit code: \(loadTask.terminationStatus))"
                throw CacheSyncError.loadFailed(errorMsg)
            }
            
            // Start the service
            let startTask = Process()
            startTask.launchPath = "/bin/launchctl"
            startTask.arguments = ["start", serviceLabel]
            try startTask.run()
            startTask.waitUntilExit()
            
            if startTask.terminationStatus != 0 {
                throw CacheSyncError.startFailed
            }
            
            // Small delay to let service start
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            
            // Update status
            checkStatus()
            
        } catch {
            installationError = error.localizedDescription
            print("❌ [CacheSync] Installation failed: \(error.localizedDescription)")
        }
    }
    
    /// Stop the service
    func stop() {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["stop", serviceLabel]
        
        do {
            try task.run()
            task.waitUntilExit()
            checkStatus()
        } catch {
            print("❌ [CacheSync] Failed to stop service: \(error.localizedDescription)")
        }
    }
    
    /// Start the service (if already installed)
    func start() {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["start", serviceLabel]
        
        do {
            try task.run()
            task.waitUntilExit()
            checkStatus()
        } catch {
            print("❌ [CacheSync] Failed to start service: \(error.localizedDescription)")
        }
    }
    
    /// Uninstall the service
    func uninstall() {
        // Stop first
        stop()
        
        // Unload
        let unloadTask = Process()
        unloadTask.launchPath = "/bin/launchctl"
        unloadTask.arguments = ["unload", serviceLabel]
        try? unloadTask.run()
        unloadTask.waitUntilExit()
        
        // Remove plist
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent(plistName)
        
        try? FileManager.default.removeItem(at: plistPath)
        
        checkStatus()
    }
    
    /// Find the sync script path
    func findSyncScript() -> String? {
        // Try to find the script in common locations
        let bundlePath = Bundle.main.bundlePath
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let currentDir = FileManager.default.currentDirectoryPath
        
        var possiblePaths: [String] = []
        
        // 1. Development: Check project root from source file location
        // If we're in a build directory, go up to find project root
        if bundlePath.contains("/build/") || bundlePath.contains("/DerivedData/") {
            // Extract project root from build path
            if let buildIndex = bundlePath.range(of: "/build/") {
                let projectRoot = String(bundlePath[..<buildIndex.lowerBound])
                possiblePaths.append("\(projectRoot)/sync_shared_cache.sh")
            } else if let derivedIndex = bundlePath.range(of: "/DerivedData/") {
                // For DerivedData, go up to find project root
                let derivedPath = String(bundlePath[..<derivedIndex.lowerBound])
                // Try going up directories to find MediaDash project
                let url = URL(fileURLWithPath: derivedPath)
                var current = url
                for _ in 0..<5 {
                    current = current.deletingLastPathComponent()
                    let testPath = current.appendingPathComponent("MediaDash/sync_shared_cache.sh").path
                    if FileManager.default.fileExists(atPath: testPath) {
                        possiblePaths.append(testPath)
                        break
                    }
                }
            }
        }
        
        // 2. Development: Try to find project root by looking for Xcode project file
        // Check common locations and look for MediaDash.xcodeproj
        let projectRootCandidates = [
            currentDir,
            homeDir + "/Projects/MediaDash",
            homeDir + "/Development/MediaDash",
            homeDir + "/Documents/MediaDash",
            homeDir + "/Desktop/MediaDash"
        ]
        
        for candidate in projectRootCandidates {
            let xcodeProject = "\(candidate)/MediaDash.xcodeproj"
            let scriptPath = "\(candidate)/sync_shared_cache.sh"
            if FileManager.default.fileExists(atPath: xcodeProject) {
                possiblePaths.append(scriptPath)
            }
        }
        
        // 3. Development: current working directory (when run from Xcode)
        possiblePaths.append("\(currentDir)/sync_shared_cache.sh")
        
        // 4. Check app bundle Resources (for installed app)
        if bundlePath.hasSuffix(".app") {
            let resourcesPath = "\(bundlePath)/Contents/Resources/sync_shared_cache.sh"
            possiblePaths.append(resourcesPath)
            
            let appDir = (bundlePath as NSString).deletingLastPathComponent
            possiblePaths.append("\(appDir)/sync_shared_cache.sh")
            
            // Try going up directories from app location
            var appDirURL = URL(fileURLWithPath: appDir)
            for _ in 0..<5 {
                appDirURL = appDirURL.deletingLastPathComponent()
                let testPath = appDirURL.appendingPathComponent("sync_shared_cache.sh").path
                if FileManager.default.fileExists(atPath: testPath) {
                    possiblePaths.append(testPath)
                    break
                }
            }
        }
        
        // 5. Check common project locations
        possiblePaths.append("\(homeDir)/Projects/MediaDash/sync_shared_cache.sh")
        possiblePaths.append("\(homeDir)/Development/MediaDash/sync_shared_cache.sh")
        possiblePaths.append("\(homeDir)/Documents/MediaDash/sync_shared_cache.sh")
        
        // 6. System-wide installation
        possiblePaths.append("/usr/local/bin/mediadash-cache-sync.sh")
        possiblePaths.append("/usr/local/bin/sync_shared_cache.sh")
        
        // 7. User bin
        possiblePaths.append("\(homeDir)/bin/sync_shared_cache.sh")
        
        // Check each path
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                print("✅ [CacheSync] Found script at: \(path)")
                return path
            }
        }
        
        print("❌ [CacheSync] Could not find script. Checked paths:")
        for path in possiblePaths {
            print("   - \(path)")
        }
        
        return nil
    }
    
    private func createPlistContent(scriptPath: String, workspaceID: String? = nil, projectID: String? = nil) -> String {
        // Build environment variables dict
        var envVars = "                <key>PATH</key>\n                <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>"
        
        // Add WORKSPACE_ID if provided
        if let workspaceID = workspaceID, !workspaceID.isEmpty {
            envVars += "\n                <key>WORKSPACE_ID</key>\n                <string>\(workspaceID)</string>"
        }
        
        // Add PROJECT_ID if provided
        if let projectID = projectID, !projectID.isEmpty {
            envVars += "\n                <key>PROJECT_ID</key>\n                <string>\(projectID)</string>"
        }
        
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(serviceLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(scriptPath)</string>
            </array>
            <key>StartInterval</key>
            <integer>1800</integer>
            <key>RunAtLoad</key>
            <false/>
            <key>StandardOutPath</key>
            <string>/tmp/mediadash-cache-sync.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/mediadash-cache-sync-error.log</string>
            <key>EnvironmentVariables</key>
            <dict>
        \(envVars)
            </dict>
            <key>KeepAlive</key>
            <false/>
            <key>ThrottleInterval</key>
            <integer>300</integer>
        </dict>
        </plist>
        """
    }
}

enum CacheSyncError: LocalizedError {
    case bundleNotFound
    case scriptNotFound
    case scriptNotExecutable
    case loadFailed(String)
    case startFailed
    
    var errorDescription: String? {
        switch self {
        case .bundleNotFound:
            return "Could not find MediaDash bundle"
        case .scriptNotFound:
            return "Cache sync script not found. Please ensure sync_shared_cache.sh is accessible."
        case .scriptNotExecutable:
            return "Failed to make script executable. Check file permissions."
        case .loadFailed(let details):
            return "Failed to load the service: \(details)"
        case .startFailed:
            return "Failed to start the service. Check logs for details."
        }
    }
}

