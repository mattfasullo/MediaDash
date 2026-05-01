import Darwin
import Foundation

/// macOS system frameworks sometimes print benign noise to stderr (CoreServices `_CSStore`, RenderBox
/// looking for `/AppleInternal/...` Metal bundles). There is no supported API to silence them at the source;
/// this installs a line-buffered filter on the process stderr fd so Xcode’s console stays readable.
enum SystemStderrNoiseFilter {
    private static let lock = NSLock()
    private static var installed = false

    static func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        let savedStderr = dup(STDERR_FILENO)
        guard savedStderr >= 0 else { return }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            close(savedStderr)
            return
        }

        let readFD = fds[0]
        let writeFD = fds[1]

        guard dup2(writeFD, STDERR_FILENO) >= 0 else {
            close(readFD)
            close(writeFD)
            close(savedStderr)
            return
        }
        close(writeFD)

        let readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        let realStderr = FileHandle(fileDescriptor: savedStderr, closeOnDealloc: false)

        var leftover = Data()

        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                if !leftover.isEmpty, !shouldSuppressLine(leftover) {
                    realStderr.write(leftover)
                }
                leftover.removeAll(keepingCapacity: false)
                return
            }

            leftover.append(chunk)

            while let newlineIdx = leftover.firstIndex(of: 0x0A) {
                let line = leftover[..<newlineIdx]
                let restStart = leftover.index(after: newlineIdx)
                leftover.removeSubrange(..<restStart)
                if !shouldSuppressLine(line) {
                    realStderr.write(line)
                    realStderr.write(Data([0x0A]))
                }
            }
        }
    }

    private static func shouldSuppressLine(_ line: Data) -> Bool {
        guard let s = String(data: line, encoding: .utf8) else { return false }

        if s.contains("Failed to get unit") && s.contains("_CSStore") {
            return true
        }
        if s.contains("Unable to open mach-O at path:") {
            if s.contains("/AppleInternal/") || s.contains("RenderBox.framework") || s.contains("default.metallib") {
                return true
            }
        }
        return false
    }
}
