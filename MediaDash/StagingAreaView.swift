import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookUI

struct StagingAreaView: View {
    @EnvironmentObject var manager: MediaManager
    @ObservedObject var cacheManager: AsanaCacheManager
    @Binding var isStagingHovered: Bool
    @Binding var isStagingPressed: Bool
    
    // Drag and drop state
    @State private var isDragTargeted: Bool = false
    @State private var dragPulsePhase: CGFloat = 0
    
    // Batch rename state
    @State private var showBatchRenameSheet: Bool = false
    
    private var totalFileCount: Int {
        manager.selectedFiles.reduce(0) { $0 + $1.fileCount }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.2")
                            .foregroundColor(.blue)
                        Text("STAGING")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)

                        if !manager.selectedFiles.isEmpty {
                            Text("\(totalFileCount)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .cornerRadius(10)
                        }
                    }

                    Spacer()

                    // Always show Add Files button
                    Button(action: { manager.pickFiles() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                            Text("Add Files")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("o", modifiers: .command)

                    if !manager.selectedFiles.isEmpty {
                        // Batch Rename button
                        Button(action: { showBatchRenameSheet = true }) {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                Text("Rename")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Batch rename files")
                        
                        HoverableButton(action: { manager.clearFiles() }) { isHovered in
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                Text("Clear")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(isHovered ? .red.opacity(0.8) : .red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isHovered ? Color.red.opacity(0.1) : Color.clear)
                            .cornerRadius(6)
                        }
                        .keyboardShortcut("w", modifiers: .command)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                
                Divider()
                    .opacity(0.3)
            }
            
            // File List or Empty State
            ZStack {
                if manager.selectedFiles.isEmpty {
                    // Empty State with enhanced drag feedback
                    VStack(spacing: 16) {
                        ZStack {
                            // Pulsing ring when dragging
                            if isDragTargeted {
                                Circle()
                                    .stroke(Color.blue.opacity(0.6), lineWidth: 3)
                                    .frame(width: 110, height: 110)
                                    .scaleEffect(1.0 + dragPulsePhase * 0.1)
                                    .opacity(1.0 - dragPulsePhase * 0.5)
                            }
                            
                            Circle()
                                .fill(isDragTargeted ? Color.blue.opacity(0.3) : (isStagingPressed ? Color.blue.opacity(0.2) : (isStagingHovered ? Color.gray.opacity(0.15) : Color.gray.opacity(0.1))))
                                .frame(width: 100, height: 100)
                            
                            Image(systemName: isDragTargeted ? "arrow.down.doc.fill" : "doc.on.doc.fill")
                                .font(.system(size: 40))
                                .foregroundColor(isDragTargeted ? .blue : (isStagingPressed ? .blue : .secondary))
                                .scaleEffect(isDragTargeted ? 1.1 : 1.0)
                        }
                        .scaleEffect(isDragTargeted ? 1.15 : (isStagingPressed ? 0.95 : (isStagingHovered ? 1.05 : 1.0)))
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDragTargeted)
                        .animation(.easeInOut(duration: 0.15), value: isStagingPressed)
                        .animation(.easeInOut(duration: 0.15), value: isStagingHovered)

                        VStack(spacing: 6) {
                            Text(isDragTargeted ? "Drop files here" : "No files staged")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(isDragTargeted ? .blue : .primary)
                            Text(isDragTargeted ? "Release to add to staging" : "Click here or use ⌘O to add files")
                                .font(.system(size: 13))
                                .foregroundColor(isDragTargeted ? .blue.opacity(0.8) : (isStagingPressed ? .blue : .secondary))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // File List with drag overlay
                    ZStack {
                        StagingFileListView(manager: manager)
                        
                        // Drag overlay when files are being dragged
                        if isDragTargeted {
                            VStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(.white)
                                Text("Drop to add files")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.blue.opacity(0.85))
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                Group {
                    if isDragTargeted {
                        Color.blue.opacity(0.1)
                    } else if isStagingPressed {
                        Color.blue.opacity(0.15)
                    } else if isStagingHovered {
                        Color.gray.opacity(0.05)
                    } else {
                        Color.clear
                    }
                }
            )
            .overlay(
                // Glowing border when dragging
                RoundedRectangle(cornerRadius: 0)
                    .stroke(Color.blue, lineWidth: isDragTargeted ? 3 : 0)
                    .opacity(isDragTargeted ? 0.8 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isDragTargeted)
            )
            .scaleEffect(isDragTargeted ? 1.01 : (isStagingPressed ? 0.998 : 1.0))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragTargeted)
            .animation(.easeInOut(duration: 0.1), value: isStagingPressed)
            .onHover { hovering in
                isStagingHovered = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isStagingPressed {
                            isStagingPressed = true
                        }
                    }
                    .onEnded { _ in
                        isStagingPressed = false
                        manager.pickFiles()
                    }
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isDragTargeted) { providers in
                return handleFileDrop(providers: providers)
            }
            .onChange(of: isDragTargeted) { _, isTargeted in
                if isTargeted {
                    // Start pulse animation
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        dragPulsePhase = 1.0
                    }
                } else {
                    // Stop pulse animation
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragPulsePhase = 0
                    }
                }
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            // Status Bar
            HStack {
                // Left side - Indexing and Asana sync indicators
                HStack(spacing: 12) {
                    if manager.isIndexing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                            Text("Indexing")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }
                    
                    if cacheManager.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                            Text("Syncing with Asana")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.blue)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                    }
                }

                Spacer()

                // Center/Right - Processing or hover info
                if manager.isProcessing {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ProgressView(value: manager.progress)
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 200)
                            Text("\(Int(manager.progress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                            Button("Cancel") {
                                manager.cancelProcessing()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Text(manager.statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    // Don't show "Ready." when syncing or indexing
                    if !cacheManager.isSyncing && !manager.isIndexing {
                        Text("Ready.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 350)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showBatchRenameSheet) {
            BatchRenameSheet(manager: manager)
        }
    }
    
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            let fileItem = FileItem(url: url)
                            let currentIDs = Set(self.manager.selectedFiles.map { $0.url })
                            if !currentIDs.contains(fileItem.url) {
                                self.manager.selectedFiles.append(fileItem)
                            }
                        }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Staging File List View

struct StagingFileListView: View {
    @ObservedObject var manager: MediaManager
    @State private var selectedFileId: UUID?
    
    // Supported thumbnail extensions
    private let thumbnailExtensions = ["jpg", "jpeg", "png", "gif", "heic", "mp4", "mov", "m4v", "avi", "mkv", "mxf"]
    
    var body: some View {
        List(manager.selectedFiles, selection: $selectedFileId) { f in
            StagingFileRow(
                file: f,
                manager: manager,
                isSelected: selectedFileId == f.id,
                supportsThumbnail: thumbnailExtensions.contains(f.url.pathExtension.lowercased())
            )
            .tag(f.id)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .animation(.easeInOut(duration: 0.3), value: manager.selectedFiles)
        .animation(.easeInOut(duration: 0.2), value: manager.fileProgress)
        .animation(.easeInOut(duration: 0.2), value: manager.conversionProgress)
        .animation(.easeInOut(duration: 0.3), value: manager.fileCompletionState)
        .onKeyPress(.space) {
            // QuickLook preview with Space key
            if let selectedId = selectedFileId,
               manager.selectedFiles.contains(where: { $0.id == selectedId }) {
                QuickLookCoordinator.shared.togglePreview(
                    for: manager.selectedFiles.map { $0.url },
                    startingAt: manager.selectedFiles.firstIndex(where: { $0.id == selectedId }) ?? 0
                )
                return .handled
            }
            return .ignored
        }
    }
}

// MARK: - Staging File Row

struct StagingFileRow: View {
    let file: FileItem
    @ObservedObject var manager: MediaManager
    let isSelected: Bool
    let supportsThumbnail: Bool
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Progress bar background
            if let progress = manager.fileProgress[file.id], progress > 0 {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: geometry.size.width * progress)
                }
            } else if let convProgress = manager.conversionProgress[file.id], convProgress > 0 {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.purple.opacity(0.2))
                        .frame(width: geometry.size.width * convProgress)
                }
            }

            // File info
            HStack(spacing: 8) {
                // Thumbnail or system icon
                if supportsThumbnail && !file.isDirectory {
                    ThumbnailImageView(url: file.url, size: 28)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                
                Text(file.name)
                    .lineLimit(1)
                
                Spacer()

                // Show checkmark, progress, or file info
                fileStatusView
                
                // Remove button
                HoverableButton(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        manager.removeFile(withId: file.id)
                    }
                }) { isHovered in
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(isHovered ? .red : .secondary)
                        .font(.system(size: 14))
                        .scaleEffect(isHovered ? 1.15 : 1.0)
                }
                .help("Remove from staging")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            // QuickLook option
            Button("Quick Look") {
                QuickLookCoordinator.shared.showPreview(for: [file.url])
            }
            .keyboardShortcut(" ", modifiers: [])
            
            Divider()
            
            // Remove option
            Button("Remove from Staging") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    manager.removeFile(withId: file.id)
                }
            }
            
            // Show context menu for OMF/AAF files
            if !file.isDirectory {
                let ext = file.url.pathExtension.lowercased()
                if ext == "omf" {
                    Divider()
                    Button("Validate OMF") {
                        manager.omfAafFileToValidate = file.url
                        manager.showOMFAAFValidator = true
                    }
                } else if ext == "aaf" {
                    Divider()
                    Button("Validate AAF") {
                        manager.omfAafFileToValidate = file.url
                        manager.showOMFAAFValidator = true
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var fileStatusView: some View {
        if let completionState = manager.fileCompletionState[file.id] {
            switch completionState {
            case .complete:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
            case .workPicDone, .prepDone:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 16))
            case .none:
                EmptyView()
            }
        } else if let convProgress = manager.conversionProgress[file.id], convProgress > 0, convProgress < 1.0 {
            HStack(spacing: 4) {
                Image(systemName: "film")
                    .font(.system(size: 10))
                Text("\(Int(convProgress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
            }
            .foregroundColor(.purple)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.1))
            .cornerRadius(4)
        } else if let progress = manager.fileProgress[file.id], progress > 0, progress < 1.0 {
            Text("\(Int(progress * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(4)
        } else {
            // Show file count for folders, or file size for files
            if file.isDirectory {
                Text("\(file.fileCount) file\(file.fileCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(4)
            } else if let size = getFileSize(file.url) {
                Text(size)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func getFileSize(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

