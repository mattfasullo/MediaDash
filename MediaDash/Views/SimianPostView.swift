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
                        }) { isHovered in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                Text(project.name)
                                    .font(.system(size: 14))
                                Spacer()
                            }
                            .padding(.vertical, 6)
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
                    Text("Click a folder to select it as the upload destination. Click the chevron to expand and see subfolders.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)

                    List {
                        // Project root - always selectable
                        ProjectRootRowView(
                            isSelected: selectedDestinationFolderId == nil,
                            onTap: {
                                selectedDestinationFolderId = nil
                                selectedDestinationPath = nil
                            },
                            onDrop: { providers in
                                handleFileDrop(providers: providers, destination: (nil, nil))
                            }
                        )
                        .contextMenu {
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
                        let treeList = flatTreeList(projectId: projectId)
                        ForEach(treeList) { item in
                            switch item {
                            case .folder(let f, let d, let p, let parentId):
                                folderTreeRow(projectId: projectId, folder: f, depth: d, path: p, parentFolderId: parentId, siblings: folderSiblings(parentId: parentId), treeList: treeList)
                            case .file(let file, let d, let p, let parentId):
                                fileTreeRow(file: file, depth: d, path: p, parentFolderId: parentId, siblings: fileSiblings(parentFolderId: parentId), treeList: treeList)
                            }
                        }
                        if treeList.count >= maxTotalTreeRows {
                            Text("(Showing first \(maxTotalTreeRows) folders — right-click any folder for link to open in Simian)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
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

    /// Single folder row in the tree: expand chevron + clickable row to select + draggable for reorder
    private func folderTreeRow(projectId: String, folder: SimianFolder, depth: Int, path: String, parentFolderId: String?, siblings: [SimianFolder], treeList: [SimianTreeItem]) -> some View {
        let isExpanded = expandedFolderIds.contains(folder.id)
        let isLoading = loadingFolderIds.contains(folder.id)
        let hasOrMayHaveChildren = folderChildrenCache[folder.id] != nil || !isExpanded
        let isSelected = selectedDestinationFolderId == folder.id

        return FolderTreeRowContentView(
            projectId: projectId,
            folderId: folder.id,
            parentFolderId: parentFolderId,
            isExpanded: isExpanded,
            isLoading: isLoading,
            hasOrMayHaveChildren: hasOrMayHaveChildren,
            isSelected: isSelected,
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
            onReorder: { draggedFolderId in
                reorderFolder(projectId: projectId, folderId: draggedFolderId, parentFolderId: parentFolderId, dropBeforeFolderId: folder.id)
            },
            canReorder: siblings.count > 1
        )
    }

    /// File row (display only; draggable for reorder)
    private func fileTreeRow(file: SimianFile, depth: Int, path: String, parentFolderId: String?, siblings: [SimianFile], treeList: [SimianTreeItem]) -> some View {
        FileTreeRowContentView(
            projectId: selectedProjectId ?? "",
            file: file,
            parentFolderId: parentFolderId,
            depth: depth,
            onReorder: { draggedFileId in
                reorderFile(projectId: selectedProjectId ?? "", fileId: draggedFileId, parentFolderId: parentFolderId, dropBeforeFileId: file.id)
            },
            canReorder: siblings.count > 1
        )
    }

    private func reorderFolder(projectId: String, folderId: String, parentFolderId: String?, dropBeforeFolderId: String) {
        let siblings = folderSiblings(parentId: parentFolderId)
        guard let fromIdx = siblings.firstIndex(where: { $0.id == folderId }),
              let toIdx = siblings.firstIndex(where: { $0.id == dropBeforeFolderId }),
              fromIdx != toIdx else { return }
        var reordered = siblings
        reordered.remove(at: fromIdx)
        let newIdx = reordered.firstIndex(where: { $0.id == dropBeforeFolderId }) ?? toIdx
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

    private func reorderFile(projectId: String, fileId: String, parentFolderId: String?, dropBeforeFileId: String) {
        guard let pid = parentFolderId else { return }
        let siblings = fileSiblings(parentFolderId: pid)
        guard let fromIdx = siblings.firstIndex(where: { $0.id == fileId }),
              let toIdx = siblings.firstIndex(where: { $0.id == dropBeforeFileId }),
              fromIdx != toIdx else { return }
        var reordered = siblings
        reordered.remove(at: fromIdx)
        let newIdx = reordered.firstIndex(where: { $0.id == dropBeforeFileId }) ?? toIdx
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

    /// destination: nil = don't change; (nil, nil) = project root; (id, path) = that folder
    private func handleFileDrop(providers: [NSItemProvider], destination: (folderId: String?, path: String?)?) -> Bool {
        if let dest = destination {
            selectedDestinationFolderId = dest.folderId
            selectedDestinationPath = dest.path ?? ""
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

// Project root row with hover and drop-target visual feedback
private struct ProjectRootRowView: View {
    let isSelected: Bool
    let onTap: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool

    @State private var isHovered = false
    @State private var isDropTargeted = false

    private var rowBackground: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.3) }
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
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground)
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
    let depth: Int
    let folderName: String
    let onChevronTap: () -> Void
    let onRowTap: () -> Void
    let onDoubleTap: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let onCopyLink: () -> Void
    let onReorder: (String) -> Void
    let canReorder: Bool

    @State private var isHovered = false
    @State private var isDropTargeted = false
    @State private var isReorderTargeted = false
    @State private var pendingSingleTap: DispatchWorkItem?

    private var dragPayload: String {
        "simian|folder|\(projectId)|\(parentFolderId ?? "")|\(folderId)"
    }

    private var safeDepth: Int { min(depth, 30) }

    private var rowBackground: Color {
        if isReorderTargeted { return Color.orange.opacity(0.3) }
        if isDropTargeted { return Color.accentColor.opacity(0.3) }
        if isSelected { return Color.accentColor.opacity(0.2) }
        if isHovered { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    var body: some View {
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
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(rowBackground)
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
                Button("Copy Link", action: onCopyLink)
            }
        }
    }
}

// File row with reorder support
private struct FileTreeRowContentView: View {
    let projectId: String
    let file: SimianFile
    let parentFolderId: String?
    let depth: Int
    let onReorder: (String) -> Void
    let canReorder: Bool

    @State private var isReorderTargeted = false

    private var safeDepth: Int { min(depth, 30) }
    private var dragPayload: String { "simian|file|\(projectId)|\(parentFolderId ?? "")|\(file.id)" }

    var body: some View {
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
                if isReorderTargeted {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isReorderTargeted ? Color.orange.opacity(0.3) : Color.clear)
        }
        .onDrop(of: [.text], isTargeted: $isReorderTargeted) { providers in
            guard canReorder else { return false }
            for p in providers {
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let ns = obj as? NSString, let parsed = parseSimianDrag(String(ns)), parsed.type == "file", parsed.itemId != file.id else { return }
                    let sameParent = (parsed.parentId ?? "") == (parentFolderId ?? "")
                    guard sameParent else { return }
                    DispatchQueue.main.async { onReorder(parsed.itemId) }
                }
            }
            return true
        }
        .draggable(canReorder ? dragPayload : "simian|none|||")
    }
}

// Helper for tracking upload progress across async recursion
private final class ProgressCounter {
    var value = 0
    func increment() { value += 1 }
}
