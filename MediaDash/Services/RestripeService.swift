//
//  RestripeService.swift
//  MediaDash
//
//  Service that combines one picture/video with multiple audio files using FFmpeg.
//

import Foundation

/// Error thrown when FFmpeg is not available or restripe fails.
enum RestripeError: LocalizedError {
    case ffmpegNotFound
    case ffmpegFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg was not found. Install it with: brew install ffmpeg"
        case .ffmpegFailed(let message):
            return "FFmpeg failed: \(message)"
        }
    }
}

/// Service that combines one picture/video with multiple audio files using FFmpeg.
enum RestripeService {

    /// Resolves the FFmpeg executable path.
    static func resolveFFmpegPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return runWhichFFmpeg()
    }

    private static func runWhichFFmpeg() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let data = try pipe.fileHandleForReading.readToEnd(),
               let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}
        return nil
    }

    /// Restripes one picture/video with each audio file. Output duration = shorter of picture or audio per pair.
    /// - Parameters:
    ///   - picture: Video or picture file
    ///   - items: Audio files with their chosen output basenames (extension added automatically)
    ///   - outputFolder: Output directory
    ///   - outputFormat: mp4 or mov
    ///   - audioGainDB: Gain in decibels (0 = no change, -12 to +12 typical)
    ///   - onProgress: Optional callback(current, total, filename)
    /// - Returns: URLs of created output files
    static func restripe(
        picture: URL,
        items: [(audio: URL, outputBasename: String)],
        outputFolder: URL,
        outputFormat: RestripeConfig.OutputFormat,
        audioGainDB: Double = 0,
        onProgress: (@Sendable (Int, Int, String) async -> Void)? = nil
    ) async throws -> [URL] {
        guard let ffmpegPath = resolveFFmpegPath() else {
            throw RestripeError.ffmpegNotFound
        }

        var outputs: [URL] = []
        let total = items.count

        for (index, item) in items.enumerated() {
            let base = item.outputBasename.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeBase = base.isEmpty ? item.audio.deletingPathExtension().lastPathComponent + "_pic" : base
            let outputFilename = "\(safeBase).\(outputFormat.fileExtension)"
            let outputURL = outputFolder.appendingPathComponent(outputFilename)

            await onProgress?(index + 1, total, outputFilename)

            var args: [String] = [
                "-i", picture.path,
                "-i", item.audio.path,
                "-shortest",
                "-map", "0:v",
                "-map", "1:a",
                "-c:v", "copy",
            ]
            if abs(audioGainDB) > 0.01 {
                args.append(contentsOf: ["-filter:a", "volume=\(audioGainDB)dB", "-c:a", "aac"])
            } else {
                args.append(contentsOf: ["-c:a", "aac"])
            }
            args.append(contentsOf: ["-movflags", "+faststart", "-y", outputURL.path])

            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = args
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw RestripeError.ffmpegFailed(underlying: error.localizedDescription)
            }

            if process.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
                throw RestripeError.ffmpegFailed(underlying: errStr)
            }

            outputs.append(outputURL)
        }

        return outputs
    }
}
