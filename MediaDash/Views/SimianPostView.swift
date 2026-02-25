//
//  SimianPostView.swift
//  MediaDash
//
//  Post to Simian: search projects, navigate folders, choose local folder and post.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SimianPostView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var manager: MediaManager
    @StateObject private var simianService = SimianService()

    @State private var searchText = ""
    @State private var allProjects: [SimianProject] = []
    @State private var projectInfos: [String: SimianProjectInfo] = [:]
    @State private var projectSortOrder: ProjectSortOrder = .nameAsc
    @State private var isLoadingProjectInfos = false
    @State private var isLoadingProjects = false
    @State private var projectLoadError: String?
    @State private var selectedProjectId: String?
    @State private var selectedProjectName: String?

    // Folder navigation: (folderId, name); empty = project root
    @State private var folderBreadcrumb: [(id: String, name: String)] = []
    @State private var currentFolders: [SimianFolder] = []
    @State private var isLoadingFolders = false
    @State private var selectedDestinationFolderId: String? = nil // nil = project root
    @State private var selectedDestinationPath: String? = nil // e.g. "01_Delivery / 02_Work Picture"

    // Tree view: expandable folders (lazy load children on expand)
    @State private var expandedFolderIds: Set<String> = []
    @State private var folderChildrenCache: [String: [SimianFolder]] = [:]
    @State private var folderFilesCache: [String: [SimianFile]] = [:]
    @State private var loadingFolderIds: Set<String> = []

    @State private var localFolderURL: URL?
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var isUploading = false
    @State private var uploadCurrent = 0
    @State private var uploadTotal = 0
    @State private var uploadFileName = ""

    // Rename sheet: folder or file
    @State private var showRenameSheet = false
    @State private var renameIsFolder = true
    @State private var renameItemId = ""
    @State private var renameParentFolderId: String?
    @State private var renameCurrentName = ""
    @State private var renameNewName = ""

    // Delete confirmation: folder or file
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteIsFolder = true
    @State private var pendingDeleteItemId = ""
    @State private var pendingDeleteItemName = ""
    @State private var pendingDeleteParentFolderId: String?

    // New folder: parent folder id (nil = project root)
    @State private var showNewFolderSheet = false
    @State private var newFolderParentId: String?
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var newFolderError: String?

    /// Keyboard focus in folder tree: 0 = project root, 1..<count = flatTreeList indices. Nil when in project list or tree empty.
    @State private var keyboardFocusTreeIndex: Int?

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    private var filteredProjects: [SimianProject] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let projects = term.isEmpty ? allProjects : allProjects.filter { $0.name.lowercased().contains(term) }
        switch projectSortOrder {
        case .nameAsc:
            return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc:
            return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .lastEditedNewest:
            return projects.sorted { a, b in
                let dateA = projectInfos[a.id]?.dateValue(for: .lastAccess) ?? .distantPast
                let dateB = projectInfos[b.id]?.dateValue(for: .lastAccess) ?? .distantPast
                return dateA > dateB
            }
        case .lastEditedOldest:
            return projects.sorted { a, b in
                let dateA = projectInfos[a.id]?.dateValue(for: .lastAccess) ?? .distantPast
                let dateB = projectInfos[b.id]?.dateValue(for: .lastAccess) ?? .distantPast
                return dateA < dateB
            }
        }
    }

    private var currentParentFolderId: String? {
        folderBreadcrumb.last?.id
    }

    private var hasNothingToUpload: Bool {
        if !manager.selectedFiles.isEmpty { return false }
        guard let url = localFolderURL else { return true }
        return countFiles(in: url) == 0
    }

    private var destinationSummary: String {
        guard let name = selectedProjectName else { return "" }
        if selectedDestinationFolderId == nil {
            return "\(name) (root)"
        }
        if let path = selectedDestinationPath, !path.isEmpty {
            return "\(name) / \(path)"
        }
        return "\(name) (selected folder)"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let err = projectLoadError, allProjects.isEmpty {
                unavailableView(message: err)
            } else {
                if let projectName = selectedProjectName {
                    projectNameBarView(projectName: projectName)
                } else {
                    searchBarView
                }
                Divider()

                if let projectId = selectedProjectId, let projectName = selectedProjectName {
                    folderBrowserView(projectId: projectId, projectName: projectName)
                } else {
                    projectListView
                }

                Divider()
                destinationAndPostView
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers: providers, destination: nil)
        }
        .onAppear {
            updateSimianServiceConfiguration()
            loadProjects()
            isSearchFocused = true
        }
        .onChange(of: settingsManager.currentSettings.simianAPIBaseURL) { _, _ in
            updateSimianServiceConfiguration()
        }
        .sheet(isPresented: $showRenameSheet) {
            renameSheet
        }
        .sheet(isPresented: $showNewFolderSheet) {
            newFolderSheet
        }
        .alert("Remove from Simian?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { performPendingDelete() }
        } message: {
            let name = pendingDeleteItemName.isEmpty ? (pendingDeleteIsFolder ? "this folder" : "this file") : pendingDeleteItemName
            Text(pendingDeleteIsFolder
                 ? "“\(name)” and its contents will be removed from Simian. This cannot be undone."
                 : "“\(name)” will be removed from Simian. This cannot be undone.")
        }
        .onKeyPress(.upArrow) { handleKeyUp() }
        .onKeyPress(.downArrow) { handleKeyDown() }
        .onKeyPress(.leftArrow) { handleKeyLeft() }
        .onKeyPress(.rightArrow) { handleKeyRight() }
        .onKeyPress(.return) { handleKeyReturn() }
        .onKeyPress(.space) { handleKeyReturn() }
        .onKeyPress(.escape) { handleKeyEscape() }
        .keyboardNavigationHandler(handleKey: { event in
            let keyCode = Int(event.keyCode)
            let result: KeyPress.Result
            switch keyCode {
            case 126: result = handleKeyUp()
            case 125: result = handleKeyDown()
            case 123: result = handleKeyLeft()
            case 124: result = handleKeyRight()
            case 36: result = handleKeyReturn()
            case 49: result = handleKeyReturn()
            case 53: result = handleKeyEscape()
            default: result = .ignored
            }
            return result == .handled
        })
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(renameIsFolder ? "Rename Folder" : "Rename File")
                .font(.headline)
            TextField("Name", text: $renameNewName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showRenameSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { submitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameNewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { renameNewName = renameCurrentName }
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder")
                .font(.headline)
            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
            if let err = newFolderError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    showNewFolderSheet = false
                    newFolderError = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") { submitNewFolder() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreatingFolder)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear {
            newFolderName = ""
            newFolderError = nil
        }
    }

    private func submitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let projectId = selectedProjectId else { return }
        isCreatingFolder = true
        newFolderError = nil
        let parentId = newFolderParentId
        Task {
            do {
                _ = try await simianService.createFolderPublic(projectId: projectId, folderName: name, parentFolderId: parentId)
                await MainActor.run {
                    isCreatingFolder = false
                    showNewFolderSheet = false
                    newFolderName = ""
                    newFolderError = nil
                    if parentId == nil {
                        loadFolders(projectId: projectId, parentFolderId: nil)
                    } else {
                        folderChildrenCache.removeValue(forKey: parentId!)
                        expandedFolderIds.insert(parentId!)
                        loadFolderChildren(projectId: projectId, folderId: parentId!)
                    }
                    statusMessage = "Folder created"
                    statusIsError = false
                }
            } catch {
                await MainActor.run {
                    isCreatingFolder = false
                    newFolderError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func submitRename() {
        let newName = renameNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, let projectId = selectedProjectId else { return }
        showRenameSheet = false
        Task {
            do {
                if renameIsFolder {
                    try await simianService.renameFolder(projectId: projectId, folderId: renameItemId, newName: newName)
                    await MainActor.run {
                        applyFolderRename(folderId: renameItemId, parentFolderId: renameParentFolderId, newName: newName)
                    }
                } else {
                    try await simianService.renameFile(projectId: projectId, fileId: renameItemId, newName: newName)
                    await MainActor.run {
                        applyFileRename(fileId: renameItemId, parentFolderId: renameParentFolderId, newName: newName)
                    }
                }
                await MainActor.run {
                    statusMessage = renameIsFolder ? "Folder renamed" : "File renamed"
                    statusIsError = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    statusIsError = true
                }
            }
        }
    }

    private func applyFolderRename(folderId: String, parentFolderId: String?, newName: String) {
        if let parentId = parentFolderId, !parentId.isEmpty {
            if var children = folderChildrenCache[parentId] {
                if let idx = children.firstIndex(where: { $0.id == folderId }) {
                    let old = children[idx]
                    children[idx] = SimianFolder(id: old.id, name: newName, parentId: old.parentId)
                    folderChildrenCache[parentId] = children
                }
            }
        } else {
            if let idx = currentFolders.firstIndex(where: { $0.id == folderId }) {
                let old = currentFolders[idx]
                currentFolders[idx] = SimianFolder(id: old.id, name: newName, parentId: old.parentId)
            }
        }
    }

    private func applyFileRename(fileId: String, parentFolderId: String?, newName: String) {
        guard let parentId = parentFolderId else { return }
        if var files = folderFilesCache[parentId],
           let idx = files.firstIndex(where: { $0.id == fileId }) {
            let old = files[idx]
            files[idx] = SimianFile(id: old.id, title: newName, fileType: old.fileType, mediaURL: old.mediaURL, folderId: old.folderId, projectId: old.projectId)
            folderFilesCache[parentId] = files
        }
    }

    private func performPendingDelete() {
        guard let projectId = selectedProjectId else { return }
        let isFolder = pendingDeleteIsFolder
        let itemId = pendingDeleteItemId
        let parentId = pendingDeleteParentFolderId
        showDeleteConfirmation = false
        Task {
            do {
                if isFolder {
                    try await simianService.deleteFolder(projectId: projectId, folderId: itemId)
                    await MainActor.run {
                        applyFolderDeletion(folderId: itemId, parentFolderId: parentId)
                        expandedFolderIds.remove(itemId)
                        folderChildrenCache.removeValue(forKey: itemId)
                        folderFilesCache.removeValue(forKey: itemId)
                        if selectedDestinationFolderId == itemId {
                            selectedDestinationFolderId = nil
                            selectedDestinationPath = nil
                        }
                        statusMessage = "Folder removed"
                        statusIsError = false
                    }
                } else {
                    try await simianService.deleteFile(projectId: projectId, fileId: itemId)
                    await MainActor.run {
                        applyFileDeletion(fileId: itemId, parentFolderId: parentId)
                        statusMessage = "File removed"
                        statusIsError = false
                    }
                }
                await MainActor.run { refreshCurrentView() }
            } catch {
                await MainActor.run {
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    statusIsError = true
                }
            }
        }
    }

    private func applyFolderDeletion(folderId: String, parentFolderId: String?) {
        if let pid = parentFolderId, !pid.isEmpty {
            folderChildrenCache[pid] = folderChildrenCache[pid]?.filter { $0.id != folderId } ?? []
        } else {
            currentFolders = currentFolders.filter { $0.id != folderId }
        }
    }

    private func applyFileDeletion(fileId: String, parentFolderId: String?) {
        guard let pid = parentFolderId else { return }
        folderFilesCache[pid] = folderFilesCache[pid]?.filter { $0.id != fileId } ?? []
    }

    /// Refresh what's on screen: project list or current folder tree
    private func refreshCurrentView() {
        if let projectId = selectedProjectId {
            folderChildrenCache.removeAll()
            folderFilesCache.removeAll()
            loadFolders(projectId: projectId, parentFolderId: currentParentFolderId)
            for folderId in expandedFolderIds {
                loadFolderChildren(projectId: projectId, folderId: folderId)
            }
        } else {
            loadProjects()
        }
    }

    private func unavailableView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            VStack(spacing: 8) {
                Text("Simian Unavailable")
                    .font(.title3.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Button("Open Settings") {
                SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func projectNameBarView(projectName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
            Text(projectName)
                .font(.subheadline.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(maxWidth: .infinity)
    }

    private var searchBarView: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: isLoadingProjects ? "hourglass" : "magnifyingglass")
                    .foregroundColor(isLoadingProjects ? .orange : .primary)

                NoSelectTextField(
                    text: $searchText,
                    placeholder: "Search by docket or project name...",
                    isEnabled: true,
                    onSubmit: { selectFirstProjectIfOne() },
                    onTextChange: { }
                )
                .padding(10)

                if !searchText.isEmpty {
                    HoverableButton(action: { searchText = "" }) { isHovered in
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(isHovered ? .primary : .secondary)
                            .scaleEffect(isHovered ? 1.1 : 1.0)
                    }
                }

                Picker("Sort", selection: $projectSortOrder) {
                    Text("Name (A–Z)").tag(ProjectSortOrder.nameAsc)
                    Text("Name (Z–A)").tag(ProjectSortOrder.nameDesc)
                    Text("Last edited (newest)").tag(ProjectSortOrder.lastEditedNewest)
                    Text("Last edited (oldest)").tag(ProjectSortOrder.lastEditedOldest)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: projectSortOrder) { _, _ in
                    loadProjectInfosIfNeeded()
                }

                Button(action: { refreshCurrentView() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Refresh project list")

                if isLoadingProjectInfos {
                    ProgressView().scaleEffect(0.7)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .frame(maxWidth: .infinity)
    }

    private var projectListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoadingProjects && allProjects.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading projects...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if filteredProjects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No projects match your search")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: $selectedProjectId) {
                    ForEach(filteredProjects, id: \.id) { project in
                        HoverableButton(action: {
                            selectedProjectId = project.id
                            selectedProjectName = project.name
                            folderBreadcrumb = []
                            selectedDestinationFolderId = nil
                            selectedDestinationPath = nil
                            expandedFolderIds.removeAll()
                            folderChildrenCache.removeAll()
                            folderFilesCache.removeAll()
                            loadFolders(projectId: project.id, parentFolderId: nil)
                            keyboardFocusTreeIndex = 0
                        }) { isHovered in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                Text(project.name)
                                    .font(.system(size: 14))
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .background(isHovered ? Color.blue.opacity(0.1) : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .tag(project.id)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func folderBrowserView(projectId: String, projectName: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: {
                    selectedProjectId = nil
                    selectedProjectName = nil
                    folderBreadcrumb = []
                    currentFolders = []
                    selectedDestinationFolderId = nil
                    selectedDestinationPath = nil
                    expandedFolderIds.removeAll()
                    folderChildrenCache.removeAll()
                    folderFilesCache.removeAll()
                    keyboardFocusTreeIndex = nil
                }) {
                    Label("Back to projects", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Text("→")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(projectName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: { refreshCurrentView() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Refresh folders and files")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            if isLoadingFolders {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading folders...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Click a folder to select it as the upload destination. Drop files on a folder to upload there directly. Use arrow keys: ↑↓ move, → expand / enter folder, ← collapse / parent.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)

                    let treeList = flatTreeList(projectId: projectId)
                    let effectiveTreeFocusIndex = keyboardFocusTreeIndex ?? destinationToTreeFocusIndex(projectId: projectId)
                    ScrollViewReader { proxy in
                        List {
                            // Project root - always selectable
                            ProjectRootRowView(
                                isSelected: selectedDestinationFolderId == nil,
                                isKeyboardFocused: effectiveTreeFocusIndex == 0,
                                onTap: {
                                    selectedDestinationFolderId = nil
                                    selectedDestinationPath = nil
                                    keyboardFocusTreeIndex = 0
                                },
                                onDrop: { providers in
                                    handleFileDrop(providers: providers, destination: (nil, nil))
                                }
                            )
                            .id("project-root")
                            .contextMenu {
                                Button("New Folder") {
                                    newFolderParentId = nil
                                    newFolderName = ""
                                    showNewFolderSheet = true
                                }
                                Button("Copy Link") {
                                    if let url = SimianService.folderLinkURL(projectId: projectId, folderId: nil) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                        statusMessage = "Project link copied"
                                        statusIsError = false
                                    }
                                }
                            }

                            // Tree of folders and files (folders expandable, click to select)
                            ForEach(Array(treeList.enumerated()), id: \.element.id) { offset, item in
                                let treeIndex = offset + 1
                                Group {
                                    switch item {
                                case .folder(let f, let d, let p, let parentId):
                                    folderTreeRow(projectId: projectId, folder: f, depth: d, path: p, parentFolderId: parentId, siblings: folderSiblings(parentId: parentId), treeList: treeList, treeIndex: treeIndex, isKeyboardFocused: effectiveTreeFocusIndex == treeIndex)
                                    case .file(let file, let d, let p, let parentId):
                                        fileTreeRow(file: file, depth: d, path: p, parentFolderId: parentId, siblings: fileSiblings(parentFolderId: parentId), treeList: treeList, isKeyboardFocused: effectiveTreeFocusIndex == treeIndex)
                                    }
                                }
                                .id(item.id)
                            }
                            if treeList.count >= maxTotalTreeRows {
                                Text("(Showing first \(maxTotalTreeRows) folders — right-click any folder for link to open in Simian)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            }
                        }
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                        .onChange(of: keyboardFocusTreeIndex) { _, newIndex in
                            guard let idx = newIndex, let id = treeRowId(projectId: projectId, index: idx) else { return }
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var destinationAndPostView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !destinationSummary.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.secondary)
                    Text("Post to: \(destinationSummary)")
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 12) {
                if !manager.selectedFiles.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.doc.fill")
                            .foregroundStyle(.blue)
                        Text("\(manager.selectedFiles.count) item(s), \(manager.selectedFiles.reduce(0) { $0 + $1.fileCount }) file(s) staged")
                            .font(.caption)
                        Button("Clear", role: .destructive) { manager.clearFiles() }
                            .font(.caption)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if let url = localFolderURL {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change") { chooseLocalFolder() }
                            .font(.caption)
                        Button("Clear", role: .destructive) { localFolderURL = nil }
                            .font(.caption)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Button(action: { chooseLocalFolder() }) {
                        Label("Choose folder…", systemImage: "folder.badge.plus")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if isUploading {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uploading \(uploadCurrent) of \(uploadTotal)")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        if !uploadFileName.isEmpty {
                            Text(uploadFileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !statusMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? .orange : .green)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .orange : .secondary)
                }
            }

            Button(action: performPost) {
                Label("Post", systemImage: "arrow.up.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedProjectId == nil || hasNothingToUpload || isUploading)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    private func updateSimianServiceConfiguration() {
        let settings = settingsManager.currentSettings
        if let baseURL = settings.simianAPIBaseURL, !baseURL.isEmpty {
            simianService.setBaseURL(baseURL)
            if let username = SharedKeychainService.getSimianUsername(),
               let password = SharedKeychainService.getSimianPassword() {
                simianService.setCredentials(username: username, password: password)
            }
        } else {
            simianService.clearConfiguration()
        }
    }

    private func loadProjects() {
        isLoadingProjects = true
        projectLoadError = nil
        Task {
            do {
                let list = try await simianService.getProjectList()
                await MainActor.run {
                    allProjects = list
                    isLoadingProjects = false
                    loadProjectInfosIfNeeded()
                }
            } catch {
                await MainActor.run {
                    projectLoadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isLoadingProjects = false
                }
            }
        }
    }

    /// Fetch project info for last-edited sorting (only when user selects that sort option)
    private func loadProjectInfosIfNeeded() {
        guard projectSortOrder.usesLastEdited, projectInfos.isEmpty, !allProjects.isEmpty else { return }
        isLoadingProjectInfos = true
        let list = allProjects
        Task {
            await withTaskGroup(of: (String, SimianProjectInfo?).self) { group in
                for project in list {
                    group.addTask {
                        (project.id, try? await simianService.getProjectInfoDetails(projectId: project.id))
                    }
                }
                for await (id, info) in group {
                    if let info = info {
                        await MainActor.run { projectInfos[id] = info }
                    }
                }
            }
            await MainActor.run { isLoadingProjectInfos = false }
        }
    }

    /// Max folders to show per expanded level (prevents crash with huge folders)
    private let maxFoldersPerLevel = 200
    /// Max total rows in tree (safety cap)
    private let maxTotalTreeRows = 500

    /// Siblings at a level: folders for reorder (parent nil = root)
    private func folderSiblings(parentId: String?) -> [SimianFolder] {
        parentId == nil ? currentFolders : (folderChildrenCache[parentId!] ?? [])
    }
    /// File siblings in a folder
    private func fileSiblings(parentFolderId: String?) -> [SimianFile] {
        guard let id = parentFolderId else { return [] }
        return folderFilesCache[id] ?? []
    }

    /// Tree item: folder (expandable, selectable, reorderable) or file (display, reorderable)
    private enum SimianTreeItem: Identifiable {
        case folder(SimianFolder, depth: Int, path: String, parentFolderId: String?)
        case file(SimianFile, depth: Int, path: String, parentFolderId: String?)
        var id: String {
            switch self {
            case .folder(let f, _, _, _): return "f-\(f.id)"
            case .file(let f, _, _, _): return "file-\(f.id)"
            }
        }
    }

    /// Build a flattened list of folders and files for tree display (respects expanded state).
    /// Folders first (with subfolders when expanded), then files under each folder. Uses DFS.
    private func flatTreeList(projectId: String) -> [SimianTreeItem] {
        var result: [SimianTreeItem] = []
        enum StackItem {
            case folders([SimianFolder], Int, String, String?)
            case files([SimianFile], Int, String, String?)
        }
        var stack: [StackItem] = [.folders(currentFolders, 0, "", nil)]
        while !stack.isEmpty && result.count < maxTotalTreeRows {
            switch stack.removeLast() {
            case .folders(let folders, let depth, let pathPrefix, let parentId):
                let capped = Array(folders.prefix(maxFoldersPerLevel))
                for (i, f) in capped.enumerated() {
                    guard result.count < maxTotalTreeRows else { break }
                    let path = pathPrefix.isEmpty ? f.name : "\(pathPrefix) / \(f.name)"
                    result.append(.folder(f, depth: depth, path: path, parentFolderId: parentId))
                    if expandedFolderIds.contains(f.id) {
                        let remaining = Array(capped.suffix(from: i + 1))
                        if !remaining.isEmpty {
                            stack.append(.folders(remaining, depth, pathPrefix, parentId))
                        }
                        if let files = folderFilesCache[f.id], !files.isEmpty {
                            stack.append(.files(Array(files.prefix(100)), depth + 1, path, f.id))
                        }
                        if let children = folderChildrenCache[f.id] {
                            stack.append(.folders(children, depth + 1, path, f.id))
                        }
                        break
                    }
                }
            case .files(let files, let depth, let path, let parentId):
                for file in files {
                    guard result.count < maxTotalTreeRows else { break }
                    result.append(.file(file, depth: depth, path: "\(path) / \(file.title)", parentFolderId: parentId))
                }
            }
        }
        return result
    }

    /// Total tree row count: 1 (root) + flatTreeList.count. Used for keyboard index bounds.
    private func treeRowCount(projectId: String) -> Int {
        1 + flatTreeList(projectId: projectId).count
    }

    /// Resolve keyboard focus index to root or tree item. Index 0 = project root; index i >= 1 = treeList[i-1].
    private func treeItemAtIndex(projectId: String, index: Int) -> (isRoot: Bool, item: SimianTreeItem?)? {
        let tree = flatTreeList(projectId: projectId)
        if index == 0 { return (true, nil) }
        let i = index - 1
        guard i < tree.count else { return nil }
        return (false, tree[i])
    }

    /// Index of the parent row for the row at `index`. Root (index 0) has no parent. For folder/file, parent is the folder row with matching parentFolderId.
    private func parentTreeIndex(projectId: String, index: Int) -> Int? {
        guard index > 0 else { return nil }
        let tree = flatTreeList(projectId: projectId)
        let i = index - 1
        guard i < tree.count else { return nil }
        let parentFolderId: String?
        switch tree[i] {
        case .folder(_, _, _, let pid): parentFolderId = pid
        case .file(_, _, _, let pid): parentFolderId = pid
        }
        if parentFolderId == nil { return 0 }
        guard let parentId = parentFolderId else { return 0 }
        for j in (0..<i).reversed() {
            if case .folder(let f, _, _, _) = tree[j], f.id == parentId {
                return j + 1
            }
        }
        return 0
    }

    /// Stable id for the row at `index` (for ScrollViewReader.scrollTo). Index 0 = "project-root".
    private func treeRowId(projectId: String, index: Int) -> String? {
        if index == 0 { return "project-root" }
        let tree = flatTreeList(projectId: projectId)
        let i = index - 1
        guard i < tree.count else { return nil }
        return tree[i].id
    }

    /// Resolve current destination to tree focus index. Returns 0 for root, or index of folder row with selectedDestinationFolderId.
    private func destinationToTreeFocusIndex(projectId: String) -> Int {
        guard selectedDestinationFolderId != nil else { return 0 }
        let tree = flatTreeList(projectId: projectId)
        guard let fid = selectedDestinationFolderId else { return 0 }
        for (idx, item) in tree.enumerated() {
            if case .folder(let f, _, _, _) = item, f.id == fid { return idx + 1 }
        }
        return 0
    }

    /// Single folder row in the tree: expand chevron + clickable row to select + draggable for reorder
    private func folderTreeRow(projectId: String, folder: SimianFolder, depth: Int, path: String, parentFolderId: String?, siblings: [SimianFolder], treeList: [SimianTreeItem], treeIndex: Int, isKeyboardFocused: Bool = false) -> some View {
        let isExpanded = expandedFolderIds.contains(folder.id)
        let isLoading = loadingFolderIds.contains(folder.id)
        let hasOrMayHaveChildren = folderChildrenCache[folder.id] != nil || !isExpanded
        let isSelected = selectedDestinationFolderId == folder.id
        let nextFolderId = siblings.firstIndex(where: { $0.id == folder.id }).flatMap { i in i + 1 < siblings.count ? siblings[i + 1].id : nil }

        return FolderTreeRowContentView(
            projectId: projectId,
            folderId: folder.id,
            parentFolderId: parentFolderId,
            isExpanded: isExpanded,
            isLoading: isLoading,
            hasOrMayHaveChildren: hasOrMayHaveChildren,
            isSelected: isSelected,
            isKeyboardFocused: isKeyboardFocused,
            depth: depth,
            folderName: folder.name,
            onChevronTap: {
                if isExpanded {
                    expandedFolderIds.remove(folder.id)
                } else {
                    expandedFolderIds.insert(folder.id)
                    if folderChildrenCache[folder.id] == nil {
                        loadFolderChildren(projectId: projectId, folderId: folder.id)
                    }
                }
            },
            onRowTap: {
                selectedDestinationFolderId = folder.id
                selectedDestinationPath = path
                keyboardFocusTreeIndex = treeIndex
            },
            onDoubleTap: {
                if isExpanded {
                    expandedFolderIds.remove(folder.id)
                } else {
                    expandedFolderIds.insert(folder.id)
                    if folderChildrenCache[folder.id] == nil {
                        loadFolderChildren(projectId: projectId, folderId: folder.id)
                    }
                }
            },
            onDrop: { providers in
                handleFileDrop(providers: providers, destination: (folder.id, path))
            },
            onCopyLink: {
                copyFolderLink(projectId: projectId, folderId: folder.id)
            },
            onRename: {
                renameIsFolder = true
                renameItemId = folder.id
                renameParentFolderId = parentFolderId
                renameCurrentName = folder.name
                renameNewName = folder.name
                showRenameSheet = true
            },
            onDelete: {
                pendingDeleteIsFolder = true
                pendingDeleteItemId = folder.id
                pendingDeleteItemName = folder.name
                pendingDeleteParentFolderId = parentFolderId
                showDeleteConfirmation = true
            },
            onNewFolder: {
                newFolderParentId = folder.id
                newFolderName = ""
                showNewFolderSheet = true
            },
            onReorder: { draggedFolderId in
                reorderFolder(projectId: projectId, folderId: draggedFolderId, parentFolderId: parentFolderId, dropBeforeFolderId: folder.id)
            },
            onReorderInsertBefore: { dropBeforeFolderId, draggedFolderId in
                reorderFolder(projectId: projectId, folderId: draggedFolderId, parentFolderId: parentFolderId, dropBeforeFolderId: dropBeforeFolderId)
            },
            canReorder: siblings.count > 1,
            nextFolderId: nextFolderId
        )
    }

    /// File row (display only; draggable for reorder)
    private func fileTreeRow(file: SimianFile, depth: Int, path: String, parentFolderId: String?, siblings: [SimianFile], treeList: [SimianTreeItem], isKeyboardFocused: Bool = false) -> some View {
        let nextFileId = siblings.firstIndex(where: { $0.id == file.id }).flatMap { i in i + 1 < siblings.count ? siblings[i + 1].id : nil }
        return FileTreeRowContentView(
            projectId: selectedProjectId ?? "",
            file: file,
            parentFolderId: parentFolderId,
            depth: depth,
            isKeyboardFocused: isKeyboardFocused,
            nextFileId: nextFileId,
            onRename: {
                renameIsFolder = false
                renameItemId = file.id
                renameParentFolderId = parentFolderId
                renameCurrentName = file.title
                renameNewName = file.title
                showRenameSheet = true
            },
            onDelete: {
                pendingDeleteIsFolder = false
                pendingDeleteItemId = file.id
                pendingDeleteItemName = file.title
                pendingDeleteParentFolderId = parentFolderId
                showDeleteConfirmation = true
            },
            onReorderInsertBefore: { dropBeforeFileId, draggedFileId in
                reorderFile(projectId: selectedProjectId ?? "", fileId: draggedFileId, parentFolderId: parentFolderId, dropBeforeFileId: dropBeforeFileId)
            },
            canReorder: siblings.count > 1
        )
    }

    private func reorderFolder(projectId: String, folderId: String, parentFolderId: String?, dropBeforeFolderId: String?) {
        let siblings = folderSiblings(parentId: parentFolderId)
        guard let fromIdx = siblings.firstIndex(where: { $0.id == folderId }) else { return }
        var reordered = siblings
        reordered.remove(at: fromIdx)
        let newIdx: Int
        if let beforeId = dropBeforeFolderId, let toIdx = reordered.firstIndex(where: { $0.id == beforeId }) {
            newIdx = toIdx
        } else {
            newIdx = reordered.count
        }
        guard fromIdx != newIdx else { return }
        reordered.insert(siblings[fromIdx], at: newIdx)
        let ids = reordered.map { $0.id }
        Task {
            do {
                try await simianService.updateFolderSort(projectId: projectId, parentFolderId: parentFolderId, folderIds: ids)
                await MainActor.run {
                    if let pid = parentFolderId {
                        folderChildrenCache[pid] = reordered
                    } else {
                        currentFolders = reordered
                    }
                    statusMessage = "Folder moved"
                    statusIsError = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    statusIsError = true
                }
            }
        }
    }

    private func reorderFile(projectId: String, fileId: String, parentFolderId: String?, dropBeforeFileId: String?) {
        guard let pid = parentFolderId else { return }
        let siblings = fileSiblings(parentFolderId: pid)
        guard let fromIdx = siblings.firstIndex(where: { $0.id == fileId }) else { return }
        var reordered = siblings
        reordered.remove(at: fromIdx)
        let newIdx: Int
        if let beforeId = dropBeforeFileId, let toIdx = reordered.firstIndex(where: { $0.id == beforeId }) {
            newIdx = toIdx
        } else {
            newIdx = reordered.count
        }
        guard fromIdx != newIdx else { return }
        reordered.insert(siblings[fromIdx], at: newIdx)
        let ids = reordered.map { $0.id }
        Task {
            do {
                try await simianService.updateFileSort(projectId: projectId, folderId: pid, fileIds: ids)
                await MainActor.run {
                    folderFilesCache[pid] = reordered
                    statusMessage = "File moved"
                    statusIsError = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    statusIsError = true
                }
            }
        }
    }

    /// Copy Simian short link (Share → Get Shortlink → Create Link) to clipboard.
    private func copyFolderLink(projectId: String, folderId: String) {
        Task {
            do {
                let shortLink = try await simianService.getShortLink(projectId: projectId, folderId: folderId)
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shortLink, forType: .string)
                    statusMessage = "Short link copied"
                    statusIsError = false
                }
            } catch {
                await MainActor.run {
                    if let url = SimianService.folderLinkURL(projectId: projectId, folderId: folderId) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        statusMessage = "Direct link copied (short link unavailable)"
                        statusIsError = false
                    } else {
                        statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        statusIsError = true
                    }
                }
            }
        }
    }

    private func loadFolderChildren(projectId: String, folderId: String) {
        loadingFolderIds.insert(folderId)
        Task {
            do {
                async let foldersTask = simianService.getProjectFolders(projectId: projectId, parentFolderId: folderId)
                async let filesTask = simianService.getProjectFiles(projectId: projectId, folderId: folderId)
                let (children, files) = try await (foldersTask, filesTask)
                await MainActor.run {
                    folderChildrenCache[folderId] = children
                    folderFilesCache[folderId] = files
                    loadingFolderIds.remove(folderId)
                }
            } catch {
                await MainActor.run {
                    folderChildrenCache[folderId] = []
                    folderFilesCache[folderId] = []
                    loadingFolderIds.remove(folderId)
                }
            }
        }
    }

    private func loadFolders(projectId: String, parentFolderId: String?) {
        isLoadingFolders = true
        Task {
            do {
                let folders = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: parentFolderId)
                await MainActor.run {
                    currentFolders = folders
                    isLoadingFolders = false
                }
            } catch {
                await MainActor.run {
                    currentFolders = []
                    isLoadingFolders = false
                }
            }
        }
    }

    private func selectFirstProjectIfOne() {
        if filteredProjects.count == 1 {
            let p = filteredProjects[0]
            selectedProjectId = p.id
            selectedProjectName = p.name
            folderBreadcrumb = []
            selectedDestinationFolderId = nil
            selectedDestinationPath = nil
            expandedFolderIds.removeAll()
            folderChildrenCache.removeAll()
            folderFilesCache.removeAll()
            loadFolders(projectId: p.id, parentFolderId: nil)
        }
    }

    private func chooseLocalFolder() {
        FilePickerService.chooseFolder { url in
            if let url = url {
                localFolderURL = url
            }
        }
    }

    // MARK: - Keyboard navigation (Finder-like)

    private func shouldIgnoreKeyPress() -> Bool {
        if isSearchFocused { return true }
        if let window = NSApp.keyWindow, KeyboardNavigationCoordinator.isEditingText(in: window) { return true }
        return false
    }

    private func handleKeyUp() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        if selectedProjectId == nil {
            // Project list: move selection up
            let list = filteredProjects
            guard !list.isEmpty else { return .handled }
            let currentId = selectedProjectId
            let idx = currentId.flatMap { id in list.firstIndex(where: { $0.id == id }) } ?? -1
            let newIdx = max(0, idx - 1)
            let project = list[newIdx]
            selectedProjectId = project.id
            selectedProjectName = project.name
            return .handled
        }
        // Folder tree: move focus up
        guard let projectId = selectedProjectId else { return .handled }
        let count = treeRowCount(projectId: projectId)
        guard count > 0 else { return .handled }
        let current = keyboardFocusTreeIndex ?? destinationToTreeFocusIndex(projectId: projectId)
        keyboardFocusTreeIndex = current
        let newIdx = max(0, current - 1)
        keyboardFocusTreeIndex = newIdx
        applyDestinationFromTreeIndex(projectId: projectId, index: newIdx)
        return .handled
    }

    private func handleKeyDown() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        if selectedProjectId == nil {
            // Project list: move selection down or select first
            let list = filteredProjects
            guard !list.isEmpty else { return .handled }
            let currentId = selectedProjectId
            let idx = currentId.flatMap { id in list.firstIndex(where: { $0.id == id }) }
            let newIdx: Int
            if let i = idx {
                newIdx = min(list.count - 1, i + 1)
            } else {
                newIdx = 0
            }
            let project = list[newIdx]
            selectedProjectId = project.id
            selectedProjectName = project.name
            return .handled
        }
        // Folder tree: move focus down
        guard let projectId = selectedProjectId else { return .handled }
        let count = treeRowCount(projectId: projectId)
        guard count > 0 else { return .handled }
        let current = keyboardFocusTreeIndex ?? destinationToTreeFocusIndex(projectId: projectId)
        keyboardFocusTreeIndex = current
        let newIdx = min(count - 1, current + 1)
        keyboardFocusTreeIndex = newIdx
        applyDestinationFromTreeIndex(projectId: projectId, index: newIdx)
        return .handled
    }

    private func handleKeyLeft() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        guard let projectId = selectedProjectId else { return .ignored }
        let count = treeRowCount(projectId: projectId)
        guard count > 0 else { return .handled }
        let current = keyboardFocusTreeIndex ?? destinationToTreeFocusIndex(projectId: projectId)
        keyboardFocusTreeIndex = current
        guard let info = treeItemAtIndex(projectId: projectId, index: current) else { return .handled }
        if !info.isRoot, let item = info.item, case .folder(let f, _, _, _) = item, expandedFolderIds.contains(f.id) {
            expandedFolderIds.remove(f.id)
            keyboardFocusTreeIndex = current
        } else if let parentIdx = parentTreeIndex(projectId: projectId, index: current) {
            keyboardFocusTreeIndex = parentIdx
            applyDestinationFromTreeIndex(projectId: projectId, index: parentIdx)
        }
        return .handled
    }

    private func handleKeyRight() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        guard let projectId = selectedProjectId else { return .ignored }
        let count = treeRowCount(projectId: projectId)
        guard count > 0 else { return .handled }
        let current = keyboardFocusTreeIndex ?? destinationToTreeFocusIndex(projectId: projectId)
        keyboardFocusTreeIndex = current
        guard let info = treeItemAtIndex(projectId: projectId, index: current) else { return .handled }
        if info.isRoot {
            return .handled
        }
        guard let item = info.item else { return .handled }
        if case .folder(let f, _, _, _) = item {
            let isExpanded = expandedFolderIds.contains(f.id)
            if !isExpanded {
                expandedFolderIds.insert(f.id)
                if folderChildrenCache[f.id] == nil {
                    loadFolderChildren(projectId: projectId, folderId: f.id)
                }
                keyboardFocusTreeIndex = current
            } else {
                let nextIdx = current + 1
                if nextIdx < count {
                    keyboardFocusTreeIndex = nextIdx
                    applyDestinationFromTreeIndex(projectId: projectId, index: nextIdx)
                }
            }
        }
        return .handled
    }

    private func handleKeyReturn() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        if selectedProjectId == nil {
            // Project list: open selected project (or first if none selected)
            let list = filteredProjects
            guard !list.isEmpty else { return .handled }
            let id = selectedProjectId ?? list[0].id
            let name = selectedProjectName ?? list.first(where: { $0.id == id })?.name ?? ""
            selectedProjectId = id
            selectedProjectName = name
            folderBreadcrumb = []
            selectedDestinationFolderId = nil
            selectedDestinationPath = nil
            expandedFolderIds.removeAll()
            folderChildrenCache.removeAll()
            folderFilesCache.removeAll()
            loadFolders(projectId: id, parentFolderId: nil)
            keyboardFocusTreeIndex = 0
            return .handled
        }
        // Folder tree: set destination from focused row (if folder or root)
        guard let projectId = selectedProjectId else { return .handled }
        let count = treeRowCount(projectId: projectId)
        guard count > 0 else { return .handled }
        let current = keyboardFocusTreeIndex ?? destinationToTreeFocusIndex(projectId: projectId)
        keyboardFocusTreeIndex = current
        applyDestinationFromTreeIndex(projectId: projectId, index: current)
        return .handled
    }

    private func handleKeyEscape() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        if selectedProjectId != nil {
            selectedProjectId = nil
            selectedProjectName = nil
            folderBreadcrumb = []
            currentFolders = []
            selectedDestinationFolderId = nil
            selectedDestinationPath = nil
            expandedFolderIds.removeAll()
            folderChildrenCache.removeAll()
            folderFilesCache.removeAll()
            keyboardFocusTreeIndex = nil
            return .handled
        }
        return .ignored
    }

    /// Update selectedDestinationFolderId and selectedDestinationPath from the tree row at index (only when row is root or folder).
    private func applyDestinationFromTreeIndex(projectId: String, index: Int) {
        guard let info = treeItemAtIndex(projectId: projectId, index: index) else { return }
        if info.isRoot {
            selectedDestinationFolderId = nil
            selectedDestinationPath = nil
            return
        }
        if case .folder(let f, _, let path, _) = info.item! {
            selectedDestinationFolderId = f.id
            selectedDestinationPath = path
        }
    }

    /// destination: nil = don't change / add to staging; (nil, nil) = project root; (id, path) = that folder. When destination is set, upload dropped files directly there (no staging).
    private func handleFileDrop(providers: [NSItemProvider], destination: (folderId: String?, path: String?)?) -> Bool {
        if let dest = destination {
            selectedDestinationFolderId = dest.folderId
            selectedDestinationPath = dest.path ?? ""
            guard let projectId = selectedProjectId else { return true }
            loadURLsFromProviders(providers) { [self] urls in
                guard !urls.isEmpty else { return }
                uploadDroppedFiles(projectId: projectId, folderId: dest.folderId, fileURLs: urls)
            }
            return true
        }
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

    /// Load all file URLs from drag providers, then call completion on main queue with the collected URLs.
    private func loadURLsFromProviders(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(urls)
        }
    }

    /// Upload dropped files directly to the given folder (no staging). Uses same logic as performPost.
    private func uploadDroppedFiles(projectId: String, folderId: String?, fileURLs: [URL]) {
        let itemsToUpload = fileURLs.map { FileItem(url: $0) }
        let totalFiles = itemsToUpload.reduce(0) { $0 + $1.fileCount }
        isUploading = true
        statusMessage = "Uploading…"
        statusIsError = false
        uploadTotal = totalFiles
        uploadCurrent = 0
        uploadFileName = ""

        Task {
            do {
                let progressCounter = ProgressCounter()
                for fileItem in itemsToUpload {
                    let existingFolders = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: folderId)
                    let existingNames = existingFolders.map { $0.name }

                    if fileItem.isDirectory {
                        try await uploadFolderWithStructure(
                            projectId: projectId,
                            destinationFolderId: folderId,
                            localFolderURL: fileItem.url,
                            existingFolderNames: existingNames,
                            uploadProgress: { fileName in
                                progressCounter.increment()
                                Task { @MainActor in
                                    uploadCurrent = progressCounter.value
                                    uploadTotal = totalFiles
                                    uploadFileName = fileName
                                }
                            }
                        )
                    } else {
                        progressCounter.increment()
                        await MainActor.run {
                            uploadCurrent = progressCounter.value
                            uploadTotal = totalFiles
                            uploadFileName = fileItem.name
                        }
                        _ = try await simianService.uploadFile(projectId: projectId, folderId: folderId, fileURL: fileItem.url)
                    }
                }

                await MainActor.run {
                    isUploading = false
                    let destSummary = folderId == nil ? "project root" : "folder"
                    statusMessage = "Uploaded \(progressCounter.value) file(s) to \(destSummary)."
                    statusIsError = false
                    if selectedProjectId == projectId {
                        if let destId = folderId {
                            folderChildrenCache.removeValue(forKey: destId)
                            folderFilesCache.removeValue(forKey: destId)
                        }
                        loadFolders(projectId: projectId, parentFolderId: currentParentFolderId)
                    }
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    statusIsError = true
                }
            }
        }
    }

    /// Count total files for progress (recursive)
    private func countFiles(in directoryURL: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            guard url.lastPathComponent != ".DS_Store" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            count += 1
        }
        return count
    }

    private func performPost() {
        guard let projectId = selectedProjectId else { return }
        let destinationFolderId = selectedDestinationFolderId

        let itemsToUpload: [FileItem]
        let totalFiles: Int
        if !manager.selectedFiles.isEmpty {
            itemsToUpload = manager.selectedFiles
            totalFiles = manager.selectedFiles.reduce(0) { $0 + $1.fileCount }
        } else if let folderURL = localFolderURL, countFiles(in: folderURL) > 0 {
            itemsToUpload = [FileItem(url: folderURL)]
            totalFiles = countFiles(in: folderURL)
        } else {
            return
        }

        isUploading = true
        statusMessage = ""
        statusIsError = false
        uploadTotal = totalFiles
        uploadCurrent = 0
        uploadFileName = ""

        Task {
            do {
                let progressCounter = ProgressCounter()
                for fileItem in itemsToUpload {
                    let existingFolders = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: destinationFolderId)
                    let existingNames = existingFolders.map { $0.name }

                    if fileItem.isDirectory {
                        try await uploadFolderWithStructure(
                            projectId: projectId,
                            destinationFolderId: destinationFolderId,
                            localFolderURL: fileItem.url,
                            existingFolderNames: existingNames,
                            uploadProgress: { fileName in
                                progressCounter.increment()
                                Task { @MainActor in
                                    uploadCurrent = progressCounter.value
                                    uploadTotal = totalFiles
                                    uploadFileName = fileName
                                }
                            }
                        )
                    } else {
                        progressCounter.increment()
                        await MainActor.run {
                            uploadCurrent = progressCounter.value
                            uploadTotal = totalFiles
                            uploadFileName = fileItem.name
                        }
                        _ = try await simianService.uploadFile(projectId: projectId, folderId: destinationFolderId, fileURL: fileItem.url)
                    }
                }

                await MainActor.run {
                    isUploading = false
                    statusMessage = "Uploaded \(progressCounter.value) file(s) to \(destinationSummary)."
                    statusIsError = false
                    if selectedProjectId == projectId {
                        if let destId = destinationFolderId {
                            folderChildrenCache.removeValue(forKey: destId)
                            folderFilesCache.removeValue(forKey: destId)
                        }
                        loadFolders(projectId: projectId, parentFolderId: currentParentFolderId)
                    }
                }
            } catch {
                await MainActor.run {
                    isUploading = false
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    statusIsError = true
                }
            }
        }
    }

    /// Upload a folder and its contents to Simian, preserving folder structure.
    /// Uses next number in sequence for numbered folders (01_, 02_, etc.) at each level.
    private func uploadFolderWithStructure(
        projectId: String,
        destinationFolderId: String?,
        localFolderURL: URL,
        existingFolderNames: [String],
        uploadProgress: @escaping (String) -> Void
    ) async throws {
        let fm = FileManager.default

        // Determine the folder name for Simian (apply numbered sequencing if destination has numbered folders)
        let sourceFolderName = localFolderURL.lastPathComponent
        let folderName = SimianService.nextNumberedFolderName(existingFolderNames: existingFolderNames, sourceFolderName: sourceFolderName)

        // Create the folder in Simian
        let simianFolderId = try await simianService.createFolderPublic(
            projectId: projectId,
            folderName: folderName,
            parentFolderId: destinationFolderId
        )

        // Get contents of the local folder
        guard let contents = try? fm.contentsOfDirectory(
            at: localFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var filesInThisFolder: [URL] = []
        var subfolders: [URL] = []

        for item in contents {
            guard item.lastPathComponent != ".DS_Store" else { continue }
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                subfolders.append(item)
            } else if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                filesInThisFolder.append(item)
            }
        }

        // Upload files in this folder
        for fileURL in filesInThisFolder {
            uploadProgress(fileURL.lastPathComponent)
            _ = try await simianService.uploadFile(projectId: projectId, folderId: simianFolderId, fileURL: fileURL)
        }

        // Recursively upload subfolders
        for subfolderURL in subfolders {
            let existingInSimian = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: simianFolderId)
            let existingNames = existingInSimian.map { $0.name }

            try await uploadFolderWithStructure(
                projectId: projectId,
                destinationFolderId: simianFolderId,
                localFolderURL: subfolderURL,
                existingFolderNames: existingNames,
                uploadProgress: uploadProgress
            )
        }
    }
}

enum ProjectSortOrder: String, CaseIterable {
    case nameAsc = "name_asc"
    case nameDesc = "name_desc"
    case lastEditedNewest = "last_newest"
    case lastEditedOldest = "last_oldest"

    var usesLastEdited: Bool {
        self == .lastEditedNewest || self == .lastEditedOldest
    }
}

/// Drag payload for Simian reorder: "simian|folder|projectId|parentId|itemId" or "simian|file|projectId|parentId|itemId"
private func parseSimianDrag(_ str: String) -> (type: String, projectId: String, parentId: String?, itemId: String)? {
    let parts = str.split(separator: "|").map(String.init)
    guard parts.count >= 5, parts[0] == "simian" else { return nil }
    return (parts[1], parts[2], parts[3].isEmpty ? nil : parts[3], parts[4])
}

/// Thin drop zone that shows a horizontal line when a reorder drag is over it. Used between rows to indicate "insert before" or "insert after".
private struct ReorderLineView: View {
    let expectedType: String // "folder" or "file"
    let validateParent: (String?) -> Bool
    let onDrop: (String) -> Void
    @Binding var isTargeted: Bool

    private let lineHeight: CGFloat = 2
    private let hitHeight: CGFloat = 4

    var body: some View {
        ZStack {
            Color.clear.frame(height: hitHeight)
            if isTargeted {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: lineHeight)
            }
        }
        .frame(height: hitHeight)
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let ns = obj as? NSString else { return }
                let str = String(ns)
                guard let parsed = parseSimianDrag(str),
                      parsed.type == expectedType,
                      validateParent(parsed.parentId) else { return }
                DispatchQueue.main.async { onDrop(parsed.itemId) }
            }
            return true
        }
    }
}

// Project root row with hover and drop-target visual feedback
private struct ProjectRootRowView: View {
    let isSelected: Bool
    var isKeyboardFocused: Bool = false
    let onTap: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool

    @State private var isHovered = false
    @State private var isDropTargeted = false

    private var rowBackground: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.3) }
        if isKeyboardFocused { return Color.accentColor.opacity(0.25) }
        if isSelected { return Color.accentColor.opacity(0.2) }
        if isHovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text("Project root")
                    .font(.system(size: 14))
                Spacer()
                if isDropTargeted {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground)
            .overlay {
                if isSelected || isKeyboardFocused {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: onDrop)
    }
}

// Folder row with hover, drop-target, and reorder support
private struct FolderTreeRowContentView: View {
    let projectId: String
    let folderId: String
    let parentFolderId: String?
    let isExpanded: Bool
    let isLoading: Bool
    let hasOrMayHaveChildren: Bool
    let isSelected: Bool
    var isKeyboardFocused: Bool = false
    let depth: Int
    let folderName: String
    let onChevronTap: () -> Void
    let onRowTap: () -> Void
    let onDoubleTap: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let onCopyLink: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onNewFolder: () -> Void
    let onReorder: (String) -> Void
    let onReorderInsertBefore: (String?, String) -> Void
    let canReorder: Bool
    let nextFolderId: String?

    @State private var isHovered = false
    @State private var isDropTargeted = false
    @State private var isReorderTargeted = false
    @State private var isLineAboveTargeted = false
    @State private var isLineBelowTargeted = false
    @State private var pendingSingleTap: DispatchWorkItem?

    private var dragPayload: String {
        "simian|folder|\(projectId)|\(parentFolderId ?? "")|\(folderId)"
    }

    private var safeDepth: Int { min(depth, 30) }

    private func validateParent(_ parsedParentId: String?) -> Bool {
        (parsedParentId ?? "") == (parentFolderId ?? "")
    }

    private var rowBackground: Color {
        if isReorderTargeted { return Color.orange.opacity(0.3) }
        if isDropTargeted { return Color.accentColor.opacity(0.3) }
        if isKeyboardFocused { return Color.accentColor.opacity(0.25) }
        if isSelected { return Color.accentColor.opacity(0.2) }
        if isHovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    var body: some View {
        VStack(spacing: 0) {
            if canReorder {
                ReorderLineView(
                    expectedType: "folder",
                    validateParent: validateParent,
                    onDrop: { draggedId in onReorderInsertBefore(folderId, draggedId) },
                    isTargeted: $isLineAboveTargeted
                )
            }
            HStack(spacing: 4) {
                ForEach(0..<safeDepth, id: \.self) { _ in
                    Rectangle().fill(Color.clear).frame(width: 12)
                }
                Button(action: onChevronTap) {
                    Group {
                        if isLoading {
                            ProgressView().scaleEffect(0.6)
                        } else if hasOrMayHaveChildren {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, height: 16)
                        } else {
                            Rectangle().fill(Color.clear).frame(width: 16, height: 16)
                        }
                    }
                }
                .buttonStyle(.plain)

                Button(action: {
                if let prior = pendingSingleTap {
                    prior.cancel()
                    pendingSingleTap = nil
                    onDoubleTap()
                } else {
                    let work = DispatchWorkItem { onRowTap() }
                    pendingSingleTap = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        if !work.isCancelled {
                            work.perform()
                        }
                        pendingSingleTap = nil
                    }
                }
            }) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folderName)
                        .font(.system(size: 14))
                    Spacer()
                    if isDropTargeted {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.accentColor)
                    } else if isReorderTargeted {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .background(rowBackground)
                .overlay {
                    if isSelected || isKeyboardFocused {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: onDrop)
            .onDrop(of: [.text], isTargeted: $isReorderTargeted) { providers in
                guard canReorder else { return false }
                for p in providers {
                    _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                        guard let ns = obj as? NSString, let parsed = parseSimianDrag(String(ns)), parsed.type == "folder", parsed.itemId != folderId else { return }
                        let sameParent = (parsed.parentId ?? "") == (parentFolderId ?? "")
                        guard sameParent else { return }
                        DispatchQueue.main.async { onReorder(parsed.itemId) }
                    }
                }
                return true
            }
            .draggable(canReorder ? dragPayload : "simian|none|||")
            .contextMenu {
                Button("New Folder", action: onNewFolder)
                Button("Rename…", action: onRename)
                Button("Copy Link", action: onCopyLink)
                Divider()
                Button("Remove from Simian…", role: .destructive, action: onDelete)
            }
            }
            if canReorder {
                ReorderLineView(
                    expectedType: "folder",
                    validateParent: validateParent,
                    onDrop: { draggedId in onReorderInsertBefore(nextFolderId, draggedId) },
                    isTargeted: $isLineBelowTargeted
                )
            }
        }
    }
}

// File row with reorder support (line indicators between files, no full-row highlight)
private struct FileTreeRowContentView: View {
    let projectId: String
    let file: SimianFile
    let parentFolderId: String?
    let depth: Int
    var isKeyboardFocused: Bool = false
    let nextFileId: String? // Next file in same folder (for "insert after" line); nil = last file
    let onRename: () -> Void
    let onDelete: () -> Void
    let onReorderInsertBefore: (String?, String) -> Void // (dropBeforeFileId, draggedFileId); nil = insert at end
    let canReorder: Bool

    @State private var isLineAboveTargeted = false
    @State private var isLineBelowTargeted = false

    private var safeDepth: Int { min(depth, 30) }
    private var dragPayload: String { "simian|file|\(projectId)|\(parentFolderId ?? "")|\(file.id)" }

    private func validateParent(_ parsedParentId: String?) -> Bool {
        (parsedParentId ?? "") == (parentFolderId ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            if canReorder {
                ReorderLineView(
                    expectedType: "file",
                    validateParent: validateParent,
                    onDrop: { draggedId in onReorderInsertBefore(file.id, draggedId) },
                    isTargeted: $isLineAboveTargeted
                )
            }
            HStack(spacing: 4) {
                ForEach(0..<safeDepth, id: \.self) { _ in
                    Rectangle().fill(Color.clear).frame(width: 12)
                }
                Rectangle().fill(Color.clear).frame(width: 16)
                HStack {
                    Image(systemName: "doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(file.title)
                        .font(.system(size: 14))
                    Spacer()
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .background(isKeyboardFocused ? Color.accentColor.opacity(0.25) : Color.clear)
                .overlay {
                    if isKeyboardFocused {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                    }
                }
            }
            if canReorder {
                ReorderLineView(
                    expectedType: "file",
                    validateParent: validateParent,
                    onDrop: { draggedId in onReorderInsertBefore(nextFileId, draggedId) },
                    isTargeted: $isLineBelowTargeted
                )
            }
        }
        .draggable(canReorder ? dragPayload : "simian|none|||")
        .contextMenu {
            Button("Rename…", action: onRename)
            Divider()
            Button("Remove from Simian…", role: .destructive, action: onDelete)
        }
    }
}

// Helper for tracking upload progress across async recursion
private final class ProgressCounter {
    var value = 0
    func increment() { value += 1 }
}
