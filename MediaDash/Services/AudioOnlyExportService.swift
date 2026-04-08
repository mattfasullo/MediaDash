//
//  AudioOnlyExportService.swift
//  MediaDash
//
//  Extracts audio from video files to AAC in M4A next to the source (Finder / in-app use).
//

import AppKit
import Foundation

enum AudioOnlyExportService {

    /// Skip obvious audio-only files when the user mixed selections.
    private static let skipExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus"
    ]

    /// Runs extraction on a background task; updates `FloatingProgressManager` on the main actor.
    @MainActor
    static func run(urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }

        guard RestripeService.resolveFFmpegPath() != nil else {
            let alert = NSAlert()
            alert.messageText = "FFmpeg Not Found"
            alert.informativeText = "Install FFmpeg to extract audio (e.g. brew install ffmpeg), then try again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        Task {
            let ffmpeg = RestripeService.resolveFFmpegPath()!
            let toProcess = files.filter { shouldAttempt(url: $0) }
            if toProcess.isEmpty {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "No Video Files"
                    alert.informativeText = "Select one or more video files (audio-only files were skipped)."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                return
            }

            await MainActor.run {
                FloatingProgressManager.shared.startOperation(.converting(filename: "Audio only"), totalFiles: toProcess.count)
            }

            var successCount = 0
            var failures: [String] = []

            for (index, url) in toProcess.enumerated() {
                await MainActor.run {
                    let p = Double(index) / Double(max(1, toProcess.count))
                    FloatingProgressManager.shared.updateProgress(
                        p,
                        message: "Extracting audio…",
                        currentFile: url.lastPathComponent
                    )
                }

                let outURL = makeUniqueOutputURL(beside: url)
                let status = await runFFmpegExtract(ffmpegPath: ffmpeg, input: url, output: outURL)
                if status == 0 {
                    successCount += 1
                } else {
                    failures.append("\(url.lastPathComponent): FFmpeg exited with status \(status)")
                }

                await MainActor.run {
                    FloatingProgressManager.shared.incrementFile()
                }
            }

            await MainActor.run {
                let msg: String
                if successCount == toProcess.count {
                    msg = successCount == 1 ? "Created 1 audio file." : "Created \(successCount) audio files."
                } else if successCount > 0 {
                    msg = "Created \(successCount) of \(toProcess.count). Some failed."
                } else {
                    msg = "Could not create audio files."
                }
                FloatingProgressManager.shared.complete(message: msg)

                if !failures.isEmpty, successCount < toProcess.count {
                    let detail = failures.prefix(5).joined(separator: "\n")
                    let more = failures.count > 5 ? "\n…" : ""
                    let alert = NSAlert()
                    alert.messageText = "Audio extraction"
                    alert.informativeText = detail + more
                    alert.alertStyle = successCount > 0 ? .informational : .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    private static func shouldAttempt(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return true }
        return !skipExtensions.contains(ext)
    }

    private static func makeUniqueOutputURL(beside source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let stem = "\(base) (audio only)"
        var candidate = dir.appendingPathComponent("\(stem).m4a")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) \(n).m4a")
            n += 1
        }
        return candidate
    }

    private nonisolated static func runFFmpegExtract(ffmpegPath: String, input: URL, output: URL) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                process.arguments = [
                    "-nostdin", "-y",
                    "-i", input.path,
                    "-vn",
                    "-c:a", "aac",
                    "-b:a", "192k",
                    "-movflags", "+faststart",
                    output.path
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(returning: -1)
                }
            }
        }
    }
}
