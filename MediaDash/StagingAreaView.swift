import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct StagingAreaView: View {
    @EnvironmentObject var manager: MediaManager
    @ObservedObject var cacheManager: AsanaCacheManager
    @Binding var isStagingHovered: Bool
    @Binding var isStagingPressed: Bool
    
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
                    // Empty State
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(isStagingPressed ? Color.blue.opacity(0.2) : (isStagingHovered ? Color.gray.opacity(0.15) : Color.gray.opacity(0.1)))
                                .frame(width: 100, height: 100)
                            Image(systemName: "doc.on.doc.fill")
                                .font(.system(size: 40))
                                .foregroundColor(isStagingPressed ? .blue : .secondary)
                        }
                        .scaleEffect(isStagingPressed ? 0.95 : (isStagingHovered ? 1.05 : 1.0))
                        .animation(.easeInOut(duration: 0.15), value: isStagingPressed)
                        .animation(.easeInOut(duration: 0.15), value: isStagingHovered)

                        VStack(spacing: 6) {
                            Text("No files staged")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("Click here or use ⌘O to add files")
                                .font(.system(size: 13))
                                .foregroundColor(isStagingPressed ? .blue : .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // File List
                    StagingFileListView(manager: manager)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                Group {
                    if isStagingPressed {
                        Color.blue.opacity(0.15)
                    } else if isStagingHovered {
                        Color.gray.opacity(0.05)
                    } else {
                        Color.clear
                    }
                }
            )
            .scaleEffect(isStagingPressed ? 0.998 : 1.0)
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
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                return handleFileDrop(providers: providers)
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
    
    var body: some View {
        List(manager.selectedFiles) { f in
            ZStack(alignment: .leading) {
                // Progress bar background
                if let progress = manager.fileProgress[f.id], progress > 0 {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.blue.opacity(0.2))
                            .frame(width: geometry.size.width * progress)
                    }
                } else if let convProgress = manager.conversionProgress[f.id], convProgress > 0 {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.purple.opacity(0.2))
                            .frame(width: geometry.size.width * convProgress)
                    }
                }

                // File info
                HStack {
                    Image(nsImage: getIcon(f.url))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(f.name)
                    Spacer()

                    // Show checkmark, progress, or file info
                    if let completionState = manager.fileCompletionState[f.id] {
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
                    } else if let convProgress = manager.conversionProgress[f.id], convProgress > 0, convProgress < 1.0 {
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
                    } else if let progress = manager.fileProgress[f.id], progress > 0, progress < 1.0 {
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
                        if f.isDirectory {
                            Text("\(f.fileCount) file\(f.fileCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                        } else if let size = getFileSize(f.url) {
                            Text(size)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Remove button
                    HoverableButton(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            manager.removeFile(withId: f.id)
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
            .contextMenu {
                // Remove option
                Button("Remove from Staging") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        manager.removeFile(withId: f.id)
                    }
                }
                
                // Show context menu for OMF/AAF files
                if !f.isDirectory {
                    let ext = f.url.pathExtension.lowercased()
                    if ext == "omf" {
                        Divider()
                        Button("Validate OMF") {
                            manager.omfAafFileToValidate = f.url
                            manager.showOMFAAFValidator = true
                        }
                    } else if ext == "aaf" {
                        Divider()
                        Button("Validate AAF") {
                            manager.omfAafFileToValidate = f.url
                            manager.showOMFAAFValidator = true
                        }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .animation(.easeInOut(duration: 0.3), value: manager.selectedFiles)
        .animation(.easeInOut(duration: 0.2), value: manager.fileProgress)
        .animation(.easeInOut(duration: 0.2), value: manager.conversionProgress)
        .animation(.easeInOut(duration: 0.3), value: manager.fileCompletionState)
    }
    
    private func getIcon(_ url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
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

