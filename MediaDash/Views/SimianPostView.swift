//
//  SimianPostView.swift
//  MediaDash
//
//  Simian: search projects, navigate folders, upload via drag-drop or right-click.
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

    @State private var folderBreadcrumb: [(id: String, name: String)] = []
    @State private var currentFolders: [SimianFolder] = []
    @State private var isLoadingFolders = false

    // Tree view
    @State private var expandedFolderIds: Set<String> = []
    @State private var folderChildrenCache: [String: [SimianFolder]] = [:]
    @State private var folderFilesCache: [String: [SimianFile]] = [:]
    @State private var loadingFolderIds: Set<String> = []

    // Native List selection (single blue highlight for files AND folders)
    @State private var selectedItemIds: Set<String> = []

    // Inline rename: which tree item is being edited, and the text field value
    @State private var inlineRenameItemId: String?
    @State private var inlineRenameText: String = ""

    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var isUploading = false
    @State private var uploadCurrent = 0
    @State private var uploadTotal = 0
    @State private var uploadFileName = ""

    // Rename sheet (fallback, kept for context menu "Rename…")
    @State private var showRenameSheet = false
    @State private var renameIsFolder = true
    @State private var renameItemId = ""
    @State private var renameParentFolderId: String?
    @State private var renameCurrentName = ""
    @State private var renameNewName = ""

    // Delete confirmation
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteIsFolder = true
    @State private var pendingDeleteItemId = ""
    @State private var pendingDeleteItemName = ""
    @State private var pendingDeleteParentFolderId: String?

    // New folder
    @State private var showNewFolderSheet = false
    @State private var newFolderParentId: String?
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false
    @State private var newFolderError: String?

    // New folder with selection
    @State private var showNewFolderWithSelectionSheet = false
    @State private var newFolderWithSelectionName = ""
    @State private var newFolderWithSelectionIds: [String] = []
    @State private var newFolderWithSelectionParentId: String?
    @State private var isCreatingFolderWithSelection = false
    @State private var newFolderWithSelectionError: String?

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isProjectListFocused: Bool
    @FocusState private var isFolderListFocused: Bool
    /// True when the Simian `NoSelectTextField` is key (AppKit); SwiftUI `isSearchFocused` is not auto-synced for `NSViewRepresentable`.
    @State private var simianSearchFieldIsFirstResponder = false

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

    private var isSimianSearchInputActive: Bool {
        isSearchFocused || simianSearchFieldIsFirstResponder
    }

    /// Drop AppKit focus from the search field so the list can receive selection/keys.
    private func resignSimianSearchFieldForListNavigation() {
        isSearchFocused = false
        simianSearchFieldIsFirstResponder = false
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private static let simianKeyDebugLog = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-simian-keyfocus.log"
    /// Session `5a89d5`: NDJSON focus / key routing (do not remove until verified).
    private static let agentDebugLogPath = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-5a89d5.log"

    // #region agent log
    private func logAgentFocus(_ message: String, hypothesisId: String, data: [String: Any]) {
        let payload: [String: Any] = [
            "sessionId": "5a89d5",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "location": "SimianPostView",
            "message": message,
            "hypothesisId": hypothesisId,
            "data": data
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8) else { return }
        let path = Self.agentDebugLogPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
        h.closeFile()
    }
    // #endregion

    private func logSimianKeyDebug(_ message: String) {
        if FileManager.default.fileExists(atPath: Self.simianKeyDebugLog) == false {
            FileManager.default.createFile(atPath: Self.simianKeyDebugLog, contents: nil)
        }
        guard let h = FileHandle(forWritingAtPath: Self.simianKeyDebugLog) else { return }
        h.seekToEndOfFile()
        h.write(Data("\(message)\n".utf8))
        h.closeFile()
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

                if isUploading || !statusMessage.isEmpty {
                    Divider()
                    statusBarView
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear {
            updateSimianServiceConfiguration()
            loadProjects()
            isProjectListFocused = false
            isSearchFocused = true
            // #region agent log
            logAgentFocus("root onAppear", hypothesisId: "H1", data: [
                "isSearchFocused": true,
                "isProjectListFocused": false
            ])
            // #endregion
        }
        .onChange(of: settingsManager.currentSettings.simianAPIBaseURL) { _, _ in
            updateSimianServiceConfiguration()
        }
        .sheet(isPresented: $showRenameSheet) { renameSheet }
        .sheet(isPresented: $showNewFolderSheet) { newFolderSheet }
        .sheet(isPresented: $showNewFolderWithSelectionSheet) { newFolderWithSelectionSheet }
        .alert("Remove from Simian?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { performPendingDelete() }
        } message: {
            let name = pendingDeleteItemName.isEmpty ? (pendingDeleteIsFolder ? "this folder" : "this file") : pendingDeleteItemName
            Text(pendingDeleteIsFolder
                 ? "\u{201C}\(name)\u{201D} and its contents will be removed from Simian. This cannot be undone."
                 : "\u{201C}\(name)\u{201D} will be removed from Simian. This cannot be undone.")
        }
        .onKeyPress(.leftArrow) { handleKeyLeft() }
        .onKeyPress(.rightArrow) { handleKeyRight() }
        .onKeyPress(.upArrow) { handleKeyUp() }
        .onKeyPress(.downArrow) { handleKeyDown() }
        .onKeyPress(.return) { handleKeyReturn() }
        .onKeyPress(.tab) { handleKeyTab() }
        .onKeyPress { handleGlobalKeyPress($0) }
        .onKeyPress(.escape) { handleKeyEscape() }
    }

    // MARK: - Keyboard navigation

    private func shouldIgnoreKeyPress(allowSearchFocusInProjectList: Bool = false, allowSearchFocusInProjectView: Bool = false) -> Bool {
        let searchActive = isSimianSearchInputActive
        if searchActive &&
            !(allowSearchFocusInProjectList && selectedProjectName == nil) &&
            !(allowSearchFocusInProjectView && selectedProjectName != nil) {
            return true
        }
        if inlineRenameItemId != nil { return true }
        // When showing the project list, the only text editor is the search field — allow arrow/tab reroute whenever typing is active.
        if let window = NSApp.keyWindow, KeyboardNavigationCoordinator.isEditingText(in: window) {
            let allowSearchReroute =
                (allowSearchFocusInProjectList && selectedProjectName == nil)
                || (allowSearchFocusInProjectView && selectedProjectName != nil && searchActive)
            if !allowSearchReroute { return true }
        }
        return false
    }

    private func handleKeyLeft() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        guard let projectId = selectedProjectId else { return .ignored }
        guard selectedItemIds.count == 1, let itemId = selectedItemIds.first else { return .ignored }
        if itemId.hasPrefix("f-") {
            let folderId = String(itemId.dropFirst(2))
            if expandedFolderIds.contains(folderId) {
                expandedFolderIds.remove(folderId)
                return .handled
            }
        }
        // Move selection to parent folder
        let treeList = flatTreeList(projectId: projectId)
        if let item = treeList.first(where: { $0.id == itemId }) {
            let parentFolderId: String?
            switch item {
            case .folder(_, _, _, let pid): parentFolderId = pid
            case .file(_, _, _, let pid): parentFolderId = pid
            }
            if let pid = parentFolderId {
                selectedItemIds = ["f-\(pid)"]
            }
            // else: at top level, stay on current item
            return .handled
        }
        return .ignored
    }

    private func handleKeyUp(fromSimianSearchField: Bool = false) -> KeyPress.Result {
        if !fromSimianSearchField {
            if shouldIgnoreKeyPress(allowSearchFocusInProjectList: true, allowSearchFocusInProjectView: true) { return .ignored }
        } else if inlineRenameItemId != nil {
            return .ignored
        }
        if selectedProjectName == nil && (isSimianSearchInputActive || fromSimianSearchField) {
            resignSimianSearchFieldForListNavigation()
            isProjectListFocused = true
        } else if selectedProjectName != nil && isSimianSearchInputActive {
            resignSimianSearchFieldForListNavigation()
            isFolderListFocused = true
        }
        if selectedProjectName == nil {
            let projects = filteredProjects
            guard !projects.isEmpty else { return .handled }
            if let selectedId = selectedProjectId,
               let idx = projects.firstIndex(where: { $0.id == selectedId }),
               idx > 0 {
                selectedProjectId = projects[idx - 1].id
            } else {
                selectedProjectId = projects.last?.id
            }
            return .handled
        }
        guard let projectId = selectedProjectId else { return .ignored }
        let treeList = flatTreeList(projectId: projectId)
        guard !treeList.isEmpty else { return .ignored }
        if selectedItemIds.isEmpty {
            selectedItemIds = [treeList.last!.id]
            return .handled
        }
        guard selectedItemIds.count == 1, let itemId = selectedItemIds.first else { return .ignored }
        if let idx = treeList.firstIndex(where: { $0.id == itemId }), idx > 0 {
            selectedItemIds = [treeList[idx - 1].id]
            return .handled
        }
        return .ignored
    }

    private func handleKeyDown(fromSimianSearchField: Bool = false) -> KeyPress.Result {
        if !fromSimianSearchField {
            if shouldIgnoreKeyPress(allowSearchFocusInProjectList: true, allowSearchFocusInProjectView: true) { return .ignored }
        } else if inlineRenameItemId != nil {
            return .ignored
        }
        if selectedProjectName == nil && (isSimianSearchInputActive || fromSimianSearchField) {
            resignSimianSearchFieldForListNavigation()
            isProjectListFocused = true
        } else if selectedProjectName != nil && isSimianSearchInputActive {
            resignSimianSearchFieldForListNavigation()
            isFolderListFocused = true
        }
        if selectedProjectName == nil {
            let projects = filteredProjects
            guard !projects.isEmpty else {
                if fromSimianSearchField { logSimianKeyDebug("handleKeyDown fromSearch emptyProjects handled") }
                return .handled
            }
            if let selectedId = selectedProjectId,
               let idx = projects.firstIndex(where: { $0.id == selectedId }),
               idx + 1 < projects.count {
                selectedProjectId = projects[idx + 1].id
            } else {
                selectedProjectId = projects.first?.id
            }
            if fromSimianSearchField {
                logSimianKeyDebug("handleKeyDown fromSearch selected=\(selectedProjectId ?? "nil") count=\(projects.count)")
            }
            return .handled
        }
        guard let projectId = selectedProjectId else { return .ignored }
        let treeList = flatTreeList(projectId: projectId)
        guard !treeList.isEmpty else { return .ignored }
        if selectedItemIds.isEmpty {
            selectedItemIds = [treeList.first!.id]
            return .handled
        }
        guard selectedItemIds.count == 1, let itemId = selectedItemIds.first else { return .ignored }
        if let idx = treeList.firstIndex(where: { $0.id == itemId }), idx + 1 < treeList.count {
            selectedItemIds = [treeList[idx + 1].id]
            return .handled
        }
        return .ignored
    }

    private func handleKeyRight() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        guard let projectId = selectedProjectId else { return .ignored }
        guard selectedItemIds.count == 1, let itemId = selectedItemIds.first else { return .ignored }
        if itemId.hasPrefix("f-") {
            let folderId = String(itemId.dropFirst(2))
            if !expandedFolderIds.contains(folderId) {
                expandedFolderIds.insert(folderId)
                if folderChildrenCache[folderId] == nil {
                    loadFolderChildren(projectId: projectId, folderId: folderId)
                }
                return .handled
            }
            // Already expanded: move selection to first child
            let treeList = flatTreeList(projectId: projectId)
            if let idx = treeList.firstIndex(where: { $0.id == itemId }), idx + 1 < treeList.count {
                selectedItemIds = [treeList[idx + 1].id]
                return .handled
            }
        }
        return .ignored
    }

    private func handleKeyReturn() -> KeyPress.Result {
        if shouldIgnoreKeyPress(allowSearchFocusInProjectList: true, allowSearchFocusInProjectView: true) { return .ignored }
        if selectedProjectName == nil && isSimianSearchInputActive {
            resignSimianSearchFieldForListNavigation()
            isProjectListFocused = true
        } else if selectedProjectName != nil && isSimianSearchInputActive {
            resignSimianSearchFieldForListNavigation()
            isFolderListFocused = true
        }
        if inlineRenameItemId != nil { return .ignored }
        // Project list mode: Enter opens selected project.
        if selectedProjectName == nil {
            guard let selectedId = selectedProjectId,
                  let project = filteredProjects.first(where: { $0.id == selectedId }) else {
                return .ignored
            }
            openProject(project)
            return .handled
        }
        guard selectedProjectId != nil else { return .ignored }
        guard selectedItemIds.count == 1, let itemId = selectedItemIds.first else { return .ignored }
        // Start inline rename
        let treeList = flatTreeList(projectId: selectedProjectId!)
        if let item = treeList.first(where: { $0.id == itemId }) {
            switch item {
            case .folder(let f, _, _, _):
                inlineRenameText = f.name
                inlineRenameItemId = itemId
            case .file(let f, _, _, _):
                inlineRenameText = f.title
                inlineRenameItemId = itemId
            }
            return .handled
        }
        return .ignored
    }

    private func handleKeyTab() -> KeyPress.Result {
        if inlineRenameItemId != nil { return .ignored }
        if isSimianSearchInputActive {
            resignSimianSearchFieldForListNavigation()
            if selectedProjectName == nil {
                isProjectListFocused = true
                if selectedProjectId == nil, let firstId = filteredProjects.first?.id {
                    selectedProjectId = firstId
                }
            } else {
                isFolderListFocused = true
                if selectedItemIds.isEmpty,
                   let projectId = selectedProjectId {
                    let treeList = flatTreeList(projectId: projectId)
                    if let first = treeList.first {
                        selectedItemIds = [first.id]
                    }
                }
            }
        } else {
            isProjectListFocused = false
            isFolderListFocused = false
            isSearchFocused = true
        }
        return .handled
    }

    private func handleGlobalKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let cmdResult = handleCommandKeyPress(press)
        if cmdResult == .handled { return .handled }

        let keyWin = NSApp.keyWindow
        let editing = keyWin.map { KeyboardNavigationCoordinator.isEditingText(in: $0) } ?? false
        // #region agent log
        logAgentFocus("handleGlobalKeyPress entry", hypothesisId: "H2", data: [
            "isEditingText": editing,
            "isSimianSearchInputActive": isSimianSearchInputActive,
            "simianNativeFR": simianSearchFieldIsFirstResponder,
            "isSearchFocusedState": isSearchFocused,
            "isProjectListFocused": isProjectListFocused,
            "charCount": press.characters.count,
            "key": String(describing: press.key)
        ])
        // #endregion

        if let window = keyWin, KeyboardNavigationCoordinator.isEditingText(in: window) {
            // #region agent log
            logAgentFocus("globalKeyPress ignored: text editing active", hypothesisId: "H2", data: [:])
            // #endregion
            return .ignored
        }

        // Typing while in keyboard-nav mode returns focus to search and seeds typed character.
        // Do NOT gate on `isSimianSearchInputActive`: after the first key we set `isSearchFocused` true while
        // AppKit first responder can still be the list — `isEditingText` is false, so requiring
        // `!isSimianSearchInputActive` drops the next keystroke → system beep (see H4 logs).
        if !press.modifiers.contains(.command),
           press.characters.count == 1,
           let char = press.characters.first,
           (char.isLetter || char.isNumber || (char.isWhitespace && !char.isNewline) || char.isPunctuation) {
            isProjectListFocused = false
            isFolderListFocused = false
            isSearchFocused = true
            searchText.append(char)
            // #region agent log
            logAgentFocus("globalKeyPress typing branch handled", hypothesisId: "H4", data: [
                "char": String(char),
                "isSimianSearchInputActive": isSimianSearchInputActive,
                "simianNativeFR": simianSearchFieldIsFirstResponder
            ])
            // #endregion
            return .handled
        }

        return .ignored
    }

    private func handleCommandKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }

        // Cmd+Down: open selected item (Finder-style).
        if press.key == .downArrow {
            // Project list mode: open selected project.
            if selectedProjectName == nil {
                if isSimianSearchInputActive {
                    resignSimianSearchFieldForListNavigation()
                    isProjectListFocused = true
                }
                guard let selectedId = selectedProjectId,
                      let project = filteredProjects.first(where: { $0.id == selectedId }) else {
                    return .ignored
                }
                openProject(project)
                return .handled
            }

            // Inside a project: if a folder is selected, enter it as the exclusive view.
            guard let projectId = selectedProjectId,
                  selectedItemIds.count == 1,
                  let itemId = selectedItemIds.first,
                  itemId.hasPrefix("f-") else {
                return .ignored
            }
            let folderId = String(itemId.dropFirst(2))
            let treeList = flatTreeList(projectId: projectId)
            let folderName: String
            if let match = treeList.first(where: { $0.id == itemId }),
               case .folder(let folder, _, _, _) = match {
                folderName = folder.name
            } else {
                folderName = "Folder"
            }

            if folderBreadcrumb.last?.id != folderId {
                folderBreadcrumb.append((id: folderId, name: folderName))
            }
            selectedItemIds.removeAll()
            expandedFolderIds.removeAll()
            loadFolders(projectId: projectId, parentFolderId: folderId)
            isFolderListFocused = true
            return .handled
        }

        // Cmd+Up: go up one level; exit project only when already at project root.
        if press.key == .upArrow {
            guard let projectId = selectedProjectId, selectedProjectName != nil else { return .ignored }
            if !folderBreadcrumb.isEmpty {
                folderBreadcrumb.removeLast()
                selectedItemIds.removeAll()
                expandedFolderIds.removeAll()
                loadFolders(projectId: projectId, parentFolderId: folderBreadcrumb.last?.id)
                isFolderListFocused = true
            } else {
                exitToProjectList(keepSelection: true)
            }
            return .handled
        }

        return .ignored
    }

    private func exitToProjectList(keepSelection: Bool) {
        let previousProjectId = selectedProjectId
        selectedProjectName = nil
        folderBreadcrumb = []
        currentFolders = []
        selectedItemIds.removeAll()
        expandedFolderIds.removeAll()
        folderChildrenCache.removeAll()
        folderFilesCache.removeAll()
        loadingFolderIds.removeAll()
        if !keepSelection {
            selectedProjectId = nil
        } else if let previousProjectId {
            selectedProjectId = previousProjectId
        }
        isProjectListFocused = true
    }

    private func handleKeyEscape() -> KeyPress.Result {
        if inlineRenameItemId != nil {
            inlineRenameItemId = nil
            inlineRenameText = ""
            return .handled
        }
        if selectedProjectId != nil && selectedItemIds.isEmpty {
            exitToProjectList(keepSelection: false)
            return .handled
        }
        if !selectedItemIds.isEmpty {
            selectedItemIds.removeAll()
            return .handled
        }
        return .ignored
    }

    /// Commit inline rename for the currently-editing item
    private func commitInlineRename() {
        guard let itemId = inlineRenameItemId, let projectId = selectedProjectId else {
            inlineRenameItemId = nil
            return
        }
        let newName = inlineRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { inlineRenameItemId = nil; return }
        let treeList = flatTreeList(projectId: projectId)
        guard let item = treeList.first(where: { $0.id == itemId }) else { inlineRenameItemId = nil; return }

        inlineRenameItemId = nil
        Task {
            do {
                switch item {
                case .folder(let f, _, _, let parentId):
                    guard newName != f.name else { return }
                    try await simianService.renameFolder(projectId: projectId, folderId: f.id, newName: newName)
                    await MainActor.run {
                        applyFolderRename(folderId: f.id, parentFolderId: parentId, newName: newName)
                        statusMessage = "Folder renamed"; statusIsError = false
                    }
                case .file(let f, _, _, let parentId):
                    guard newName != f.title else { return }
                    try await simianService.renameFile(projectId: projectId, fileId: f.id, newName: newName)
                    await MainActor.run {
                        applyFileRename(fileId: f.id, parentFolderId: parentId, newName: newName)
                        statusMessage = "File renamed"; statusIsError = false
                    }
                }
            } catch {
                await MainActor.run {
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    statusIsError = true
                }
            }
        }
    }

    // MARK: - Sheets

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(renameIsFolder ? "Rename Folder" : "Rename File").font(.headline)
            TextField("Name", text: $renameNewName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showRenameSheet = false }.keyboardShortcut(.cancelAction)
                Button("Rename") { submitRename() }.keyboardShortcut(.defaultAction)
                    .disabled(renameNewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 320)
        .onAppear { renameNewName = renameCurrentName }
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder").font(.headline)
            TextField("Folder name", text: $newFolderName).textFieldStyle(.roundedBorder)
            if let err = newFolderError { Text(err).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { showNewFolderSheet = false; newFolderError = nil }.keyboardShortcut(.cancelAction)
                Button("Create") { submitNewFolder() }.keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreatingFolder)
            }
        }
        .padding(24).frame(width: 320)
        .onAppear { newFolderName = ""; newFolderError = nil }
    }

    private var newFolderWithSelectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder with Selection").font(.headline)
            Text("Create a folder and move \(newFolderWithSelectionIds.count) selected item(s) into it.")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("Folder name", text: $newFolderWithSelectionName).textFieldStyle(.roundedBorder)
            if let err = newFolderWithSelectionError { Text(err).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { showNewFolderWithSelectionSheet = false; newFolderWithSelectionError = nil }.keyboardShortcut(.cancelAction)
                Button("Create") { submitNewFolderWithSelection() }.keyboardShortcut(.defaultAction)
                    .disabled(newFolderWithSelectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreatingFolderWithSelection)
            }
        }
        .padding(24).frame(width: 360)
        .onAppear { newFolderWithSelectionName = "New Folder"; newFolderWithSelectionError = nil }
    }

    // MARK: - Submit actions

    private func submitNewFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let projectId = selectedProjectId else { return }
        isCreatingFolder = true; newFolderError = nil
        let parentId = newFolderParentId
        Task {
            do {
                _ = try await simianService.createFolderPublic(projectId: projectId, folderName: name, parentFolderId: parentId)
                await MainActor.run {
                    isCreatingFolder = false; showNewFolderSheet = false; newFolderName = ""; newFolderError = nil
                    if parentId == nil { loadFolders(projectId: projectId, parentFolderId: nil) }
                    else { folderChildrenCache.removeValue(forKey: parentId!); expandedFolderIds.insert(parentId!); loadFolderChildren(projectId: projectId, folderId: parentId!) }
                    statusMessage = "Folder created"; statusIsError = false
                }
            } catch {
                await MainActor.run { isCreatingFolder = false; newFolderError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    private func submitNewFolderWithSelection() {
        let name = newFolderWithSelectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let projectId = selectedProjectId else { return }
        isCreatingFolderWithSelection = true; newFolderWithSelectionError = nil
        let parentId = newFolderWithSelectionParentId
        let itemIds = newFolderWithSelectionIds
        let treeList = flatTreeList(projectId: projectId)
        typealias FolderMoveInfo = (sourceParentId: String?, sourceSiblingIds: [String])
        var folderMoveInfos: [String: FolderMoveInfo] = [:]
        for treeId in itemIds where treeId.hasPrefix("f-") && treeId.count > 2 {
            let folderId = String(treeId.dropFirst(2))
            guard let item = treeList.first(where: { $0.id == treeId }),
                  case .folder(_, _, _, let sourceParentId) = item else { continue }
            let siblings = folderSiblings(parentId: sourceParentId)
            folderMoveInfos[folderId] = (sourceParentId, siblings.filter { $0.id != folderId }.map { $0.id })
        }
        Task {
            do {
                let newFolderId = try await simianService.createFolderPublic(projectId: projectId, folderName: name, parentFolderId: parentId)
                var filesMoved = 0
                var foldersMoved = 0
                for treeId in itemIds {
                    if treeId.hasPrefix("file-"), treeId.count > 5 {
                        let fileId = String(treeId.dropFirst(5))
                        try await simianService.moveFile(projectId: projectId, fileId: fileId, folderId: newFolderId)
                        filesMoved += 1
                    } else if treeId.hasPrefix("f-"), treeId.count > 2 {
                        let folderId = String(treeId.dropFirst(2))
                        guard let info = folderMoveInfos[folderId] else { continue }
                        try await moveFolderIntoFolder(projectId: projectId, folderId: folderId, sourceParentId: info.sourceParentId, sourceSiblingIdsWithoutThis: info.sourceSiblingIds, targetFolderId: newFolderId)
                        foldersMoved += 1
                    }
                }
                await MainActor.run {
                    isCreatingFolderWithSelection = false; showNewFolderWithSelectionSheet = false
                    newFolderWithSelectionName = ""; newFolderWithSelectionError = nil
                    if parentId == nil { loadFolders(projectId: projectId, parentFolderId: nil) }
                    else {
                        folderChildrenCache.removeValue(forKey: parentId!); folderFilesCache.removeValue(forKey: parentId!)
                        expandedFolderIds.insert(parentId!); loadFolderChildren(projectId: projectId, folderId: parentId!)
                    }
                    folderChildrenCache.removeValue(forKey: newFolderId); folderFilesCache.removeValue(forKey: newFolderId)
                    var msg = "Folder created"
                    if filesMoved > 0 || foldersMoved > 0 {
                        var parts: [String] = []
                        if filesMoved > 0 { parts.append("\(filesMoved) file(s)") }
                        if foldersMoved > 0 { parts.append("\(foldersMoved) folder(s)") }
                        msg += "; \(parts.joined(separator: " and ")) moved"
                    }
                    statusMessage = msg; statusIsError = false
                }
            } catch {
                await MainActor.run { isCreatingFolderWithSelection = false; newFolderWithSelectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    /// Move a folder into another folder (same project) using update_folder_sort.
    private func moveFolderIntoFolder(projectId: String, folderId: String, sourceParentId: String?, sourceSiblingIdsWithoutThis: [String], targetFolderId: String) async throws {
        try await simianService.updateFolderSort(projectId: projectId, parentFolderId: sourceParentId, folderIds: sourceSiblingIdsWithoutThis)
        let targetChildren = (try? await simianService.getProjectFolders(projectId: projectId, parentFolderId: targetFolderId)) ?? []
        let existingIds = targetChildren.map { $0.id }
        if existingIds.contains(folderId) { return }
        try await simianService.updateFolderSort(projectId: projectId, parentFolderId: targetFolderId, folderIds: existingIds + [folderId])
    }

    /// Move files and/or folders into a target folder (e.g. when dropping on a folder row).
    private func moveItemsIntoFolder(projectId: String, itemIds: [String], targetFolderId: String) {
        let treeList = flatTreeList(projectId: projectId)
        typealias FolderMoveInfo = (sourceParentId: String?, sourceSiblingIds: [String])
        var folderMoveInfos: [String: FolderMoveInfo] = [:]
        for treeId in itemIds where treeId.hasPrefix("f-") && treeId.count > 2 {
            let folderId = String(treeId.dropFirst(2))
            guard let item = treeList.first(where: { $0.id == treeId }),
                  case .folder(_, _, _, let sourceParentId) = item else { continue }
            let siblings = folderSiblings(parentId: sourceParentId)
            folderMoveInfos[folderId] = (sourceParentId, siblings.filter { $0.id != folderId }.map { $0.id })
        }
        Task {
            do {
                var filesMoved = 0, foldersMoved = 0
                for treeId in itemIds {
                    if treeId.hasPrefix("file-"), treeId.count > 5 {
                        let fileId = String(treeId.dropFirst(5))
                        try await simianService.moveFile(projectId: projectId, fileId: fileId, folderId: targetFolderId)
                        filesMoved += 1
                    } else if treeId.hasPrefix("f-"), treeId.count > 2 {
                        let folderId = String(treeId.dropFirst(2))
                        guard let info = folderMoveInfos[folderId] else { continue }
                        try await moveFolderIntoFolder(projectId: projectId, folderId: folderId, sourceParentId: info.sourceParentId, sourceSiblingIdsWithoutThis: info.sourceSiblingIds, targetFolderId: targetFolderId)
                        foldersMoved += 1
                    }
                }
                await MainActor.run {
                    folderChildrenCache.removeValue(forKey: targetFolderId)
                    folderFilesCache.removeValue(forKey: targetFolderId)
                    for (_, info) in folderMoveInfos { if let pid = info.sourceParentId { folderChildrenCache.removeValue(forKey: pid) } }
                    loadFolders(projectId: projectId, parentFolderId: currentParentFolderId)
                    for folderId in expandedFolderIds { loadFolderChildren(projectId: projectId, folderId: folderId) }
                    var msg = ""
                    if filesMoved > 0 || foldersMoved > 0 {
                        var parts: [String] = []
                        if filesMoved > 0 { parts.append("\(filesMoved) file(s)") }
                        if foldersMoved > 0 { parts.append("\(foldersMoved) folder(s)") }
                        msg = "\(parts.joined(separator: " and ")) moved"
                    } else { msg = "Moved" }
                    statusMessage = msg; statusIsError = false
                }
            } catch {
                await MainActor.run { statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
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
                    await MainActor.run { applyFolderRename(folderId: renameItemId, parentFolderId: renameParentFolderId, newName: newName) }
                } else {
                    try await simianService.renameFile(projectId: projectId, fileId: renameItemId, newName: newName)
                    await MainActor.run { applyFileRename(fileId: renameItemId, parentFolderId: renameParentFolderId, newName: newName) }
                }
                await MainActor.run { statusMessage = renameIsFolder ? "Folder renamed" : "File renamed"; statusIsError = false }
            } catch {
                await MainActor.run { statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
            }
        }
    }

    private func applyFolderRename(folderId: String, parentFolderId: String?, newName: String) {
        if let parentId = parentFolderId, !parentId.isEmpty {
            if var children = folderChildrenCache[parentId], let idx = children.firstIndex(where: { $0.id == folderId }) {
                let old = children[idx]; children[idx] = SimianFolder(id: old.id, name: newName, parentId: old.parentId)
                folderChildrenCache[parentId] = children
            }
        } else {
            if let idx = currentFolders.firstIndex(where: { $0.id == folderId }) {
                let old = currentFolders[idx]; currentFolders[idx] = SimianFolder(id: old.id, name: newName, parentId: old.parentId)
            }
        }
    }

    private func applyFileRename(fileId: String, parentFolderId: String?, newName: String) {
        guard let parentId = parentFolderId else { return }
        if var files = folderFilesCache[parentId], let idx = files.firstIndex(where: { $0.id == fileId }) {
            let old = files[idx]
            files[idx] = SimianFile(id: old.id, title: newName, fileType: old.fileType, mediaURL: old.mediaURL, folderId: old.folderId, projectId: old.projectId)
            folderFilesCache[parentId] = files
        }
    }

    private func performPendingDelete() {
        guard let projectId = selectedProjectId else { return }
        let isFolder = pendingDeleteIsFolder; let itemId = pendingDeleteItemId; let parentId = pendingDeleteParentFolderId
        showDeleteConfirmation = false
        Task {
            do {
                if isFolder {
                    try await simianService.deleteFolder(projectId: projectId, folderId: itemId)
                    await MainActor.run {
                        applyFolderDeletion(folderId: itemId, parentFolderId: parentId)
                        expandedFolderIds.remove(itemId); folderChildrenCache.removeValue(forKey: itemId); folderFilesCache.removeValue(forKey: itemId)
                        selectedItemIds.remove("f-\(itemId)"); statusMessage = "Folder removed"; statusIsError = false
                    }
                } else {
                    try await simianService.deleteFile(projectId: projectId, fileId: itemId)
                    await MainActor.run {
                        applyFileDeletion(fileId: itemId, parentFolderId: parentId)
                        selectedItemIds.remove("file-\(itemId)"); statusMessage = "File removed"; statusIsError = false
                    }
                }
                await MainActor.run { refreshCurrentView() }
            } catch {
                await MainActor.run { statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
            }
        }
    }

    private func applyFolderDeletion(folderId: String, parentFolderId: String?) {
        if let pid = parentFolderId, !pid.isEmpty { folderChildrenCache[pid] = folderChildrenCache[pid]?.filter { $0.id != folderId } ?? [] }
        else { currentFolders = currentFolders.filter { $0.id != folderId } }
    }

    private func applyFileDeletion(fileId: String, parentFolderId: String?) {
        guard let pid = parentFolderId else { return }
        folderFilesCache[pid] = folderFilesCache[pid]?.filter { $0.id != fileId } ?? []
    }

    private func refreshCurrentView() {
        if let projectId = selectedProjectId {
            folderChildrenCache.removeAll(); folderFilesCache.removeAll()
            loadFolders(projectId: projectId, parentFolderId: currentParentFolderId)
            for folderId in expandedFolderIds { loadFolderChildren(projectId: projectId, folderId: folderId) }
        } else { loadProjects() }
    }

    // MARK: - View builders

    private func unavailableView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
            VStack(spacing: 8) {
                Text("Simian Unavailable").font(.title3.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Button("Open Settings") { SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager) }.buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func projectNameBarView(projectName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").font(.system(size: 14)).foregroundStyle(.blue)
            Text(projectName).font(.subheadline.weight(.medium))
            Spacer()
        }.padding(.horizontal, 12).padding(.vertical, 8).background(Color(nsColor: .controlBackgroundColor)).frame(maxWidth: .infinity)
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
                    onTextChange: { },
                    onMoveUp: {
                        switch handleKeyUp(fromSimianSearchField: true) {
                        case .handled: return true
                        default: return false
                        }
                    },
                    onMoveDown: {
                        switch handleKeyDown(fromSimianSearchField: true) {
                        case .handled: return true
                        default: return false
                        }
                    },
                    onTab: {
                        switch handleKeyTab() {
                        case .handled: return true
                        default: return false
                        }
                    },
                    onEditingBegan: { simianSearchFieldIsFirstResponder = true },
                    onEditingEnded: { simianSearchFieldIsFirstResponder = false },
                    onNativeFirstResponderChange: { isKey in
                        // #region agent log
                        logAgentFocus("search onNativeFirstResponderChange", hypothesisId: "H3", data: [
                            "isKey": isKey,
                            "searchTextLen": searchText.count
                        ])
                        // #endregion
                        simianSearchFieldIsFirstResponder = isKey
                    }
                )
                .padding(10)
                if !searchText.isEmpty {
                    HoverableButton(action: { searchText = "" }) { isHovered in
                        Image(systemName: "xmark.circle.fill").foregroundStyle(isHovered ? .primary : .secondary).scaleEffect(isHovered ? 1.1 : 1.0)
                    }
                }
                Picker("Sort", selection: $projectSortOrder) {
                    Text("Name (A\u{2013}Z)").tag(ProjectSortOrder.nameAsc)
                    Text("Name (Z\u{2013}A)").tag(ProjectSortOrder.nameDesc)
                    Text("Last edited (newest)").tag(ProjectSortOrder.lastEditedNewest)
                    Text("Last edited (oldest)").tag(ProjectSortOrder.lastEditedOldest)
                }.pickerStyle(.menu).labelsHidden().frame(width: 160).onChange(of: projectSortOrder) { _, _ in loadProjectInfosIfNeeded() }
                Button(action: { refreshCurrentView() }) { Image(systemName: "arrow.clockwise").font(.system(size: 14)) }.buttonStyle(.borderless).help("Refresh project list")
                if isLoadingProjectInfos { ProgressView().scaleEffect(0.7) }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(Color(nsColor: .controlBackgroundColor)).frame(maxWidth: .infinity)
    }

    private var projectListView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoadingProjects && allProjects.isEmpty {
                HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text("Loading projects...").font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else if filteredProjects.isEmpty {
                VStack(spacing: 8) { Image(systemName: "folder.badge.questionmark").font(.title).foregroundStyle(.secondary); Text("No projects match your search").font(.subheadline).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedProjectId) {
                        ForEach(filteredProjects, id: \.id) { project in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                                Text(project.name).font(.system(size: 14))
                                Spacer()
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .tag(project.id)
                            .id(project.id)
                            .onTapGesture { openProject(project) }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .focusable()
                    .focused($isProjectListFocused)
                    .onAppear {
                        // #region agent log
                        logAgentFocus("projectList onAppear (no longer stealing list focus)", hypothesisId: "H1", data: [
                            "filteredCount": filteredProjects.count,
                            "searchLen": searchText.count
                        ])
                        // #endregion
                        if selectedProjectId == nil, let firstId = filteredProjects.first?.id {
                            selectedProjectId = firstId
                        }
                    }
                    .onChange(of: selectedProjectId) { _, newValue in
                        guard selectedProjectName == nil, let id = newValue else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openProject(_ project: SimianProject) {
        selectedProjectId = project.id; selectedProjectName = project.name; folderBreadcrumb = []
        selectedItemIds.removeAll(); expandedFolderIds.removeAll(); folderChildrenCache.removeAll(); folderFilesCache.removeAll()
        loadFolders(projectId: project.id, parentFolderId: nil)
    }

    private func folderBrowserView(projectId: String, projectName: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: {
                    selectedProjectId = nil; selectedProjectName = nil; folderBreadcrumb = []; currentFolders = []
                    selectedItemIds.removeAll(); expandedFolderIds.removeAll(); folderChildrenCache.removeAll(); folderFilesCache.removeAll()
                }) { Label("Back to projects", systemImage: "chevron.left").font(.caption) }.buttonStyle(.borderless)
                Text("\u{2192}").font(.caption).foregroundStyle(.secondary)
                Text(projectName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: { refreshCurrentView() }) { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }.buttonStyle(.borderless).help("Refresh folders and files")
            }.padding(.horizontal, 12).padding(.vertical, 8).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            if isLoadingFolders {
                HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text("Loading folders...").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding()
            } else {
                let treeList = flatTreeList(projectId: projectId)
                let treeListAnimationKey = treeList.map(\.id).joined(separator: "|")
                ScrollViewReader { proxy in
                    List(selection: $selectedItemIds) {
                        ForEach(Array(treeList.enumerated()), id: \.element.id) { _, item in
                            Group {
                                switch item {
                                case .folder(let f, let d, let p, let parentId):
                                    folderTreeRow(projectId: projectId, folder: f, depth: d, path: p, parentFolderId: parentId, siblings: folderSiblings(parentId: parentId), treeList: treeList)
                                case .file(let file, let d, let p, let parentId):
                                    fileTreeRow(file: file, depth: d, path: p, parentFolderId: parentId, siblings: fileSiblings(parentFolderId: parentId), treeList: treeList)
                                }
                            }
                            .tag(item.id).id(item.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 8))
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if treeList.count >= maxTotalTreeRows {
                            Text("(Showing first \(maxTotalTreeRows) items)").font(.caption2).foregroundStyle(.secondary).padding(.vertical, 4)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .animation(.spring(response: 0.45, dampingFraction: 0.7, blendDuration: 0.15), value: treeListAnimationKey)
                    .focusable()
                    .focused($isFolderListFocused)
                    .onAppear {
                        isFolderListFocused = true
                        if selectedItemIds.isEmpty, !treeList.isEmpty {
                            selectedItemIds = [treeList[0].id]
                        }
                    }
                    .onChange(of: selectedItemIds) { _, newValue in
                        guard selectedProjectId != nil,
                              selectedProjectName != nil,
                              newValue.count == 1,
                              let id = newValue.first else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status bar

    private var statusBarView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isUploading {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Uploading \(uploadCurrent) of \(uploadTotal)").font(.subheadline).fontWeight(.medium)
                        if !uploadFileName.isEmpty { Text(uploadFileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !statusMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(statusIsError ? .orange : .green)
                    Text(statusMessage).font(.caption).foregroundStyle(statusIsError ? .orange : .secondary)
                    Spacer()
                    Button(action: { statusMessage = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Upload via context menu

    private func uploadToFolder(folderId: String?) {
        guard let projectId = selectedProjectId else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "Select files or folders to upload"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            DispatchQueue.main.async { uploadDroppedFiles(projectId: projectId, folderId: folderId, fileURLs: panel.urls) }
        }
    }

    private func uploadStagedFiles(folderId: String?) {
        guard let projectId = selectedProjectId, !manager.selectedFiles.isEmpty else { return }
        uploadDroppedFiles(projectId: projectId, folderId: folderId, fileURLs: manager.selectedFiles.map { $0.url })
    }

    // MARK: - Tree row builders

    private func folderTreeRow(projectId: String, folder: SimianFolder, depth: Int, path: String, parentFolderId: String?, siblings: [SimianFolder], treeList: [SimianTreeItem]) -> some View {
        let isExpanded = expandedFolderIds.contains(folder.id)
        let isLoading = loadingFolderIds.contains(folder.id)
        let hasOrMayHaveChildren = folderChildrenCache[folder.id] != nil || !isExpanded
        let isEditing = inlineRenameItemId == "f-\(folder.id)"

        return SimianFolderRow(
            folderId: folder.id, projectId: projectId, parentFolderId: parentFolderId,
            isExpanded: isExpanded, isLoading: isLoading, hasOrMayHaveChildren: hasOrMayHaveChildren,
            depth: depth, folderName: folder.name, canReorder: siblings.count > 1,
            isEditing: isEditing, editText: $inlineRenameText,
            selectedItemIds: selectedItemIds,
            onChevronTap: { selectedItemIds = ["f-\(folder.id)"]; toggleExpand(projectId: projectId, folderId: folder.id) },
            onDoubleTap: { selectedItemIds = ["f-\(folder.id)"]; toggleExpand(projectId: projectId, folderId: folder.id) },
            onExternalFileDrop: { providers in handleExternalFileDrop(providers: providers, folderId: folder.id) },
            onSelect: { selectedItemIds = ["f-\(folder.id)"] },
            onMoveIntoFolder: { draggedIds in moveItemsIntoFolder(projectId: projectId, itemIds: draggedIds, targetFolderId: folder.id) },
            onReorderDrop: { draggedIds in reorderItems(projectId: projectId, draggedIds: draggedIds, targetId: "f-\(folder.id)", treeList: treeList) },
            onReorderInsertAfter: { draggedIds in
                let nextId = siblings.firstIndex(where: { $0.id == folder.id }).flatMap { i in i + 1 < siblings.count ? siblings[i + 1].id : nil }
                reorderItems(projectId: projectId, draggedIds: draggedIds, targetId: nextId.map { "f-\($0)" }, treeList: treeList)
            },
            onCommitRename: { commitInlineRename() },
            onCancelRename: { inlineRenameItemId = nil; inlineRenameText = "" }
        )
        .contextMenu {
            Button("Upload to\u{2026}") { uploadToFolder(folderId: folder.id) }
            if !manager.selectedFiles.isEmpty {
                Button("Upload \(manager.selectedFiles.count) staged file(s) here") { uploadStagedFiles(folderId: folder.id) }
            }
            Divider()
            Button("New Folder with Selection") { startNewFolderWithSelection(projectId: projectId, treeList: treeList, rightClickedId: "f-\(folder.id)") }
            Button("New Folder") { newFolderParentId = folder.id; newFolderName = ""; showNewFolderSheet = true }
            Button("Rename\u{2026}") {
                renameIsFolder = true; renameItemId = folder.id; renameParentFolderId = parentFolderId
                renameCurrentName = folder.name; renameNewName = folder.name; showRenameSheet = true
            }
            Button("Copy Link") { copyFolderLink(projectId: projectId, folderId: folder.id) }
            Divider()
            Button("Remove from Simian\u{2026}", role: .destructive) {
                pendingDeleteIsFolder = true; pendingDeleteItemId = folder.id; pendingDeleteItemName = folder.name
                pendingDeleteParentFolderId = parentFolderId; showDeleteConfirmation = true
            }
        }
    }

    private func fileTreeRow(file: SimianFile, depth: Int, path: String, parentFolderId: String?, siblings: [SimianFile], treeList: [SimianTreeItem]) -> some View {
        let isEditing = inlineRenameItemId == "file-\(file.id)"
        return SimianFileRow(
            fileId: file.id, projectId: selectedProjectId ?? "", parentFolderId: parentFolderId,
            depth: depth, fileName: file.title, canReorder: siblings.count > 1,
            isEditing: isEditing, editText: $inlineRenameText,
            selectedItemIds: selectedItemIds,
            onSelect: { selectedItemIds = ["file-\(file.id)"] },
            onReorderDrop: { draggedIds in reorderItems(projectId: selectedProjectId ?? "", draggedIds: draggedIds, targetId: "file-\(file.id)", treeList: treeList) },
            onReorderInsertAfter: { draggedIds in
                let nextId = siblings.firstIndex(where: { $0.id == file.id }).flatMap { i in i + 1 < siblings.count ? siblings[i + 1].id : nil }
                reorderItems(projectId: selectedProjectId ?? "", draggedIds: draggedIds, targetId: nextId.map { "file-\($0)" }, treeList: treeList)
            },
            onCommitRename: { commitInlineRename() },
            onCancelRename: { inlineRenameItemId = nil; inlineRenameText = "" }
        )
        .contextMenu {
            Button("New Folder with Selection") { startNewFolderWithSelection(projectId: selectedProjectId ?? "", treeList: treeList, rightClickedId: "file-\(file.id)") }
            Button("Rename\u{2026}") {
                renameIsFolder = false; renameItemId = file.id; renameParentFolderId = parentFolderId
                renameCurrentName = file.title; renameNewName = file.title; showRenameSheet = true
            }
            Divider()
            Button("Remove from Simian\u{2026}", role: .destructive) {
                pendingDeleteIsFolder = false; pendingDeleteItemId = file.id; pendingDeleteItemName = file.title
                pendingDeleteParentFolderId = parentFolderId; showDeleteConfirmation = true
            }
        }
    }

    private func toggleExpand(projectId: String, folderId: String) {
        if expandedFolderIds.contains(folderId) { expandedFolderIds.remove(folderId) }
        else {
            expandedFolderIds.insert(folderId)
            if folderChildrenCache[folderId] == nil { loadFolderChildren(projectId: projectId, folderId: folderId) }
        }
    }

    private func startNewFolderWithSelection(projectId: String, treeList: [SimianTreeItem], rightClickedId: String) {
        func parentId(for treeId: String) -> String? {
            guard let item = treeList.first(where: { $0.id == treeId }) else { return nil }
            switch item { case .folder(_, _, _, let pid): return pid; case .file(_, _, _, let pid): return pid }
        }
        // Use all selected items when the right-clicked item is in the selection; otherwise just the right-clicked item
        let ids = (selectedItemIds.contains(rightClickedId) && selectedItemIds.count > 1)
            ? Array(selectedItemIds)
            : [rightClickedId]
        newFolderWithSelectionIds = ids
        newFolderWithSelectionParentId = parentId(for: rightClickedId)
        newFolderWithSelectionName = "New Folder"
        newFolderWithSelectionError = nil
        showNewFolderWithSelectionSheet = true
    }

    // MARK: - Multi-item reorder

    /// Reorder one or more dragged items relative to a target position in the tree.
    private func reorderItems(projectId: String, draggedIds: [String], targetId: String?, treeList: [SimianTreeItem]) {
        // For now, handle the first dragged item to determine type, then batch
        let folderIds = draggedIds.compactMap { id -> String? in id.hasPrefix("f-") ? String(id.dropFirst(2)) : nil }
        let fileIds = draggedIds.compactMap { id -> String? in id.hasPrefix("file-") ? String(id.dropFirst(5)) : nil }

        if !folderIds.isEmpty, let targetId = targetId, targetId.hasPrefix("f-") {
            let targetFolderId = String(targetId.dropFirst(2))
            // Find parent from target
            if let targetItem = treeList.first(where: { $0.id == targetId }), case .folder(_, _, _, let parentId) = targetItem {
                reorderFolders(projectId: projectId, folderIds: folderIds, parentFolderId: parentId, dropBeforeFolderId: targetFolderId)
            }
        }
        if !fileIds.isEmpty, let targetId = targetId, targetId.hasPrefix("file-") {
            let targetFileId = String(targetId.dropFirst(5))
            if let targetItem = treeList.first(where: { $0.id == targetId }), case .file(_, _, _, let parentId) = targetItem {
                reorderFiles(projectId: projectId, fileIds: fileIds, parentFolderId: parentId, dropBeforeFileId: targetFileId)
            }
        }
        // If targetId is nil (insert at end), use last item's parent
        if targetId == nil {
            if !folderIds.isEmpty {
                if let firstDragged = treeList.first(where: { draggedIds.contains($0.id) }), case .folder(_, _, _, let parentId) = firstDragged {
                    reorderFolders(projectId: projectId, folderIds: folderIds, parentFolderId: parentId, dropBeforeFolderId: nil)
                }
            }
            if !fileIds.isEmpty {
                if let firstDragged = treeList.first(where: { draggedIds.contains($0.id) }), case .file(_, _, _, let parentId) = firstDragged {
                    reorderFiles(projectId: projectId, fileIds: fileIds, parentFolderId: parentId, dropBeforeFileId: nil)
                }
            }
        }
    }

    private func reorderFolders(projectId: String, folderIds: [String], parentFolderId: String?, dropBeforeFolderId: String?) {
        let siblings = folderSiblings(parentId: parentFolderId)
        var reordered = siblings.filter { !folderIds.contains($0.id) }
        let moved = siblings.filter { folderIds.contains($0.id) }
        guard !moved.isEmpty else { return }
        let insertIdx: Int
        if let beforeId = dropBeforeFolderId, let toIdx = reordered.firstIndex(where: { $0.id == beforeId }) { insertIdx = toIdx }
        else { insertIdx = reordered.count }
        reordered.insert(contentsOf: moved, at: insertIdx)
        let ids = reordered.map { $0.id }
        Task {
            do {
                try await simianService.updateFolderSort(projectId: projectId, parentFolderId: parentFolderId, folderIds: ids)
                await MainActor.run {
                    if let pid = parentFolderId { folderChildrenCache[pid] = reordered } else { currentFolders = reordered }
                    statusMessage = moved.count > 1 ? "\(moved.count) folders moved" : "Folder moved"; statusIsError = false
                }
            } catch {
                await MainActor.run { statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
            }
        }
    }

    private func reorderFiles(projectId: String, fileIds: [String], parentFolderId: String?, dropBeforeFileId: String?) {
        guard let pid = parentFolderId else { return }
        let siblings = fileSiblings(parentFolderId: pid)
        var reordered = siblings.filter { !fileIds.contains($0.id) }
        let moved = siblings.filter { fileIds.contains($0.id) }
        guard !moved.isEmpty else { return }
        let insertIdx: Int
        if let beforeId = dropBeforeFileId, let toIdx = reordered.firstIndex(where: { $0.id == beforeId }) { insertIdx = toIdx }
        else { insertIdx = reordered.count }
        reordered.insert(contentsOf: moved, at: insertIdx)
        let ids = reordered.map { $0.id }
        Task {
            do {
                try await simianService.updateFileSort(projectId: projectId, folderId: pid, fileIds: ids)
                await MainActor.run {
                    folderFilesCache[pid] = reordered
                    statusMessage = moved.count > 1 ? "\(moved.count) files moved" : "File moved"; statusIsError = false
                }
            } catch {
                await MainActor.run { statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
            }
        }
    }

    private func copyFolderLink(projectId: String, folderId: String) {
        Task {
            do {
                let shortLink = try await simianService.getShortLink(projectId: projectId, folderId: folderId)
                await MainActor.run { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shortLink, forType: .string); statusMessage = "Short link copied"; statusIsError = false }
            } catch {
                await MainActor.run {
                    if let url = SimianService.folderLinkURL(projectId: projectId, folderId: folderId) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        statusMessage = "Direct link copied (short link unavailable)"; statusIsError = false
                    } else { statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
                }
            }
        }
    }

    // MARK: - Data loading

    private func updateSimianServiceConfiguration() {
        let settings = settingsManager.currentSettings
        if let baseURL = settings.simianAPIBaseURL, !baseURL.isEmpty {
            simianService.setBaseURL(baseURL)
            if let username = SharedKeychainService.getSimianUsername(), let password = SharedKeychainService.getSimianPassword() {
                simianService.setCredentials(username: username, password: password)
            }
        } else { simianService.clearConfiguration() }
    }

    private func loadProjects() {
        isLoadingProjects = true; projectLoadError = nil
        Task {
            do { let list = try await simianService.getProjectList(); await MainActor.run { allProjects = list; isLoadingProjects = false; loadProjectInfosIfNeeded() } }
            catch { await MainActor.run { projectLoadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; isLoadingProjects = false } }
        }
    }

    private func loadProjectInfosIfNeeded() {
        guard projectSortOrder.usesLastEdited, projectInfos.isEmpty, !allProjects.isEmpty else { return }
        isLoadingProjectInfos = true; let list = allProjects
        Task {
            await withTaskGroup(of: (String, SimianProjectInfo?).self) { group in
                for project in list { group.addTask { (project.id, try? await simianService.getProjectInfoDetails(projectId: project.id)) } }
                for await (id, info) in group { if let info = info { await MainActor.run { projectInfos[id] = info } } }
            }
            await MainActor.run { isLoadingProjectInfos = false }
        }
    }

    private func loadFolderChildren(projectId: String, folderId: String) {
        loadingFolderIds.insert(folderId)
        Task {
            do {
                async let foldersTask = simianService.getProjectFolders(projectId: projectId, parentFolderId: folderId)
                async let filesTask = simianService.getProjectFiles(projectId: projectId, folderId: folderId)
                let (children, files) = try await (foldersTask, filesTask)
                await MainActor.run { folderChildrenCache[folderId] = children; folderFilesCache[folderId] = files; loadingFolderIds.remove(folderId) }
            } catch { await MainActor.run { folderChildrenCache[folderId] = []; folderFilesCache[folderId] = []; loadingFolderIds.remove(folderId) } }
        }
    }

    private func loadFolders(projectId: String, parentFolderId: String?) {
        isLoadingFolders = true
        Task {
            do { let folders = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: parentFolderId); await MainActor.run { currentFolders = folders; isLoadingFolders = false } }
            catch { await MainActor.run { currentFolders = []; isLoadingFolders = false } }
        }
    }

    private func selectFirstProjectIfOne() { if filteredProjects.count == 1 { openProject(filteredProjects[0]) } }

    // MARK: - Tree model

    private let maxFoldersPerLevel = 200
    private let maxTotalTreeRows = 500

    private func folderSiblings(parentId: String?) -> [SimianFolder] {
        parentId == nil ? currentFolders : (folderChildrenCache[parentId!] ?? [])
    }
    private func fileSiblings(parentFolderId: String?) -> [SimianFile] {
        guard let id = parentFolderId else { return [] }; return folderFilesCache[id] ?? []
    }

    enum SimianTreeItem: Identifiable {
        case folder(SimianFolder, depth: Int, path: String, parentFolderId: String?)
        case file(SimianFile, depth: Int, path: String, parentFolderId: String?)
        var id: String {
            switch self { case .folder(let f, _, _, _): return "f-\(f.id)"; case .file(let f, _, _, _): return "file-\(f.id)" }
        }
    }

    private func flatTreeList(projectId: String) -> [SimianTreeItem] {
        var result: [SimianTreeItem] = []
        enum StackItem { case folders([SimianFolder], Int, String, String?); case files([SimianFile], Int, String, String?) }
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
                        if !remaining.isEmpty { stack.append(.folders(remaining, depth, pathPrefix, parentId)) }
                        if let files = folderFilesCache[f.id], !files.isEmpty { stack.append(.files(Array(files.prefix(100)), depth + 1, path, f.id)) }
                        if let children = folderChildrenCache[f.id] { stack.append(.folders(children, depth + 1, path, f.id)) }
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

    // MARK: - File drop handling

    private func handleExternalFileDrop(providers: [NSItemProvider], folderId: String?) -> Bool {
        guard let projectId = selectedProjectId else { return false }
        loadURLsFromProviders(providers) { urls in guard !urls.isEmpty else { return }; uploadDroppedFiles(projectId: projectId, folderId: folderId, fileURLs: urls) }
        return true
    }

    private func loadURLsFromProviders(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []; let group = DispatchGroup()
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }; group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    private func uploadDroppedFiles(projectId: String, folderId: String?, fileURLs: [URL]) {
        let itemsToUpload = fileURLs.map { FileItem(url: $0) }
        let totalFiles = itemsToUpload.reduce(0) { $0 + $1.fileCount }
        isUploading = true; statusMessage = "Uploading\u{2026}"; statusIsError = false; uploadTotal = totalFiles; uploadCurrent = 0; uploadFileName = ""
        Task {
            do {
                let progressCounter = ProgressCounter()
                for fileItem in itemsToUpload {
                    let existingFolders = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: folderId)
                    if fileItem.isDirectory {
                        try await uploadFolderWithStructure(projectId: projectId, destinationFolderId: folderId, localFolderURL: fileItem.url, existingFolderNames: existingFolders.map { $0.name }) { fileName in
                            progressCounter.increment(); Task { @MainActor in uploadCurrent = progressCounter.value; uploadTotal = totalFiles; uploadFileName = fileName }
                        }
                    } else {
                        progressCounter.increment(); await MainActor.run { uploadCurrent = progressCounter.value; uploadTotal = totalFiles; uploadFileName = fileItem.name }
                        _ = try await simianService.uploadFile(projectId: projectId, folderId: folderId, fileURL: fileItem.url)
                    }
                }
                await MainActor.run {
                    isUploading = false; statusMessage = "Uploaded \(progressCounter.value) file(s)."; statusIsError = false
                    if selectedProjectId == projectId {
                        if let destId = folderId { folderChildrenCache.removeValue(forKey: destId); folderFilesCache.removeValue(forKey: destId) }
                        loadFolders(projectId: projectId, parentFolderId: currentParentFolderId)
                    }
                }
            } catch {
                await MainActor.run { isUploading = false; statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
            }
        }
    }

    private func uploadFolderWithStructure(projectId: String, destinationFolderId: String?, localFolderURL: URL, existingFolderNames: [String], uploadProgress: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let folderName = SimianService.nextNumberedFolderName(existingFolderNames: existingFolderNames, sourceFolderName: localFolderURL.lastPathComponent)
        let simianFolderId = try await simianService.createFolderPublic(projectId: projectId, folderName: folderName, parentFolderId: destinationFolderId)
        guard let contents = try? fm.contentsOfDirectory(at: localFolderURL, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        var filesHere: [URL] = []; var subfolders: [URL] = []
        for item in contents {
            guard item.lastPathComponent != ".DS_Store" else { continue }
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { subfolders.append(item) }
            else if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { filesHere.append(item) }
        }
        for fileURL in filesHere { uploadProgress(fileURL.lastPathComponent); _ = try await simianService.uploadFile(projectId: projectId, folderId: simianFolderId, fileURL: fileURL) }
        for sub in subfolders {
            let existing = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: simianFolderId)
            try await uploadFolderWithStructure(projectId: projectId, destinationFolderId: simianFolderId, localFolderURL: sub, existingFolderNames: existing.map { $0.name }, uploadProgress: uploadProgress)
        }
    }
}

// MARK: - Sort order

enum ProjectSortOrder: String, CaseIterable {
    case nameAsc = "name_asc"; case nameDesc = "name_desc"; case lastEditedNewest = "last_newest"; case lastEditedOldest = "last_oldest"
    var usesLastEdited: Bool { self == .lastEditedNewest || self == .lastEditedOldest }
}

// MARK: - Drag payload: "simian-multi|type|projectId|parentId|id1,id2,id3"

private func buildSimianDragPayload(type: String, projectId: String, parentId: String?, itemIds: [String]) -> String {
    "simian-multi|\(type)|\(projectId)|\(parentId ?? "")|\(itemIds.joined(separator: ","))"
}

private func parseSimianMultiDrag(_ str: String) -> (type: String, projectId: String, parentId: String?, itemIds: [String])? {
    let parts = str.split(separator: "|", maxSplits: 4).map(String.init)
    guard parts.count >= 5 else { return nil }
    if parts[0] == "simian-multi" {
        let ids = parts[4].split(separator: ",").map(String.init)
        return (parts[1], parts[2], parts[3].isEmpty ? nil : parts[3], ids)
    }
    // Legacy single-item format
    if parts[0] == "simian", parts.count >= 5 {
        return (parts[1], parts[2], parts[3].isEmpty ? nil : parts[3], [parts[4]])
    }
    return nil
}

// MARK: - Reorder gap (items shift apart dynamically)

private struct ReorderGapView: View {
    let expectedType: String
    let validateParent: (String?) -> Bool
    let onDrop: ([String]) -> Void
    @Binding var isTargeted: Bool

    private let hitHeight: CGFloat = 8
    private let expandedHeight: CGFloat = 28

    var body: some View {
        ZStack {
            Color.clear
            if isTargeted {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .frame(height: isTargeted ? expandedHeight : hitHeight)
        .animation(.spring(response: 0.45, dampingFraction: 0.7, blendDuration: 0.15), value: isTargeted)
        .contentShape(Rectangle())
        .onDrop(of: [.text, .plainText, .utf8PlainText], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            let types: [UTType] = [.text, .plainText, .utf8PlainText]
            let hasPayload = types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
            guard hasPayload else { return false }
            _ = provider.loadObject(ofClass: String.self) { obj, _ in
                guard let str = obj else { return }
                guard let parsed = parseSimianMultiDrag(str),
                      parsed.type == expectedType, validateParent(parsed.parentId) else { return }
                DispatchQueue.main.async { onDrop(parsed.itemIds) }
            }
            return true
        }
    }
}

// MARK: - Folder row

private struct SimianFolderRow: View {
    let folderId: String
    let projectId: String
    let parentFolderId: String?
    let isExpanded: Bool
    let isLoading: Bool
    let hasOrMayHaveChildren: Bool
    let depth: Int
    let folderName: String
    let canReorder: Bool
    let isEditing: Bool
    @Binding var editText: String
    let selectedItemIds: Set<String>
    let onChevronTap: () -> Void
    let onDoubleTap: () -> Void
    let onExternalFileDrop: ([NSItemProvider]) -> Bool
    let onSelect: () -> Void
    let onMoveIntoFolder: ([String]) -> Void
    let onReorderDrop: ([String]) -> Void
    let onReorderInsertAfter: ([String]) -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var isDropTargeted = false
    @State private var isSimianDropTargeted = false
    @State private var isGapBelow = false
    @State private var isHovered = false
    @FocusState private var isEditFocused: Bool

    private var safeDepth: Int { min(depth, 30) }
    private var treeId: String { "f-\(folderId)" }

    private var dragPayload: String {
        let selected = selectedItemIds.contains(treeId) ? selectedItemIds : [treeId]
        let treeIdsInSelection = Array(selected.filter { $0.hasPrefix("f-") })
        guard !treeIdsInSelection.isEmpty else {
            return buildSimianDragPayload(type: "folder", projectId: projectId, parentId: parentFolderId, itemIds: [treeId])
        }
        return buildSimianDragPayload(type: "folder", projectId: projectId, parentId: parentFolderId, itemIds: treeIdsInSelection)
    }

    private func validateParent(_ parsedParentId: String?) -> Bool { (parsedParentId ?? "") == (parentFolderId ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<safeDepth, id: \.self) { _ in Rectangle().fill(Color.clear).frame(width: 10) }
                Button(action: onChevronTap) {
                    Group {
                        if isLoading {
                            ProgressView().scaleEffect(0.4).frame(width: 14, height: 14)
                        }
                        else if hasOrMayHaveChildren {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).frame(width: 14, height: 14)
                        } else { Rectangle().fill(Color.clear).frame(width: 14, height: 14) }
                    }
                    .offset(y: 3.5)
                }.buttonStyle(.plain)

                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary).offset(y: 3.5).allowsHitTesting(false)
                if isEditing {
                    TextField("", text: $editText, onCommit: { onCommitRename() })
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        .focused($isEditFocused)
                        .onAppear { isEditFocused = true }
                        .onExitCommand { onCancelRename() }
                } else {
                    Text(folderName).font(.system(size: 13)).lineLimit(1).offset(y: 3.5).allowsHitTesting(false)
                }
                Spacer()
                if isDropTargeted { Image(systemName: "plus.circle.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor) }
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .center)
            .contentShape(Rectangle())
            .background((isDropTargeted || isSimianDropTargeted) ? Color.accentColor.opacity(0.15) : Color.clear)
            .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap() })
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: onExternalFileDrop)
            .onDrop(of: [.text, .plainText, .utf8PlainText], isTargeted: $isSimianDropTargeted) { providers in
                guard let p = providers.first else { return false }
                let types: [UTType] = [.text, .plainText, .utf8PlainText]
                guard types.contains(where: { p.hasItemConformingToTypeIdentifier($0.identifier) }) else { return false }
                _ = p.loadObject(ofClass: String.self) { obj, _ in
                    guard let str = obj, let parsed = parseSimianMultiDrag(str), parsed.projectId == projectId else { return }
                    DispatchQueue.main.async { onMoveIntoFolder(parsed.itemIds) }
                }
                return true
            }

            ReorderGapView(expectedType: "folder", validateParent: validateParent, onDrop: { ids in onReorderInsertAfter(ids) }, isTargeted: $isGapBelow)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered ? Color.blue.opacity(0.08) : Color.clear)
        .onHover { isHovered = $0 }
        .draggable(dragPayload)
    }
}

// MARK: - File row

private struct SimianFileRow: View {
    let fileId: String
    let projectId: String
    let parentFolderId: String?
    let depth: Int
    let fileName: String
    let canReorder: Bool
    let isEditing: Bool
    @Binding var editText: String
    let selectedItemIds: Set<String>
    let onSelect: () -> Void
    let onReorderDrop: ([String]) -> Void
    let onReorderInsertAfter: ([String]) -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var isGapBelow = false
    @State private var isHovered = false
    @FocusState private var isEditFocused: Bool

    private var safeDepth: Int { min(depth, 30) }
    private var treeId: String { "file-\(fileId)" }

    private var dragPayload: String {
        let selected = selectedItemIds.contains(treeId) ? selectedItemIds : [treeId]
        let treeIdsInSelection = Array(selected.filter { $0.hasPrefix("file-") })
        guard !treeIdsInSelection.isEmpty else {
            return buildSimianDragPayload(type: "file", projectId: projectId, parentId: parentFolderId, itemIds: [treeId])
        }
        return buildSimianDragPayload(type: "file", projectId: projectId, parentId: parentFolderId, itemIds: treeIdsInSelection)
    }

    private func validateParent(_ parsedParentId: String?) -> Bool { (parsedParentId ?? "") == (parentFolderId ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<safeDepth, id: \.self) { _ in Rectangle().fill(Color.clear).frame(width: 10) }
                Rectangle().fill(Color.clear).frame(width: 14)
                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary).offset(y: 3.5).allowsHitTesting(false)
                if isEditing {
                    TextField("", text: $editText, onCommit: { onCommitRename() })
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        .focused($isEditFocused)
                        .onAppear { isEditFocused = true }
                        .onExitCommand { onCancelRename() }
                } else {
                    Text(fileName).font(.system(size: 13)).lineLimit(1).offset(y: 3.5).allowsHitTesting(false)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .center)
            .contentShape(Rectangle())

            ReorderGapView(expectedType: "file", validateParent: validateParent, onDrop: { ids in onReorderInsertAfter(ids) }, isTargeted: $isGapBelow)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovered ? Color.blue.opacity(0.08) : Color.clear)
        .onHover { isHovered = $0 }
        .draggable(dragPayload)
    }
}

// MARK: - Upload progress counter

private final class ProgressCounter {
    var value = 0
    func increment() { value += 1 }
}
