//
//  SessionPrepElementsSheet.swift
//  MediaDash
//
//  Prep from Calendar: session description by line; drag files onto lines to assign.
//  Lines with files become checklist rows (highlighted/checked). Staging can be grouped by type (visual only).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A single line of the description; becomes a checklist row when files are dropped on it.
struct DescriptionLineRow: Identifiable {
    let id: UUID
    var text: String
    var assignedFileIds: Set<UUID>
}

enum StagingViewMode: String, CaseIterable {
    case byFolder = "By folder"
    case byFileType = "By file type"
    case flat = "Flat list"
    case byAssignedLine = "By description line"
}

enum PrepRightPanelMode: String, CaseIterable {
    case categorize = "Categorize"
    case sessionDescription = "Session description"
}

struct SessionPrepElementsSheet: View {
    let session: DocketInfo
    let asanaService: AsanaService
    @ObservedObject var manager: MediaManager
    @Binding var isPresented: Bool
    
    @State private var descriptionText: String = ""
    @State private var descriptionLines: [DescriptionLineRow] = []
    @State private var stagedFiles: [FileItem] = []
    @State private var stagingViewMode: StagingViewMode = .byFolder
    @State private var prepTreeNodes: [FileTreeNode] = []
    @State private var fileItemCache: [String: FileItem] = [:]
    @State private var flattenedFileList: [FileItem] = []
    @State private var isLoadingNotes = true
    @State private var loadError: String?
    @State private var dragTargetLineId: UUID?
    @State private var expandedLineIds: Set<UUID> = []
    @State private var videoDurations: [UUID: String] = [:]
    @State private var hoveredStagedFileId: UUID?
    @State private var prepRightPanelMode: PrepRightPanelMode = .categorize
    @State private var fileClassificationOverrides: [UUID: String] = [:]
    @State private var selectedStagedFileIds: Set<UUID> = []
    @State private var showExistingPrepSheet = false
    @State private var existingPrepFoldersForSession: [(name: String, path: String)] = []

    private static let videoExtensions = ["mp4", "mov", "avi", "mxf", "m4v", "prores"]

    private var docketFolderName: String {
        let safeJob = session.jobName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(session.number)_\(safeJob)"
    }
    
    private var settings: AppSettings {
        manager.config.settings
    }
    
    /// Category folder name for a file (PICTURE, MUSIC, AAF-OMF, OTHER). For directories, uses first contained file or OTHER.
    private func category(for file: FileItem) -> String {
        if file.isDirectory {
            // Could inspect contents; for simplicity treat as OTHER
            return settings.otherFolderName
        }
        let ext = file.url.pathExtension.lowercased()
        if settings.pictureExtensions.contains(ext) { return settings.pictureFolderName }
        if settings.musicExtensions.contains(ext) { return settings.musicFolderName }
        if settings.aafOmfExtensions.contains(ext) { return settings.aafOmfFolderName }
        return settings.otherFolderName
    }
    
    /// All files recursively from staged items (files only; stable ids via cache). Used for "By file type" and "Flat" and checklist resolution.
    private func updateFlattenedFileList() {
        var list: [FileItem] = []
        for item in stagedFiles {
            if item.isDirectory {
                let urls = MediaLogic.getAllFiles(at: item.url)
                for url in urls {
                    let path = url.path
                    if let cached = fileItemCache[path] {
                        list.append(cached)
                    } else {
                        let fi = FileItem(url: url)
                        fileItemCache[path] = fi
                        list.append(fi)
                    }
                }
            } else {
                let path = item.url.path
                if let cached = fileItemCache[path] {
                    list.append(cached)
                } else {
                    fileItemCache[path] = item
                    list.append(item)
                }
            }
        }
        flattenedFileList = list
    }

    /// All file items that can resolve an assigned id (staged + flattened so inner files work).
    private var allResolvableFileItems: [FileItem] {
        var byId: [UUID: FileItem] = Dictionary(uniqueKeysWithValues: stagedFiles.map { ($0.id, $0) })
        for f in flattenedFileList {
            byId[f.id] = f
        }
        return Array(byId.values)
    }

    /// Group flattened files by category for "By file type" view (no folders, only files).
    private var filesGroupedByType: [(category: String, files: [FileItem])] {
        let groups = Dictionary(grouping: flattenedFileList, by: { category(for: $0) })
        let order = [settings.pictureFolderName, settings.aafOmfFolderName, settings.musicFolderName, settings.otherFolderName]
        return order.compactMap { key in
            guard let list = groups[key], !list.isEmpty else { return nil }
            return (key, list)
        }
            + groups.filter { !order.contains($0.key) }.map { ($0.key, $0.value) }
    }

    /// Group by the description line they're assigned to; fileById includes flattened files so inner-file assigns resolve.
    private var filesGroupedByLine: [(line: DescriptionLineRow, files: [FileItem])] {
        let fileById = Dictionary(uniqueKeysWithValues: allResolvableFileItems.map { ($0.id, $0) })
        return descriptionLines.compactMap { line in
            let files = line.assignedFileIds.compactMap { fileById[$0] }
            guard !files.isEmpty else { return nil }
            return (line, files)
        }
    }

    /// All files currently assigned to any description line (for Slack checklist).
    private var allAssignedFiles: [FileItem] {
        let fileById = Dictionary(uniqueKeysWithValues: allResolvableFileItems.map { ($0.id, $0) })
        return descriptionLines.flatMap { $0.assignedFileIds.compactMap { fileById[$0] } }
    }

    /// Prep checklist text for Slack, populated from assigned files. Updates as user drags files onto lines.
    private var slackChecklistText: String {
        let files = allAssignedFiles
        guard !files.isEmpty else {
            return "\(session.fullName) [@producer]\n- Assign files to description lines to build the checklist."
        }
        let pic = settings.pictureFolderName
        let music = settings.musicFolderName
        let aaf = settings.aafOmfFolderName
        let other = settings.otherFolderName
        var lines: [String] = []
        lines.append("\(session.fullName) [@producer]")
        let byCat = Dictionary(grouping: files.filter { !$0.isDirectory }, by: { category(for: $0) })
        if let videos = byCat[pic], !videos.isEmpty {
            var durationCounts: [String: Int] = [:]
            for f in videos {
                let d = videoDurations[f.id] ?? "?"
                durationCounts[d, default: 0] += 1
            }
            let parts = durationCounts.sorted { ($0.key == "?") ? false : (($1.key == "?") ? true : $0.key < $1.key) }.map { "\($0.value) x \($0.key)" }
            lines.append("- \(parts.joined(separator: ", ")) converted & prepped")
        }
        if let aafFiles = byCat[aaf], !aafFiles.isEmpty {
            lines.append("- AAFs or OMFs prepped")
        }
        if let otherFiles = byCat[other], !otherFiles.isEmpty {
            lines.append("- SFX folder ready [@sound designer]")
        }
        if let musicFiles = byCat[music], !musicFiles.isEmpty {
            lines.append("- Music prepped")
            for f in musicFiles.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
                lines.append("     - \(f.displayName)")
            }
        }
        if lines.count == 1 {
            lines.append("- (Assign files to description lines to build the checklist)")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            loadDescriptionFromAsana()
            updatePrepTreeNodes()
            updateFlattenedFileList()
        }
        .onChange(of: stagedFiles) { _, _ in
            updatePrepTreeNodes()
            updateFlattenedFileList()
        }
        .onChange(of: stagingViewMode) { _, _ in
            updatePrepTreeNodes()
        }
        .sheet(isPresented: $showExistingPrepSheet) {
            ExistingPrepFolderPickerSheet(
                existingFolders: existingPrepFoldersForSession,
                onSelectExisting: { path in
                    doRunPrep(existingFolderName: path)
                },
                onCreateNew: {
                    doRunPrep(existingFolderName: nil)
                },
                onCancel: {
                    showExistingPrepSheet = false
                }
            )
            .compactSheetContent()
            .sheetBorder()
        }
    }

    private func updatePrepTreeNodes() {
        prepTreeNodes = stagedFiles.map { FileTreeNode(file: $0) }
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prep from Calendar")
                    .font(.title2)
                Text(session.fullName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("\(stagedFiles.count) file\(stagedFiles.count == 1 ? "" : "s") staged")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
    
    private var content: some View {
        HStack(spacing: 0) {
            stagedFilesPanel
            Divider()
            rightPanel
        }
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $prepRightPanelMode) {
                ForEach(PrepRightPanelMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if prepRightPanelMode == .categorize {
                categorizePanel
            } else {
                descriptionPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var standardClassificationNames: [String] {
        [settings.pictureFolderName, settings.aafOmfFolderName, settings.musicFolderName, "STINGS", "VO REFS", "MNEMONIC", settings.otherFolderName]
    }

    private var categorizePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag files from the left to classify. Others are auto-classified by type.")
                .font(.caption)
                .foregroundColor(.secondary)
            List {
                ForEach(standardClassificationNames, id: \.self) { classification in
                    categorizeDropRow(classification: classification)
                }
            }
            .listStyle(.inset)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func categorizeDropRow(classification: String) -> some View {
        let fileCount = flattenedFileList.filter { file in
            let cat = fileClassificationOverrides[stagedFileIdFor(file)] ?? category(for: file)
            return cat == classification
        }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(classification)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let string = obj as? String else { return }
                let uuids = string.split(separator: ",").compactMap { UUID(uuidString: String($0.trimmingCharacters(in: .whitespaces))) }
                DispatchQueue.main.async {
                    for uuid in uuids {
                        let rootId = rootIdForStaged(fileId: uuid)
                        fileClassificationOverrides[rootId] = classification
                    }
                }
            }
            return true
        }
    }

    private func stagedFileIdFor(_ file: FileItem) -> UUID {
        if stagedFiles.contains(where: { $0.id == file.id }) { return file.id }
        for root in stagedFiles where file.url.path.hasPrefix(root.url.path + "/") || file.url == root.url {
            return root.id
        }
        return file.id
    }

    private func rootIdForStaged(fileId: UUID) -> UUID {
        guard let file = allResolvableFileItems.first(where: { $0.id == fileId }) else { return fileId }
        return stagedFileIdFor(file)
    }
    
    private var stagedFilesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Staged Files")
                    .font(.headline)
                Spacer()
                Picker("", selection: $stagingViewMode) {
                    ForEach(StagingViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                Button("Add Files…") {
                    addFiles()
                }
            }
            
            Text("Switch view to see files by folder, by type, flat, or by description line. Drag files onto description lines to assign.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            ZStack {
                if stagedFiles.isEmpty {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Drop files or click Add Files")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    stagingFileList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url = url else { return }
                        DispatchQueue.main.async {
                            addFileURL(url)
                        }
                    }
                }
                return true
            }
        }
        .padding()
        .frame(minWidth: 320, idealWidth: 380)
    }
    
    @ViewBuilder
    private var stagingFileList: some View {
        switch stagingViewMode {
        case .byFolder:
            List(selection: $selectedStagedFileIds) {
                ForEach(prepTreeNodes) { node in
                    PrepTreeNodeView(
                        node: node,
                        stagedFileIds: Set(stagedFiles.map(\.id)),
                        selectedStagedFileIds: $selectedStagedFileIds,
                        rowContent: stagingFileRow
                    )
                    .tag(node.file.id)
                }
            }
            .listStyle(.inset)
        case .byFileType:
            List(selection: $selectedStagedFileIds) {
                ForEach(filesGroupedByType, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.files) { file in
                            stagingFileRow(file)
                                .tag(file.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
        case .flat:
            List(selection: $selectedStagedFileIds) {
                ForEach(flattenedFileList) { file in
                    stagingFileRow(file)
                        .tag(file.id)
                }
            }
            .listStyle(.inset)
        case .byAssignedLine:
            List(selection: $selectedStagedFileIds) {
                ForEach(filesGroupedByLine, id: \.line.id) { group in
                    Section {
                        ForEach(group.files) { file in
                            stagingFileRow(file)
                                .tag(file.id)
                        }
                    } header: {
                        Text(group.line.text)
                            .lineLimit(1)
                            .font(.caption)
                    }
                }
                let unassigned = allResolvableFileItems.filter { file in
                    !descriptionLines.contains(where: { $0.assignedFileIds.contains(file.id) })
                }
                if !unassigned.isEmpty {
                    Section("Unassigned") {
                        ForEach(unassigned) { file in
                            stagingFileRow(file)
                                .tag(file.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
    
    private func isFileAssignedToPrep(_ fileId: UUID) -> Bool {
        descriptionLines.contains(where: { $0.assignedFileIds.contains(fileId) })
    }

    private func stagingFileRow(_ file: FileItem) -> some View {
        let isVideo = !file.isDirectory && Self.videoExtensions.contains(file.url.pathExtension.lowercased())
        let isHovered = hoveredStagedFileId == file.id
        let isAssigned = isFileAssignedToPrep(file.id)
        let rootId = stagedFileIdFor(file)
        let displayCategory = fileClassificationOverrides[rootId] ?? category(for: file)
        return HStack(alignment: .center, spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let size = file.formattedSize {
                        Text(size)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    if file.isDirectory {
                        Text("\(file.fileCount) files")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Text("→ \(displayCategory)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if isVideo {
                        if let duration = videoDurations[file.id] {
                            Text(duration)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        } else {
                            Text("…")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    if isAssigned {
                        Text("prepped")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
        }
        .opacity(isAssigned ? 0.55 : 1)
        .foregroundColor(isAssigned ? .secondary : .primary)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredStagedFileId = hovering ? file.id : nil
            if hovering {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .task(id: file.id) {
            guard isVideo, videoDurations[file.id] == nil else { return }
            guard let seconds = await MediaLogic.getVideoDuration(file.url) else { return }
            let formatted = MediaLogic.formatDuration(seconds)
            await MainActor.run {
                videoDurations[file.id] = formatted
            }
        }
        .onDrag {
            NSItemProvider(object: file.id.uuidString as NSString)
        }
        .help(isAssigned ? "Assigned to a line (expand the line and click ✕ to unassign)" : "Drag onto a description line to assign")
    }
    
    private var descriptionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Session description")
                        .font(.headline)
                    Spacer()
                    if isLoadingNotes {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }
                if let err = loadError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("Drag files from the left onto a line to assign. Lines with files become checklist items.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if descriptionLines.isEmpty && !isLoadingNotes {
                    Text("No description for this session, or task could not be loaded.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(descriptionLines) { line in
                                descriptionLineRow(line)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .cornerRadius(6)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)

            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Prep checklist for Slack")
                        .font(.headline)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(slackChecklistText, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                ScrollView {
                    Text(slackChecklistText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
                .frame(height: 120)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .cornerRadius(6)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isDragTarget(_ lineId: UUID) -> Bool {
        dragTargetLineId == lineId
    }

    private func descriptionLineRow(_ line: DescriptionLineRow) -> some View {
        let hasFiles = !line.assignedFileIds.isEmpty
        let isExpanded = expandedLineIds.contains(line.id)
        let isHighlighted = isDragTarget(line.id)
        let fileById = Dictionary(uniqueKeysWithValues: allResolvableFileItems.map { ($0.id, $0) })
        let assignedFiles = line.assignedFileIds.compactMap { fileById[$0] }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if hasFiles {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 14, alignment: .leading)
                if hasFiles {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                }
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                if hasFiles {
                    Text("\(line.assignedFileIds.count)")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .cornerRadius(4)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(backgroundForLine(hasFiles: hasFiles, isHighlighted: isHighlighted))
            .cornerRadius(4)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasFiles {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if expandedLineIds.contains(line.id) {
                            expandedLineIds.remove(line.id)
                        } else {
                            expandedLineIds.insert(line.id)
                        }
                    }
                }
            }
            .onDrop(of: [.text], isTargeted: Binding(
                get: { isDragTarget(line.id) },
                set: { targeted in
                    if targeted {
                        dragTargetLineId = line.id
                    } else if dragTargetLineId == line.id {
                        dragTargetLineId = nil
                    }
                }
            )) { providers in
                dragTargetLineId = nil
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let uuidString = obj as? String, let fileId = UUID(uuidString: uuidString) else { return }
                    DispatchQueue.main.async {
                        assignFile(fileId, toLineId: line.id)
                    }
                }
                return true
            }

            if hasFiles && isExpanded && !assignedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(assignedFiles) { file in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                .resizable()
                                .frame(width: 14, height: 14)
                            Text(file.displayName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                removeFile(file.id, fromLineId: line.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                    .help("Remove from this line")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .padding(.leading, 12)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .cornerRadius(4)
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 6)
            }
        }
        .contentShape(Rectangle())
    }

    private func backgroundForLine(hasFiles: Bool, isHighlighted: Bool) -> Color {
        if isHighlighted {
            return Color.accentColor.opacity(0.25)
        }
        if hasFiles {
            return Color.accentColor.opacity(0.12)
        }
        return Color.clear
    }

    private func removeFile(_ fileId: UUID, fromLineId lineId: UUID) {
        guard let index = descriptionLines.firstIndex(where: { $0.id == lineId }) else { return }
        descriptionLines[index].assignedFileIds.remove(fileId)
    }
    
    private var footer: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            let assignedCount = descriptionLines.reduce(0) { $0 + $1.assignedFileIds.count }
            if assignedCount > 0 {
                Text("\(assignedCount) file\(assignedCount == 1 ? "" : "s") on description lines")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button("Run Prep") {
                runPrep()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(stagedFiles.isEmpty)
        }
        .padding()
    }
    
    // MARK: - Actions
    
    private func loadDescriptionFromAsana() {
        guard let taskGid = session.taskGid else {
            loadError = "No session task ID"
            isLoadingNotes = false
            return
        }
        isLoadingNotes = true
        loadError = nil
        Task {
            do {
                let task = try await asanaService.fetchTask(taskGid: taskGid)
                await MainActor.run {
                    descriptionText = effectiveDescription(from: task)
                    rebuildDescriptionLines()
                    isLoadingNotes = false
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoadingNotes = false
                }
            }
        }
    }
    
    /// Prefer plain-text notes; fall back to stripping HTML from html_notes so we always show the task description.
    private func effectiveDescription(from task: AsanaTask) -> String {
        if let notes = task.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return notes
        }
        if let html = task.html_notes, !html.isEmpty {
            return stripHTMLFromAsana(html)
        }
        return ""
    }

    private func stripHTMLFromAsana(_ html: String) -> String {
        var text = html
        if let scriptRegex = try? NSRegularExpression(pattern: #"<script[^>]*>.*?</script>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = scriptRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if let styleRegex = try? NSRegularExpression(pattern: #"<style[^>]*>.*?</style>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = styleRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rebuildDescriptionLines() {
        let lines = descriptionText
            .components(separatedBy: .newlines)
        descriptionLines = lines.enumerated().map { _, raw in
            DescriptionLineRow(
                id: UUID(),
                text: raw.trimmingCharacters(in: .whitespaces),
                assignedFileIds: []
            )
        }
    }
    
    private func assignFile(_ fileId: UUID, toLineId lineId: UUID) {
        guard let index = descriptionLines.firstIndex(where: { $0.id == lineId }) else { return }
        descriptionLines[index].assignedFileIds.insert(fileId)
    }
    
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addFileURL(url)
        }
    }
    
    private func addFileURL(_ url: URL) {
        let item = FileItem(url: url)
        if !stagedFiles.contains(where: { $0.url == item.url }) {
            stagedFiles.append(item)
        }
    }
    
    private func runPrep() {
        let sessionDocket = docketFolderName
        let docketNumber = manager.config.namingService.parseDocket(sessionDocket).docketNumber
        Task {
            let folders = MediaLogic.existingPrepFolders(docketNumber: docketNumber, config: manager.config)
            await MainActor.run {
                if !folders.isEmpty {
                    existingPrepFoldersForSession = folders
                    showExistingPrepSheet = true
                } else {
                    doRunPrep(existingFolderName: nil)
                }
            }
        }
    }

    private func doRunPrep(existingFolderName: String?) {
        let sessionDocket = docketFolderName
        let items: [PrepChecklistItem] = descriptionLines
            .filter { !$0.assignedFileIds.isEmpty }
            .map { line in
                PrepChecklistItem(
                    id: line.id,
                    title: line.text.isEmpty ? "Unnamed" : line.text,
                    assignedFileIds: line.assignedFileIds
                )
            }
        if !items.isEmpty {
            manager.pendingPrepChecklistSession = PrepChecklistSession(
                docket: sessionDocket,
                items: items,
                rawChecklistText: descriptionText
            )
        } else {
            manager.pendingPrepChecklistSession = nil
        }
        manager.pendingPrepFileOverrides = fileClassificationOverrides.isEmpty ? nil : fileClassificationOverrides
        manager.pendingPrepAllFileItemsForChecklist = allResolvableFileItems
        manager.selectedFiles = stagedFiles
        showExistingPrepSheet = false
        isPresented = false
        let calendar = Calendar.current
        let prepDate = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        manager.runJob(
            type: .prep,
            docket: sessionDocket,
            wpDate: Date(),
            prepDate: prepDate,
            existingPrepFolderName: existingFolderName
        )
    }
}

// MARK: - Prep staging tree (folder navigation)

struct PrepTreeNodeView<RowContent: View>: View {
    @ObservedObject var node: FileTreeNode
    let stagedFileIds: Set<UUID>
    @Binding var selectedStagedFileIds: Set<UUID>
    @ViewBuilder let rowContent: (FileItem) -> RowContent

    var body: some View {
        if node.file.isDirectory {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                ForEach(node.children) { childNode in
                    PrepTreeNodeView(
                        node: childNode,
                        stagedFileIds: stagedFileIds,
                        selectedStagedFileIds: $selectedStagedFileIds,
                        rowContent: rowContent
                    )
                    .tag(childNode.file.id)
                }
            } label: {
                rowLabel
                    .onTapGesture(count: 2) {
                        node.isExpanded.toggle()
                    }
            }
            .onChange(of: node.isExpanded) { _, isExpanded in
                if isExpanded && !node.hasLoadedChildren {
                    node.loadChildrenIfNeeded()
                }
            }
            .tag(node.file.id)
        } else {
            rowLabel
                .tag(node.file.id)
        }
    }

    @ViewBuilder
    private var rowLabel: some View {
        if stagedFileIds.contains(node.file.id) {
            rowContent(node.file)
                .contentShape(Rectangle())
                .onDrag {
                    let idsToDrag: [UUID] = selectedStagedFileIds.contains(node.file.id) && selectedStagedFileIds.count > 1
                        ? Array(selectedStagedFileIds)
                        : [node.file.id]
                    let payload = idsToDrag.map(\.uuidString).joined(separator: ",")
                    return NSItemProvider(object: payload as NSString)
                }
        } else {
            rowContent(node.file)
                .contentShape(Rectangle())
        }
    }
}
