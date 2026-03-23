//
//  RestripeView.swift
//  MediaDash
//
//  Main view for restriping: combining picture/video with multiple audio files.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RestripeView: View {
    @StateObject private var config = RestripeConfig()
    @State private var selectedUnassigned: Set<URL> = []
    @State private var selectedPictureURL: URL?
    @State private var selectedAssignmentIds: Set<UUID> = []
    @State private var selectionAnchorId: UUID?
    @State private var isCreating = false
    @State private var statusMessage = ""
    @State private var statusType: StatusType = .info
    @State private var lastOutputPath: String?
    @State private var showRevealButton = false
    @State private var progressCurrent = 0
    @State private var progressTotal = 0
    @State private var progressFilename = ""
    @State private var completedFilenames: [String] = []
    @State private var showFFmpegInstallSheet = false
    @State private var ffmpegAvailable = true
    @State private var showBatchRename = false
    @State private var audioListHeight: CGFloat = 220
    /// Highlights the assignments column when dragging; also pins `onDrop` to the `[NSItemProvider]` perform overload (not `DropDelegate`).
    @State private var assignmentsColumnDropTargeted = false

    private enum StatusType { case info, success, error }

    private static let videoTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    /// Use [.data] to allow all files; .audio alone can be overly restrictive on some macOS versions
    private static let audioTypes: [UTType] = [.audio, .data]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !ffmpegAvailable { ffmpegBanner }

            VStack(alignment: .leading, spacing: 20) {
                header
                linkingWorkspace
                outputSection
                summaryAndAction
            }
            .padding(24)
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            checkFFmpeg()
            ensureSelectedPicture()
        }
        .onChange(of: config.pictures) { _, _ in
            ensureSelectedPicture()
        }
        .onExitCommand {
            selectedUnassigned = []
            selectedAssignmentIds = []
        }
        .onDeleteCommand {
            if !selectedUnassigned.isEmpty {
                config.unassignedAudio.removeAll { selectedUnassigned.contains($0) }
                selectedUnassigned = []
            }
            if !selectedAssignmentIds.isEmpty {
                config.assignments.removeAll { selectedAssignmentIds.contains($0.id) }
                selectedAssignmentIds = []
            }
        }
        .sheet(isPresented: $showFFmpegInstallSheet) {
            FFmpegInstallSheet { checkFFmpeg() }
        }
        .sheet(isPresented: $showBatchRename) {
            RestripeBatchRenameSheet(
                selectedBasenames: selectedAssignments.map(\.outputBasename),
                outputFormat: config.outputFormat
            ) { newBasenames in
                let selected = selectedAssignments
                for (idx, a) in selected.enumerated() {
                    if let i = config.assignments.firstIndex(where: { $0.id == a.id }),
                       idx < newBasenames.count {
                        config.assignments[i].outputBasename = newBasenames[idx]
                    }
                }
                selectedAssignmentIds = []
            }
        }
    }

    private var selectedAssignments: [RestripeAssignment] {
        config.assignments.filter { selectedAssignmentIds.contains($0.id) }
    }

    private var selectedPictureAssignments: [RestripeAssignment] {
        guard let selectedPictureURL else { return [] }
        return config.assignments(for: selectedPictureURL)
    }

    private var canLinkSelectionToPicture: Bool {
        selectedPictureURL != nil && !selectedUnassigned.isEmpty
    }

    private func ensureSelectedPicture() {
        guard !config.pictures.isEmpty else {
            selectedPictureURL = nil
            return
        }
        if let selectedPictureURL, config.pictures.contains(selectedPictureURL) {
            return
        }
        selectedPictureURL = config.pictures.first
    }

    // MARK: - FFmpeg banner

    private var ffmpegBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("FFmpeg is required")
                    .fontWeight(.medium)
                Text("Install it with one click to enable restriping.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install FFmpeg") { showFFmpegInstallSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.orange.opacity(0.3)).frame(height: 1)
        }
    }

    private func checkFFmpeg() { ffmpegAvailable = RestripeService.resolveFFmpegPath() != nil }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Restriping")
                .font(.title)
                .fontWeight(.bold)
            Text("Use Add in each column or click the dashed area to import. Drag from Finder still works everywhere.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var linkingWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                audioPoolColumn
                picturesColumn
                assignmentsColumn
            }
            Button {
                linkSelectedAudioToSelectedPicture()
            } label: {
                Label("Link selected audio to the chosen picture", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canLinkSelectionToPicture)
        }
    }

    private var audioPoolColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("1. Audio pool")
                    .font(.headline)
                Spacer()
                if !selectedUnassigned.isEmpty {
                    Button("Remove selected", role: .destructive) {
                        config.unassignedAudio.removeAll { selectedUnassigned.contains($0) }
                        selectedUnassigned = []
                    }
                }
                Button(action: addAudioFromPicker) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            UnassignedAudioList(
                urls: config.unassignedAudio,
                selected: $selectedUnassigned,
                height: $audioListHeight,
                onAdd: addAudioFromPicker,
                onDrop: { urls in linkDroppedUnassigned(urls) }
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func addAudioFromPicker() {
        FilePickerService.chooseFiles(allowedTypes: Self.audioTypes, allowsMultiple: true) { urls in
            let existingPaths = Set(config.unassignedAudio.map(\.path) + config.assignments.map { $0.audioURL.path })
            let newUrls = urls.filter { !existingPaths.contains($0.path) }
            if !newUrls.isEmpty {
                config.unassignedAudio = config.unassignedAudio + newUrls
            }
        }
    }

    private func addVideosFromPicker() {
        FilePickerService.chooseFiles(allowedTypes: Self.videoTypes, allowsMultiple: true) { urls in
            let existingPaths = Set(config.pictures.map(\.path))
            let newUrls = urls.filter { !existingPaths.contains($0.path) }
            if !newUrls.isEmpty {
                config.pictures.append(contentsOf: newUrls)
            }
        }
    }

    private var picturesColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("2. Pictures / Videos")
                    .font(.headline)
                Spacer()
                Button(action: addVideosFromPicker) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    picturesColumnRows
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var picturesColumnRows: some View {
        if config.pictures.isEmpty {
            picturesEmptyDropZone
                .frame(maxWidth: .infinity)
        } else {
            ForEach(config.pictures, id: \.self) { pictureURL in
                pictureSelectionRow(for: pictureURL)
            }
        }
    }

    private func pictureSelectionRow(for pictureURL: URL) -> some View {
        let linked = config.assignments(for: pictureURL).count
        return PictureSelectionRow(
            url: pictureURL,
            isSelected: selectedPictureURL == pictureURL,
            linkedCount: linked,
            onSelect: {
                selectedPictureURL = pictureURL
                selectedAssignmentIds = []
            },
            onDropAudio: { urls in
                selectedPictureURL = pictureURL
                linkAudio(urls, to: pictureURL)
            },
            onRemove: { removePicture(pictureURL) }
        )
    }

    private func removePicture(_ pictureURL: URL) {
        config.pictures.removeAll { $0 == pictureURL }
        let removedAssignments = config.assignments.filter { $0.pictureURL == pictureURL }
        config.assignments.removeAll { $0.pictureURL == pictureURL }
        for assignment in removedAssignments {
            if !config.unassignedAudio.contains(where: { $0.path == assignment.audioURL.path }) {
                config.unassignedAudio.append(assignment.audioURL)
            }
        }
        selectedAssignmentIds = []
        ensureSelectedPicture()
    }

    private var assignmentsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            assignmentsColumnHeader
            assignmentsColumnBody
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var assignmentsColumnHeader: some View {
        HStack {
            Text("3. Linked to selected picture")
                .font(.headline)
            Spacer()
            if selectedPictureAssignments.count >= 2 {
                Button("Batch Rename") {
                    let ids = selectedPictureAssignments.map(\.id)
                    let selectedInPicture = Set(ids).intersection(selectedAssignmentIds)
                    selectedAssignmentIds = selectedInPicture.count >= 2 ? selectedInPicture : Set(ids)
                    showBatchRename = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var assignmentsColumnBody: some View {
        if let url = selectedPictureURL {
            selectedPictureAssignmentsPanel(pictureURL: url)
        } else {
            assignmentsColumnEmptyState
        }
    }

    private var assignmentsColumnEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Choose a video in the middle column first. Then you can drop audio here or use Link below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func selectedPictureAssignmentsPanel(pictureURL: URL) -> some View {
        let assignments = config.assignments(for: pictureURL)
        return VStack(alignment: .leading, spacing: 8) {
            Text(pictureURL.lastPathComponent)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if assignments.isEmpty {
                selectedPictureAssignmentsEmptyHint
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        linkedAudioRowsForSelectedPicture(assignments: assignments)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onDrop(
            of: [.fileURL, .url, UTType.json],
            isTargeted: $assignmentsColumnDropTargeted
        ) { providers in
            handleSelectedPictureDrop(providers: providers)
        }
    }

    @ViewBuilder
    private func linkedAudioRowsForSelectedPicture(assignments: [RestripeAssignment]) -> some View {
        ForEach(Array(assignments.enumerated()), id: \.element.id) { index, assignment in
            LinkedAudioRow(
                assignment: assignment,
                config: config,
                outputFormat: config.outputFormat,
                isSelected: selectedAssignmentIds.contains(assignment.id),
                assignmentCount: assignments.count,
                onSelectRow: { handleLinkedAudioSelectionForSelectedPicture(at: index) },
                onRemove: { removeLinkedAssignment(assignment) },
                onBatchRename: { prepareBatchRenameForAssignments(assignments) }
            )
        }
    }

    private func removeLinkedAssignment(_ assignment: RestripeAssignment) {
        config.assignments.removeAll { $0.id == assignment.id }
        if !config.unassignedAudio.contains(where: { $0.path == assignment.audioURL.path }) {
            config.unassignedAudio.append(assignment.audioURL)
        }
        selectedAssignmentIds.remove(assignment.id)
    }

    private func prepareBatchRenameForAssignments(_ assignments: [RestripeAssignment]) {
        let ids = assignments.map(\.id)
        let selectedInPicture = Set(ids).intersection(selectedAssignmentIds)
        selectedAssignmentIds = selectedInPicture.count >= 2 ? selectedInPicture : Set(ids)
        showBatchRename = true
    }

    private var selectedPictureAssignmentsEmptyHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.left.and.right.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Drag audio here or use “Link selected audio” below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func linkSelectedAudioToSelectedPicture() {
        guard let selectedPictureURL, !selectedUnassigned.isEmpty else { return }
        let urls = config.unassignedAudio.filter { selectedUnassigned.contains($0) }
        linkAudio(urls, to: selectedPictureURL)
        selectedUnassigned = []
    }

    private func handleSelectedPictureDrop(providers: [NSItemProvider]) -> Bool {
        guard let selectedPictureURL else { return false }
        Task {
            let urls = await loadAudioURLs(from: providers)
            await MainActor.run {
                if !urls.isEmpty {
                    linkAudio(urls, to: selectedPictureURL)
                }
            }
        }
        return true
    }

    private func loadAudioURLs(from providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                let payload = await withCheckedContinuation { (cont: CheckedContinuation<AudioDropPayload?, Never>) in
                    _ = p.loadTransferable(type: AudioDropPayload.self) { r in
                        cont.resume(returning: (try? r.get()))
                    }
                }
                if let payload {
                    result.append(contentsOf: payload.urls)
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let item = await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        cont.resume(returning: item)
                    }
                }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    result.append(url)
                }
            }
        }
        return result
    }

    private func handleLinkedAudioSelectionForSelectedPicture(at index: Int) {
        let ids = selectedPictureAssignments.map(\.id)
        guard index < ids.count else { return }
        let clickedId = ids[index]
        let flags = NSEvent.modifierFlags

        if flags.contains(.shift) {
            if let anchor = selectionAnchorId, let anchorIdx = ids.firstIndex(of: anchor) {
                let lo = min(anchorIdx, index)
                let hi = max(anchorIdx, index)
                let range = Set(ids[lo...hi])
                selectedAssignmentIds.formUnion(range)
            } else {
                selectedAssignmentIds = [clickedId]
                selectionAnchorId = clickedId
            }
        } else if flags.contains(.command) {
            if selectedAssignmentIds.contains(clickedId) {
                selectedAssignmentIds.remove(clickedId)
            } else {
                selectedAssignmentIds.insert(clickedId)
            }
        } else {
            selectedAssignmentIds = [clickedId]
            selectionAnchorId = clickedId
        }
    }

    @State private var picturesEmptyZoneTargeted = false

    private var picturesEmptyDropZone: some View {
        Button(action: addVideosFromPicker) {
            VStack(spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Add videos or drag files here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(picturesEmptyZoneTargeted ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .onDrop(of: [.fileURL, .url], isTargeted: $picturesEmptyZoneTargeted) { providers in
            Task {
                let urls = await loadVideoURLs(from: providers)
                await MainActor.run {
                    mergeVideoURLs(urls)
                }
            }
            return true
        }
    }

    private func mergeVideoURLs(_ urls: [URL]) {
        let existingPaths = Set(config.pictures.map(\.path))
        let newUrls = urls.filter { !existingPaths.contains($0.path) }
        if !newUrls.isEmpty {
            config.pictures.append(contentsOf: newUrls)
        }
    }

    private func loadVideoURLs(from providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for p in providers {
            guard p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            let item = await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    cont.resume(returning: item)
                }
            }
            if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                let ext = (u.pathExtension as NSString).lowercased
                if ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext) {
                    result.append(u)
                }
            }
        }
        return result
    }

    private func linkAudio(_ urls: [URL], to pictureURL: URL) {
        for audioURL in urls {
            guard !config.assignments.contains(where: { $0.audioURL == audioURL }) else { continue }
            config.unassignedAudio.removeAll { $0 == audioURL }
            config.assignments.append(RestripeAssignment.make(pictureURL: pictureURL, audioURL: audioURL))
        }
    }

    private func linkDroppedUnassigned(_ urls: [URL]) {
        var existingPaths = Set(config.unassignedAudio.map(\.path))
        for url in urls {
            config.assignments.removeAll { $0.audioURL.path == url.path }
            if !existingPaths.contains(url.path) {
                config.unassignedAudio = config.unassignedAudio + [url]
                existingPaths.insert(url.path)
            }
        }
    }

    // MARK: - Output section

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("4. Output")
                .font(.headline)
            HStack(spacing: 8) {
                Picker("Format", selection: Binding(
                    get: { config.outputFormat },
                    set: { config.outputFormat = $0 }
                )) {
                    ForEach(RestripeConfig.OutputFormat.allCases, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            HStack(spacing: 12) {
                Text("Audio gain")
                    .font(.subheadline)
                Slider(value: Binding(
                    get: { config.audioGainDB },
                    set: { config.audioGainDB = $0 }
                ), in: -12...12, step: 0.5)
                .frame(maxWidth: 200)
                Text(config.audioGainDB == 0 ? "0 dB" : String(format: "%+.1f dB", config.audioGainDB))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            if let url = config.outputFolder {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(url.path)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change") {
                        FilePickerService.chooseFolder { if let u = $0 { config.outputFolder = u } }
                    }
                    Button("Remove", role: .destructive) { config.outputFolder = nil }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Button {
                    FilePickerService.chooseFolder { if let u = $0 { config.outputFolder = u } }
                } label: {
                    Label("Choose output folder…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                        .padding(16)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Summary and action

    private var canRestripe: Bool {
        !config.assignments.isEmpty &&
        config.outputFolder != nil &&
        ffmpegAvailable &&
        !isCreating
    }

    private var summaryAndAction: some View {
        VStack(alignment: .leading, spacing: 16) {
            if canRestripe && !isCreating {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Will create \(config.assignments.count) file(s)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if let folder = config.outputFolder {
                        Text("in \(folder.path)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isCreating {
                progressBlock
            } else {
                Button { runRestripe() } label: {
                    Label("Restripe", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canRestripe)
            }

            if !statusMessage.isEmpty { statusBlock }
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Processing \(progressCurrent) of \(progressTotal)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if !progressFilename.isEmpty {
                        Text(progressFilename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !completedFilenames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(completedFilenames, id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(statusMessage).font(.subheadline)
                if showRevealButton, let path = lastOutputPath {
                    Button("Reveal in Finder") {
                        let dir = (path as NSString).deletingLastPathComponent
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: dir)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(statusColor.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusIcon: String {
        switch statusType {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch statusType {
        case .info: return .blue
        case .success: return .green
        case .error: return .orange
        }
    }

    // MARK: - Run

    private func runRestripe() {
        guard let outputFolder = config.outputFolder, !config.assignments.isEmpty else { return }

        isCreating = true
        showRevealButton = false
        statusMessage = ""
        let groups = Dictionary(grouping: config.assignments, by: { $0.pictureURL })
        let flatItems = config.assignments
        progressTotal = flatItems.count
        progressCurrent = 0
        progressFilename = ""
        completedFilenames = []

        Task {
            var processedSoFar = 0
            for (pictureURL, items) in groups {
                let subset = items.map { (audio: $0.audioURL, outputBasename: $0.outputBasename) }
                do {
                    _ = try await RestripeService.restripe(
                        picture: pictureURL,
                        items: subset,
                        outputFolder: outputFolder,
                        outputFormat: config.outputFormat,
                        audioGainDB: config.audioGainDB
                    ) { current, total, filename in
                        await MainActor.run {
                            progressCurrent = processedSoFar + current
                            progressTotal = flatItems.count
                            progressFilename = filename
                            completedFilenames = flatItems.prefix(max(0, progressCurrent - 1))
                                .map { "\($0.outputBasename).\(config.outputFormat.fileExtension)" }
                        }
                    }
                    processedSoFar += subset.count
                } catch {
                    let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    await MainActor.run {
                        isCreating = false
                        statusType = .error
                        if let err = error as? RestripeError, case .ffmpegNotFound = err {
                            showFFmpegInstallSheet = true
                            ffmpegAvailable = false
                            statusMessage = "FFmpeg is required."
                        } else {
                            statusMessage = desc
                        }
                    }
                    return
                }
            }
            await MainActor.run {
                isCreating = false
                completedFilenames = flatItems.map { "\($0.outputBasename).\(config.outputFormat.fileExtension)" }
                statusType = .success
                statusMessage = "Done! Created \(flatItems.count) file(s)."
                if let first = flatItems.first {
                    lastOutputPath = outputFolder.appendingPathComponent("\(first.outputBasename).\(config.outputFormat.fileExtension)").path
                    showRevealButton = true
                }
            }
        }
    }
}

// MARK: - Picture card (drop zone + linked audio)

private struct PictureCard: View {
    let url: URL
    @ObservedObject var config: RestripeConfig
    let outputFormat: RestripeConfig.OutputFormat
    @Binding var selectedIds: Set<UUID>
    @Binding var selectionAnchorId: UUID?
    let onRemovePicture: () -> Void
    let onDropAudio: ([URL]) -> Void
    let onBatchRename: ([UUID]) -> Void

    @State private var isTargeted = false

    private var assignments: [RestripeAssignment] {
        config.assignments(for: url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay { Image(systemName: "film").font(.caption) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 100, alignment: .leading)
                Spacer()
                Button("Remove", role: .destructive) { onRemovePicture() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .help(url.path)
            .padding(8)
            .background(isTargeted ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onDrop(of: [.fileURL, .url, UTType.json], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }

            ForEach(Array(assignments.enumerated()), id: \.element.id) { index, a in
                LinkedAudioRow(
                    assignment: a,
                    config: config,
                    outputFormat: outputFormat,
                    isSelected: selectedIds.contains(a.id),
                    assignmentCount: assignments.count,
                    onSelectRow: { handleLinkedAudioSelection(at: index) },
                    onRemove: { config.assignments.removeAll { $0.id == a.id } },
                    onBatchRename: {
                        let ids = assignments.map(\.id)
                        let selectedInCard = Set(ids).intersection(selectedIds)
                        onBatchRename(selectedInCard.count >= 2 ? Array(selectedInCard) : ids)
                    }
                )
            }

            if assignments.count >= 2 {
                Button("Batch Rename") {
                    let ids = assignments.map(\.id)
                    let selectedInCard = Set(ids).intersection(selectedIds)
                    onBatchRename(selectedInCard.count >= 2 ? Array(selectedInCard) : ids)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .frame(minWidth: 240, maxWidth: 240, minHeight: 120, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func handleLinkedAudioSelection(at index: Int) {
        let ids = assignments.map(\.id)
        guard index < ids.count else { return }
        let clickedId = ids[index]
        let flags = NSEvent.modifierFlags

        if flags.contains(.shift) {
            if let anchor = selectionAnchorId, let anchorIdx = ids.firstIndex(of: anchor) {
                let lo = min(anchorIdx, index)
                let hi = max(anchorIdx, index)
                let range = Set(ids[lo...hi])
                selectedIds.formUnion(range)
            } else {
                selectedIds = [clickedId]
                selectionAnchorId = clickedId
            }
        } else if flags.contains(.command) {
            if selectedIds.contains(clickedId) {
                selectedIds.remove(clickedId)
            } else {
                selectedIds.insert(clickedId)
            }
        } else {
            selectedIds = [clickedId]
            selectionAnchorId = clickedId
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for p in providers {
                if p.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                    let payload = await withCheckedContinuation { (cont: CheckedContinuation<AudioDropPayload?, Never>) in
                        _ = p.loadTransferable(type: AudioDropPayload.self) { r in
                            cont.resume(returning: (try? r.get()))
                        }
                    }
                    if let pl = payload { urls.append(contentsOf: pl.urls) }
                } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let item = await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
                        p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                            cont.resume(returning: item)
                        }
                    }
                    if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(u)
                    }
                }
            }
            await MainActor.run {
                if !urls.isEmpty { onDropAudio(urls) }
            }
        }
        return true
    }
}

private struct PictureSelectionRow: View {
    let url: URL
    let isSelected: Bool
    let linkedCount: Int
    let onSelect: () -> Void
    let onDropAudio: ([URL]) -> Void
    let onRemove: () -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 28, height: 28)
                .overlay { Image(systemName: "film").font(.caption2) }
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(linkedCount) linked")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onSelect() }
        .onDrop(of: [.fileURL, .url, UTType.json], isTargeted: $isTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                        let payload = await withCheckedContinuation { (cont: CheckedContinuation<AudioDropPayload?, Never>) in
                            _ = provider.loadTransferable(type: AudioDropPayload.self) { result in
                                cont.resume(returning: try? result.get())
                            }
                        }
                        if let payload {
                            urls.append(contentsOf: payload.urls)
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let item = await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                                cont.resume(returning: item)
                            }
                        }
                        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            urls.append(url)
                        }
                    }
                }
                await MainActor.run {
                    if !urls.isEmpty {
                        onDropAudio(urls)
                    }
                }
            }
            return true
        }
    }
}

// MARK: - Linked audio row (under a picture)

private struct LinkedAudioRow: View {
    let assignment: RestripeAssignment
    @ObservedObject var config: RestripeConfig
    let outputFormat: RestripeConfig.OutputFormat
    let isSelected: Bool
    let assignmentCount: Int
    let onSelectRow: () -> Void
    let onRemove: () -> Void
    let onBatchRename: () -> Void

    @FocusState private var isNameFocused: Bool

    private var outputBasenameBinding: Binding<String> {
        Binding(
            get: { assignment.outputBasename },
            set: { newVal in
                if let i = config.assignments.firstIndex(where: { $0.id == assignment.id }) {
                    config.assignments[i].outputBasename = newVal
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.purple.opacity(0.15))
                .frame(width: 24, height: 24)
                .overlay { Image(systemName: "waveform").font(.system(size: 8)) }
            VStack(alignment: .leading, spacing: 2) {
                Text(assignment.audioURL.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TextField("Name", text: outputBasenameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($isNameFocused)
            }
            Button("×", role: .destructive) { onRemove() }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(6)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(count: 2) {
            isNameFocused = true
        }
        .onTapGesture(count: 1) {
            if !isNameFocused {
                onSelectRow()
            }
        }
        .contextMenu {
            if assignmentCount >= 2 {
                Button("Batch Rename") { onBatchRename() }
            }
        }
    }
}

// MARK: - Unassigned audio list

private struct UnassignedAudioList: View {
    let urls: [URL]
    @Binding var selected: Set<URL>
    @Binding var height: CGFloat
    let onAdd: () -> Void
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false
    @State private var selectionAnchorIndex: Int?
    private let minHeight: CGFloat = 120
    private let maxHeight: CGFloat = 400

    private func handleUnassignedSelection(at index: Int) {
        guard index < urls.count else { return }
        let url = urls[index]
        var s = selected
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            if let anchor = selectionAnchorIndex {
                let lo = min(anchor, index)
                let hi = max(anchor, index)
                s.formUnion(Set(urls[lo...hi]))
                selected = s
            } else {
                selected = [url]
                selectionAnchorIndex = index
            }
        } else if flags.contains(.command) {
            if s.contains(url) { s.remove(url) }
            else { s.insert(url) }
            selected = s
        } else {
            selected = [url]
            selectionAnchorIndex = index
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if urls.isEmpty {
                    Button(action: onAdd) {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.circle")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("Add audio or drag files here")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                        .background(isTargeted ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                                UnassignedAudioRow(
                                    url: url,
                                    isSelected: selected.contains(url),
                                    onSelect: { handleUnassignedSelection(at: index) },
                                    payload: AudioDropPayload(urls: selected.isEmpty ? [url] : Array(selected))
                                )
                            }
                        }
                    }
                }
            }
            .frame(height: max(0, height - 10))
            .background(
                urls.isEmpty
                    ? Color.clear
                    : (isTargeted ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onDrop(of: [.fileURL, .url, UTType.json], isTargeted: $isTargeted) { providers in
                Task {
                    let urls = await loadURLs(from: providers)
                    await MainActor.run {
                        if !urls.isEmpty { onDrop(urls) }
                    }
                }
                return true
            }
            ResizeHandle(height: $height, minHeight: minHeight, maxHeight: maxHeight)
        }
    }

    private func loadURLs(from providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                let payload = await withCheckedContinuation { (cont: CheckedContinuation<AudioDropPayload?, Never>) in
                    _ = p.loadTransferable(type: AudioDropPayload.self) { r in
                        cont.resume(returning: (try? r.get()))
                    }
                }
                if let pl = payload { result.append(contentsOf: pl.urls) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let item = await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
                    p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        cont.resume(returning: item)
                    }
                }
                if let data = item as? Data, let u = URL(dataRepresentation: data, relativeTo: nil) {
                    result.append(u)
                }
            }
        }
        return result
    }
}

private struct ResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartHeight == nil { dragStartHeight = height }
                        if let start = dragStartHeight {
                            let newHeight = start + value.translation.height
                            height = min(max(newHeight, minHeight), maxHeight)
                        }
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .overlay(alignment: .center) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 36, height: 4)
            }
    }
}

private struct UnassignedAudioRow: View {
    let url: URL
    let isSelected: Bool
    let onSelect: () -> Void
    let payload: AudioDropPayload

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(6)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { onSelect() }
        .draggable(payload)
    }
}
