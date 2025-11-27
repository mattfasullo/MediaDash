import Foundation
import AppKit
import QuickLookThumbnailing
import AVFoundation
import SwiftUI
import Combine
import Quartz

// MARK: - Thumbnail Cache

/// A service for generating and caching file thumbnails asynchronously
@MainActor
class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    
    @Published private var cache: [URL: NSImage] = [:]
    private var pendingRequests: Set<URL> = []
    
    private let thumbnailSize = CGSize(width: 32, height: 32)
    private let maxCacheSize = 200
    private var cacheOrder: [URL] = []
    
    // File extensions that support thumbnail generation
    private let supportedImageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp"]
    private let supportedVideoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "mxf", "prores"]
    private let supportedAudioExtensions = ["mp3", "wav", "aiff", "aif", "m4a", "flac", "aac"]
    
    private init() {}
    
    // MARK: - Public API
    
    /// Get a thumbnail for a file URL, generating it asynchronously if not cached
    func thumbnail(for url: URL) -> NSImage? {
        // Return cached thumbnail if available
        if let cached = cache[url] {
            return cached
        }
        
        // Check if we're already generating this thumbnail
        guard !pendingRequests.contains(url) else {
            return nil
        }
        
        // Check if this file type supports thumbnails
        let ext = url.pathExtension.lowercased()
        guard supportedImageExtensions.contains(ext) ||
              supportedVideoExtensions.contains(ext) ||
              supportedAudioExtensions.contains(ext) else {
            return nil
        }
        
        // Start async generation
        pendingRequests.insert(url)
        
        Task {
            await generateThumbnail(for: url)
        }
        
        return nil
    }
    
    /// Check if a URL has a cached thumbnail
    func hasCachedThumbnail(for url: URL) -> Bool {
        cache[url] != nil
    }
    
    /// Clear the cache
    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }
    
    /// Remove a specific thumbnail from cache
    func invalidate(url: URL) {
        cache.removeValue(forKey: url)
        cacheOrder.removeAll { $0 == url }
    }
    
    // MARK: - Thumbnail Generation
    
    private func generateThumbnail(for url: URL) async {
        defer {
            pendingRequests.remove(url)
        }
        
        // Use QLThumbnailGenerator for system-level thumbnail generation
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: thumbnailSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        
        do {
            let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            
            await MainActor.run {
                storeThumbnail(thumbnail.nsImage, for: url)
            }
        } catch {
            // Fallback: try to generate thumbnail manually for videos
            let ext = url.pathExtension.lowercased()
            if supportedVideoExtensions.contains(ext) {
                await generateVideoThumbnail(for: url)
            }
        }
    }
    
    private func generateVideoThumbnail(for url: URL) async {
        let asset = AVAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 64, height: 64)
        
        do {
            let cgImage = try imageGenerator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 60), actualTime: nil)
            let nsImage = NSImage(cgImage: cgImage, size: thumbnailSize)
            
            await MainActor.run {
                storeThumbnail(nsImage, for: url)
            }
        } catch {
            // Silent fail - we'll just show the system icon
        }
    }
    
    private func storeThumbnail(_ image: NSImage, for url: URL) {
        // Enforce cache size limit using LRU eviction
        if cache.count >= maxCacheSize, let oldest = cacheOrder.first {
            cache.removeValue(forKey: oldest)
            cacheOrder.removeFirst()
        }
        
        cache[url] = image
        cacheOrder.append(url)
        
        // Trigger UI update
        objectWillChange.send()
    }
}

// MARK: - Thumbnail Image View

/// A view that displays a file thumbnail with automatic async loading
struct ThumbnailImageView: View {
    let url: URL
    let size: CGFloat
    
    @ObservedObject private var cache = ThumbnailCache.shared
    @State private var systemIcon: NSImage?
    
    init(url: URL, size: CGFloat = 32) {
        self.url = url
        self.size = size
    }
    
    var body: some View {
        Group {
            if let thumbnail = cache.thumbnail(for: url) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let icon = systemIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                // Placeholder while loading
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: size, height: size)
                    .overlay(
                        ProgressView()
                            .scaleEffect(0.5)
                    )
            }
        }
        .onAppear {
            systemIcon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

// MARK: - QuickLook Preview Coordinator

/// Coordinator for managing QuickLook preview panel
class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    
    private var previewItems: [PreviewItem] = []
    var currentIndex: Int = 0
    
    private override init() {
        super.init()
    }
    
    func showPreview(for urls: [URL], startingAt index: Int = 0) {
        previewItems = urls.map { PreviewItem(url: $0) }
        currentIndex = index
        
        guard let panel = QLPreviewPanel.shared() else { return }
        
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = index
        
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    func hidePreview() {
        QLPreviewPanel.shared()?.orderOut(nil)
    }
    
    func togglePreview(for urls: [URL], startingAt index: Int = 0) {
        guard let panel = QLPreviewPanel.shared() else { return }
        
        if panel.isVisible {
            hidePreview()
        } else {
            showPreview(for: urls, startingAt: index)
        }
    }
    
    // MARK: - QLPreviewPanelDataSource
    
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewItems.count
    }
    
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard index < previewItems.count else { return nil }
        return previewItems[index]
    }
    
    // MARK: - QLPreviewPanelDelegate
    
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            if event.keyCode == 53 { // Escape key
                hidePreview()
                return true
            }
        }
        return false
    }
}

// MARK: - Preview Item Wrapper

/// Wrapper class for URL to conform to QLPreviewItem (which requires NSObjectProtocol)
class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    
    init(url: URL) {
        self.url = url
        super.init()
    }
    
    var previewItemURL: URL? { url }
    var previewItemTitle: String? { url.lastPathComponent }
}

