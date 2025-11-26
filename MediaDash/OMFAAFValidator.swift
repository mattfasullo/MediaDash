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
// REMOVED: All playback functionality has been removed - we only need timeline visualization

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
        // Try multiple locations in order of priority:
        // 1. App bundle Resources (PRIMARY - for distribution builds)
        // 2. Same directory as executable (for development)
        // 3. Current working directory (for development)
        // 4. Parent of current directory (workspace root for development)
        
        var foundPath: URL?
        
        // Try 1: App bundle Resources (PRIMARY - this is where it should be in distributed builds)
        if let resourcePath = Bundle.main.resourcePath {
            let scriptPath = URL(fileURLWithPath: resourcePath).appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        // Try 2: Same directory as executable (development)
        if foundPath == nil, let executablePath = Bundle.main.executablePath {
            let executableURL = URL(fileURLWithPath: executablePath)
            let scriptPath = executableURL.deletingLastPathComponent().appendingPathComponent("media_validator.py")
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
        
        // Try 4: Parent of current directory (workspace root for development)
        if foundPath == nil {
            let cwd = FileManager.default.currentDirectoryPath
            let scriptPath = URL(fileURLWithPath: cwd)
                .deletingLastPathComponent()
                .appendingPathComponent("media_validator.py")
            if FileManager.default.fileExists(atPath: scriptPath.path) {
                foundPath = scriptPath
            }
        }
        
        // Try 5: Walk up from executable to find workspace root (development fallback only)
        if foundPath == nil, let executablePath = Bundle.main.executablePath {
            var currentPath = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
            
            // Walk up directory tree looking for media_validator.py
            for _ in 0..<10 { // Limit to 10 levels up
                let scriptPath = currentPath.appendingPathComponent("media_validator.py")
                if FileManager.default.fileExists(atPath: scriptPath.path) {
                    foundPath = scriptPath
                    break
                }
                
                // Also check parent directories (for when script is in project root but app is in build folder)
                let parentPath = currentPath.deletingLastPathComponent()
                let parentScriptPath = parentPath.appendingPathComponent("media_validator.py")
                if FileManager.default.fileExists(atPath: parentScriptPath.path) {
                    foundPath = parentScriptPath
                    break
                }
                
                let parent = currentPath.deletingLastPathComponent()
                if parent.path == currentPath.path {
                    break // Reached root
                }
                currentPath = parent
            }
        }
        
        // If not found, use a placeholder path that will trigger a clear error message
        // The error will indicate where the script should be located
        if let found = foundPath {
            self.pythonScriptPath = found
        } else {
            // Use bundle resources path as the expected location for error message
            let expectedPath = Bundle.main.resourcePath.map { 
                URL(fileURLWithPath: $0).appendingPathComponent("media_validator.py").path 
            } ?? "app bundle Resources folder"
            self.pythonScriptPath = URL(fileURLWithPath: expectedPath)
        }
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
        
        // Run the Python script with timeout
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python3)
        process.arguments = [pythonScriptPath.path, fileURL.path]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up real-time stderr streaming for debug output
        let errorHandle = errorPipe.fileHandleForReading
        let debugQueue = DispatchQueue(label: "com.mediadash.debugOutput")
        var streamingDebugText = ""
        
        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                let newText = lines.joined(separator: "\n")
                
                // Thread-safe append to debug text
                debugQueue.async {
                    streamingDebugText += (streamingDebugText.isEmpty ? "" : "\n") + newText
                    let currentDebug = streamingDebugText
                    
                    // Update debug output in real-time on main actor
                    Task { @MainActor in
                        self.debugOutput = currentDebug
                        self.showDebugOutput = true
                    }
                }
            }
        }
        
        try process.run()
        
        // Wait with timeout (30 seconds) using Task
        let timeout: TimeInterval = 30.0
        let startTime = Date()
        
        // Wait for process to finish with timeout
        while process.isRunning {
            if Date().timeIntervalSince(startTime) > timeout {
                process.terminate()
                errorHandle.readabilityHandler = nil
                await MainActor.run {
                    self.debugOutput += "\n\nERROR: Process timed out after \(Int(timeout)) seconds. The OMF file may be too large or complex."
                    self.showDebugOutput = true
                }
                throw ValidationError.validationFailed("Validation timed out after \(Int(timeout)) seconds. The file may be too large or complex to parse.")
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
        
        // Clean up readability handler
        errorHandle.readabilityHandler = nil
        
        // Read remaining output
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
    
    // REMOVED: Playback extraction functionality - no longer needed
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

// MARK: - Preference Keys

struct TimelineFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Validator View

struct OMFAAFValidatorView: View {
    @ObservedObject var validator: OMFAAFValidatorManager
    let fileURL: URL
    @Environment(\.dismiss) var dismiss
    @State private var hoveredClip: TimelineClip? = nil
    @State private var hoveredClipTrackIndex: Int? = nil
    @State private var hoveredClipXPosition: CGFloat? = nil
    @State private var timelineFrame: CGRect = .zero
    
    var body: some View {
        ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
                headerView
                Divider()
                contentView
            }
            .coordinateSpace(name: "validator")
            .onPreferenceChange(TimelineFrameKey.self) { frame in
                timelineFrame = frame
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
            
            // Tooltip overlay - outside VStack so it doesn't take up space
        }
    }
    
    private var headerView: some View {
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
    }
            
    @ViewBuilder
    private var contentView: some View {
            if validator.isValidating {
            validatingView
        } else if let report = validator.currentReport {
            reportContentView(report: report)
        }
    }
    
    private var validatingView: some View {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Validating media references...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
    }
    
    @ViewBuilder
    private func reportContentView(report: ValidationReportResult) -> some View {
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
                                
                                    TimelineView(
                                        clips: report.timelineClips,
                                        hoveredClip: $hoveredClip,
                                        hoveredClipTrackIndex: $hoveredClipTrackIndex,
                                        hoveredClipXPosition: $hoveredClipXPosition
                                    )
                                    .frame(height: CGFloat(report.timelineClips.map { $0.trackIndex }.max() ?? 0) * 18 + 18 + 6) // +6 for padding (3 top + 3 bottom)
                                    .background(
                                        Rectangle()
                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    )
                                    .background(
                                        GeometryReader { geometry in
                                            Color.clear
                                                .preference(key: TimelineFrameKey.self, value: geometry.frame(in: .named("validator")))
                                        }
                                    )
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                        }
                        
                            
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
                                }
                                
                            // Always show debug section if there are 0 clips, even if empty
                            if report.totalClips == 0 {
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
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                            .cornerRadius(8)
                        
                                // Debug output section (always show when 0 clips, even if empty)
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
                                            if !validator.debugOutput.isEmpty {
                                        Text("\(validator.debugOutput.components(separatedBy: .newlines).count) lines")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            } else {
                                                Text("No debug output available")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            }
                                    }
                                }
                                .buttonStyle(.plain)
                                
                                if validator.showDebugOutput {
                                    ScrollView {
                                            if validator.debugOutput.isEmpty {
                                                Text("No debug output was captured. The Python script may not have produced any debug messages.")
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .padding(8)
                                            } else {
                                        Text(validator.debugOutput)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                            .padding(8)
                                            }
                                        }
                                        .frame(maxHeight: 300)
                                            .background(Color.black.opacity(0.05))
                                            .cornerRadius(4)
                                }
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                            .cornerRadius(8)
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
