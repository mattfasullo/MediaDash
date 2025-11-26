import Foundation
import AVFoundation

/// Protocol for video conversion operations
protocol VideoConverting {
    func addFiles(urls: [URL], format: VideoFormat, aspectRatio: AspectRatio, outputDirectory: URL, keepOriginalName: Bool)
    func startConversion() async
    var jobs: [ConversionJob] { get }
}

// Extension to provide default parameter
extension VideoConverting {
    func addFiles(urls: [URL], format: VideoFormat, aspectRatio: AspectRatio, outputDirectory: URL) {
        addFiles(urls: urls, format: format, aspectRatio: aspectRatio, outputDirectory: outputDirectory, keepOriginalName: false)
    }
}

