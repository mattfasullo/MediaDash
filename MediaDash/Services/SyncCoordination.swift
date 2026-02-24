import Foundation

/// Shared lock and progress file for coordinating Asana cache sync across multiple MediaDash instances.
/// All file I/O is designed to run off the main thread. Use a dedicated queue or Task.detached.
enum SyncCoordination {
    static let lockDirectoryName = "mediadash_sync_lock"
    static let progressFileName = "progress.json"
    static let staleLockInterval: TimeInterval = 15 * 60  // 15 minutes
    static let ioTimeout: TimeInterval = 2.0
    static let progressWriteThrottle: TimeInterval = 0.5

    // Explicitly nonisolated (SE-0449) so usable from nonisolated static methods. Mutable vars require nonisolated(unsafe).
    nonisolated static let _syncCoordinationQueue = DispatchQueue(label: "com.mediadash.sync-coordination", qos: .utility)
    nonisolated(unsafe) static var _syncLastProgressWriteTime: TimeInterval = 0
    nonisolated(unsafe) static var _syncLastProgressWritePhase: String = ""

    struct SyncProgressPayload: Codable, Sendable {
        let startedAt: String
        var progress: Double
        var phase: String
        let hostDeviceName: String

        nonisolated init(startedAt: String, progress: Double, phase: String, hostDeviceName: String) {
            self.startedAt = startedAt
            self.progress = progress
            self.phase = phase
            self.hostDeviceName = hostDeviceName
        }

        nonisolated init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try c.decode(String.self, forKey: .startedAt)
            progress = try c.decode(Double.self, forKey: .progress)
            phase = try c.decode(String.self, forKey: .phase)
            hostDeviceName = try c.decode(String.self, forKey: .hostDeviceName)
        }

        nonisolated func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(progress, forKey: .progress)
            try c.encode(phase, forKey: .phase)
            try c.encode(hostDeviceName, forKey: .hostDeviceName)
        }

        private enum CodingKeys: String, CodingKey {
            case startedAt, progress, phase, hostDeviceName
        }
    }

    /// Resolve shared cache URL to the cache directory (parent of mediadash_docket_cache.json).
    /// Returns nil if path is HTTP, empty, or not a usable file path.
    /// Logic must stay in sync with AsanaCacheManager.getFileURL(from:) — same cache file name and path resolution.
    nonisolated static func syncLockDirectoryURL(sharedCacheURL: String) -> URL? {
        let path = sharedCacheURL.trimmingCharacters(in: .whitespaces)
        if path.isEmpty || path.hasPrefix("http://") || path.hasPrefix("https://") {
            return nil
        }
        let cacheFileName = "mediadash_docket_cache.json"
        let url: URL
        if path.hasPrefix("file://") {
            url = URL(string: path) ?? URL(fileURLWithPath: path.replacingOccurrences(of: "file://", with: ""))
        } else {
            url = URL(fileURLWithPath: path)
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let cacheFileURL: URL
        if path.hasPrefix("file://") && (url.pathExtension.isEmpty || path.hasSuffix("/")) {
            cacheFileURL = url.appendingPathComponent(cacheFileName)
        } else if exists {
            if isDirectory.boolValue {
                cacheFileURL = url.appendingPathComponent(cacheFileName)
            } else {
                if url.pathExtension == "json" && url.lastPathComponent == cacheFileName {
                    cacheFileURL = url
                } else {
                    cacheFileURL = url.deletingLastPathComponent().appendingPathComponent(cacheFileName)
                }
            }
        } else {
            if url.pathExtension.isEmpty && !path.lowercased().hasSuffix(".json") {
                cacheFileURL = url.appendingPathComponent(cacheFileName)
            } else {
                cacheFileURL = url
            }
        }
        return cacheFileURL.deletingLastPathComponent().appendingPathComponent("mediadash_sync_lock", isDirectory: true)
    }

    /// Try to acquire the sync lock by creating the lock directory. Returns true if we are the host.
    /// If directory already exists and progress is stale (>15 min), removes it and returns false (caller may retry).
    nonisolated static func tryAcquireSyncLock(sharedCacheURL: String, hostDeviceName: String) -> Bool {
        guard let lockDir = syncLockDirectoryURL(sharedCacheURL: sharedCacheURL) else { return true }
        let parentDir = lockDir.deletingLastPathComponent()
        return _syncCoordinationQueue.sync {
            _runWithTimeout(2.0) {
                let fm = FileManager.default
                guard fm.fileExists(atPath: parentDir.path) else { return false }
                do {
                    try fm.createDirectory(at: lockDir, withIntermediateDirectories: false, attributes: nil)
                    let payload = SyncProgressPayload(
                        startedAt: _iso8601(from: Date()),
                        progress: 0,
                        phase: "Starting sync...",
                        hostDeviceName: hostDeviceName
                    )
                    let data = try JSONEncoder().encode(payload)
                    let progressURL = lockDir.appendingPathComponent("progress.json")
                    try data.write(to: progressURL)
                    return true
                } catch {
                    if fm.fileExists(atPath: lockDir.path) {
                        if let (_, isStale) = readSyncProgress(sharedCacheURL: sharedCacheURL), isStale {
                            try? fm.removeItem(at: lockDir)
                        }
                    }
                    return false
                }
            } ?? false
        }
    }

    /// Write progress to the lock directory. Throttled to ~0.5s or on phase change. Call from background.
    nonisolated static func writeSyncProgress(sharedCacheURL: String, progress: Double, phase: String, hostDeviceName: String) {
        guard let lockDir = syncLockDirectoryURL(sharedCacheURL: sharedCacheURL) else { return }
        _syncCoordinationQueue.async {
            guard FileManager.default.fileExists(atPath: lockDir.path) else { return }
            let now = Date().timeIntervalSince1970
            if now - _syncLastProgressWriteTime < 0.5 && phase == _syncLastProgressWritePhase {
                return
            }
            _ = _runWithTimeout(2.0) {
                let progressURL = lockDir.appendingPathComponent("progress.json")
                var startedAt = _iso8601(from: Date())
                if let data = try? Data(contentsOf: progressURL),
                   let existing = try? JSONDecoder().decode(SyncProgressPayload.self, from: data) {
                    startedAt = existing.startedAt
                }
                let payload = SyncProgressPayload(
                    startedAt: startedAt,
                    progress: progress,
                    phase: phase,
                    hostDeviceName: hostDeviceName
                )
                let data = try? JSONEncoder().encode(payload)
                guard let data = data else { return }
                try? data.write(to: progressURL)
                _syncLastProgressWriteTime = now
                _syncLastProgressWritePhase = phase
            }
        }
    }

    /// Release the sync lock by removing the lock directory. Call from background.
    nonisolated static func releaseSyncLock(sharedCacheURL: String) {
        guard let lockDir = syncLockDirectoryURL(sharedCacheURL: sharedCacheURL) else { return }
        _syncCoordinationQueue.async {
            _ = _runWithTimeout(2.0) {
                try? FileManager.default.removeItem(at: lockDir)
            }
        }
    }

    /// Read current progress from the lock directory. Returns (payload, isStale). Call from background.
    nonisolated static func readSyncProgress(sharedCacheURL: String) -> (payload: SyncProgressPayload, isStale: Bool)? {
        guard let lockDir = syncLockDirectoryURL(sharedCacheURL: sharedCacheURL) else { return nil }
        let progressURL = lockDir.appendingPathComponent("progress.json")
        let result: (SyncProgressPayload, Bool)? = _syncCoordinationQueue.sync {
            _runWithTimeout(2.0) {
                guard let data = try? Data(contentsOf: progressURL),
                      let payload = try? JSONDecoder().decode(SyncProgressPayload.self, from: data) else {
                    return nil
                }
                let started = _parseISO8601(payload.startedAt) ?? Date.distantPast
                let isStale = Date().timeIntervalSince(started) > (15 * 60)
                return (payload, isStale)
            } ?? nil
        }
        return result
    }

    /// Returns true if the lock directory exists. Call from background.
    nonisolated static func isSyncLockPresent(sharedCacheURL: String) -> Bool {
        guard let lockDir = syncLockDirectoryURL(sharedCacheURL: sharedCacheURL) else { return false }
        return _syncCoordinationQueue.sync {
            _runWithTimeout(2.0) {
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: lockDir.path, isDirectory: &isDir) && isDir.boolValue
            } ?? false
        }
    }

    /// Remove stale lock directory if present. Call from background. Used by observer when progress is stale.
    nonisolated static func removeStaleLock(sharedCacheURL: String) {
        guard let lockDir = syncLockDirectoryURL(sharedCacheURL: sharedCacheURL) else { return }
        _syncCoordinationQueue.async {
            _ = _runWithTimeout(2.0) {
                try? FileManager.default.removeItem(at: lockDir)
            }
        }
    }

    // Helpers (nonisolated so callable from nonisolated static methods).
    nonisolated static func _iso8601(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated static func _parseISO8601(_ s: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: s) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }

    nonisolated static func _runWithTimeout<T>(_ timeout: TimeInterval, _ work: @escaping () throws -> T) -> T? {
        var result: T?
        var error: Error?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            do {
                result = try work()
            } catch let e {
                error = e
            }
            sem.signal()
        }
        let waitResult = sem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut { return nil }
        if error != nil { return nil }
        return result
    }
}
