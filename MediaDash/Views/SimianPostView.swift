//
//  SimianPostView.swift
//  MediaDash
//
//  Simian: search projects, navigate folders, upload via drag-drop or right-click.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct SimianPendingDeleteItem: Identifiable {
    let isFolder: Bool
    let itemId: String
    let displayName: String
    let parentFolderId: String?
    var id: String { (isFolder ? "f-" : "file-") + itemId }
}

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
    @State private var selectedProjectIds: Set<String> = []
    /// Anchor index in `filteredProjects` while extending selection with Shift+arrow; `nil` after plain arrows.
    @State private var projectKeyboardAnchorIndex: Int? = nil
    @State private var projectKeyboardHeadIndex: Int = 0
    /// Indices into `flatTreeList` for Shift+arrow range in the folder/file list.
    @State private var treeKeyboardAnchorIndex: Int? = nil
    @State private var treeKeyboardHeadIndex: Int = 0
    @State private var selectedProjectName: String?

    @State private var folderBreadcrumb: [(id: String, name: String)] = []
    @State private var currentFolders: [SimianFolder] = []
    @State private var currentFiles: [SimianFile] = []
    @State private var isLoadingFolders = false
    @State private var folderListFocusTrigger = 0

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
    /// Finder (file URL) drag over list chrome / empty area → upload into current breadcrumb folder (or project root).
    @State private var isFolderListExternalDropTargeted = false

    /// Right-click → Download file or folder (Simian → disk).
    @State private var isDownloadingFromSimian = false
    @State private var showDownloadEntireProjectConfirmation = false

    // Rename sheet (fallback, kept for context menu "Rename…")
    @State private var showRenameSheet = false
    @State private var renameIsFolder = true
    @State private var renameItemId = ""
    @State private var renameParentFolderId: String?
    @State private var renameCurrentName = ""
    @State private var renameNewName = ""

    // Batch rename
    @State private var showBatchRenameSheet = false
    @State private var batchRenameTargets: [BatchRenameTarget] = []
    @State private var batchRenameMode: BatchRenameMode = .replace
    @State private var batchRenameFindText = ""
    @State private var batchRenameValueText = ""
    @State private var batchRenameError: String?
    @State private var isBatchRenaming = false
    @State private var isApplyingSimianAddDate = false

    // Delete confirmation (one or many items)
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteItems: [SimianPendingDeleteItem] = []

    /// Creating folder on server (Finder-style Cmd+N / New Folder with Selection).
    @State private var isCreatingFolder = false

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isProjectListFocused: Bool
    @FocusState private var isFolderListFocused: Bool
    /// True when the Simian `NoSelectTextField` is key (AppKit); SwiftUI `isSearchFocused` is not auto-synced for `NSViewRepresentable`.
    @State private var simianSearchFieldIsFirstResponder = false
    /// Bumped to resign the AppKit search field without `makeFirstResponder(nil)` (see `NoSelectTextField.blurRequestToken`).
    @State private var simianSearchBlurRequestToken = 0

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

    /// While browsing inside a project, `selectedProjectIds` contains exactly the open project id.
    private var browsingProjectId: String? {
        guard selectedProjectName != nil else { return nil }
        return selectedProjectIds.first
    }

    private var isSimianSearchInputActive: Bool {
        isSearchFocused || simianSearchFieldIsFirstResponder
    }

    /// Move SwiftUI focus to the project or folder list, then resign the AppKit search field (no `makeFirstResponder(nil)`).
    private func resignSimianSearchFieldForListNavigation() {
        isSearchFocused = false
        simianSearchFieldIsFirstResponder = false
        if selectedProjectName == nil {
            isProjectListFocused = true
        } else {
            isFolderListFocused = true
        }
        simianSearchBlurRequestToken += 1
    }

    /// After in-place list updates, AppKit can leave the window without a row-list first responder while `@FocusState` stays true.
    /// Toggling on the next run loop matches the `onAppear` repair on the project and folder `List`s.
    private func syncFolderListFocusWithAppKit() {
        DispatchQueue.main.async {
            isFolderListFocused = false
            isFolderListFocused = true
            // #region agent log
            logFocusSnapshot("after syncFolderListFocusWithAppKit toggle", hypothesisId: "H2")
            // #endregion
        }
    }

    private func syncProjectListFocusWithAppKit() {
        DispatchQueue.main.async {
            isProjectListFocused = false
            isProjectListFocused = true
            // #region agent log
            logFocusSnapshot("after syncProjectListFocusWithAppKit toggle", hypothesisId: "H2")
            // #endregion
        }
    }

    private static let simianKeyDebugLog = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-simian-keyfocus.log"
    /// Debug session NDJSON (session d89040).
    private static let agentDebugLogPath = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug-d89040.log"

    // #region agent log
    /// AppKit first responder vs SwiftUI focus — tests whether List rebuilds leave FR out of sync (H1/H5).
    private func logFocusSnapshot(_ message: String, hypothesisId: String) {
        let fr = NSApp.keyWindow?.firstResponder
        let frType = fr.map { String(describing: type(of: $0)) } ?? "nil"
        logAgentFocus(message, hypothesisId: hypothesisId, data: [
            "firstResponderType": frType,
            "keyWindowNil": NSApp.keyWindow == nil,
            "isSearchFocused": isSearchFocused,
            "isProjectListFocused": isProjectListFocused,
            "isFolderListFocused": isFolderListFocused,
            "simianNativeFR": simianSearchFieldIsFirstResponder,
            "inProjectView": selectedProjectName != nil,
            "isLoadingFolders": isLoadingFolders
        ])
    }

    private func logAgentFocus(_ message: String, hypothesisId: String, data: [String: Any]) {
        let payload: [String: Any] = [
            "sessionId": "d89040",
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

                if let projectId = browsingProjectId, let projectName = selectedProjectName {
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
        .sheet(isPresented: $showBatchRenameSheet) { batchRenameSheet }
        .alert("Remove from Simian?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { pendingDeleteItems = [] }
                .keyboardShortcut(.cancelAction)
            Button("Remove", role: .destructive) { performPendingDelete() }
                .keyboardShortcut(.defaultAction)
        } message: {
            if pendingDeleteItems.count == 1, let only = pendingDeleteItems.first {
                let name = only.displayName.isEmpty ? (only.isFolder ? "this folder" : "this file") : only.displayName
                Text(only.isFolder
                     ? "\u{201C}\(name)\u{201D} and its contents will be removed from Simian. This cannot be undone."
                     : "\u{201C}\(name)\u{201D} will be removed from Simian. This cannot be undone.")
            } else if pendingDeleteItems.count > 1 {
                Text("\(pendingDeleteItems.count) selected items will be removed from Simian. This cannot be undone.")
            }
        }
        .alert("Download entire project?", isPresented: $showDownloadEntireProjectConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Download") {
                guard let projectId = browsingProjectId, let name = selectedProjectName else { return }
                presentSubtreeDownloadSavePanel(
                    projectId: projectId,
                    folderId: nil,
                    rootFolderLabel: name,
                    panelMessage: "A folder will be created here with all files from the project “\(name)”.",
                    emptyResultMessage: "No files to download in this project."
                )
            }
        } message: {
            Text("This downloads every file in the project from Simian. Large projects may take a long time and use a lot of disk space.")
        }
        .onKeyPress(.leftArrow) { handleKeyLeft() }
        .onKeyPress(.rightArrow) { handleKeyRight() }
        .onKeyPress { press in
            switch press.key {
            case .upArrow:
                return handleKeyUp(shift: press.modifiers.contains(.shift))
            case .downArrow:
                return handleKeyDown(shift: press.modifiers.contains(.shift))
            default:
                return .ignored
            }
        }
        .onKeyPress(.return) { handleKeyReturn() }
        .onKeyPress(.tab) { handleKeyTab() }
        .onKeyPress { handleGlobalKeyPress($0) }
        .onKeyPress(.escape) { handleKeyEscape() }
    }

    // MARK: - Keyboard navigation

    private enum BatchRenameMode: String, CaseIterable, Identifiable {
        case replace
        case addBefore
        case addAfter

        var id: String { rawValue }
        var label: String {
            switch self {
            case .replace: return "Replace"
            case .addBefore: return "Add Before"
            case .addAfter: return "Add After"
            }
        }
    }

    private struct BatchRenameTarget: Identifiable {
        let id: String          // tree id: f-123 or file-123
        let itemId: String      // raw Simian id
        let isFolder: Bool
        let parentFolderId: String?
        let currentName: String
        /// From Simian payload when present; used for “Add Date” → upload time.
        let uploadedAt: Date?
    }

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
        guard let projectId = browsingProjectId else { return .ignored }
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

    private func handleKeyUp(fromSimianSearchField: Bool = false, shift: Bool = false) -> KeyPress.Result {
        if !fromSimianSearchField {
            if shouldIgnoreKeyPress(allowSearchFocusInProjectList: true, allowSearchFocusInProjectView: true) {
                // #region agent log
                if (isProjectListFocused || isFolderListFocused), !isSimianSearchInputActive {
                    logFocusSnapshot("handleKeyUp ignored: shouldIgnore but list FocusState true, search inactive", hypothesisId: "H4")
                }
                // #endregion
                return .ignored
            }
        } else if inlineRenameItemId != nil {
            return .ignored
        }
        if selectedProjectName == nil && (isSimianSearchInputActive || fromSimianSearchField) {
            resignSimianSearchFieldForListNavigation()
        } else if selectedProjectName != nil && isSimianSearchInputActive {
            resignSimianSearchFieldForListNavigation()
        }
        if selectedProjectName == nil {
            return handleProjectListArrow(direction: -1, shift: shift, fromSimianSearchField: fromSimianSearchField)
        }
        guard let projectId = browsingProjectId else { return .ignored }
        let treeList = flatTreeList(projectId: projectId)
        guard !treeList.isEmpty else { return .ignored }
        return handleTreeListArrow(direction: -1, shift: shift, treeList: treeList)
    }

    private func handleKeyDown(fromSimianSearchField: Bool = false, shift: Bool = false) -> KeyPress.Result {
        if !fromSimianSearchField {
            if shouldIgnoreKeyPress(allowSearchFocusInProjectList: true, allowSearchFocusInProjectView: true) {
                // #region agent log
                if (isProjectListFocused || isFolderListFocused), !isSimianSearchInputActive {
                    logFocusSnapshot("handleKeyDown ignored: shouldIgnore but list FocusState true, search inactive", hypothesisId: "H4")
                }
                // #endregion
                return .ignored
            }
        } else if inlineRenameItemId != nil {
            return .ignored
        }
        if selectedProjectName == nil && (isSimianSearchInputActive || fromSimianSearchField) {
            resignSimianSearchFieldForListNavigation()
        } else if selectedProjectName != nil && isSimianSearchInputActive {
            resignSimianSearchFieldForListNavigation()
        }
        if selectedProjectName == nil {
            return handleProjectListArrow(direction: 1, shift: shift, fromSimianSearchField: fromSimianSearchField)
        }
        guard let projectId = browsingProjectId else { return .ignored }
        let treeList = flatTreeList(projectId: projectId)
        guard !treeList.isEmpty else { return .ignored }
        return handleTreeListArrow(direction: 1, shift: shift, treeList: treeList)
    }

    private func syncProjectKeyboardIndices(projectCount n: Int) {
        guard n > 0 else { return }
        projectKeyboardHeadIndex = min(max(projectKeyboardHeadIndex, 0), n - 1)
        if let a = projectKeyboardAnchorIndex {
            projectKeyboardAnchorIndex = min(max(a, 0), n - 1)
        }
    }

    /// When the project list contents or order changes, drop invalid ids and keep head/anchor in range.
    private func syncProjectSelectionToFilteredList() {
        guard selectedProjectName == nil else { return }
        let projects = filteredProjects
        guard !projects.isEmpty else {
            selectedProjectIds = []
            return
        }
        let valid = Set(projects.map(\.id))
        selectedProjectIds = selectedProjectIds.intersection(valid)
        if selectedProjectIds.isEmpty, let first = projects.first {
            selectedProjectIds = [first.id]
            projectKeyboardHeadIndex = 0
            projectKeyboardAnchorIndex = nil
        } else {
            syncProjectKeyboardIndices(projectCount: projects.count)
        }
    }

    private func handleProjectListArrow(direction: Int, shift: Bool, fromSimianSearchField: Bool) -> KeyPress.Result {
        let projects = filteredProjects
        guard !projects.isEmpty else {
            if fromSimianSearchField { logSimianKeyDebug("handleKeyDown fromSearch emptyProjects handled") }
            return .handled
        }
        let n = projects.count
        syncProjectKeyboardIndices(projectCount: n)

        if shift {
            if projectKeyboardAnchorIndex == nil {
                projectKeyboardAnchorIndex = projectKeyboardHeadIndex
            }
            let anchor = projectKeyboardAnchorIndex ?? projectKeyboardHeadIndex
            let newHead = min(max(projectKeyboardHeadIndex + direction, 0), n - 1)
            projectKeyboardHeadIndex = newHead
            let lo = min(anchor, newHead)
            let hi = max(anchor, newHead)
            selectedProjectIds = Set(projects[lo...hi].map(\.id))
            if fromSimianSearchField {
                logSimianKeyDebug("handleKeyDown fromSearch shift range count=\(projects.count) head=\(newHead)")
            }
            return .handled
        }

        projectKeyboardAnchorIndex = nil
        syncProjectKeyboardIndices(projectCount: n)
        let idx: Int = {
            if selectedProjectIds.isEmpty { return projectKeyboardHeadIndex }
            if selectedProjectIds.count == 1, let only = selectedProjectIds.first,
               let i = projects.firstIndex(where: { $0.id == only }) {
                return i
            }
            let indices = selectedProjectIds.compactMap { id in projects.firstIndex(where: { $0.id == id }) }
            if direction < 0, let mn = indices.min() { return mn }
            if direction > 0, let mx = indices.max() { return mx }
            return projectKeyboardHeadIndex
        }()
        var newIdx = idx + direction
        if newIdx < 0 {
            newIdx = n - 1
        } else if newIdx >= n {
            newIdx = 0
        }
        projectKeyboardHeadIndex = newIdx
        selectedProjectIds = [projects[newIdx].id]
        if fromSimianSearchField {
            logSimianKeyDebug("handleKeyDown fromSearch selected=\(projects[newIdx].id) count=\(projects.count)")
        }
        return .handled
    }

    private func handleTreeListArrow(direction: Int, shift: Bool, treeList: [SimianTreeItem]) -> KeyPress.Result {
        let n = treeList.count
        guard n > 0 else { return .ignored }

        if selectedItemIds.isEmpty {
            treeKeyboardAnchorIndex = nil
            treeKeyboardHeadIndex = direction > 0 ? 0 : n - 1
            selectedItemIds = [treeList[treeKeyboardHeadIndex].id]
            return .handled
        }

        treeKeyboardHeadIndex = min(max(treeKeyboardHeadIndex, 0), n - 1)
        if selectedItemIds.count == 1, let only = selectedItemIds.first,
           let idx = treeList.firstIndex(where: { $0.id == only }) {
            treeKeyboardHeadIndex = idx
        } else if selectedItemIds.count > 1 {
            let indices = selectedItemIds.compactMap { id in treeList.firstIndex(where: { $0.id == id }) }
            if direction < 0, let mn = indices.min() {
                treeKeyboardHeadIndex = mn
            } else if direction > 0, let mx = indices.max() {
                treeKeyboardHeadIndex = mx
            }
        }

        if shift {
            if treeKeyboardAnchorIndex == nil {
                treeKeyboardAnchorIndex = treeKeyboardHeadIndex
            }
            let anchor = treeKeyboardAnchorIndex ?? treeKeyboardHeadIndex
            let newHead = min(max(treeKeyboardHeadIndex + direction, 0), n - 1)
            treeKeyboardHeadIndex = newHead
            let lo = min(anchor, newHead)
            let hi = max(anchor, newHead)
            selectedItemIds = Set(treeList[lo...hi].map(\.id))
            return .handled
        }

        treeKeyboardAnchorIndex = nil
        let newHead = min(max(treeKeyboardHeadIndex + direction, 0), n - 1)
        treeKeyboardHeadIndex = newHead
        selectedItemIds = [treeList[newHead].id]
        return .handled
    }

    private func handleKeyRight() -> KeyPress.Result {
        if shouldIgnoreKeyPress() { return .ignored }
        guard let projectId = browsingProjectId else { return .ignored }
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
        } else if selectedProjectName != nil && isSimianSearchInputActive {
            resignSimianSearchFieldForListNavigation()
        }
        if inlineRenameItemId != nil { return .ignored }
        // Project list mode: Enter opens the keyboard-focused row (head).
        if selectedProjectName == nil {
            let projects = filteredProjects
            guard !projects.isEmpty else { return .ignored }
            let hi = min(max(projectKeyboardHeadIndex, 0), projects.count - 1)
            let headId = projects[hi].id
            guard let project = projects.first(where: { $0.id == headId }) else { return .ignored }
            openProject(project)
            syncFolderListFocusWithAppKit()
            // #region agent log
            DispatchQueue.main.async { logFocusSnapshot("after openProject+syncFolder (Enter)", hypothesisId: "H1") }
            // #endregion
            return .handled
        }
        guard browsingProjectId != nil else { return .ignored }
        guard selectedItemIds.count == 1, let itemId = selectedItemIds.first else { return .ignored }
        // Start inline rename
        guard let browseId = browsingProjectId else { return .ignored }
        let treeList = flatTreeList(projectId: browseId)
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
                if selectedProjectIds.isEmpty, let firstId = filteredProjects.first?.id {
                    selectedProjectIds = [firstId]
                    projectKeyboardHeadIndex = 0
                    projectKeyboardAnchorIndex = nil
                }
            } else {
                if selectedItemIds.isEmpty,
                   let projectId = browsingProjectId {
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

    /// Backspace (⌫) vs forward delete (⌦). `KeyPress.key` is a `KeyEquivalent`; the ⌫ key often maps to ASCII DEL (`\u{7F}`), not `.delete` (BS / `\u{8}`).
    private func keyPressRepresentsDeleteKey(_ press: KeyPress) -> Bool {
        if press.key == .delete || press.key == .deleteForward { return true }
        if press.key == KeyEquivalent("\u{7f}") { return true }
        guard press.characters.count == 1, let u = press.characters.unicodeScalars.first?.value else { return false }
        return u == 8 || u == 127
    }

    private func handleCommandKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else { return .ignored }

        // Cmd+Down: open selected item (Finder-style).
        if press.key == .downArrow {
            // Project list mode: open selected project.
            if selectedProjectName == nil {
                if isSimianSearchInputActive {
                    resignSimianSearchFieldForListNavigation()
                }
                let projects = filteredProjects
                guard !projects.isEmpty else { return .ignored }
                let hi = min(max(projectKeyboardHeadIndex, 0), projects.count - 1)
                let headId = projects[hi].id
                guard let project = projects.first(where: { $0.id == headId }) else { return .ignored }
                openProject(project)
                return .handled
            }

            // Inside a project: if a folder is selected, enter it as the exclusive view.
            guard let projectId = browsingProjectId,
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
            syncFolderListFocusWithAppKit()
            return .handled
        }

        // Cmd+Up: go up one level; exit project only when already at project root.
        if press.key == .upArrow {
            guard let projectId = browsingProjectId, selectedProjectName != nil else { return .ignored }
            if !folderBreadcrumb.isEmpty {
                folderBreadcrumb.removeLast()
                selectedItemIds.removeAll()
                expandedFolderIds.removeAll()
                loadFolders(projectId: projectId, parentFolderId: folderBreadcrumb.last?.id)
                isFolderListFocused = true
                syncFolderListFocusWithAppKit()
            } else {
                exitToProjectList(keepSelection: true)
            }
            return .handled
        }

        // Cmd+N: New Folder in current directory (Finder-style). Ctrl+Cmd+N: same + move selection into the new folder.
        if press.characters.lowercased() == "n", press.modifiers.contains(.command) {
            guard !press.modifiers.contains(.shift), !press.modifiers.contains(.option) else { return .ignored }
            guard selectedProjectName != nil, let projectId = browsingProjectId else { return .ignored }
            if let window = NSApp.keyWindow, KeyboardNavigationCoordinator.isEditingText(in: window) { return .ignored }
            if inlineRenameItemId != nil || isCreatingFolder { return .ignored }

            resignSimianSearchFieldForListNavigation()
            let treeList = flatTreeList(projectId: projectId)
            let ctrl = press.modifiers.contains(.control)
            if ctrl {
                let ids = selectedTreeIdsInCurrentFolder(treeList: treeList)
                beginFinderStyleNewFolder(parentFolderId: currentParentFolderId, itemIdsToMove: ids)
            } else {
                beginFinderStyleNewFolder(parentFolderId: currentParentFolderId, itemIdsToMove: [])
            }
            return .handled
        }

        // Cmd+Delete / Cmd+Fn+Delete: prompt to remove selected files/folders (Finder-style).
        if keyPressRepresentsDeleteKey(press) {
            guard !press.modifiers.contains(.shift),
                  !press.modifiers.contains(.option),
                  !press.modifiers.contains(.control) else { return .ignored }
            if showDeleteConfirmation { return .ignored }
            guard selectedProjectName != nil, let projectId = browsingProjectId else { return .ignored }
            if let window = NSApp.keyWindow, KeyboardNavigationCoordinator.isEditingText(in: window) { return .ignored }
            if inlineRenameItemId != nil { return .ignored }
            guard !selectedItemIds.isEmpty else { return .ignored }
            resignSimianSearchFieldForListNavigation()
            let treeList = flatTreeList(projectId: projectId)
            enqueueDeleteForTreeIds(Array(selectedItemIds), treeList: treeList)
            return .handled
        }

        return .ignored
    }

    private func exitToProjectList(keepSelection: Bool) {
        let previousProjectId = browsingProjectId
        selectedProjectName = nil
        treeKeyboardAnchorIndex = nil
        treeKeyboardHeadIndex = 0
        folderBreadcrumb = []
        currentFolders = []
        currentFiles = []
        selectedItemIds.removeAll()
        expandedFolderIds.removeAll()
        folderChildrenCache.removeAll()
        folderFilesCache.removeAll()
        loadingFolderIds.removeAll()
        if !keepSelection {
            selectedProjectIds = []
            projectKeyboardAnchorIndex = nil
            projectKeyboardHeadIndex = 0
        } else if let previousProjectId {
            selectedProjectIds = [previousProjectId]
            projectKeyboardAnchorIndex = nil
            if let idx = filteredProjects.firstIndex(where: { $0.id == previousProjectId }) {
                projectKeyboardHeadIndex = idx
            }
        }
        // Defer focus after hierarchy shows project list; clearing `@FocusState` while folder `List` still exists can stick (H3 logs).
        DispatchQueue.main.async {
            isFolderListFocused = false
            isSearchFocused = false
            isProjectListFocused = true
            syncProjectListFocusWithAppKit()
            // #region agent log
            logFocusSnapshot("after exitToProjectList", hypothesisId: "H3")
            // #endregion
        }
    }

    private func handleKeyEscape() -> KeyPress.Result {
        if inlineRenameItemId != nil {
            inlineRenameItemId = nil
            inlineRenameText = ""
            return .handled
        }
        if browsingProjectId != nil && selectedItemIds.isEmpty {
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
        guard let itemId = inlineRenameItemId, let projectId = browsingProjectId else {
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

    private var batchRenameCanApply: Bool {
        guard !isBatchRenaming, !batchRenameTargets.isEmpty else { return false }
        switch batchRenameMode {
        case .replace:
            return !batchRenameFindText.isEmpty
        case .addBefore, .addAfter:
            return !batchRenameValueText.isEmpty
        }
    }

    private func batchRenamedName(from original: String) -> String {
        switch batchRenameMode {
        case .replace:
            guard !batchRenameFindText.isEmpty else { return original }
            return original.replacingOccurrences(of: batchRenameFindText, with: batchRenameValueText)
        case .addBefore:
            return batchRenameValueText + original
        case .addAfter:
            return original + batchRenameValueText
        }
    }

    private func batchRenamePreviewRows(limit: Int = 10) -> [(String, String)] {
        batchRenameTargets.prefix(limit).map { target in
            (target.currentName, batchRenamedName(from: target.currentName))
        }
    }

    private var batchRenameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Batch Rename")
                .font(.headline)
            Text("Rename \(batchRenameTargets.count) selected item(s).")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $batchRenameMode) {
                ForEach(BatchRenameMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if batchRenameMode == .replace {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Find text", text: $batchRenameFindText)
                        .textFieldStyle(.roundedBorder)
                    TextField("Replace with", text: $batchRenameValueText)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                TextField(batchRenameMode == .addBefore ? "Text to add before" : "Text to add after", text: $batchRenameValueText)
                    .textFieldStyle(.roundedBorder)
            }

            let rows = batchRenamePreviewRows()
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview")
                        .font(.subheadline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack {
                                    Text(row.0)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(row.1)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }

            if let err = batchRenameError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    if !isBatchRenaming {
                        showBatchRenameSheet = false
                        batchRenameError = nil
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isBatchRenaming)
                Spacer()
                Button("Apply") {
                    submitBatchRename()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!batchRenameCanApply)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            batchRenameError = nil
            isBatchRenaming = false
        }
    }

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

    // MARK: - Submit actions

    private func submitBatchRename() {
        guard let projectId = browsingProjectId else { return }
        isBatchRenaming = true
        batchRenameError = nil
        let targets = batchRenameTargets
        let mode = batchRenameMode
        let findText = batchRenameFindText
        let valueText = batchRenameValueText
        Task {
            var renamedCount = 0
            var skippedCount = 0
            var failures: [String] = []

            for target in targets {
                let newName: String
                switch mode {
                case .replace:
                    if findText.isEmpty {
                        newName = target.currentName
                    } else {
                        newName = target.currentName.replacingOccurrences(of: findText, with: valueText)
                    }
                case .addBefore:
                    newName = valueText + target.currentName
                case .addAfter:
                    newName = target.currentName + valueText
                }
                if newName == target.currentName {
                    skippedCount += 1
                    continue
                }
                if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append("\"\(target.currentName)\" became empty")
                    continue
                }
                do {
                    if target.isFolder {
                        try await simianService.renameFolder(projectId: projectId, folderId: target.itemId, newName: newName)
                        await MainActor.run {
                            applyFolderRename(folderId: target.itemId, parentFolderId: target.parentFolderId, newName: newName)
                        }
                    } else {
                        try await simianService.renameFile(projectId: projectId, fileId: target.itemId, newName: newName)
                        await MainActor.run {
                            applyFileRename(fileId: target.itemId, parentFolderId: target.parentFolderId, newName: newName)
                        }
                    }
                    renamedCount += 1
                } catch {
                    failures.append(target.currentName)
                }
            }

            await MainActor.run {
                isBatchRenaming = false
                if failures.isEmpty {
                    showBatchRenameSheet = false
                    let skippedPart = skippedCount > 0 ? " (\(skippedCount) unchanged)" : ""
                    statusMessage = "Renamed \(renamedCount) item(s)\(skippedPart)"
                    statusIsError = false
                } else {
                    let firstFew = failures.prefix(3).joined(separator: ", ")
                    let extra = failures.count > 3 ? ", ..." : ""
                    batchRenameError = "Could not rename \(failures.count) item(s): \(firstFew)\(extra)"
                    statusMessage = "Batch rename completed with errors"
                    statusIsError = true
                }
            }
        }
    }

    /// Context menu “Add Date”: append or normalize `_MMMdd.yy` on each selected tree item (same selection rules as batch rename).
    private func addDateStampToSelection(treeList: [SimianTreeItem], rightClickedId: String, useUploadTime: Bool) {
        guard let projectId = browsingProjectId else { return }
        let ids = (selectedItemIds.contains(rightClickedId) && selectedItemIds.count > 1)
            ? Array(selectedItemIds)
            : [rightClickedId]
        let mapped: [BatchRenameTarget] = ids.compactMap { id in
            guard let item = treeList.first(where: { $0.id == id }) else { return nil }
            switch item {
            case .folder(let folder, _, _, let parentId):
                return BatchRenameTarget(
                    id: id,
                    itemId: folder.id,
                    isFolder: true,
                    parentFolderId: parentId,
                    currentName: folder.name,
                    uploadedAt: folder.uploadedAt
                )
            case .file(let file, _, _, let parentId):
                return BatchRenameTarget(
                    id: id,
                    itemId: file.id,
                    isFolder: false,
                    parentFolderId: parentId,
                    currentName: file.title,
                    uploadedAt: file.uploadedAt
                )
            }
        }
        guard !mapped.isEmpty, !isApplyingSimianAddDate else { return }
        isApplyingSimianAddDate = true
        statusMessage = ""
        let label = useUploadTime ? "Add Date (upload)" : "Add Date (today)"
        Task {
            var renamedCount = 0
            var skippedCount = 0
            var failures: [String] = []
            for target in mapped {
                let ref: Date
                if useUploadTime {
                    var upload = target.uploadedAt
                    if upload == nil, !target.isFolder {
                        if let info = try? await simianService.getFileInfo(projectId: projectId, fileId: target.itemId) {
                            upload = info.uploadedAt
                        }
                    }
                    ref = upload ?? Date()
                } else {
                    ref = Date()
                }
                let newName = SimianFolderNaming.fullLabelByAddingOrNormalizingSimianDate(target.currentName, referenceDate: ref, timeZone: TimeZone.current)
                if newName == target.currentName {
                    skippedCount += 1
                    continue
                }
                if newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    failures.append("\"\(target.currentName)\" became empty")
                    continue
                }
                do {
                    if target.isFolder {
                        try await simianService.renameFolder(projectId: projectId, folderId: target.itemId, newName: newName)
                        await MainActor.run {
                            applyFolderRename(folderId: target.itemId, parentFolderId: target.parentFolderId, newName: newName)
                        }
                    } else {
                        try await simianService.renameFile(projectId: projectId, fileId: target.itemId, newName: newName)
                        await MainActor.run {
                            applyFileRename(fileId: target.itemId, parentFolderId: target.parentFolderId, newName: newName)
                        }
                    }
                    renamedCount += 1
                } catch {
                    failures.append(target.currentName)
                }
            }
            await MainActor.run {
                isApplyingSimianAddDate = false
                if failures.isEmpty {
                    let skippedPart = skippedCount > 0 ? " (\(skippedCount) unchanged)" : ""
                    statusMessage = "\(label): \(renamedCount) item(s)\(skippedPart)"
                    statusIsError = false
                } else {
                    let firstFew = failures.prefix(3).joined(separator: ", ")
                    let extra = failures.count > 3 ? ", ..." : ""
                    statusMessage = "\(label): \(failures.count) failed (\(firstFew)\(extra))"
                    statusIsError = true
                }
            }
        }
    }

    @ViewBuilder
    private func renameAndAddDateSection(treeList: [SimianTreeItem], rightClickedId: String) -> some View {
        if shouldOfferBatchRename(rightClickedId: rightClickedId) {
            Button("Batch Rename\u{2026}") {
                startBatchRename(treeList: treeList, rightClickedId: rightClickedId)
            }
        } else {
            Button("Rename\u{2026}") {
                presentRenameSheetForTreeItem(id: rightClickedId, treeList: treeList)
            }
        }
        Menu("Add Date") {
            Button("Today's Date") {
                addDateStampToSelection(treeList: treeList, rightClickedId: rightClickedId, useUploadTime: false)
            }
            Button("Upload Date") {
                addDateStampToSelection(treeList: treeList, rightClickedId: rightClickedId, useUploadTime: true)
            }
        }
        .disabled(isApplyingSimianAddDate)
    }

    private static let finderNewFolderPlaceholderName = "New Folder"

    /// Finder-style: create `New Folder`, optionally move items into it, refresh, then inline-rename with name selected.
    private func beginFinderStyleNewFolder(parentFolderId: String?, itemIdsToMove: [String]) {
        guard let projectId = browsingProjectId, selectedProjectName != nil else { return }
        guard !isCreatingFolder, inlineRenameItemId == nil else { return }

        let name = Self.finderNewFolderPlaceholderName
        let parent = parentFolderId
        let items = itemIdsToMove

        isCreatingFolder = true
        statusMessage = ""

        Task {
            do {
                typealias FolderMoveInfo = (sourceParentId: String?, sourceSiblingIds: [String])
                let treeList = await MainActor.run { flatTreeList(projectId: projectId) }
                var folderMoveInfos: [String: FolderMoveInfo] = [:]
                for treeId in items where treeId.hasPrefix("f-") && treeId.count > 2 {
                    let folderId = String(treeId.dropFirst(2))
                    guard let item = treeList.first(where: { $0.id == treeId }),
                          case .folder(_, _, _, let sourceParentId) = item else { continue }
                    let siblings = await MainActor.run { folderSiblings(parentId: sourceParentId) }
                    folderMoveInfos[folderId] = (sourceParentId, siblings.filter { $0.id != folderId }.map { $0.id })
                }

                let newFolderId = try await simianService.createFolderPublic(projectId: projectId, folderName: name, parentFolderId: parent)

                for treeId in items {
                    if treeId.hasPrefix("file-"), treeId.count > 5 {
                        let fileId = String(treeId.dropFirst(5))
                        try await simianService.moveFile(projectId: projectId, fileId: fileId, folderId: newFolderId)
                    } else if treeId.hasPrefix("f-"), treeId.count > 2 {
                        let folderId = String(treeId.dropFirst(2))
                        guard let info = folderMoveInfos[folderId] else { continue }
                        try await moveFolderIntoFolder(projectId: projectId, folderId: folderId, sourceParentId: info.sourceParentId, sourceSiblingIdsWithoutThis: info.sourceSiblingIds, targetFolderId: newFolderId)
                    }
                }

                if items.isEmpty {
                    try await refreshListingAfterEmptyFolderCreate(projectId: projectId, parentId: parent)
                } else {
                    try await refreshListingAfterFolderCreateWithMoves(projectId: projectId, parentId: parent, newFolderId: newFolderId)
                }

                await MainActor.run {
                    isCreatingFolder = false
                    resignSimianSearchFieldForListNavigation()
                    selectedItemIds = ["f-\(newFolderId)"]
                    inlineRenameItemId = "f-\(newFolderId)"
                    inlineRenameText = name
                    var filesMoved = 0
                    var foldersMoved = 0
                    for tid in items {
                        if tid.hasPrefix("file-") { filesMoved += 1 }
                        else if tid.hasPrefix("f-") { foldersMoved += 1 }
                    }
                    if items.isEmpty {
                        statusMessage = "Folder created"
                    } else {
                        var parts: [String] = []
                        if filesMoved > 0 { parts.append("\(filesMoved) file(s)") }
                        if foldersMoved > 0 { parts.append("\(foldersMoved) folder(s)") }
                        statusMessage = "Folder created; \(parts.joined(separator: " and ")) moved"
                    }
                    statusIsError = false
                }
            } catch {
                await MainActor.run {
                    isCreatingFolder = false
                    statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    statusIsError = true
                }
            }
        }
    }

    private func reloadListingAsync(projectId: String, parentFolderId: String?) async throws {
        async let foldersTask = simianService.getProjectFolders(projectId: projectId, parentFolderId: parentFolderId)
        let files: [SimianFile]
        if let folderId = parentFolderId {
            files = try await simianService.getProjectFiles(projectId: projectId, folderId: folderId)
        } else {
            files = []
        }
        let folders = try await foldersTask
        await MainActor.run {
            currentFolders = folders
            currentFiles = files
        }
    }

    private func reloadFolderChildrenAsync(projectId: String, folderId: String) async throws {
        async let foldersTask = simianService.getProjectFolders(projectId: projectId, parentFolderId: folderId)
        async let filesTask = simianService.getProjectFiles(projectId: projectId, folderId: folderId)
        let (children, files) = try await (foldersTask, filesTask)
        await MainActor.run {
            folderChildrenCache[folderId] = children
            folderFilesCache[folderId] = files
        }
    }

    private func refreshListingAfterEmptyFolderCreate(projectId: String, parentId: String?) async throws {
        if parentId == nil {
            try await reloadListingAsync(projectId: projectId, parentFolderId: nil)
        } else {
            await MainActor.run {
                folderChildrenCache.removeValue(forKey: parentId!)
                expandedFolderIds.insert(parentId!)
            }
            try await reloadFolderChildrenAsync(projectId: projectId, folderId: parentId!)
        }
    }

    private func refreshListingAfterFolderCreateWithMoves(projectId: String, parentId: String?, newFolderId: String) async throws {
        await MainActor.run {
            folderChildrenCache.removeValue(forKey: newFolderId)
            folderFilesCache.removeValue(forKey: newFolderId)
        }
        if parentId == nil {
            try await reloadListingAsync(projectId: projectId, parentFolderId: nil)
        } else {
            await MainActor.run {
                folderChildrenCache.removeValue(forKey: parentId!)
                folderFilesCache.removeValue(forKey: parentId!)
                expandedFolderIds.insert(parentId!)
            }
            try await reloadFolderChildrenAsync(projectId: projectId, folderId: parentId!)
        }
        await MainActor.run {
            folderChildrenCache.removeValue(forKey: newFolderId)
            folderFilesCache.removeValue(forKey: newFolderId)
        }
    }

    private func parentFolderId(forTreeItemId treeId: String, in treeList: [SimianTreeItem]) -> String? {
        guard let item = treeList.first(where: { $0.id == treeId }) else { return nil }
        switch item {
        case .folder(_, _, _, let pid): return pid
        case .file(_, _, _, let pid): return pid
        }
    }

    /// Look up the parent folder ID of a folder by searching caches directly.
    /// Returns `.some(nil)` for root-level folders, `.some(id)` for nested folders,
    /// and `nil` (Double Optional `.none`) when the folder is not found in any cache.
    /// This is used when the flat treeList may be truncated (maxTotalTreeRows cap).
    private func cachedParentFolderId(forFolderId folderId: String) -> String?? {
        if currentFolders.contains(where: { $0.id == folderId }) { return .some(nil) }
        for (parentId, children) in folderChildrenCache {
            if children.contains(where: { $0.id == folderId }) { return .some(parentId) }
        }
        return nil
    }

    /// Look up a folder's display name from caches. Used to resolve destination folder names
    /// for file uploads when the target folder is not the breadcrumb root.
    private func cachedFolderName(forFolderId folderId: String) -> String? {
        if let f = currentFolders.first(where: { $0.id == folderId }) { return f.name }
        for children in folderChildrenCache.values {
            if let f = children.first(where: { $0.id == folderId }) { return f.name }
        }
        return nil
    }

    /// Move a folder into another folder (same project) using update_folder_sort.
    private func moveFolderIntoFolder(projectId: String, folderId: String, sourceParentId: String?, sourceSiblingIdsWithoutThis: [String], targetFolderId: String) async throws {
        try await simianService.updateFolderSort(projectId: projectId, parentFolderId: sourceParentId, folderIds: sourceSiblingIdsWithoutThis)
        let targetChildren = (try? await simianService.getProjectFolders(projectId: projectId, parentFolderId: targetFolderId)) ?? []
        let existingIds = targetChildren.map { $0.id }
        if existingIds.contains(folderId) { return }
        try await simianService.updateFolderSort(projectId: projectId, parentFolderId: targetFolderId, folderIds: existingIds + [folderId])
    }

    /// Drop onto a folder row: reorder before this folder when all dragged folders are siblings of the target; otherwise move into the folder (files always nest).
    private func handleFolderRowSimianDrop(projectId: String, itemIds: [String], targetFolderId: String, targetSiblingParentId: String?, treeList: [SimianTreeItem]) {
        let targetTreeId = "f-\(targetFolderId)"
        if itemIds.contains(targetTreeId) { return }
        let hasFileDrag = itemIds.contains { $0.hasPrefix("file-") }
        if hasFileDrag {
            moveItemsIntoFolder(projectId: projectId, itemIds: itemIds, targetFolderId: targetFolderId)
            return
        }
        let folderTreeIds = itemIds.filter { $0.hasPrefix("f-") }
        guard !folderTreeIds.isEmpty else { return }
        var resolvedParents: [String?] = []
        resolvedParents.reserveCapacity(folderTreeIds.count)
        for tid in folderTreeIds {
            if let item = treeList.first(where: { $0.id == tid }), case .folder(_, _, _, let p) = item {
                // Fast path: item is visible in the current treeList.
                resolvedParents.append(p)
            } else {
                // Slow path: item may be off-screen due to maxTotalTreeRows truncation.
                // Search caches directly so we don't confuse "sibling reorder" with "move into folder".
                let rawId = String(tid.dropFirst(2))
                guard let optionalParent = cachedParentFolderId(forFolderId: rawId) else {
                    // Truly unknown — abort rather than accidentally nesting into target folder.
                    return
                }
                resolvedParents.append(optionalParent)
            }
        }
        if resolvedParents.allSatisfy({ $0 == targetSiblingParentId }) {
            reorderItems(projectId: projectId, draggedIds: itemIds, targetId: targetTreeId, treeList: treeList)
        } else {
            moveItemsIntoFolder(projectId: projectId, itemIds: itemIds, targetFolderId: targetFolderId)
        }
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
        guard !newName.isEmpty, let projectId = browsingProjectId else { return }
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
        let renamed = { (old: SimianFolder) -> SimianFolder in
            SimianFolder(id: old.id, name: newName, parentId: old.parentId, uploadedAt: old.uploadedAt)
        }
        if let parentId = parentFolderId, !parentId.isEmpty {
            if parentId == currentParentFolderId, let idx = currentFolders.firstIndex(where: { $0.id == folderId }) {
                currentFolders[idx] = renamed(currentFolders[idx])
            }
            if var children = folderChildrenCache[parentId], let idx = children.firstIndex(where: { $0.id == folderId }) {
                children[idx] = renamed(children[idx])
                folderChildrenCache[parentId] = children
            }
        } else {
            if let idx = currentFolders.firstIndex(where: { $0.id == folderId }) {
                currentFolders[idx] = renamed(currentFolders[idx])
            }
        }
    }

    private func applyFileRename(fileId: String, parentFolderId: String?, newName: String) {
        guard let parentId = parentFolderId else { return }
        let renamed = { (old: SimianFile) -> SimianFile in
            SimianFile(id: old.id, title: newName, fileType: old.fileType, mediaURL: old.mediaURL, folderId: old.folderId, projectId: old.projectId, uploadedAt: old.uploadedAt)
        }
        if parentId == currentParentFolderId, let idx = currentFiles.firstIndex(where: { $0.id == fileId }) {
            currentFiles[idx] = renamed(currentFiles[idx])
        }
        if var files = folderFilesCache[parentId], let idx = files.firstIndex(where: { $0.id == fileId }) {
            files[idx] = renamed(files[idx])
            folderFilesCache[parentId] = files
        }
    }

    private func performPendingDelete() {
        guard let projectId = browsingProjectId, !pendingDeleteItems.isEmpty else { return }
        let items = pendingDeleteItems
        pendingDeleteItems = []
        showDeleteConfirmation = false
        Task {
            do {
                for item in items {
                    if item.isFolder {
                        try await simianService.deleteFolder(projectId: projectId, folderId: item.itemId)
                        await MainActor.run {
                            applyFolderDeletion(folderId: item.itemId, parentFolderId: item.parentFolderId)
                            expandedFolderIds.remove(item.itemId)
                            folderChildrenCache.removeValue(forKey: item.itemId)
                            folderFilesCache.removeValue(forKey: item.itemId)
                            selectedItemIds.remove("f-\(item.itemId)")
                        }
                    } else {
                        try await simianService.deleteFile(projectId: projectId, fileId: item.itemId)
                        await MainActor.run {
                            applyFileDeletion(fileId: item.itemId, parentFolderId: item.parentFolderId)
                            selectedItemIds.remove("file-\(item.itemId)")
                        }
                    }
                }
                await MainActor.run {
                    if items.count == 1, let only = items.first {
                        statusMessage = only.isFolder ? "Folder removed" : "File removed"
                    } else {
                        statusMessage = "Removed \(items.count) items from Simian"
                    }
                    statusIsError = false
                    refreshCurrentView()
                }
            } catch {
                await MainActor.run { statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
            }
        }
    }

    private func applyFolderDeletion(folderId: String, parentFolderId: String?) {
        if let pid = parentFolderId, !pid.isEmpty {
            if pid == currentParentFolderId {
                currentFolders.removeAll { $0.id == folderId }
            }
            folderChildrenCache[pid] = folderChildrenCache[pid]?.filter { $0.id != folderId } ?? []
        } else {
            currentFolders = currentFolders.filter { $0.id != folderId }
        }
    }

    private func applyFileDeletion(fileId: String, parentFolderId: String?) {
        guard let pid = parentFolderId else { return }
        if pid == currentParentFolderId {
            currentFiles.removeAll { $0.id == fileId }
        }
        folderFilesCache[pid] = folderFilesCache[pid]?.filter { $0.id != fileId } ?? []
    }

    private func refreshCurrentView() {
        if let projectId = browsingProjectId {
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
                    onMoveUp: { shift in
                        switch handleKeyUp(fromSimianSearchField: true, shift: shift) {
                        case .handled: return true
                        default: return false
                        }
                    },
                    onMoveDown: { shift in
                        switch handleKeyDown(fromSimianSearchField: true, shift: shift) {
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
                    },
                    blurRequestToken: simianSearchBlurRequestToken
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
                    List(selection: $selectedProjectIds) {
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
                        if selectedProjectIds.isEmpty, let firstId = filteredProjects.first?.id {
                            selectedProjectIds = [firstId]
                            projectKeyboardHeadIndex = 0
                            projectKeyboardAnchorIndex = nil
                        }
                        // List rebuild (search filter, navigation) recreates the outline; AppKit can leave `NSWindow` as first responder while `@FocusState` still says list (logs: onAppear then NSWindow + beep).
                        DispatchQueue.main.async {
                            guard selectedProjectName == nil, isProjectListFocused else { return }
                            isProjectListFocused = false
                            isProjectListFocused = true
                        }
                    }
                    .onChange(of: selectedProjectIds) { _, newIds in
                        guard selectedProjectName == nil else { return }
                        let projects = filteredProjects
                        guard !projects.isEmpty else { return }
                        let id: String?
                        if newIds.count == 1, let only = newIds.first {
                            id = only
                        } else {
                            let hi = min(max(projectKeyboardHeadIndex, 0), projects.count - 1)
                            id = projects[hi].id
                        }
                        guard let scrollId = id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(scrollId, anchor: .center)
                        }
                    }
                    .onChange(of: searchText) { _, _ in syncProjectSelectionToFilteredList() }
                    .onChange(of: projectSortOrder) { _, _ in syncProjectSelectionToFilteredList() }
                    .onChange(of: allProjects.count) { _, _ in syncProjectSelectionToFilteredList() }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openProject(_ project: SimianProject) {
        selectedProjectIds = [project.id]
        selectedProjectName = project.name
        projectKeyboardAnchorIndex = nil
        if let idx = filteredProjects.firstIndex(where: { $0.id == project.id }) {
            projectKeyboardHeadIndex = idx
        }
        treeKeyboardAnchorIndex = nil
        treeKeyboardHeadIndex = 0
        folderBreadcrumb = []
        currentFiles = []
        selectedItemIds.removeAll(); expandedFolderIds.removeAll(); folderChildrenCache.removeAll(); folderFilesCache.removeAll()
        isProjectListFocused = false
        isFolderListFocused = false
        loadFolders(projectId: project.id, parentFolderId: nil)
        // #region agent log
        logFocusSnapshot("openProject sync (before load completes)", hypothesisId: "H1")
        // #endregion
    }

    private func folderBrowserView(projectId: String, projectName: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { exitToProjectList(keepSelection: false) }) { Label("Back to projects", systemImage: "chevron.left").font(.caption) }.buttonStyle(.borderless)
                Text("\u{2192}").font(.caption).foregroundStyle(.secondary)
                Text(projectName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: { beginFinderStyleNewFolder(parentFolderId: currentParentFolderId, itemIdsToMove: []) }) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("New Folder (⌘N)")
                .disabled(isCreatingFolder)
                Button(action: { refreshCurrentView() }) { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }.buttonStyle(.borderless).help("Refresh folders and files")
            }.padding(.horizontal, 12).padding(.vertical, 8).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            if isLoadingFolders {
                HStack(spacing: 8) { ProgressView().scaleEffect(0.8); Text("Loading folders...").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding()
            } else {
                SimianTreeView(
                    projectId: projectId,
                    currentFolders: currentFolders,
                    currentFiles: currentFiles,
                    folderChildrenCache: folderChildrenCache,
                    folderFilesCache: folderFilesCache,
                    loadingFolderIds: loadingFolderIds,
                    expandedFolderIds: expandedFolderIds,
                    selectedItemIds: selectedItemIds,
                    inlineRenameItemId: inlineRenameItemId,
                    currentParentFolderId: currentParentFolderId,
                    stagedFileCount: manager.selectedFiles.count,
                    focusTrigger: folderListFocusTrigger,
                    inlineRenameText: $inlineRenameText,
                    onToggleExpand: { folderId in toggleExpand(projectId: projectId, folderId: folderId) },
                    onSpringLoadExpand: { folderId in expandFolderForSpringLoad(projectId: projectId, folderId: folderId) },
                    onLoadChildren: { folderId in loadFolderChildren(projectId: projectId, folderId: folderId) },
                    onReorderFolders: { pid, folderIds, parentId, dropBeforeId in
                        reorderFolders(projectId: pid, folderIds: folderIds, parentFolderId: parentId, dropBeforeFolderId: dropBeforeId)
                    },
                    onReorderFiles: { pid, fileIds, parentId, dropBeforeId in
                        reorderFiles(projectId: pid, fileIds: fileIds, parentFolderId: parentId, dropBeforeFileId: dropBeforeId)
                    },
                    onMoveIntoFolder: { pid, itemIds, targetFolderId in
                        moveItemsIntoFolder(projectId: pid, itemIds: itemIds, targetFolderId: targetFolderId)
                    },
                    onExternalFileDrop: { providers, folderId, folderName in
                        handleExternalFileDrop(providers: providers, folderId: folderId, destinationFolderName: folderName)
                    },
                    onSelectionChange: { ids in selectedItemIds = ids },
                    onCommitRename: { commitInlineRename() },
                    onCancelRename: { inlineRenameItemId = nil; inlineRenameText = "" },
                    onContextAction: { action in handleSimianTreeContextAction(action, projectId: projectId) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func uploadToFolder(folderId: String?, destinationFolderName: String?) {
        guard let projectId = browsingProjectId else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.message = "Select files or folders to upload"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            DispatchQueue.main.async { uploadDroppedFiles(projectId: projectId, folderId: folderId, destinationFolderName: destinationFolderName, fileURLs: panel.urls) }
        }
    }

    private func uploadStagedFiles(folderId: String?, destinationFolderName: String?) {
        guard let projectId = browsingProjectId, !manager.selectedFiles.isEmpty else { return }
        uploadDroppedFiles(projectId: projectId, folderId: folderId, destinationFolderName: destinationFolderName, fileURLs: manager.selectedFiles.map { $0.url })
    }

    /// Selected tree rows whose parent folder matches the folder we are currently browsing (for empty-area context menu).
    private func selectedTreeIdsInCurrentFolder(treeList: [SimianTreeItem]) -> [String] {
        let parentId = currentParentFolderId
        return treeList.compactMap { item -> String? in
            guard selectedItemIds.contains(item.id) else { return nil }
            switch item {
            case .folder(_, _, _, let p), .file(_, _, _, let p): return p == parentId ? item.id : nil
            }
        }
    }

    private func startNewFolderWithSelectionFromCurrentDirectory(treeList: [SimianTreeItem]) {
        let ids = selectedTreeIdsInCurrentFolder(treeList: treeList)
        guard !ids.isEmpty else { return }
        beginFinderStyleNewFolder(parentFolderId: currentParentFolderId, itemIdsToMove: ids)
    }

    @ViewBuilder
    private func folderBrowserEmptyAreaContextMenu(projectId: String, treeList: [SimianTreeItem]) -> some View {
        let selectionInFolder = selectedTreeIdsInCurrentFolder(treeList: treeList)
        Button("Upload to\u{2026}") { uploadToFolder(folderId: currentParentFolderId, destinationFolderName: folderBreadcrumb.last?.name) }
        if !manager.selectedFiles.isEmpty {
            Button("Upload \(manager.selectedFiles.count) staged file(s) here") { uploadStagedFiles(folderId: currentParentFolderId, destinationFolderName: folderBreadcrumb.last?.name) }
        }
        Divider()
        Button("New Folder with Selection") { startNewFolderWithSelectionFromCurrentDirectory(treeList: treeList) }
            .disabled(selectionInFolder.isEmpty)
        Button("New Folder") { beginFinderStyleNewFolder(parentFolderId: currentParentFolderId, itemIdsToMove: []) }
        if let rid = selectionInFolder.first {
            Divider()
            renameAndAddDateSection(treeList: treeList, rightClickedId: rid)
        }
        if let folderId = currentParentFolderId, let folderName = folderBreadcrumb.last?.name {
            Button("Rename\u{2026}") {
                renameIsFolder = true
                renameItemId = folderId
                renameParentFolderId = folderBreadcrumb.dropLast().last?.id
                renameCurrentName = folderName
                renameNewName = folderName
                showRenameSheet = true
            }
            Button("Copy Link") { copyFolderLink(projectId: projectId, folderId: folderId) }
            Button("Download folder contents\u{2026}") {
                presentSubtreeDownloadSavePanel(
                    projectId: projectId,
                    folderId: folderId,
                    rootFolderLabel: folderName,
                    panelMessage: "A folder will be created here with all files from “\(folderName)”.",
                    emptyResultMessage: "Folder is empty."
                )
            }
            .disabled(isDownloadingFromSimian)
            Divider()
            Button("Remove from Simian\u{2026}", role: .destructive) {
                pendingDeleteItems = [
                    SimianPendingDeleteItem(isFolder: true, itemId: folderId, displayName: folderName, parentFolderId: folderBreadcrumb.dropLast().last?.id)
                ]
                showDeleteConfirmation = true
            }
        } else if browsingProjectId != nil, selectedProjectName != nil {
            Button("Download entire project\u{2026}") {
                showDownloadEntireProjectConfirmation = true
            }
            .disabled(isDownloadingFromSimian)
        }
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
            onExternalFileDrop: { providers in handleExternalFileDrop(providers: providers, folderId: folder.id, destinationFolderName: folder.name) },
            onMoveIntoFolder: { draggedIds in
                handleFolderRowSimianDrop(projectId: projectId, itemIds: draggedIds, targetFolderId: folder.id, targetSiblingParentId: parentFolderId, treeList: treeList)
            },
            onReorderInsertAfter: { draggedIds in
                let nextId = siblings.firstIndex(where: { $0.id == folder.id }).flatMap { i in i + 1 < siblings.count ? siblings[i + 1].id : nil }
                reorderItems(projectId: projectId, draggedIds: draggedIds, targetId: nextId.map { "f-\($0)" }, treeList: treeList)
            },
            onCommitRename: { commitInlineRename() },
            onCancelRename: { inlineRenameItemId = nil; inlineRenameText = "" }
        )
        .contextMenu {
            Button("Upload to\u{2026}") { uploadToFolder(folderId: folder.id, destinationFolderName: folder.name) }
            if !manager.selectedFiles.isEmpty {
                Button("Upload \(manager.selectedFiles.count) staged file(s) here") { uploadStagedFiles(folderId: folder.id, destinationFolderName: folder.name) }
            }
            Divider()
            Button("New Folder with Selection") { startNewFolderWithSelection(treeList: treeList, rightClickedId: "f-\(folder.id)") }
            Button("New Folder") { beginFinderStyleNewFolder(parentFolderId: folder.id, itemIdsToMove: []) }
            Divider()
            renameAndAddDateSection(treeList: treeList, rightClickedId: "f-\(folder.id)")
            Divider()
            Button("Copy Link") { copyFolderLink(projectId: projectId, folderId: folder.id) }
            Button("Download folder contents\u{2026}") {
                presentSubtreeDownloadSavePanel(
                    projectId: projectId,
                    folderId: folder.id,
                    rootFolderLabel: folder.name,
                    panelMessage: "A folder will be created here with all files from “\(folder.name)”.",
                    emptyResultMessage: "Folder is empty."
                )
            }
            .disabled(isDownloadingFromSimian)
            Divider()
            Button("Remove from Simian\u{2026}", role: .destructive) {
                enqueueDeleteForTreeIds(treeIdsForMultiSelectContextAction(rightClickedTreeId: "f-\(folder.id)"), treeList: treeList)
            }
        }
    }

    private func fileTreeRow(file: SimianFile, depth: Int, path: String, parentFolderId: String?, siblings: [SimianFile], treeList: [SimianTreeItem]) -> some View {
        let isEditing = inlineRenameItemId == "file-\(file.id)"
        // Resolve the destination folder name from caches so nested-file drops go to the correct folder.
        let dropFolderName = parentFolderId.flatMap { cachedFolderName(forFolderId: $0) } ?? folderBreadcrumb.last?.name
        return SimianFileRow(
            fileId: file.id, projectId: browsingProjectId ?? "", parentFolderId: parentFolderId,
            depth: depth, fileName: file.title, canReorder: siblings.count > 1,
            isEditing: isEditing, editText: $inlineRenameText,
            selectedItemIds: selectedItemIds,
            onExternalFileDrop: { providers in handleExternalFileDrop(providers: providers, folderId: parentFolderId, destinationFolderName: dropFolderName) },
            onReorderInsertAfter: { draggedIds in
                let nextId = siblings.firstIndex(where: { $0.id == file.id }).flatMap { i in i + 1 < siblings.count ? siblings[i + 1].id : nil }
                reorderItems(projectId: browsingProjectId ?? "", draggedIds: draggedIds, targetId: nextId.map { "file-\($0)" }, treeList: treeList)
            },
            onCommitRename: { commitInlineRename() },
            onCancelRename: { inlineRenameItemId = nil; inlineRenameText = "" }
        )
        .contextMenu {
            Button("New Folder with Selection") { startNewFolderWithSelection(treeList: treeList, rightClickedId: "file-\(file.id)") }
            Divider()
            renameAndAddDateSection(treeList: treeList, rightClickedId: "file-\(file.id)")
            Divider()
            Button("Download\u{2026}") { beginDownloadSimianFile(file) }
                .disabled(file.mediaURL == nil || isDownloadingFromSimian)
            Divider()
            Button("Remove from Simian\u{2026}", role: .destructive) {
                enqueueDeleteForTreeIds(treeIdsForMultiSelectContextAction(rightClickedTreeId: "file-\(file.id)"), treeList: treeList)
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

    /// Expand-only spring-load: expands without toggling (so the folder stays open after the drag ends)
    /// and never changes selectedItemIds so the dragged item's selection is preserved.
    private func expandFolderForSpringLoad(projectId: String, folderId: String) {
        guard !expandedFolderIds.contains(folderId) else { return }
        expandedFolderIds.insert(folderId)
        if folderChildrenCache[folderId] == nil { loadFolderChildren(projectId: projectId, folderId: folderId) }
    }

    /// Route context menu actions from SimianTreeView back into existing SimianPostView logic.
    private func handleSimianTreeContextAction(_ action: SimianTreeContextAction, projectId: String) {
        let treeList = flatTreeList(projectId: projectId)
        switch action {
        case .uploadTo(let folderId, let folderName):
            uploadToFolder(folderId: folderId, destinationFolderName: folderName)
        case .uploadStagedFiles(let folderId, let folderName):
            uploadStagedFiles(folderId: folderId, destinationFolderName: folderName)
        case .newFolderWithSelection(let treeId):
            if treeId.isEmpty {
                startNewFolderWithSelectionFromCurrentDirectory(treeList: treeList)
            } else {
                startNewFolderWithSelection(treeList: treeList, rightClickedId: treeId)
            }
        case .newFolder(let parentFolderId):
            beginFinderStyleNewFolder(parentFolderId: parentFolderId, itemIdsToMove: [])
        case .beginRename(let treeId):
            if shouldOfferBatchRename(rightClickedId: treeId) {
                startBatchRename(treeList: treeList, rightClickedId: treeId)
            } else {
                presentRenameSheetForTreeItem(id: treeId, treeList: treeList)
            }
        case .addDate(let treeId, let useUploadTime):
            addDateStampToSelection(treeList: treeList, rightClickedId: treeId, useUploadTime: useUploadTime)
        case .copyLink(let treeId):
            if treeId.hasPrefix("f-"), treeId.count > 2 {
                copyFolderLink(projectId: projectId, folderId: String(treeId.dropFirst(2)))
            }
        case .downloadFolder(let folderId, let folderName):
            presentSubtreeDownloadSavePanel(
                projectId: projectId,
                folderId: folderId,
                rootFolderLabel: folderName,
                panelMessage: "A folder will be created here with all files from \u{201C}\(folderName)\u{201D}.",
                emptyResultMessage: "Folder is empty."
            )
        case .downloadFile(let fileId):
            if let treeItem = treeList.first(where: { $0.id == "file-\(fileId)" }),
               case .file(let f, _, _, _) = treeItem {
                beginDownloadSimianFile(f)
            }
        case .delete(let treeId):
            let ids = treeIdsForMultiSelectContextAction(rightClickedTreeId: treeId)
            enqueueDeleteForTreeIds(ids, treeList: treeList)
        }
    }

    private func startNewFolderWithSelection(treeList: [SimianTreeItem], rightClickedId: String) {
        // Use all selected items when the right-clicked item is in the selection; otherwise just the right-clicked item
        let ids = (selectedItemIds.contains(rightClickedId) && selectedItemIds.count > 1)
            ? Array(selectedItemIds)
            : [rightClickedId]
        let parent = parentFolderId(forTreeItemId: rightClickedId, in: treeList)
        beginFinderStyleNewFolder(parentFolderId: parent, itemIdsToMove: ids)
    }

    /// Multiple items selected and the row you opened the menu on is part of that selection → batch rename; otherwise single-item rename.
    private func shouldOfferBatchRename(rightClickedId: String) -> Bool {
        selectedItemIds.contains(rightClickedId) && selectedItemIds.count > 1
    }

    /// Same selection rule as batch rename / new folder with selection: act on full selection when the row is in it.
    private func treeIdsForMultiSelectContextAction(rightClickedTreeId: String) -> [String] {
        (selectedItemIds.contains(rightClickedTreeId) && selectedItemIds.count > 1)
            ? Array(selectedItemIds)
            : [rightClickedTreeId]
    }

    private func enqueueDeleteForTreeIds(_ treeIds: [String], treeList: [SimianTreeItem]) {
        let items: [SimianPendingDeleteItem] = treeIds.compactMap { id in
            guard let treeItem = treeList.first(where: { $0.id == id }) else { return nil }
            switch treeItem {
            case .folder(let f, _, _, let pid):
                return SimianPendingDeleteItem(isFolder: true, itemId: f.id, displayName: f.name, parentFolderId: pid)
            case .file(let f, _, _, let pid):
                return SimianPendingDeleteItem(isFolder: false, itemId: f.id, displayName: f.title, parentFolderId: pid)
            }
        }
        guard !items.isEmpty else { return }
        pendingDeleteItems = items
        showDeleteConfirmation = true
    }

    private func presentRenameSheetForTreeItem(id: String, treeList: [SimianTreeItem]) {
        guard let item = treeList.first(where: { $0.id == id }) else { return }
        switch item {
        case .folder(let folder, _, _, let parentId):
            renameIsFolder = true
            renameItemId = folder.id
            renameParentFolderId = parentId
            renameCurrentName = folder.name
            renameNewName = folder.name
        case .file(let file, _, _, let parentId):
            renameIsFolder = false
            renameItemId = file.id
            renameParentFolderId = parentId
            renameCurrentName = file.title
            renameNewName = file.title
        }
        showRenameSheet = true
    }

    private func startBatchRename(treeList: [SimianTreeItem], rightClickedId: String) {
        let ids = (selectedItemIds.contains(rightClickedId) && selectedItemIds.count > 1)
            ? Array(selectedItemIds)
            : [rightClickedId]
        let mapped: [BatchRenameTarget] = ids.compactMap { id in
            guard let item = treeList.first(where: { $0.id == id }) else { return nil }
            switch item {
            case .folder(let folder, _, _, let parentId):
                return BatchRenameTarget(
                    id: id,
                    itemId: folder.id,
                    isFolder: true,
                    parentFolderId: parentId,
                    currentName: folder.name,
                    uploadedAt: folder.uploadedAt
                )
            case .file(let file, _, _, let parentId):
                return BatchRenameTarget(
                    id: id,
                    itemId: file.id,
                    isFolder: false,
                    parentFolderId: parentId,
                    currentName: file.title,
                    uploadedAt: file.uploadedAt
                )
            }
        }
        guard !mapped.isEmpty else { return }
        batchRenameTargets = mapped
        batchRenameMode = .replace
        batchRenameFindText = ""
        batchRenameValueText = ""
        batchRenameError = nil
        isBatchRenaming = false
        showBatchRenameSheet = true
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
        // If targetId is nil (insert at end), use the first dragged item of each type to determine parent.
        // Search is type-specific so a mixed selection (f- and file-) resolves each type independently.
        if targetId == nil {
            if !folderIds.isEmpty {
                if let firstDragged = treeList.first(where: { $0.id.hasPrefix("f-") && draggedIds.contains($0.id) }),
                   case .folder(_, _, _, let parentId) = firstDragged {
                    reorderFolders(projectId: projectId, folderIds: folderIds, parentFolderId: parentId, dropBeforeFolderId: nil)
                }
            }
            if !fileIds.isEmpty {
                if let firstDragged = treeList.first(where: { $0.id.hasPrefix("file-") && draggedIds.contains($0.id) }),
                   case .file(_, _, _, let parentId) = firstDragged {
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
        // When dropping on the gap below the row above, "insert before next" is the dragged item itself;
        // it is absent from `reordered`, so use its original index among siblings (same fix as files).
        let insertIdx: Int
        if let beforeId = dropBeforeFolderId {
            if let toIdx = reordered.firstIndex(where: { $0.id == beforeId }) {
                insertIdx = toIdx
            } else if folderIds.contains(beforeId), let origIdx = siblings.firstIndex(where: { $0.id == beforeId }) {
                insertIdx = siblings[..<origIdx].filter { !folderIds.contains($0.id) }.count
            } else {
                insertIdx = reordered.count
            }
        } else {
            insertIdx = reordered.count
        }
        reordered.insert(contentsOf: moved, at: insertIdx)
        let ids = reordered.map { $0.id }
        Task {
            do {
                try await simianService.updateFolderSort(projectId: projectId, parentFolderId: parentFolderId, folderIds: ids)
                await MainActor.run {
                    withAnimation(SimianReorderMotion.listSpring) {
                        if let pid = parentFolderId {
                            folderChildrenCache[pid] = reordered
                            if pid == currentParentFolderId { currentFolders = reordered }
                        } else {
                            currentFolders = reordered
                        }
                    }
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
        if let beforeId = dropBeforeFileId {
            if let toIdx = reordered.firstIndex(where: { $0.id == beforeId }) {
                insertIdx = toIdx
            } else if fileIds.contains(beforeId), let origIdx = siblings.firstIndex(where: { $0.id == beforeId }) {
                insertIdx = siblings[..<origIdx].filter { !fileIds.contains($0.id) }.count
            } else {
                insertIdx = reordered.count
            }
        } else {
            insertIdx = reordered.count
        }
        reordered.insert(contentsOf: moved, at: insertIdx)
        let ids = reordered.map { $0.id }
        Task {
            do {
                try await simianService.updateFileSort(projectId: projectId, folderId: pid, fileIds: ids)
                await MainActor.run {
                    withAnimation(SimianReorderMotion.listSpring) {
                        folderFilesCache[pid] = reordered
                        if pid == currentParentFolderId { currentFiles = reordered }
                    }
                    statusMessage = moved.count > 1 ? "\(moved.count) files moved" : "File moved"; statusIsError = false
                }
            } catch {
                await MainActor.run { statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
            }
        }
    }

    private func uniqueSimianDownloadSubfolderURL(under parent: URL, name: String) -> URL {
        let fm = FileManager.default
        let base = SimianService.sanitizeFileNameForDownload(name.isEmpty ? "SimianFolder" : name)
        var candidate = parent.appendingPathComponent(base)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) (\(n))")
            n += 1
        }
        return candidate
    }

    private func beginDownloadSimianFile(_ file: SimianFile) {
        guard let mediaURL = file.mediaURL else {
            statusMessage = "This file has no download URL."
            statusIsError = true
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SimianService.buildDownloadFileName(for: file, mediaURL: mediaURL)
        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            isDownloadingFromSimian = true
            statusMessage = "Downloading\u{2026}"
            statusIsError = false
            Task {
                do {
                    try await simianService.downloadFile(from: mediaURL, to: destURL)
                    await MainActor.run {
                        isDownloadingFromSimian = false
                        statusMessage = "Downloaded to \(destURL.lastPathComponent)"
                        statusIsError = false
                    }
                } catch {
                    await MainActor.run {
                        isDownloadingFromSimian = false
                        statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        statusIsError = true
                    }
                }
            }
        }
    }

    /// Enumerate and download a folder subtree (or project root when `folderId` is nil) after the user picks a parent directory.
    private func presentSubtreeDownloadSavePanel(
        projectId: String,
        folderId: String?,
        rootFolderLabel: String,
        panelMessage: String,
        emptyResultMessage: String
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Destination"
        panel.message = panelMessage
        panel.begin { response in
            guard response == .OK, let parentURL = panel.url else { return }
            let destRoot = uniqueSimianDownloadSubfolderURL(under: parentURL, name: rootFolderLabel)
            isDownloadingFromSimian = true
            statusMessage = "Preparing download\u{2026}"
            statusIsError = false
            Task {
                do {
                    let items = try await simianService.enumerateFilesInFolderSubtree(projectId: projectId, folderId: folderId)
                    if items.isEmpty {
                        await MainActor.run {
                            isDownloadingFromSimian = false
                            statusMessage = emptyResultMessage
                            statusIsError = false
                        }
                        return
                    }
                    let skipped = items.filter { $0.file.mediaURL == nil }.count
                    try await simianService.downloadFilesWithRelativePaths(items, to: destRoot) { completed, total, path in
                        statusMessage = "Downloading \(path) (\(completed)/\(total))"
                        statusIsError = false
                    }
                    await MainActor.run {
                        isDownloadingFromSimian = false
                        let base = destRoot.lastPathComponent
                        if skipped > 0 {
                            statusMessage = "Downloaded \(base) (\(skipped) file(s) had no URL and were skipped)"
                        } else {
                            statusMessage = "Downloaded folder \(base)"
                        }
                        statusIsError = false
                    }
                } catch {
                    await MainActor.run {
                        isDownloadingFromSimian = false
                        statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        statusIsError = true
                    }
                }
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
            do {
                async let foldersTask = simianService.getProjectFolders(projectId: projectId, parentFolderId: parentFolderId)
                let files: [SimianFile]
                if let folderId = parentFolderId {
                    files = try await simianService.getProjectFiles(projectId: projectId, folderId: folderId)
                } else {
                    files = []
                }
                let folders = try await foldersTask
                await MainActor.run {
                    currentFolders = folders
                    currentFiles = files
                    isLoadingFolders = false
                    // #region agent log
                    logFocusSnapshot("loadFolders completed (success)", hypothesisId: "H5")
                    // #endregion
                    // After the new SimianTreeView mounts, make its NSOutlineView first responder.
                    if selectedProjectName != nil {
                        folderListFocusTrigger += 1
                    }
                }
            } catch {
                await MainActor.run {
                    currentFolders = []
                    currentFiles = []
                    isLoadingFolders = false
                    // #region agent log
                    logFocusSnapshot("loadFolders completed (error)", hypothesisId: "H5")
                    // #endregion
                    if selectedProjectName != nil {
                        folderListFocusTrigger += 1
                    }
                }
            }
        }
    }

    private func selectFirstProjectIfOne() { if filteredProjects.count == 1 { openProject(filteredProjects[0]) } }

    // MARK: - Tree model

    private let maxFoldersPerLevel = 200
    private let maxTotalTreeRows = 500

    private func folderSiblings(parentId: String?) -> [SimianFolder] {
        guard let parentId else { return currentFolders }
        if parentId == currentParentFolderId { return currentFolders }
        return folderChildrenCache[parentId] ?? []
    }
    private func fileSiblings(parentFolderId: String?) -> [SimianFile] {
        guard let id = parentFolderId else { return [] }
        if id == currentParentFolderId { return currentFiles }
        return folderFilesCache[id] ?? []
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
        var stack: [StackItem] = []
        if !currentFiles.isEmpty {
            stack.append(.files(currentFiles, 0, "", currentParentFolderId))
        }
        stack.append(.folders(currentFolders, 0, "", currentParentFolderId))
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

    private func handleExternalFileDrop(providers: [NSItemProvider], folderId: String?, destinationFolderName: String?) -> Bool {
        guard let projectId = browsingProjectId else { return false }
        loadURLsFromProviders(providers) { urls in
            guard !urls.isEmpty else { return }
            uploadDroppedFiles(projectId: projectId, folderId: folderId, destinationFolderName: destinationFolderName, fileURLs: urls)
        }
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

    private func uploadDroppedFiles(projectId: String, folderId: String?, destinationFolderName: String?, fileURLs: [URL]) {
        let itemsToUpload = fileURLs.map { FileItem(url: $0) }
        let totalFiles = itemsToUpload.reduce(0) { $0 + $1.fileCount }
        let resolvedDestinationFolderName = SimianFolderNaming.effectiveDestinationFolderName(
            providedName: destinationFolderName,
            folderId: folderId,
            currentFolderId: currentParentFolderId,
            currentFolderName: folderBreadcrumb.last?.name,
            cachedFolderName: folderId.flatMap { cachedFolderName(forFolderId: $0) }
        )
        isUploading = true; statusMessage = "Uploading\u{2026}"; statusIsError = false; uploadTotal = totalFiles; uploadCurrent = 0; uploadFileName = ""
        Task {
            do {
                let progressCounter = ProgressCounter()
                let looseItems = itemsToUpload.filter { !$0.isDirectory }
                let dirItems = itemsToUpload.filter { $0.isDirectory }
                let shouldNestLoose = SimianFolderNaming.shouldAutoNestLooseFiles(inDestinationFolderNamed: resolvedDestinationFolderName)
                    && folderId != nil
                    && !looseItems.isEmpty

                var looseFolderId = folderId
                if shouldNestLoose, let parentId = folderId {
                    let siblings = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: parentId)
                    let newName = SimianFolderNaming.nextDateStampedLooseFileFolderName(existingFolderNames: siblings.map { $0.name })
                    looseFolderId = try await simianService.createFolderPublic(projectId: projectId, folderName: newName, parentFolderId: parentId)
                }

                for fileItem in looseItems {
                    progressCounter.increment()
                    await MainActor.run { uploadCurrent = progressCounter.value; uploadTotal = totalFiles; uploadFileName = fileItem.name }
                    _ = try await simianService.uploadFile(
                        projectId: projectId,
                        folderId: looseFolderId,
                        fileURL: fileItem.url,
                        musicExtensionsForUploadNaming: settingsManager.currentSettings.musicExtensions
                    )
                }

                for fileItem in dirItems {
                    let existingFolders = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: folderId)
                    try await uploadFolderWithStructure(projectId: projectId, destinationFolderId: folderId, localFolderURL: fileItem.url, existingFolderNames: existingFolders.map { $0.name }) { fileName in
                        progressCounter.increment(); Task { @MainActor in uploadCurrent = progressCounter.value; uploadTotal = totalFiles; uploadFileName = fileName }
                    }
                }
                await MainActor.run {
                    isUploading = false; statusMessage = "Uploaded \(progressCounter.value) file(s)."; statusIsError = false
                    if browsingProjectId == projectId {
                        // Full refresh (like after delete): reload current level + all expanded folder children.
                        refreshCurrentView()
                        // Simian list APIs can lag slightly behind upload; a second pass catches new items.
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            guard browsingProjectId == projectId else { return }
                            refreshCurrentView()
                        }
                    }
                }
            } catch {
                await MainActor.run { isUploading = false; statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; statusIsError = true }
            }
        }
    }

    private func uploadFolderWithStructure(projectId: String, destinationFolderId: String?, localFolderURL: URL, existingFolderNames: [String], uploadProgress: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        let folderName = SimianFolderNaming.nextNumberedFolderName(existingFolderNames: existingFolderNames, sourceFolderName: localFolderURL.lastPathComponent)
        let simianFolderId = try await simianService.createFolderPublic(projectId: projectId, folderName: folderName, parentFolderId: destinationFolderId)
        guard let contents = try? fm.contentsOfDirectory(at: localFolderURL, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        var filesHere: [URL] = []; var subfolders: [URL] = []
        for item in contents {
            guard item.lastPathComponent != ".DS_Store" else { continue }
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { subfolders.append(item) }
            else if (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { filesHere.append(item) }
        }
        for fileURL in filesHere {
            uploadProgress(fileURL.lastPathComponent)
            _ = try await simianService.uploadFile(
                projectId: projectId,
                folderId: simianFolderId,
                fileURL: fileURL,
                musicExtensionsForUploadNaming: settingsManager.currentSettings.musicExtensions
            )
        }
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

func buildSimianDragPayload(type: String, projectId: String, parentId: String?, itemIds: [String]) -> String {
    "simian-multi|\(type)|\(projectId)|\(parentId ?? "")|\(itemIds.joined(separator: ","))"
}

func parseSimianMultiDrag(_ str: String) -> (type: String, projectId: String, parentId: String?, itemIds: [String])? {
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

/// Spring used only when committing a reorder so the list does not animate every hover/layout tick during drag.
private enum SimianReorderMotion {
    static let listSpring = Animation.spring(response: 0.48, dampingFraction: 0.88, blendDuration: 0.2)
}

private struct ReorderGapView: View {
    let expectedType: String
    let validateParent: (String?) -> Bool
    let onDrop: ([String]) -> Void
    let canReorder: Bool
    @Binding var isTargeted: Bool

    /// Fixed height avoids animating row geometry during drag (that + list-level animation caused jitter with the drag preview).
    private let rowHeight: CGFloat = 10

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(isTargeted ? Color.accentColor.opacity(0.22) : Color.clear)
                .padding(.horizontal, 4)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onDrop(of: [.text, .plainText, .utf8PlainText], isTargeted: $isTargeted) { providers in
            guard canReorder else { return false }
            guard let provider = providers.first,
                  provider.canLoadObject(ofClass: String.self) else { return false }
            // Synchronous pre-validation via the drag pasteboard; avoids accepting drops whose
            // payload will fail validation in the async callback (which would look like a silent no-op).
            let dragPB = NSPasteboard(name: .drag)
            let pbStr = dragPB.string(forType: .string)
                       ?? dragPB.string(forType: NSPasteboard.PasteboardType(rawValue: UTType.utf8PlainText.identifier))
                       ?? dragPB.string(forType: NSPasteboard.PasteboardType(rawValue: UTType.plainText.identifier))
            if let str = pbStr {
                guard let parsed = parseSimianMultiDrag(str),
                      parsed.type == expectedType,
                      validateParent(parsed.parentId) else { return false }
            }
            _ = provider.loadObject(ofClass: String.self) { obj, _ in
                guard let str = obj,
                      let parsed = parseSimianMultiDrag(str),
                      parsed.type == expectedType,
                      validateParent(parsed.parentId) else { return }
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
    let onExternalFileDrop: ([NSItemProvider]) -> Bool
    let onMoveIntoFolder: ([String]) -> Void
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
                    .offset(y: 5)
                }.buttonStyle(.plain)

                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary).offset(y: 5).allowsHitTesting(false)
                if isEditing {
                    TextField("", text: $editText, onCommit: { onCommitRename() })
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        .focused($isEditFocused)
                        .onAppear {
                            isEditFocused = true
                            DispatchQueue.main.async {
                                DispatchQueue.main.async {
                                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                                }
                            }
                        }
                        .onExitCommand { onCancelRename() }
                } else {
                    Text(folderName).font(.system(size: 13)).lineLimit(1).offset(y: 5).allowsHitTesting(false)
                }
                Spacer()
                if isDropTargeted { Image(systemName: "plus.circle.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor).offset(y: 5) }
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .center)
            .contentShape(Rectangle())
            .background((isDropTargeted || isSimianDropTargeted) ? Color.accentColor.opacity(0.15) : Color.clear)
            // Avoid TapGesture / onTapGesture on this row: they prevent `.draggable` on the parent VStack
            // from starting a drag on macOS. Selection uses `List(selection:)`; expand via chevron (or context menu).
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

            ReorderGapView(expectedType: "folder", validateParent: validateParent, onDrop: { ids in onReorderInsertAfter(ids) }, canReorder: canReorder, isTargeted: $isGapBelow)
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
    /// Drop Finder files onto the row body → upload into this file's parent folder.
    let onExternalFileDrop: ([NSItemProvider]) -> Bool
    let onReorderInsertAfter: ([String]) -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    @State private var isGapBelow = false
    @State private var isHovered = false
    @State private var isExternalFileDropTargeted = false
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
                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary).offset(y: 5).allowsHitTesting(false)
                if isEditing {
                    TextField("", text: $editText, onCommit: { onCommitRename() })
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                        .focused($isEditFocused)
                        .onAppear {
                            isEditFocused = true
                            DispatchQueue.main.async {
                                DispatchQueue.main.async {
                                    (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                                }
                            }
                        }
                        .onExitCommand { onCancelRename() }
                } else {
                    Text(fileName).font(.system(size: 13)).lineLimit(1).offset(y: 5).allowsHitTesting(false)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .center)
            .contentShape(Rectangle())
            .background(isExternalFileDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
            .onDrop(of: [UTType.fileURL], isTargeted: $isExternalFileDropTargeted, perform: onExternalFileDrop)

            ReorderGapView(expectedType: "file", validateParent: validateParent, onDrop: { ids in onReorderInsertAfter(ids) }, canReorder: canReorder, isTargeted: $isGapBelow)
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
