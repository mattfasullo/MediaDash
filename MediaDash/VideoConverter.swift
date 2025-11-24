import Foundation
import AVFoundation
import SwiftUI
import AppKit
import Combine

// MARK: - Video Format Options

enum VideoFormat: String, CaseIterable, Codable {
    case proResProxy = "ProRes Proxy"

    var fileExtension: String {
        return "mov"
    }

    var presetName: String {
        return AVAssetExportPresetAppleProRes422LPCM
    }
}

enum AspectRatio: String, CaseIterable, Codable {
    case original = "Original"
    case sixteenNine = "16:9 (1920x1080)"

    var size: CGSize? {
        switch self {
        case .original:
            return nil
        case .sixteenNine:
            return CGSize(width: 1920, height: 1080)
        }
    }
}

// MARK: - Conversion Job

struct ConversionJob: Identifiable, Hashable {
    let id = UUID()
    let sourceURL: URL
    let destinationURL: URL
    let format: VideoFormat
    let aspectRatio: AspectRatio
    var progress: Double = 0
    var status: ConversionStatus = .pending
    var error: String?

    enum ConversionStatus: Hashable {
        case pending
        case converting
        case completed
        case failed
    }

    var sourceName: String {
        sourceURL.lastPathComponent
    }

    var destinationName: String {
        destinationURL.lastPathComponent
    }
}

// MARK: - Video Converter Manager

@MainActor
class VideoConverterManager: ObservableObject {
    @Published var jobs: [ConversionJob] = []
    @Published var isConverting = false
    @Published var currentJobIndex = 0
    @Published var overallProgress: Double = 0

    private var exportSessions: [UUID: AVAssetExportSession] = [:]
    
    // Find FFmpeg executable path
    private func findFFmpegPath() -> String? {
        // Common FFmpeg installation paths
        let possiblePaths = [
            "/opt/homebrew/bin/ffmpeg",      // Homebrew on Apple Silicon
            "/usr/local/bin/ffmpeg",         // Homebrew on Intel Mac
            "/usr/bin/ffmpeg",                // System installation
            "/opt/local/bin/ffmpeg"          // MacPorts
        ]
        
        // Check each path
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        // Try using 'which' command as fallback
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["ffmpeg"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                        return path
                    }
                }
            }
        } catch {
            // Ignore errors, will return nil
        }
        
        return nil
    }

    // Add files for conversion
    func addFiles(urls: [URL], format: VideoFormat, aspectRatio: AspectRatio, outputDirectory: URL, keepOriginalName: Bool = false) {
        for url in urls {
            // Create output filename
            let baseName = url.deletingPathExtension().lastPathComponent
            let outputName: String
            if keepOriginalName {
                // Keep original name, just change extension
                outputName = "\(baseName).\(format.fileExtension)"
            } else {
                outputName = "\(baseName)_ProResProxy.\(format.fileExtension)"
            }
            let outputURL = outputDirectory.appendingPathComponent(outputName)

            // Ensure unique filename
            let uniqueURL = makeUniqueURL(outputURL)

            let job = ConversionJob(
                sourceURL: url,
                destinationURL: uniqueURL,
                format: format,
                aspectRatio: aspectRatio
            )
            jobs.append(job)
        }
    }

    // Make filename unique if it already exists
    private func makeUniqueURL(_ url: URL) -> URL {
        var uniqueURL = url
        var counter = 1
        let fm = FileManager.default

        while fm.fileExists(atPath: uniqueURL.path) {
            let baseName = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let newName = "\(baseName)_\(counter).\(ext)"
            uniqueURL = url.deletingLastPathComponent().appendingPathComponent(newName)
            counter += 1
        }

        return uniqueURL
    }

    // Remove a job
    func removeJob(_ job: ConversionJob) {
        // Cancel if it's currently converting
        if let session = exportSessions[job.id] {
            session.cancelExport()
            exportSessions.removeValue(forKey: job.id)
        }


        jobs.removeAll { $0.id == job.id }
    }

    // Clear all jobs
    func clearCompleted() {
        jobs.removeAll { $0.status == .completed }
    }

    func clearAll() {
        // Cancel any ongoing conversions
        for session in exportSessions.values {
            session.cancelExport()
        }
        exportSessions.removeAll()
        jobs.removeAll()
    }

    // Start conversion process
    func startConversion() async {
        guard !jobs.isEmpty else { return }
        guard !isConverting else { return }

        isConverting = true
        currentJobIndex = 0
        overallProgress = 0

        for index in jobs.indices {
            guard jobs[index].status != .completed else { continue }

            currentJobIndex = index
            await convertJob(at: index)

            // Update overall progress
            let completedJobs = jobs.filter { $0.status == .completed }.count
            overallProgress = Double(completedJobs) / Double(jobs.count)
        }

        isConverting = false

        // Play completion sound
        NSSound(named: "Glass")?.play()
    }

    // Convert a single job using FFmpeg
    private func convertJob(at index: Int) async {
        guard index < jobs.count else { return }

        var job = jobs[index]
        job.status = .converting
        jobs[index] = job

        // Find FFmpeg executable
        guard let ffmpegPath = findFFmpegPath() else {
            job.status = .failed
            job.error = "FFmpeg not found. Please install FFmpeg using Homebrew: brew install ffmpeg"
            jobs[index] = job
            return
        }
        
        // Build FFmpeg command for ProRes Proxy with 23.976fps
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        var arguments = [
            "-i", job.sourceURL.path,
            "-c:v", "prores_ks",        // ProRes encoder
            "-profile:v", "0",           // Profile 0 = ProRes Proxy
            "-c:a", "pcm_s16le",         // PCM audio
        ]

        // Build video filter chain
        var videoFilters: [String] = []
        
        // Add aspect ratio filter if needed (always use letterboxing, no stretching)
        if job.aspectRatio != .original, let targetSize = job.aspectRatio.size {
            let width = Int(targetSize.width)
            let height = Int(targetSize.height)
            // Scale to fit within target size maintaining aspect ratio, then pad with black bars
            videoFilters.append("scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:black")
        }
        
        // Always set frame rate to 23.976fps using fps filter for better quality
        videoFilters.append("fps=24000/1001")
        
        // Apply video filter
        arguments.append(contentsOf: ["-vf", videoFilters.joined(separator: ",")])

        arguments.append(contentsOf: [
            "-y",  // Overwrite output file
            job.destinationURL.path
        ])

        process.arguments = arguments

        // Capture stderr for progress monitoring
        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()

            // Monitor progress in background
            Task {
                await monitorFFmpegProgress(pipe: pipe, jobIndex: index, jobId: job.id)
            }

            process.waitUntilExit()

            // Check exit status
            if process.terminationStatus == 0 {
                job.status = .completed
                job.progress = 1.0
                jobs[index] = job
            } else {
                job.status = .failed
                job.error = "FFmpeg conversion failed with code \(process.terminationStatus)"
                jobs[index] = job

                // Clean up failed output file
                try? FileManager.default.removeItem(at: job.destinationURL)
            }
        } catch {
            job.status = .failed
            job.error = "Failed to start FFmpeg: \(error.localizedDescription)"
            jobs[index] = job
        }

        // Clean up
        exportSessions.removeValue(forKey: job.id)
    }

    // Monitor FFmpeg progress from stderr output
    private func monitorFFmpegProgress(pipe: Pipe, jobIndex: Int, jobId: UUID) async {
        let data = pipe.fileHandleForReading
        var buffer = Data()

        while true {
            let chunk = data.availableData
            if chunk.isEmpty { break }

            buffer.append(chunk)
            if let output = String(data: buffer, encoding: .utf8) {
                // Parse duration and time from FFmpeg output
                // FFmpeg outputs progress like: "time=00:00:05.23"
                if output.range(of: "time=(\\d+):(\\d+):(\\d+\\.\\d+)", options: .regularExpression) != nil {
                    // Extract and calculate progress (simplified)
                    await MainActor.run {
                        guard jobIndex < self.jobs.count else { return }
                        var job = self.jobs[jobIndex]
                        // Increment progress gradually (actual duration parsing would be more accurate)
                        job.progress = min(0.95, job.progress + 0.05)
                        self.jobs[jobIndex] = job
                    }
                }
                buffer.removeAll()
            }

            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }

}

// MARK: - Video Converter View Coordinator

class VideoConverterViewCoordinator: ObservableObject {
    @Published var jobs: [ConversionJob] = []
    @Published var isConverting: Bool = false
    @Published var overallProgress: Double = 0
    
    private var cancellables = Set<AnyCancellable>()
    private var converter: VideoConverterManager?
    
    func subscribe(to converter: VideoConverterManager) {
        self.converter = converter
        
        // Cancel existing subscriptions
        cancellables.removeAll()
        
        // Subscribe to jobs updates
        converter.$jobs
            .receive(on: DispatchQueue.main)
            .assign(to: &$jobs)
        
        // Subscribe to isConverting updates
        converter.$isConverting
            .receive(on: DispatchQueue.main)
            .assign(to: &$isConverting)
        
        // Subscribe to overallProgress updates
        converter.$overallProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$overallProgress)
    }
    
    func unsubscribe() {
        cancellables.removeAll()
    }
}

// MARK: - Video Converter View

struct VideoConverterView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var manager: MediaManager
    @StateObject private var coordinator = VideoConverterViewCoordinator()
    @State private var selectedAspectRatio: AspectRatio = .sixteenNine
    @State private var outputDirectory: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var hasStartedConversion = false

    // Filter staging area files to only video files
    private var videoFiles: [FileItem] {
        let videoExtensions = ["mp4", "mov", "avi", "mxf", "m4v", "prores"]
        return manager.selectedFiles.filter { item in
            !item.isDirectory && videoExtensions.contains(item.url.pathExtension.lowercased())
        }
    }
    
    // Get converter from manager
    private var converter: VideoConverterManager? {
        manager.videoConverter
    }
    

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Convert to ProRes Proxy")
                        .font(.system(size: 20, weight: .bold))
                    if hasStartedConversion {
                        Text("\(coordinator.jobs.count) job(s) - \(Int(coordinator.overallProgress * 100))% complete")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(videoFiles.count) video file(s) from staging area")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(coordinator.isConverting)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if hasStartedConversion {
                // Job List View (like Shutter Encoder)
                VStack(spacing: 0) {
                    // Overall Progress
                    if coordinator.isConverting {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Overall Progress:")
                                    .font(.headline)
                                Spacer()
                                Text("\(Int(coordinator.overallProgress * 100))%")
                                    .font(.headline)
                                    .foregroundColor(.blue)
                            }
                            ProgressView(value: coordinator.overallProgress)
                                .progressViewStyle(.linear)
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        
                        Divider()
                    }
                    
                    // Job List
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(coordinator.jobs) { job in
                                JobRowView(job: job) {
                                    converter?.removeJob(job)
                                }
                            }
                        }
                        .padding()
                    }
                    
                    // Action Buttons
                    HStack(spacing: 12) {
                        Button("Clear Completed") {
                            converter?.clearCompleted()
                        }
                        .disabled(coordinator.jobs.filter { $0.status == .completed }.isEmpty)
                        
                        Spacer()
                        
                        Button("Clear All") {
                            converter?.clearAll()
                            hasStartedConversion = false
                        }
                        .disabled(coordinator.jobs.isEmpty)
                    }
                    .padding()
                }
            } else {
                // Settings Section (before conversion starts)
                VStack(spacing: 16) {
                    // Aspect Ratio Selection
                    HStack {
                        Text("Aspect Ratio:")
                            .font(.headline)

                        Picker("Aspect Ratio", selection: $selectedAspectRatio) {
                            ForEach(AspectRatio.allCases, id: \.self) { ratio in
                                Text(ratio.rawValue).tag(ratio)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 250)

                        Spacer()
                    }

                    // Output Directory
                    HStack {
                        Text("Output Folder:")
                            .font(.headline)

                        if let outputDir = outputDirectory {
                            Text(outputDir.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Not selected")
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        Spacer()

                        Button("Choose...") {
                            selectOutputDirectory()
                        }
                    }

                    Divider()

                    // Action Buttons
                    HStack(spacing: 12) {
                        Button("Start Conversion") {
                            startConversion()
                        }
                        .disabled(videoFiles.isEmpty || outputDirectory == nil)
                        .buttonStyle(.borderedProminent)

                        Spacer()
                    }
                }
                .padding()

                Divider()

                // Instructions
                VStack(spacing: 12) {
                    Image(systemName: "film.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    if videoFiles.isEmpty {
                        Text("No video files in staging area")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Add video files to the staging area first")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(videoFiles.count) video file(s) ready")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Select output folder and click Start Conversion")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Conversion progress will be shown here")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 500, height: hasStartedConversion ? 400 : 350)
        .alert("Error", isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            // Initialize converter if needed
            if manager.videoConverter == nil {
                manager.videoConverter = VideoConverterManager()
            }
            if let converter = manager.videoConverter {
                coordinator.subscribe(to: converter)
            }
        }
        .onDisappear {
            coordinator.unsubscribe()
        }
        .onChange(of: coordinator.jobs.count) { oldValue, newValue in
            if newValue > 0 && !hasStartedConversion {
                hasStartedConversion = true
            }
        }
    }

    // Select output directory
    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select output directory for converted files"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                outputDirectory = url
            }
        }
    }

    // Start conversion
    private func startConversion() {
        guard let outputDir = outputDirectory else {
            alertMessage = "Please select an output directory first"
            showAlert = true
            return
        }

        guard let converter = converter else {
            alertMessage = "Video converter not available"
            showAlert = true
            return
        }

        // Add files to converter
        converter.addFiles(
            urls: videoFiles.map { $0.url },
            format: .proResProxy,
            aspectRatio: selectedAspectRatio,
            outputDirectory: outputDir
        )

        // Mark that conversion has started
        hasStartedConversion = true

        // Start conversion in background
        Task {
            await converter.startConversion()
        }
    }
}

// MARK: - Job Row View

struct JobRowView: View {
    let job: ConversionJob
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Status Icon
                statusIcon

                VStack(alignment: .leading, spacing: 4) {
                    Text(job.sourceName)
                        .font(.headline)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(job.destinationName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    if let error = job.error {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Status Text
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
                    .frame(width: 80, alignment: .trailing)

                // Remove Button
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .disabled(job.status == .converting)
            }

            // Progress Bar
            if job.status == .converting || job.status == .completed {
                ProgressView(value: job.progress)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var statusIcon: some View {
        Group {
            switch job.status {
            case .pending:
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
            case .converting:
                ProgressView()
                    .scaleEffect(0.7)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
        .frame(width: 24, height: 24)
    }

    private var statusText: String {
        switch job.status {
        case .pending:
            return "Pending"
        case .converting:
            return "\(Int(job.progress * 100))%"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .pending:
            return .secondary
        case .converting:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}
