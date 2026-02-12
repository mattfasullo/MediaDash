//
//  FFmpegInstallService.swift
//  MediaDash
//
//  Service for installing FFmpeg via Homebrew from within the app.
//

import Foundation

/// Service for installing FFmpeg via Homebrew from within the app.
enum FFmpegInstallService {

    /// Path to the brew executable, or nil if not installed.
    static func brewPath() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        guard let path = runWhichBrew(), !path.isEmpty else { return nil }
        return path
    }

    private static func runWhichBrew() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", "-lc", "which brew"]
        process.standardOutput = Pipe()
        process.standardError = FileHandle.nullDevice
        process.environment = baseEnvironment()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let data = try (process.standardOutput as? Pipe)?.fileHandleForReading.readToEnd(),
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}
        return nil
    }

    /// Environment that includes Homebrew in PATH so subprocesses can find brew and formulae.
    private static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let brewPaths = "/opt/homebrew/bin:/usr/local/bin"
        let existing = env["PATH"] ?? ""
        env["PATH"] = "\(brewPaths):\(existing)"
        return env
    }

    /// Runs `brew install ffmpeg`, streaming output via the callback. Throws on failure.
    static func installFFmpeg(
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let brew = brewPath() else {
            throw FFmpegInstallError.homebrewNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "ffmpeg"]
        process.environment = baseEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let queue = DispatchQueue(label: "ffmpeg.install.output")
        let emit: @Sendable (String) -> Void = { text in
            DispatchQueue.main.async { onOutput(text) }
        }

        final class Buffers {
            var outBuffer = ""
            var errBuffer = ""
        }
        let buffers = Buffers()

        outPipe.fileHandleForReading.readabilityHandler = { [weak buffers] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            guard let s = String(data: data, encoding: .utf8), let buffers = buffers else { return }
            queue.async {
                buffers.outBuffer += s
                let lines = buffers.outBuffer.split(separator: "\n", omittingEmptySubsequences: false)
                buffers.outBuffer = lines.last.map(String.init) ?? ""
                for line in lines.dropLast() {
                    emit(String(line))
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak buffers] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            guard let s = String(data: data, encoding: .utf8), let buffers = buffers else { return }
            queue.async {
                buffers.errBuffer += s
                let lines = buffers.errBuffer.split(separator: "\n", omittingEmptySubsequences: false)
                buffers.errBuffer = lines.last.map(String.init) ?? ""
                for line in lines.dropLast() {
                    emit(String(line))
                }
            }
        }

        try process.run()
        process.waitUntilExit()

        // Flush remaining buffers (on same queue so we see final state)
        queue.sync {
            if !buffers.outBuffer.isEmpty { emit(buffers.outBuffer) }
            if !buffers.errBuffer.isEmpty { emit(buffers.errBuffer) }
        }

        if process.terminationStatus != 0 {
            throw FFmpegInstallError.installFailed(exitCode: Int(process.terminationStatus))
        }
    }
}

enum FFmpegInstallError: LocalizedError {
    case homebrewNotFound
    case installFailed(exitCode: Int)

    var errorDescription: String? {
        switch self {
        case .homebrewNotFound:
            return "Homebrew is not installed. Install it from brew.sh first."
        case .installFailed(let code):
            return "Installation failed (exit code \(code)). Try running 'brew install ffmpeg' in Terminal."
        }
    }
}
