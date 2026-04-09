import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookUI
import Combine

struct StagingAreaView: View {
    @EnvironmentObject var manager: MediaManager
    @EnvironmentObject var settingsManager: SettingsManager
    /// Not `@ObservedObject`: sync progress updates many times per second; observing here re-renders the whole
    /// staging column (including sessions rows that scan the server for folders). Status UI observes separately.
    let cacheManager: AsanaCacheManager
    let wpDate: Date
    let prepDate: Date
    @Binding var isStagingHovered: Bool
    @Binding var isStagingPressed: Bool
    @Binding var showVideoConverterSheet: Bool
    @Environment(\.layoutMode) var layoutMode
    @Environment(\.windowSize) var windowSize
    
    @State private var stagingContentMode: StagingCenterContentMode = .files
    // Drag and drop state
    @State private var isDragTargeted: Bool = false
    
    // Batch rename state
    @State private var showBatchRenameSheet: Bool = false
    @State private var filesToRename: [FileItem] = []
    
    private var totalFileCount: Int {
        manager.selectedFiles.reduce(0) { $0 + $1.fileCount }
    }
    
    // Fixed padding for compact mode
    private var contentPadding: CGFloat {
        return 20
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stagingHeader
            stagingContent
            StagingAreaStatusBar(cacheManager: cacheManager, manager: manager)
        }
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Cosmetic: paint the bottom window inset seam (behind content; does not shift layout).
        .background(alignment: .bottom) {
            Color(nsColor: .controlBackgroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 16)
                .ignoresSafeArea(.all, edges: .bottom)
        }
        .sheet(isPresented: $showBatchRenameSheet) {
            BatchRenameSheet(manager: manager, filesToRename: filesToRename)
                .sheetSizeStabilizer()
        }
    }
    
    private var stagingHeader: some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    StagingHeaderModeToggleButton(selection: $stagingContentMode)
                    if !manager.selectedFiles.isEmpty {
                        Text("\(totalFileCount) file\(totalFileCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    Button(action: { manager.pickFiles() }) {
                        Color.clear.frame(width: 1, height: 1)
                    }
                    .keyboardShortcut("o", modifiers: .command)
                    .opacity(0.01)
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                    if !manager.selectedFiles.isEmpty {
                        HoverableButton(action: { manager.clearFiles() }) { isHovered in
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                Text("Clear")
                                    .font(.caption)
                            }
                            .foregroundColor(isHovered ? .red.opacity(0.85) : .red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isHovered ? Color.red.opacity(0.08) : Color.clear)
                            .cornerRadius(6)
                        }
                        .keyboardShortcut("w", modifiers: .command)
                        .disabled(stagingContentMode == .sessions)
                    }
                }
                .padding(.horizontal, contentPadding)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
                    .opacity(0.3)
            }
            }
            
    private var stagingContent: some View {
        Group {
            switch stagingContentMode {
            case .sessions:
                StagingSessionsPanel(cacheManager: cacheManager, wpDate: wpDate, prepDate: prepDate)
            case .files:
                filesStagingContent
            }
        }
    }

    private var filesStagingContent: some View {
        ZStack {
            if manager.selectedFiles.isEmpty {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(isDragTargeted ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2), lineWidth: 1.5)
                            .frame(width: 72, height: 72)
                        Image(systemName: isDragTargeted ? "arrow.down.doc" : "doc")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(isDragTargeted ? Color.accentColor : .secondary)
                    }
                    VStack(spacing: 4) {
                        Text(isDragTargeted ? "Drop to add" : "No files staged")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(isDragTargeted ? "Release to add" : "Click or press ⌘O")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                ZStack {
                    StagingFileListView(
                        manager: manager,
                        showBatchRenameSheet: $showBatchRenameSheet,
                        filesToRename: $filesToRename,
                        showVideoConverterSheet: $showVideoConverterSheet
                    )
                    if isDragTargeted {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Drop to add files")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
                        .transition(.opacity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(
            Group {
                if isDragTargeted {
                    Color.accentColor.opacity(0.06)
                } else if isStagingPressed {
                    Color.accentColor.opacity(0.05)
                } else if isStagingHovered {
                    Color.secondary.opacity(0.04)
                } else {
                    Color.clear
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: isDragTargeted ? 2 : 0)
        )
        .animation(.easeInOut(duration: 0.18), value: isDragTargeted)
        .animation(.easeInOut(duration: 0.1), value: isStagingPressed)
        .onHover { hovering in
            isStagingHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
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
            handleFileDrop(providers: providers)
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

// MARK: - Staging status bar (isolated observation)

/// Observes `AsanaCacheManager` here only so high-frequency `syncProgress` updates do not rebuild the whole staging column.
private struct StagingAreaStatusBar: View {
    @ObservedObject var cacheManager: AsanaCacheManager
    @ObservedObject var manager: MediaManager

    private var stagingSyncPhaseText: String {
        let phase = cacheManager.syncPhase.isEmpty ? "Syncing from Asana..." : cacheManager.syncPhase
        if let name = cacheManager.syncHostDeviceName, !name.isEmpty {
            return "\(phase) (\(name))"
        }
        return phase
    }

    var body: some View {
        HStack {
            HStack(spacing: 12) {
                if manager.isIndexing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text("Scanning")
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
                        if cacheManager.isSyncHost {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                        }
                        let syncBar = min(1, max(0, cacheManager.syncProgress))
                        ProgressView(value: syncBar)
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                        Text("\(Int(syncBar * 100))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.blue)
                        Text(stagingSyncPhaseText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
            }

            Spacer()

            if manager.isProcessing {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ProgressView(value: max(0, min(1, manager.progress)))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 200)
                        Text("\(Int(max(0, min(1, manager.progress)) * 100))%")
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
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - File Tree Node

class FileTreeNode: Identifiable, ObservableObject {
    let id = UUID()
    let file: FileItem
    @Published var children: [FileTreeNode]
    @Published var isExpanded: Bool = false
    var hasLoadedChildren: Bool = false
    
    init(file: FileItem) {
        self.file = file
        self.children = []
    }
    
    var hasChildren: Bool {
        file.isDirectory
    }
    
    func loadChildrenIfNeeded() {
        guard file.isDirectory, !hasLoadedChildren else { return }
        hasLoadedChildren = true
        
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: file.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        
        self.children = contents.map { url in
            FileTreeNode(file: FileItem(url: url))
        }.sorted { node1, node2 in
            // Folders first, then files, both alphabetically
            if node1.file.isDirectory && !node2.file.isDirectory {
                return true
            } else if !node1.file.isDirectory && node2.file.isDirectory {
                return false
            }
            return node1.file.name.localizedCaseInsensitiveCompare(node2.file.name) == .orderedAscending
        }
    }
}

// MARK: - Staging File List View

struct StagingFileListView: View {
    @ObservedObject var manager: MediaManager
    @State private var selectedFileId: UUID?
    @State private var treeNodes: [FileTreeNode] = []
    @Binding var showBatchRenameSheet: Bool
    @Binding var filesToRename: [FileItem]
    @Binding var showVideoConverterSheet: Bool
    
    // Supported thumbnail extensions
    private let thumbnailExtensions = ["jpg", "jpeg", "png", "gif", "heic", "mp4", "mov", "m4v", "avi", "mkv", "mxf"]
    
    var body: some View {
        List {
            ForEach(treeNodes) { node in
                TreeNodeView(
                    node: node,
                    manager: manager,
                    selectedFileId: $selectedFileId,
                    thumbnailExtensions: thumbnailExtensions,
                    filesToRename: $filesToRename,
                    showBatchRenameSheet: $showBatchRenameSheet,
                    showVideoConverterSheet: $showVideoConverterSheet
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .animation(.easeInOut(duration: 0.3), value: manager.selectedFiles)
        .animation(.easeInOut(duration: 0.2), value: manager.fileProgress)
        .animation(.easeInOut(duration: 0.2), value: manager.conversionProgress)
        .animation(.easeInOut(duration: 0.3), value: manager.fileCompletionState)
        .onChange(of: manager.selectedFiles) { _, newFiles in
            updateTreeNodes(from: newFiles)
        }
        .onAppear {
            updateTreeNodes(from: manager.selectedFiles)
        }
        .onKeyPress(.space) {
            // QuickLook preview with Space key
            if let selectedId = selectedFileId,
               findNode(id: selectedId, in: treeNodes) != nil {
                let allFiles = getAllFiles(from: treeNodes)
                if let index = allFiles.firstIndex(where: { $0.id == selectedId }) {
                    QuickLookCoordinator.shared.togglePreview(
                        for: allFiles.map { $0.url },
                        startingAt: index
                    )
                    return .handled
                }
            }
            return .ignored
        }
    }
    
    private func updateTreeNodes(from files: [FileItem]) {
        treeNodes = files.map { FileTreeNode(file: $0) }
    }
    
    private func findNode(id: UUID, in nodes: [FileTreeNode]) -> FileTreeNode? {
        for node in nodes {
            if node.file.id == id {
                return node
            }
            if !node.children.isEmpty {
                if let found = findNode(id: id, in: node.children) {
                    return found
                }
            }
        }
        return nil
    }
    
    private func getAllFiles(from nodes: [FileTreeNode]) -> [FileItem] {
        var files: [FileItem] = []
        for node in nodes {
            files.append(node.file)
            if !node.children.isEmpty {
                files.append(contentsOf: getAllFiles(from: node.children))
            }
        }
        return files
    }
}

// MARK: - Tree Node View

struct TreeNodeView: View {
    @ObservedObject var node: FileTreeNode
    @ObservedObject var manager: MediaManager
    @Binding var selectedFileId: UUID?
    let thumbnailExtensions: [String]
    @Binding var filesToRename: [FileItem]
    @Binding var showBatchRenameSheet: Bool
    @Binding var showVideoConverterSheet: Bool
    
    var body: some View {
        if node.file.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                ForEach(node.children) { childNode in
                    TreeNodeView(
                        node: childNode,
                        manager: manager,
                        selectedFileId: $selectedFileId,
                        thumbnailExtensions: thumbnailExtensions,
                        filesToRename: $filesToRename,
                        showBatchRenameSheet: $showBatchRenameSheet,
                        showVideoConverterSheet: $showVideoConverterSheet
                    )
                }
            } label: {
                StagingFileRow(
                    file: node.file,
                    manager: manager,
                    isSelected: selectedFileId == node.file.id,
                    supportsThumbnail: false,
                    onRename: nil,
                    showVideoConverterSheet: $showVideoConverterSheet
                )
                .tag(node.file.id)
            }
            .onChange(of: node.isExpanded) { _, isExpanded in
                if isExpanded && !node.hasLoadedChildren {
                    node.loadChildrenIfNeeded()
                }
            }
        } else {
            StagingFileRow(
                file: node.file,
                manager: manager,
                isSelected: selectedFileId == node.file.id,
                supportsThumbnail: thumbnailExtensions.contains(node.file.url.pathExtension.lowercased()),
                onRename: {
                    filesToRename = [node.file]
                    showBatchRenameSheet = true
                },
                showVideoConverterSheet: $showVideoConverterSheet
            )
            .tag(node.file.id)
        }
    }
}

// MARK: - Staging File Row

struct StagingFileRow: View {
    let file: FileItem
    @ObservedObject var manager: MediaManager
    let isSelected: Bool
    let supportsThumbnail: Bool
    var onRename: (() -> Void)?
    @Binding var showVideoConverterSheet: Bool
    
    // Video file extensions
    private let videoExtensions = ["mp4", "mov", "avi", "mxf", "m4v", "prores"]
    
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
                    .truncationMode(.middle)
                
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .contentShape(Rectangle())
        .contextMenu {
            // QuickLook option
            Button("Quick Look") {
                QuickLookCoordinator.shared.showPreview(for: [file.url])
            }
            .keyboardShortcut(" ", modifiers: [])
            
            Divider()
            
            // Rename option (only for files, not directories)
            if !file.isDirectory {
                Button("Rename") {
                    onRename?()
                }
                .keyboardShortcut("r", modifiers: [])
                
                Divider()
            }
            
            // Remove option
            Button("Remove from Staging") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    manager.removeFile(withId: file.id)
                }
            }
            
            // Show context menu for video files
            if !file.isDirectory {
                let ext = file.url.pathExtension.lowercased()
                if videoExtensions.contains(ext) {
                    Divider()
                    Button("Convert Video") {
                        showVideoConverterSheet = true
                    }
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

