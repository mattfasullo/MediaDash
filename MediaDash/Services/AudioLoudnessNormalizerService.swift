//
//  AudioLoudnessNormalizerService.swift
//  MediaDash
//
//  Two-pass FFmpeg loudnorm normalization to integrated LUFS targets (-14 / -24).
//

import Foundation

enum AudioLoudnessNormalizerError: LocalizedError {
    case ffmpegMissing
    case passFailed(exitCode: Int32, detail: String)
    case invalidMeasureJSON

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "FFmpeg was not found. Install with Homebrew (e.g. brew install ffmpeg)."
        case .passFailed(let code, let detail):
            return "FFmpeg failed (exit \(code)): \(detail)"
        case .invalidMeasureJSON:
            return "Could not parse loudnorm measurement JSON from FFmpeg."
        }
    }
}

/// Normalizes staged media files whose first audio stream FFmpeg can decode, writing `Stem_-14LUFS.wav` beside the source.
enum AudioLoudnessNormalizerService {

    private static let lra = "11"
    private static let truePeak = "-2"

    /// Runs normalization sequentially; callers should drive `FloatingProgressManager` around this.
    static func normalizeBatch(
        inputURLs: [URL],
        targetLUFS: Int,
        ffmpegPath: String,
        progress: ((_ index: Int, _ fileName: String, _ phase: String) async -> Void)? = nil
    ) async -> (successURLs: [URL], failures: [(url: URL, message: String)]) {
        precondition(targetLUFS == -14 || targetLUFS == -24)
        let unique = uniqFiles(inputURLs)
        var successes: [URL] = []
        var failures: [(URL, String)] = []

        for (index, url) in unique.enumerated() {
            let name = url.lastPathComponent
            await progress?(index, name, "Measuring \(name)")
            do {
                let measure = try await runMeasurementPass(
                    ffmpegPath: ffmpegPath,
                    input: url,
                    targetLUFS: targetLUFS
                )
                let outURL = makeOutputURL(beside: url, targetLUFS: targetLUFS)
                await progress?(index, name, "Normalizing \(name)")
                try await runRenderPass(
                    ffmpegPath: ffmpegPath,
                    input: url,
                    output: outURL,
                    targetLUFS: targetLUFS,
                    measure: measure
                )
                successes.append(outURL)
            } catch let e as LocalizedError {
                failures.append((url, e.localizedDescription))
            } catch {
                failures.append((url, error.localizedDescription))
            }
        }

        return (successes, failures)
    }

    private static func uniqFiles(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []
        for u in urls {
            guard !u.hasDirectoryPath else { continue }
            let path = u.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            ordered.append(u)
        }
        return ordered
    }

    private struct LoudnormMeasure {
        /// Values as printed by FFmpeg (may contain decimals as strings).
        let measuredI: String
        let measuredLRA: String
        let measuredTP: String
        let measuredThresh: String
        let offset: String
    }

    /// Pass 1: produce JSON stderr with integrated loudness analysis.
    private static func runMeasurementPass(
        ffmpegPath: String,
        input: URL,
        targetLUFS: Int
    ) async throws -> LoudnormMeasure {
        let target = Double(targetLUFS)
        let filter = "loudnorm=I=\(target):LRA=\(lra):TP=\(truePeak):print_format=json"
        let (status, stderrData) = await runProcess(
            executable: ffmpegPath,
            arguments: [
                "-hide_banner", "-nostdin", "-threads", "0",
                "-i", input.path,
                "-map", "a:0",
                "-vn",
                "-af", filter,
                "-f", "null", "-",
            ]
        )

        guard status == 0 else {
            let tail = stderrString(stderrData).suffix(900)
            throw AudioLoudnessNormalizerError.passFailed(exitCode: status, detail: String(tail))
        }

        let stderr = stderrString(stderrData)
        guard let jsonSlice = extractJSONObject(from: stderr) else {
            throw AudioLoudnessNormalizerError.invalidMeasureJSON
        }
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioLoudnessNormalizerError.invalidMeasureJSON
        }

        guard let measured = parseMeasure(dict: obj) else {
            throw AudioLoudnessNormalizerError.invalidMeasureJSON
        }
        return measured
    }

    private static func parseMeasure(dict: [String: Any]) -> LoudnormMeasure? {
        guard let i = firstString(dict, keys: ["measured_I", "input_i"]),
              let lr = firstString(dict, keys: ["measured_LRA", "input_lra"]),
              let tp = firstString(dict, keys: ["measured_TP", "input_tp"]),
              let th = firstString(dict, keys: ["measured_thresh", "input_thresh"]),
              let off = firstString(dict, keys: ["offset", "target_offset"]) else {
            return nil
        }

        return LoudnormMeasure(
            measuredI: i.trimmingCharacters(in: .whitespacesAndNewlines),
            measuredLRA: lr.trimmingCharacters(in: .whitespacesAndNewlines),
            measuredTP: tp.trimmingCharacters(in: .whitespacesAndNewlines),
            measuredThresh: th.trimmingCharacters(in: .whitespacesAndNewlines),
            offset: off.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String { return s }
            if let n = dict[k] as? NSNumber { return n.stringValue }
            if let d = dict[k] as? Double { return formatFilterNumber(d) }
            if let i = dict[k] as? Int { return "\(i)" }
        }
        return nil
    }

    private static func formatFilterNumber(_ d: Double) -> String {
        if d == floor(d), abs(d) < 1e12 { return "\(Int(d))" }
        let s = String(format: "%.4f", d)
        var t = s
        while t.contains(".") && (t.last == "0" || t.last == ".") {
            t.removeLast()
        }
        return t
    }

    /// Pass 2: linear normalization to target using measured coefficients.
    private static func runRenderPass(
        ffmpegPath: String,
        input: URL,
        output: URL,
        targetLUFS: Int,
        measure: LoudnormMeasure
    ) async throws {
        let target = Double(targetLUFS)
        let filt = """
        loudnorm=I=\(target):LRA=\(lra):TP=\(truePeak):measured_I=\(measure.measuredI):measured_LRA=\(measure.measuredLRA):measured_TP=\(measure.measuredTP):measured_thresh=\(measure.measuredThresh):offset=\(measure.offset):linear=true:print_format=summary
        """

        try? FileManager.default.removeItem(at: output)

        let (status, stderrData) = await runProcess(
            executable: ffmpegPath,
            arguments: [
                "-hide_banner", "-nostdin", "-threads", "0",
                "-i", input.path,
                "-map", "a:0",
                "-vn",
                "-af", filt,
                "-ar", "48000",
                "-c:a", "pcm_s24le",
                "-y",
                output.path,
            ]
        )

        guard status == 0 else {
            try? FileManager.default.removeItem(at: output)
            let tail = stderrString(stderrData).suffix(900)
            throw AudioLoudnessNormalizerError.passFailed(exitCode: status, detail: String(tail))
        }
    }

    static func makeOutputURL(beside source: URL, targetLUFS: Int) -> URL {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let label = "_\(targetLUFS)LUFS"
        let baseFilename = stem + label
        var candidate = dir.appendingPathComponent(baseFilename).appendingPathExtension("wav")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(baseFilename) \(n)").appendingPathExtension("wav")
            n += 1
        }
        return candidate
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let closing = text.lastIndex(of: "}") else { return nil }
        var depth = 0
        var i = closing
        while true {
            let ch = text[i]
            if ch == "}" { depth += 1 }
            if ch == "{" {
                depth -= 1
                if depth == 0 {
                    return String(text[i...closing])
                }
            }
            if i == text.startIndex { return nil }
            i = text.index(before: i)
        }
    }

    private static func stderrString(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func runProcess(executable: String, arguments: [String]) async -> (status: Int32, stderr: Data) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice

                let errPipe = Pipe()
                process.standardError = errPipe

                do {
                    try process.run()
                    let errHandle = errPipe.fileHandleForReading
                    process.waitUntilExit()
                    let outData = (try? errHandle.readToEnd()) ?? Data()
                    continuation.resume(returning: (process.terminationStatus, outData))
                } catch {
                    continuation.resume(returning: (-1, Data()))
                }
            }
        }
    }
}
