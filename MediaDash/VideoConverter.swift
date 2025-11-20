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

    // Add files for conversion
    func addFiles(urls: [URL], format: VideoFormat, aspectRatio: AspectRatio, outputDirectory: URL) {
        for url in urls {
            // Create output filename
            let baseName = url.deletingPathExtension().lastPathComponent
            let outputName = "\(baseName)_ProResProxy.\(format.fileExtension)"
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

    // Convert a single job
    private func convertJob(at index: Int) async {
        guard index < jobs.count else { return }

        var job = jobs[index]
        job.status = .converting
        jobs[index] = job

        let asset = AVAsset(url: job.sourceURL)

        // Create export session with ProRes Proxy preset
        guard let session = AVAssetExportSession(asset: asset, presetName: job.format.presetName) else {
            job.status = .failed
            job.error = "Could not create export session"
            jobs[index] = job
            return
        }

        // Configure export session
        session.outputURL = job.destinationURL
        session.outputFileType = .mov

        // Apply aspect ratio conversion if needed
        if job.aspectRatio != .original, let targetSize = job.aspectRatio.size {
            do {
                let composition = try await createVideoComposition(for: asset, targetSize: targetSize)
                session.videoComposition = composition
            } catch {
                job.status = .failed
                job.error = "Failed to create video composition: \(error.localizedDescription)"
                jobs[index] = job
                return
            }
        }

        // Store session for cancellation
        exportSessions[job.id] = session

        // Observe progress
        await observeProgress(for: job.id, session: session, jobIndex: index)

        // Start export
        await session.export()

        // Check status
        switch session.status {
        case .completed:
            job.status = .completed
            job.progress = 1.0
            jobs[index] = job

        case .failed, .cancelled:
            job.status = .failed
            job.error = session.error?.localizedDescription ?? "Export failed"
            jobs[index] = job

            // Clean up failed output file
            try? FileManager.default.removeItem(at: job.destinationURL)

        default:
            break
        }

        // Clean up
        exportSessions.removeValue(forKey: job.id)
    }

    // Create video composition with letterboxing for aspect ratio conversion
    private func createVideoComposition(for asset: AVAsset, targetSize: CGSize) async throws -> AVMutableVideoComposition {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoConverter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)

        // Apply transform to get actual dimensions
        let transformedSize = naturalSize.applying(preferredTransform)
        let videoSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))

        // Calculate scale to fit within target size (letterbox, don't crop)
        let videoAspect = videoSize.width / videoSize.height
        let targetAspect = targetSize.width / targetSize.height

        var scale: CGFloat
        if videoAspect > targetAspect {
            // Video is wider - fit to width
            scale = targetSize.width / videoSize.width
        } else {
            // Video is taller - fit to height
            scale = targetSize.height / videoSize.height
        }

        let scaledWidth = videoSize.width * scale
        let scaledHeight = videoSize.height * scale

        // Center the video
        let xOffset = (targetSize.width - scaledWidth) / 2
        let yOffset = (targetSize.height - scaledHeight) / 2

        // Create composition
        let composition = AVMutableVideoComposition()
        composition.renderSize = targetSize
        composition.frameDuration = CMTime(value: 1, timescale: 30) // 30 fps

        // Create instruction
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)

        // Apply transformations: scale and center
        var transform = CGAffineTransform.identity
        transform = transform.concatenating(preferredTransform)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(translationX: xOffset, y: yOffset))

        layerInstruction.setTransform(transform, at: .zero)

        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        return composition
    }

    // Observe export progress
    private func observeProgress(for jobId: UUID, session: AVAssetExportSession, jobIndex: Int) async {
        // Use a task instead of Timer to avoid Sendable issues
        let progressTask = Task {
            while session.status == .exporting || session.status == .waiting {
                await MainActor.run {
                    guard jobIndex < self.jobs.count else { return }
                    var job = self.jobs[jobIndex]
                    job.progress = Double(session.progress)
                    self.jobs[jobIndex] = job
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }
        }

        // Wait for export to complete
        await progressTask.value
    }
}

// MARK: - Video Converter View


// MARK: - Video Converter View

struct VideoConverterView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var manager: MediaManager
    @State private var selectedAspectRatio: AspectRatio = .sixteenNine
    @State private var outputDirectory: URL?
    @State private var showAlert = false
    @State private var alertMessage = ""

    // Filter staging area files to only video files
    private var videoFiles: [FileItem] {
        let videoExtensions = ["mp4", "mov", "avi", "mxf", "m4v", "prores"]
        return manager.selectedFiles.filter { item in
            !item.isDirectory && videoExtensions.contains(item.url.pathExtension.lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Convert to ProRes Proxy")
                        .font(.system(size: 20, weight: .bold))
                    Text("\(videoFiles.count) video file(s) from staging area")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Settings Section
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
                    Text("Progress will be shown in the staging area")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 500, height: 500)
        .alert("Error", isPresented: $showAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
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

        // Start conversion in MediaManager
        Task {
            await manager.startVideoConversion(aspectRatio: selectedAspectRatio, outputDirectory: outputDir)
        }

        // Close the window
        dismiss()
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
