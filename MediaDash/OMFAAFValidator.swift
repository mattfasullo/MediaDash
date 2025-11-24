import Foundation
import SwiftUI
import AppKit
import Combine
import AVFoundation

// MARK: - Validation Result Models

// JSON decoding structs
struct ValidationResponse: Codable {
    let totalClips: Int
    let embeddedClips: Int
    let linkedClips: Int
    let missingClips: Int
    let validClips: Int
    let filePath: String
    let totalDuration: Double
    let missingClipDetails: [MediaClipResultCodable]
    let timelineClips: [MediaClipResultCodable]
    
    enum CodingKeys: String, CodingKey {
        case totalClips = "total_clips"
        case embeddedClips = "embedded_clips"
        case linkedClips = "linked_clips"
        case missingClips = "missing_clips"
        case validClips = "valid_clips"
        case filePath = "file_path"
        case totalDuration = "total_duration"
        case missingClipDetails = "missing_clip_details"
        case timelineClips = "timeline_clips"
    }
}

struct MediaClipResultCodable: Codable {
    let name: String
    let clipId: String?
    let isEmbedded: Bool
    let externalPath: String?
    let isValid: Bool
    let errorMessage: String?
    let trackIndex: Int
    let timelineStart: Double
    let timelineEnd: Double
    let nameMatchesFile: Bool?
    let expectedFilename: String?
    
    enum CodingKeys: String, CodingKey {
        case name
        case clipId = "clip_id"
        case isEmbedded = "is_embedded"
        case externalPath = "external_path"
        case isValid = "is_valid"
        case errorMessage = "error_message"
        case trackIndex = "track_index"
        case timelineStart = "timeline_start"
        case timelineEnd = "timeline_end"
        case nameMatchesFile = "name_matches_file"
        case expectedFilename = "expected_filename"
    }
    
    func toMediaClipResult() -> MediaClipResult {
        return MediaClipResult(
            name: name,
            clipId: clipId,
            isEmbedded: isEmbedded,
            externalPath: externalPath,
            isValid: isValid,
            errorMessage: errorMessage,
            trackIndex: trackIndex,
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            nameMatchesFile: nameMatchesFile,
            expectedFilename: expectedFilename
        )
    }
}

extension MediaClipResultCodable {
    func toTimelineClip() -> TimelineClip {
        return TimelineClip(from: toMediaClipResult())
    }
}

struct MediaClipResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let clipId: String?
    let isEmbedded: Bool
    let externalPath: String?
    let isValid: Bool
    let errorMessage: String?
    // Timeline information
    let trackIndex: Int
    let timelineStart: Double
    let timelineEnd: Double
    // Name matching validation
    let nameMatchesFile: Bool?
    let expectedFilename: String?
    
    init(name: String, clipId: String? = nil, isEmbedded: Bool = false, externalPath: String? = nil,
         isValid: Bool = true, errorMessage: String? = nil, trackIndex: Int = 0,
         timelineStart: Double = 0.0, timelineEnd: Double = 0.0,
         nameMatchesFile: Bool? = nil, expectedFilename: String? = nil) {
        self.name = name
        self.clipId = clipId
        self.isEmbedded = isEmbedded
        self.externalPath = externalPath
        self.isValid = isValid
        self.errorMessage = errorMessage
        self.trackIndex = trackIndex
        self.timelineStart = timelineStart
        self.timelineEnd = timelineEnd
        self.nameMatchesFile = nameMatchesFile
        self.expectedFilename = expectedFilename
    }
}

struct TimelineClip: Identifiable {
    let id: UUID
    let name: String
    let trackIndex: Int
    let startTime: Double
    let endTime: Double
    let nameMatches: Bool  // true = green, false = red
    let expectedFilename: String?
    
    init(from clip: MediaClipResult) {
        self.id = clip.id
        self.name = clip.name
        self.trackIndex = clip.trackIndex
        self.startTime = clip.timelineStart
        self.endTime = clip.timelineEnd
        // If nameMatchesFile is nil (embedded), default to true (green)
        self.nameMatches = clip.nameMatchesFile ?? true
        self.expectedFilename = clip.expectedFilename
    }
}

struct ValidationReportResult: Identifiable, Equatable {
    let id = UUID()
    let filePath: String
    let totalClips: Int
    let embeddedClips: Int
    let linkedClips: Int
    let missingClips: Int
    let validClips: Int
    let missingClipDetails: [MediaClipResult]
    // Timeline information
    let timelineClips: [TimelineClip]
    let totalDuration: Double
    
    var hasIssues: Bool {
        missingClips > 0
    }
    
    var hasNameMismatches: Bool {
        timelineClips.contains { !$0.nameMatches }
    }
    
    init(filePath: String, totalClips: Int, embeddedClips: Int, linkedClips: Int,
         missingClips: Int, validClips: Int, missingClipDetails: [MediaClipResult],
         timelineClips: [TimelineClip] = [], totalDuration: Double = 0.0) {
        self.filePath = filePath
        self.totalClips = totalClips
        self.embeddedClips = embeddedClips
        self.linkedClips = linkedClips
        self.missingClips = missingClips
        self.validClips = validClips
        self.missingClipDetails = missingClipDetails
        self.timelineClips = timelineClips
        self.totalDuration = totalDuration
    }
    
    static func == (lhs: ValidationReportResult, rhs: ValidationReportResult) -> Bool {
        // Compare by file path and key metrics for equality
        return lhs.filePath == rhs.filePath &&
               lhs.totalClips == rhs.totalClips &&
               lhs.missingClips == rhs.missingClips &&
               lhs.validClips == rhs.validClips
    }
}

// MARK: - Playback Models
// ARCHIVED: Playback verification feature - disabled due to aaf2 library limitations
// TODO: Revisit when we have a solution for extracting embedded essence data
// Date archived: 2024-12-19
#if false
struct PlaybackClip: Identifiable, Codable {
    let id: UUID
    let name: String
    let filePath: String
    let startTime: Double
    let duration: Double
    let trackIndex: Int
    let timelineStart: Double
    let timelineEnd: Double
    let sourceIn: Double
    let sourceOut: Double
    
    enum CodingKeys: String, CodingKey {
        case name
        case filePath = "file_path"
        case startTime = "start_time"
        case duration
        case trackIndex = "track_index"
        case timelineStart = "timeline_start"
        case timelineEnd = "timeline_end"
        case sourceIn = "source_in"
        case sourceOut = "source_out"
    }
    
    init(name: String, filePath: String, startTime: Double, duration: Double, 
         trackIndex: Int = 0, timelineStart: Double = 0.0, timelineEnd: Double = 0.0,
         sourceIn: Double = 0.0, sourceOut: Double = 0.0) {
        self.id = UUID()
        self.name = name
        self.filePath = filePath
        self.startTime = startTime
        self.duration = duration
        self.trackIndex = trackIndex
        self.timelineStart = timelineStart
        self.timelineEnd = timelineEnd
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.filePath = try container.decode(String.self, forKey: .filePath)
        self.startTime = try container.decodeIfPresent(Double.self, forKey: .startTime) ?? 0.0
        self.duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0.0
        self.trackIndex = try container.decodeIfPresent(Int.self, forKey: .trackIndex) ?? 0
        self.timelineStart = try container.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0.0
        self.timelineEnd = try container.decodeIfPresent(Double.self, forKey: .timelineEnd) ?? 0.0
        self.sourceIn = try container.decodeIfPresent(Double.self, forKey: .sourceIn) ?? 0.0
        self.sourceOut = try container.decodeIfPresent(Double.self, forKey: .sourceOut) ?? 0.0
    }
}
#endif

// MARK: - Playback Manager
#if false
class OMFPlaybackManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentClipIndex: Int?
    @Published var currentClipName: String?
    @Published var playbackError: String?
    @Published var playbackClips: [PlaybackClip] = []
    @Published var failedClips: [String] = []  // Clip names that failed to load
    @Published var isPaused = false
    
    private var audioPlayer: AVAudioPlayer?
    private var currentIndex: Int = 0
    private var currentTempFile: URL?  // Track temp file for cleanup
    
    func loadPlaybackClips(_ clips: [PlaybackClip]) {
        playbackClips = clips
        currentIndex = 0
        failedClips = []
        stop()
    }
    
    func play() {
        guard !playbackClips.isEmpty else {
            playbackError = "No clips available for playback"
            return
        }
        
        if isPaused && audioPlayer != nil {
            // Resume playback
            audioPlayer?.play()
            isPlaying = true
            isPaused = false
            return
        }
        
        // Start playing from current index
        playNextClip()
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        isPaused = true
    }
    
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        
        // Clean up temp file if exists
        if let tempFile = currentTempFile {
            try? FileManager.default.removeItem(at: tempFile)
            currentTempFile = nil
        }
        
        isPlaying = false
        isPaused = false
        currentIndex = 0
        currentClipIndex = nil
        currentClipName = nil
        playbackError = nil
    }
    
    private func playNextClip() {
        guard currentIndex < playbackClips.count else {
            // Finished playing all clips
            stop()
            return
        }
        
        let clip = playbackClips[currentIndex]
        currentClipIndex = currentIndex
        currentClipName = clip.name
        
        // Check if this is embedded audio
        if clip.filePath.hasPrefix("EMBEDDED:") {
            // Extract embedded audio from AAF/OMF file
            extractAndPlayEmbeddedAudio(clip: clip)
            return
        }
        
        // Regular file path
        let fileURL = URL(fileURLWithPath: clip.filePath)
        
        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            playbackError = "File not found: \(clip.filePath)"
            failedClips.append(clip.name)
            currentIndex += 1
            // Continue to next clip
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.playNextClip()
            }
            return
        }
        
        do {
            // Create audio player
            audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            // Handle start time offset if specified
            if clip.startTime > 0.0 {
                audioPlayer?.currentTime = clip.startTime
            }
            
            // Handle duration limit if specified
            if clip.duration > 0.0 {
                // We'll stop manually after duration
                audioPlayer?.play()
                isPlaying = true
                isPaused = false
                playbackError = nil
                
                // Schedule stop after duration
                DispatchQueue.main.asyncAfter(deadline: .now() + clip.duration) {
                    if self.isPlaying && self.currentIndex == self.currentClipIndex {
                        self.audioPlayer?.stop()
                        self.audioPlayerDidFinishPlaying(self.audioPlayer!, successfully: true)
                    }
                }
            } else {
                // Play entire file
                audioPlayer?.play()
                isPlaying = true
                isPaused = false
                playbackError = nil
            }
        } catch {
            playbackError = "Failed to load \(clip.name): \(error.localizedDescription)"
            failedClips.append(clip.name)
            currentIndex += 1
            // Continue to next clip
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.playNextClip()
            }
        }
    }
    
    private func extractAndPlayEmbeddedAudio(clip: PlaybackClip) {
        // Parse embedded path: "EMBEDDED:/path/to/file.aaf:mob_id"
        let embeddedPath = clip.filePath
        guard embeddedPath.hasPrefix("EMBEDDED:") else {
            playbackError = "Invalid embedded path format: \(embeddedPath)"
            currentIndex += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.playNextClip()
            }
            return
        }
        
        let pathComponents = embeddedPath.dropFirst("EMBEDDED:".count).split(separator: ":", maxSplits: 1)
        guard pathComponents.count == 2 else {
            playbackError = "Invalid embedded path format: \(embeddedPath)"
            currentIndex += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.playNextClip()
            }
            return
        }
        
        let aafFilePath = String(pathComponents[0])
        let mobId = String(pathComponents[1])
        
        // Create temporary file for extracted audio
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("\(UUID().uuidString).wav")
        
        // Extract audio using Python script
        Task {
            do {
                let extractedPath = try await extractEmbeddedAudioFromAAF(
                    aafFilePath: aafFilePath,
                    mobId: mobId,
                    outputPath: tempFile.path,
                    startTime: clip.startTime,
                    duration: clip.duration > 0 ? clip.duration : nil
                )
                
                await MainActor.run {
                    // Play the extracted audio file
                    let fileURL = URL(fileURLWithPath: extractedPath)
                    self.currentTempFile = fileURL  // Track for cleanup
                    
                    do {
                        self.audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
                        self.audioPlayer?.delegate = self
                        self.audioPlayer?.prepareToPlay()
                        self.audioPlayer?.play()
                        self.isPlaying = true
                        self.isPaused = false
                        self.playbackError = nil
                    } catch {
                        self.playbackError = "Failed to play extracted audio for \(clip.name): \(error.localizedDescription)"
                        self.failedClips.append(clip.name)
                        // Clean up temp file
                        try? FileManager.default.removeItem(at: fileURL)
                        self.currentTempFile = nil
                        self.currentIndex += 1
                        if self.currentIndex < self.playbackClips.count {
                            self.playNextClip()
                        } else {
                            self.stop()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.playbackError = "Failed to extract audio for \(clip.name): \(error.localizedDescription)"
                    self.failedClips.append(clip.name)
                    // Clean up temp file if it exists
                    try? FileManager.default.removeItem(at: tempFile)
                    self.currentIndex += 1
                    if self.currentIndex < self.playbackClips.count {
                        self.playNextClip()
                    } else {
                        self.stop()
                    }
                }
            }
        }
    }
    
    private func extractEmbeddedAudioFromAAF(aafFilePath: String, mobId: String, outputPath: String, startTime: Double, duration: Double?) async throws -> String {
        // Find Python script and Python executable (same logic as validator)
        let pythonScriptPath = findPythonScriptPath()
        let python3 = findPython3() ?? "/usr/bin/python3"
        
        guard FileManager.default.fileExists(atPath: pythonScriptPath.path) else {
            throw NSError(domain: "OMFPlaybackManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Python script not found at \(pythonScriptPath.path)"])
        }
        
        // Build command arguments
        var args = [pythonScriptPath.path, aafFilePath, "--extract-audio", mobId, outputPath]
        if startTime > 0.0 {
            args.append(String(startTime))
            if let duration = duration, duration > 0.0 {
                args.append(String(duration))
            }
        } else if let duration = duration, duration > 0.0 {
            args.append("0.0")
            args.append(String(duration))
        }
        
        // Run Python script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python3)
        process.arguments = args
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        // Check exit code
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OMFPlaybackManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Audio extraction failed: \(errorString)"])
        }
        
        // Read output (should be the output path)
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !outputString.isEmpty {
            // Verify file exists
            if FileManager.default.fileExists(atPath: outputString) {
                return outputString
            }
        }
        
        // Fallback: check if output path exists
        if FileManager.default.fileExists(atPath: outputPath) {
            return outputPath
        }
        
        throw NSError(domain: "OMFPlaybackManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Extracted audio file not found"])
    }
    
    private func findPythonScriptPath() -> URL {
        // Same logic as OMFAAFValidatorManager
        var foundPath: URL?
        
        if let executablePath = Bundle.main.executablePath {
            let executableURL = URL(fileURLWithPath: executablePath)
            let scriptPath = executableURL.deletingLastPathComponent().appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        if foundPath == nil, let resourcePath = Bundle.main.resourcePath {
            let scriptPath = URL(fileURLWithPath: resourcePath).appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        if foundPath == nil {
            let cwd = FileManager.default.currentDirectoryPath
            let scriptPath = URL(fileURLWithPath: cwd).appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        if foundPath == nil {
            let workspacePath = URL(fileURLWithPath: "/Users/mattfasullo/Documents/MediaDash/media_validator.py")
            if FileManager.default.fileExists(atPath: workspacePath.path) {
                foundPath = workspacePath
            }
        }
        
        return foundPath ?? URL(fileURLWithPath: "/Users/mattfasullo/Documents/MediaDash/media_validator.py")
    }
    
    private func findPython3() -> String? {
        let possiblePaths = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Clean up temp file from previous clip
        if let tempFile = currentTempFile {
            try? FileManager.default.removeItem(at: tempFile)
            currentTempFile = nil
        }
        
        if flag {
            // Move to next clip
            currentIndex += 1
            if currentIndex < playbackClips.count {
                playNextClip()
            } else {
                // Finished all clips
                stop()
            }
        } else {
            // Playback failed
            if currentIndex < playbackClips.count {
                let clip = playbackClips[currentIndex]
                playbackError = "Playback failed for \(clip.name)"
                failedClips.append(clip.name)
                currentIndex += 1
                if currentIndex < playbackClips.count {
                    playNextClip()
                } else {
                    stop()
                }
            }
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if currentIndex < playbackClips.count {
            let clip = playbackClips[currentIndex]
            playbackError = "Decode error for \(clip.name): \(error?.localizedDescription ?? "Unknown error")"
            failedClips.append(clip.name)
            currentIndex += 1
            if currentIndex < playbackClips.count {
                playNextClip()
            } else {
                stop()
            }
        }
    }
}
#endif

// MARK: - Validator Manager

class OMFAAFValidatorManager: ObservableObject {
    @Published var currentReport: ValidationReportResult?
    @Published var isValidating = false
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var debugOutput: String = ""
    @Published var showDebugOutput = false
    
    private let pythonScriptPath: URL
    
    init() {
        // Find the media_validator.py script
        // Try multiple locations:
        // 1. Same directory as the app (for development)
        // 2. In the app bundle's Resources (for distribution)
        // 3. Current working directory
        
        var foundPath: URL?
        
        // Try 1: Same directory as executable (development)
        if let executablePath = Bundle.main.executablePath {
            let executableURL = URL(fileURLWithPath: executablePath)
            let scriptPath = executableURL.deletingLastPathComponent().appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        // Try 2: App bundle Resources
        if foundPath == nil, let resourcePath = Bundle.main.resourcePath {
            let scriptPath = URL(fileURLWithPath: resourcePath).appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        // Try 3: Current working directory (development)
        if foundPath == nil {
            let cwd = FileManager.default.currentDirectoryPath
            let scriptPath = URL(fileURLWithPath: cwd).appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        // Try 4: Parent of current directory (workspace root)
        if foundPath == nil {
            let cwd = FileManager.default.currentDirectoryPath
            let scriptPath = URL(fileURLWithPath: cwd)
                .deletingLastPathComponent()
                .appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        // Try 5: Explicit workspace path (for development)
        if foundPath == nil {
            let workspacePath = URL(fileURLWithPath: "/Users/mattfasullo/Documents/MediaDash/media_validator.py")
            if FileManager.default.fileExists(atPath: workspacePath.path) {
                foundPath = workspacePath
            }
        }
        
        // Fallback: Use workspace path even if file doesn't exist (will show error with correct path)
        self.pythonScriptPath = foundPath ?? URL(fileURLWithPath: "/Users/mattfasullo/Documents/MediaDash/media_validator.py")
    }
    
    func validateFile(_ fileURL: URL) async {
        await MainActor.run {
            isValidating = true
            errorMessage = nil
            currentReport = nil
        }
        
        do {
            let report = try await runValidation(fileURL: fileURL)
            await MainActor.run {
                currentReport = report
                isValidating = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
                isValidating = false
            }
        }
    }
    
    private func runValidation(fileURL: URL) async throws -> ValidationReportResult {
        // Check if Python script exists
        guard FileManager.default.fileExists(atPath: pythonScriptPath.path) else {
            throw ValidationError.scriptNotFound(pythonScriptPath.path)
        }
        
        // Check if Python 3 is available
        let python3Path = findPython3()
        guard let python3 = python3Path else {
            throw ValidationError.pythonNotFound
        }
        
        // Run the Python script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python3)
        process.arguments = [pythonScriptPath.path, fileURL.path]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        // Read output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        // Debug output goes to stderr, capture it
        if let debugText = String(data: errorData, encoding: .utf8), !debugText.isEmpty {
            // Filter out only DEBUG lines (ignore system warnings)
            let allLines = debugText.components(separatedBy: .newlines)
            let debugLines = allLines.filter { $0.contains("DEBUG:") }
            
            // Also capture any Python errors or important messages
            let importantLines = allLines.filter { line in
                line.contains("DEBUG:") || 
                line.contains("Error:") || 
                line.contains("Traceback") ||
                line.contains("Exception") ||
                (line.contains("python") && line.contains("error"))
            }
            
            let linesToShow = !debugLines.isEmpty ? debugLines : importantLines
            
            if !linesToShow.isEmpty {
                // Deduplicate consecutive lines
                var deduplicatedLines: [String] = []
                var lastLine: String? = nil
                var repeatCount = 0
                
                for line in linesToShow {
                    if line == lastLine {
                        repeatCount += 1
                    } else {
                        // Output previous line with count if it was repeated
                        if let last = lastLine {
                            if repeatCount > 0 {
                                deduplicatedLines.append("\(last) (x\(repeatCount + 1))")
                            } else {
                                deduplicatedLines.append(last)
                            }
                        }
                        lastLine = line
                        repeatCount = 0
                    }
                }
                
                // Don't forget the last line
                if let last = lastLine {
                    if repeatCount > 0 {
                        deduplicatedLines.append("\(last) (x\(repeatCount + 1))")
                    } else {
                        deduplicatedLines.append(last)
                    }
                }
                
                let fullDebug = deduplicatedLines.joined(separator: "\n")
                await MainActor.run {
                    self.debugOutput = fullDebug
                    self.showDebugOutput = true  // Always show if there's any output
                }
                print("=== AAF Parser Debug Output ===")
                for line in deduplicatedLines {
                    print(line)
                }
                print("=== End Debug Output ===")
            } else if !debugText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // If there's stderr output but no DEBUG lines, show it anyway (might be useful)
                await MainActor.run {
                    self.debugOutput = "Stderr output (no DEBUG lines found):\n" + debugText
                    self.showDebugOutput = true
                }
            }
        }
        
        guard let output = String(data: outputData, encoding: .utf8) else {
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ValidationError.parseError(errorOutput)
        }
        
        // Parse the output
        return try parseValidationOutput(output, filePath: fileURL.path)
    }
    
    private func findPython3() -> String? {
        // Try common Python 3 paths, including framework paths
        let possiblePaths = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/opt/python@3.12/bin/python3",
            "/usr/local/opt/python@3.11/bin/python3",
            "/usr/bin/python3",
        ]
        
        // First, try to find a Python that has pyaaf2 installed
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                // Verify it has pyaaf2
                if pythonHasPyaaf2(path: path) {
                    return path
                }
            }
        }
        
        // If none found with pyaaf2, try using 'which python3' and verify it
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["python3"]
        
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                // Verify it has pyaaf2
                if pythonHasPyaaf2(path: path) {
                    return path
                }
            }
        } catch {
            // Ignore
        }
        
        // Fallback: return first available Python (user will get error if pyaaf2 missing)
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    private func pythonHasPyaaf2(path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", "import aaf2; print('OK')"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8),
                   output.contains("OK") {
                    return true
                }
            }
        } catch {
            // Ignore
        }
        
        return false
    }
    
    private func parseValidationOutput(_ output: String, filePath: String) throws -> ValidationReportResult {
        // Parse JSON output from Python script
        guard let jsonData = output.data(using: .utf8) else {
            throw ValidationError.parseError("Failed to convert output to data")
        }
        
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(ValidationResponse.self, from: jsonData)
            
            // Convert timeline clips and missing clip details
            let timelineClips = response.timelineClips.map { $0.toTimelineClip() }
            let missingClipDetails = response.missingClipDetails.map { $0.toMediaClipResult() }
            
            return ValidationReportResult(
                filePath: response.filePath,
                totalClips: response.totalClips,
                embeddedClips: response.embeddedClips,
                linkedClips: response.linkedClips,
                missingClips: response.missingClips,
                validClips: response.validClips,
                missingClipDetails: missingClipDetails,
                timelineClips: timelineClips,
                totalDuration: response.totalDuration
            )
        } catch {
            // Fallback to text parsing for backwards compatibility
            return try parseTextReport(output, filePath: filePath)
        }
    }
    
    private func parseTextReport(_ output: String, filePath: String) throws -> ValidationReportResult {
        // Parse the formatted report output (fallback)
        
        var totalClips = 0
        var embeddedClips = 0
        var linkedClips = 0
        var missingClips = 0
        var validClips = 0
        var missingClipDetails: [MediaClipResult] = []
        
        // Extract summary numbers
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("Total Audio Clips:") {
                if let value = extractNumber(from: line) {
                    totalClips = value
                }
            } else if line.contains("Embedded Clips:") {
                if let value = extractNumber(from: line) {
                    embeddedClips = value
                }
            } else if line.contains("Linked Clips:") {
                if let value = extractNumber(from: line) {
                    linkedClips = value
                }
            } else if line.contains("Valid Clips:") {
                if let value = extractNumber(from: line) {
                    validClips = value
                }
            } else if line.contains("Missing/Invalid Clips:") {
                if let value = extractNumber(from: line) {
                    missingClips = value
                }
            }
        }
        
        // Parse missing clip details
        var inMissingSection = false
        var currentClip: (name: String?, id: String?, type: String?, path: String?, error: String?) = (nil, nil, nil, nil, nil)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.contains("Missing/Invalid Clips Details:") {
                inMissingSection = true
                continue
            }
            
            if inMissingSection {
                if trimmed.hasPrefix("Clip:") {
                    // Save previous clip if exists
                    if let name = currentClip.name {
                        missingClipDetails.append(MediaClipResult(
                            name: name,
                            clipId: currentClip.id,
                            isEmbedded: currentClip.type == "Embedded",
                            externalPath: currentClip.path,
                            isValid: false,
                            errorMessage: currentClip.error
                        ))
                    }
                    // Start new clip
                    currentClip.name = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    currentClip.id = nil
                    currentClip.type = nil
                    currentClip.path = nil
                    currentClip.error = nil
                } else if trimmed.hasPrefix("ID:") {
                    currentClip.id = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Type:") {
                    currentClip.type = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Expected Path:") {
                    currentClip.path = String(trimmed.dropFirst(14)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("Error:") {
                    currentClip.error = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if trimmed.isEmpty && currentClip.name != nil {
                    // Empty line might indicate end of clip, but continue parsing
                }
            }
        }
        
        // Add last clip
        if let name = currentClip.name {
            missingClipDetails.append(MediaClipResult(
                name: name,
                clipId: currentClip.id,
                isEmbedded: currentClip.type == "Embedded",
                externalPath: currentClip.path,
                isValid: false,
                errorMessage: currentClip.error
            ))
        }
        
        return ValidationReportResult(
            filePath: filePath,
            totalClips: totalClips,
            embeddedClips: embeddedClips,
            linkedClips: linkedClips,
            missingClips: missingClips,
            validClips: validClips,
            missingClipDetails: missingClipDetails,
            timelineClips: [],
            totalDuration: 0.0
        )
    }
    
    private func extractNumber(from line: String) -> Int? {
        let components = line.components(separatedBy: ":")
        if components.count > 1 {
            return Int(components[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
    
    func clearReport() {
        currentReport = nil
        errorMessage = nil
    }
    
    // ARCHIVED: Playback extraction - disabled due to aaf2 library limitations
    #if false
    func extractPlaybackClips(fileURL: URL) async throws -> [PlaybackClip] {
        // Check if Python script exists
        guard FileManager.default.fileExists(atPath: pythonScriptPath.path) else {
            throw ValidationError.scriptNotFound(pythonScriptPath.path)
        }
        
        // Check if Python 3 is available
        let python3Path = findPython3()
        guard let python3 = python3Path else {
            throw ValidationError.pythonNotFound
        }
        
        // Run the Python script with --playback flag
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python3)
        process.arguments = [pythonScriptPath.path, fileURL.path, "--playback"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up real-time stderr reading with thread-safe storage
        let debugLinesQueue = DispatchQueue(label: "com.mediadash.debuglines")
        var debugLines: [String] = []
        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines)
                for line in lines {
                    if !line.isEmpty {
                        if line.contains("DEBUG:") {
                            debugLinesQueue.sync {
                                debugLines.append(line)
                            }
                            print("DEBUG: [Python] \(line)")
                        } else if line.contains("Error:") || line.contains("Traceback") || line.contains("Exception") {
                            debugLinesQueue.sync {
                                debugLines.append(line)
                            }
                            print("ERROR: [Python] \(line)")
                        }
                        // Update debug output in real-time
                        Task { @MainActor in
                            let allLines = debugLinesQueue.sync { debugLines }
                            self.debugOutput = allLines.joined(separator: "\n")
                            self.showDebugOutput = true
                        }
                    }
                }
            }
        }
        
        print("DEBUG: Starting Python process: \(python3) \(process.arguments?.joined(separator: " ") ?? "")")
        try process.run()
        print("DEBUG: Python process started, PID: \(process.processIdentifier)")
        
        // Wait with timeout (60 seconds should be enough with simplified extraction)
        let timeout: TimeInterval = 60.0
        let startTime = Date()
        
        while process.isRunning {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > timeout {
                print("DEBUG: Python process timed out after \(elapsed) seconds, terminating...")
                process.terminate()
                // Give it a moment to terminate
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                if process.isRunning {
                    print("DEBUG: Process still running, force terminating...")
                    // Force terminate by sending SIGKILL via shell
                    let killProcess = Process()
                    killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/kill")
                    killProcess.arguments = ["-9", "\(process.processIdentifier)"]
                    try? killProcess.run()
                    killProcess.waitUntilExit()
                }
                throw ValidationError.parseError("Python script timed out after \(Int(timeout)) seconds")
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
        
        print("DEBUG: Python process finished, exit code: \(process.terminationStatus)")
        
        // Stop reading from stderr
        errorHandle.readabilityHandler = nil
        
        // Collect final debug lines
        let finalDebugLines = debugLinesQueue.sync { debugLines }
        
        // Read remaining output
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        // Capture debug output from stderr
        // Combine real-time captured lines with any remaining stderr output
        var allDebugLines = finalDebugLines
        var debugText = ""
        if let errorText = String(data: errorData, encoding: .utf8), !errorText.isEmpty {
            debugText = errorText
            // Filter out only DEBUG lines (ignore system warnings)
            let stderrLines = errorText.components(separatedBy: .newlines)
            let additionalDebugLines = stderrLines.filter { $0.contains("DEBUG:") }
            allDebugLines.append(contentsOf: additionalDebugLines)
        }
        
        if !allDebugLines.isEmpty {
            // Filter out only DEBUG lines (ignore system warnings)
            let debugLines = allDebugLines.filter { $0.contains("DEBUG:") }
            
            // Also capture any Python errors or important messages
            let allLines = debugText.isEmpty ? [] : debugText.components(separatedBy: .newlines)
            let importantLines = allLines.filter { line in
                line.contains("DEBUG:") || 
                line.contains("Error:") || 
                line.contains("Traceback") ||
                line.contains("Exception") ||
                (line.contains("python") && line.contains("error"))
            }
            
            let linesToShow = !debugLines.isEmpty ? debugLines : importantLines
            
            if !linesToShow.isEmpty {
                // Deduplicate consecutive lines
                var deduplicatedLines: [String] = []
                var lastLine: String? = nil
                var repeatCount = 0
                
                for line in linesToShow {
                    if line == lastLine {
                        repeatCount += 1
                    } else {
                        // Output previous line with count if it was repeated
                        if let last = lastLine {
                            if repeatCount > 0 {
                                deduplicatedLines.append("\(last) (x\(repeatCount + 1))")
                            } else {
                                deduplicatedLines.append(last)
                            }
                        }
                        lastLine = line
                        repeatCount = 0
                    }
                }
                
                // Don't forget the last line
                if let last = lastLine {
                    if repeatCount > 0 {
                        deduplicatedLines.append("\(last) (x\(repeatCount + 1))")
                    } else {
                        deduplicatedLines.append(last)
                    }
                }
                
                let fullDebug = deduplicatedLines.joined(separator: "\n")
                await MainActor.run {
                    self.debugOutput = fullDebug
                    self.showDebugOutput = true  // Always show if there's any output
                }
                print("=== AAF Playback Extraction Debug Output ===")
                for line in deduplicatedLines {
                    print(line)
                }
                print("=== End Debug Output ===")
            } else if !debugText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // If there's stderr output but no DEBUG lines, show it anyway (might be useful)
                await MainActor.run {
                    self.debugOutput = "Stderr output (no DEBUG lines found):\n" + debugText
                    self.showDebugOutput = true
                }
            }
        }
        
        // Check process exit code
        if process.terminationStatus != 0 {
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            let stdout = String(data: outputData, encoding: .utf8) ?? ""
            throw ValidationError.parseError("Python script exited with code \(process.terminationStatus)\nError: \(errorOutput)\nOutput: \(stdout)")
        }
        
        guard let output = String(data: outputData, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw ValidationError.parseError("No output from Python script\nError: \(errorOutput)")
        }
        
        // Parse JSON output
        guard let jsonData = output.data(using: .utf8) else {
            throw ValidationError.parseError("Failed to convert output to data\nOutput: \(output)")
        }
        
        struct PlaybackResponse: Codable {
            let clips: [PlaybackClip]
        }
        
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(PlaybackResponse.self, from: jsonData)
            return response.clips
        } catch {
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            throw ValidationError.parseError("Failed to parse JSON: \(error.localizedDescription)\nOutput: \(output)\nError output: \(errorOutput)")
        }
    }
    #endif
}

enum ValidationError: LocalizedError {
    case scriptNotFound(String)
    case pythonNotFound
    case parseError(String)
    case validationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path):
            return "Python validation script not found at: \(path)"
        case .pythonNotFound:
            return "Python 3 not found. Please install Python 3 to use the OMF/AAF validator."
        case .parseError(let message):
            return "Failed to parse validation output: \(message)"
        case .validationFailed(let message):
            return "Validation failed: \(message)"
        }
    }
}

// MARK: - Validator View

struct OMFAAFValidatorView: View {
    @ObservedObject var validator: OMFAAFValidatorManager
    let fileURL: URL
    @Environment(\.dismiss) var dismiss
    // ARCHIVED: Playback manager - disabled due to aaf2 library limitations
    #if false
    @StateObject private var playbackManager = OMFPlaybackManager()
    @State private var isLoadingPlaybackClips = false
    #endif
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OMF/AAF Media Validator")
                        .font(.system(size: 18, weight: .semibold))
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Content
            if validator.isValidating {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Validating media references...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if let report = validator.currentReport {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Summary
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Summary")
                                .font(.system(size: 16, weight: .semibold))
                            
                            HStack(spacing: 20) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Total Clips")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("\(report.totalClips)")
                                        .font(.system(size: 20, weight: .semibold))
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Valid")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("\(report.validClips)")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(.green)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Missing")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("\(report.missingClips)")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundColor(report.missingClips > 0 ? .red : .green)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Embedded")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("\(report.embeddedClips)")
                                        .font(.system(size: 20, weight: .semibold))
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Linked")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("\(report.linkedClips)")
                                        .font(.system(size: 20, weight: .semibold))
                                }
                            }
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .cornerRadius(8)
                        
                        // Status message
                        if report.hasIssues {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("\(report.missingClips) audio clip\(report.missingClips == 1 ? "" : "s") have missing or unlinked media")
                                    .font(.system(size: 13))
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        } else {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("All audio clips are valid and accessible")
                                    .font(.system(size: 13))
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                        }
                        
                        // Timeline Visualization
                        if !report.timelineClips.isEmpty && report.totalDuration > 0 {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Timeline View")
                                        .font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                    if report.hasNameMismatches {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(Color.red)
                                                .frame(width: 8, height: 8)
                                            Text("Name Mismatch")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                
                                Text("Green = Name matches file | Red = Name mismatch")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                
                                TimelineView(clips: report.timelineClips, totalDuration: report.totalDuration)
                                    .frame(height: min(400, CGFloat(report.timelineClips.map { $0.trackIndex }.max() ?? 0) * 55 + 50))
                                    .border(Color.gray.opacity(0.3), width: 1)
                                    .cornerRadius(4)
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                        }
                        
                        // ARCHIVED: Playback Controls - disabled due to aaf2 library limitations
                        // TODO: Revisit when we have a solution for extracting embedded essence data
                        #if false
                        // Playback Controls
                        if report.validClips > 0 {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Playback Verification")
                                    .font(.system(size: 16, weight: .semibold))
                                
                                HStack(spacing: 12) {
                                    Button(action: {
                                        if playbackManager.isPlaying {
                                            playbackManager.pause()
                                        } else {
                                            // Auto-load clips if not loaded yet
                                            if playbackManager.playbackClips.isEmpty && !isLoadingPlaybackClips {
                                                loadPlaybackClips()
                                                // Wait a moment for clips to load, then play
                                                Task {
                                                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                                                    await MainActor.run {
                                                        if !playbackManager.playbackClips.isEmpty {
                                                            playbackManager.play()
                                                        }
                                                    }
                                                }
                                            } else {
                                                playbackManager.play()
                                            }
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: playbackManager.isPlaying ? "pause.fill" : "play.fill")
                                            Text(playbackManager.isPlaying ? "Pause" : "Play")
                                        }
                                        .frame(minWidth: 80)
                                    }
                                    .disabled(isLoadingPlaybackClips)
                                    
                                    Button(action: {
                                        playbackManager.stop()
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "stop.fill")
                                            Text("Stop")
                                        }
                                        .frame(minWidth: 80)
                                    }
                                    .disabled(!playbackManager.isPlaying && !playbackManager.isPaused)
                                    
                                    if isLoadingPlaybackClips {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                        Text("Loading clips...")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    } else if playbackManager.playbackClips.isEmpty && !isLoadingPlaybackClips {
                                        // Auto-load clips when play is clicked
                                        Button(action: {
                                            loadPlaybackClips()
                                        }) {
                                            Text("Load Clips for Playback")
                                                .font(.system(size: 12))
                                        }
                                    }
                                    
                                    Spacer()
                                    
                                    if let currentClip = playbackManager.currentClipName {
                                        HStack(spacing: 6) {
                                            Image(systemName: "waveform")
                                                .foregroundColor(.blue)
                                            Text("Playing: \(currentClip)")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                
                                if let error = playbackManager.playbackError {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.red)
                                        Text(error)
                                            .font(.system(size: 11))
                                            .foregroundColor(.red)
                                    }
                                    .padding(.vertical, 4)
                                }
                                
                                if !playbackManager.failedClips.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Failed Clips: \(playbackManager.failedClips.count)")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.red)
                                        ForEach(Array(playbackManager.failedClips.enumerated()), id: \.offset) { index, clipName in
                                            Text("• \(clipName)")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(8)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(4)
                                }
                                
                                if !playbackManager.playbackClips.isEmpty {
                                    Text("\(playbackManager.playbackClips.count) clip\(playbackManager.playbackClips.count == 1 ? "" : "s") loaded")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    
                                    // Timeline View
                                    TimelineView(clips: playbackManager.playbackClips, playbackManager: playbackManager)
                                        .frame(height: 300)
                                        .padding(.top, 8)
                                }
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                        }
                        #endif
                        
                        // Debug output section (collapsible)
                        if !validator.debugOutput.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Button(action: {
                                    validator.showDebugOutput.toggle()
                                }) {
                                    HStack {
                                        Image(systemName: validator.showDebugOutput ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10))
                                        Text("Debug Output")
                                            .font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Text("\(validator.debugOutput.components(separatedBy: .newlines).count) lines")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                
                                if validator.showDebugOutput {
                                    ScrollView {
                                        Text(validator.debugOutput)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .background(Color.black.opacity(0.05))
                                            .cornerRadius(4)
                                    }
                                    .frame(maxHeight: 300)
                                }
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                            .cornerRadius(8)
                        } else if report.totalClips == 0 {
                            // Show a message if no clips found and no debug output
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.orange)
                                    Text("No audio clips detected")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                Text("The parser found 0 clips in this file. This could mean:\n• The file has no audio tracks\n• The file structure is different than expected\n• Check the Debug Output section below for details")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(8)
                        }
                        
                        // Missing clips details
                        if !report.missingClipDetails.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Missing/Invalid Clips")
                                    .font(.system(size: 16, weight: .semibold))
                                
                                ForEach(report.missingClipDetails) { clip in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(clip.name)
                                                .font(.system(size: 13, weight: .medium))
                                            Spacer()
                                            Text(clip.isEmbedded ? "Embedded" : "Linked")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                        
                                        if let path = clip.externalPath {
                                            Text(path)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                        
                                        if let error = clip.errorMessage {
                                            Text(error)
                                                .font(.system(size: 11))
                                                .foregroundColor(.red)
                                        }
                                    }
                                    .padding()
                                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                                    .cornerRadius(6)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 700, height: 600)
        .alert("Error", isPresented: $validator.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let error = validator.errorMessage {
                Text(error)
            }
        }
        .onAppear {
            Task {
                await validator.validateFile(fileURL)
            }
        }
        // ARCHIVED: Auto-load playback clips - disabled due to aaf2 library limitations
        #if false
        .onChange(of: validator.currentReport) { oldValue, newValue in
            // Auto-load playback clips when validation report is ready
            if newValue != nil && playbackManager.playbackClips.isEmpty && !isLoadingPlaybackClips {
                loadPlaybackClips()
            }
        }
        #endif
    }
    
    // ARCHIVED: Playback loading function - disabled due to aaf2 library limitations
    #if false
    private func loadPlaybackClips() {
        print("DEBUG: loadPlaybackClips() called")
        isLoadingPlaybackClips = true
        playbackManager.playbackError = nil
        
        Task {
            do {
                print("DEBUG: Calling extractPlaybackClips for \(fileURL.path)")
                let clips = try await validator.extractPlaybackClips(fileURL: fileURL)
                print("DEBUG: Got \(clips.count) clips")
                
                await MainActor.run {
                    playbackManager.loadPlaybackClips(clips)
                    isLoadingPlaybackClips = false
                    if clips.isEmpty {
                        playbackManager.playbackError = "No clips found for playback"
                    }
                }
            } catch {
                print("DEBUG: Error loading clips: \(error)")
                await MainActor.run {
                    playbackManager.playbackError = "Failed to load clips: \(error.localizedDescription)"
                    isLoadingPlaybackClips = false
                }
            }
        }
    }
    #endif
}

