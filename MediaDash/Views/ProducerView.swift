import SwiftUI

/// Filter/organize task list in Producer view
enum TaskListFilterKind: String, CaseIterable {
    case none = "All"
    case tag = "Tag"
    case assignee = "Assigned to"
    case createdBy = "Created by"
}

enum ProducerProjectSortMode: String, CaseIterable, Identifiable {
    case lastModified = "Last Modified"
    case creationTime = "Creation Time"
    
    var id: String { rawValue }
    
    var asanaSortField: AsanaProjectSortField {
        switch self {
        case .lastModified:
            return .lastModified
        case .creationTime:
            return .creationTime
        }
    }
}

// MARK: - Producer View (Search → Project → Section → Task → Push to Airtable)

struct ProducerView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var asanaCacheManager: AsanaCacheManager
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var asanaService = AsanaService()
    @StateObject private var airtableService = AirtableService()
    
    // Search & navigation (same data model as media: dockets from fetchDockets, then filter like searchAsana)
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var statusMessage: String?
    @State private var allDockets: [DocketInfo] = []
    @State private var filteredDockets: [DocketInfo] = []
    @State private var projectSortMode: ProducerProjectSortMode = .lastModified
    @State private var isLoadingDockets = false
    @State private var docketsLoadError: String?
    @State private var isInSearchResultsMode = false
    @State private var didLoadInitialProjects = false
    @State private var selectedProject: AsanaProject?
    @State private var sections: [AsanaSection] = []
    @State private var selectedSection: AsanaSection?
    @State private var sectionTasks: [AsanaTask] = []
    /// Filter task list: .none, .tag(name), .assignee(name), .createdBy(name)
    @State private var taskListFilterKind: TaskListFilterKind = .none
    @State private var taskListFilterValue: String = ""
    @State private var selectedTask: AsanaTask?
    @State private var taskDetail: AsanaTask? // Full task with notes
    @State private var isLoadingTaskDetail = false
    
    // Airtable
    @State private var airtableColumnNames: [String] = []
    @State private var loadingColumns = false
    @State private var columnLoadError: String?
    @State private var airtableTables: [AirtableTableInfo] = []
    @State private var isLoadingTables = false
    @State private var pushCheckboxes: [String: Bool] = [:] // "Brief": true, "Music Type": false
    @State private var isPushing = false
    @State private var pushMessage: String?
    @State private var pushError: String?
    /// Task chosen for push from list; sheet shows confirm + checkboxes
    @State private var pushSheetTask: AsanaTask?
    @State private var pushSheetCheckboxes: [String: Bool] = [:]
    /// Job name shown/edited in push sheet (parsed from project name or user-entered)
    @State private var pushSheetJobName: String = ""
    @State private var hoveredTaskGid: String?
    @State private var hoveredDocketId: UUID?
    @State private var hoveredSectionGid: String?
    @State private var hoveredBackFromSections = false
    @State private var hoveredBackFromTasks = false
    @State private var hoveredBackFromTaskDetail = false
    /// Job name for push from task detail (parsed from project name or user-edited)
    @State private var jobNameForPush: String = ""
    /// Per-column custom/override values when pushing (column name -> value). Empty means use auto.
    @State private var pushFieldValues: [String: String] = [:]
    @State private var pushSheetFieldValues: [String: String] = [:]
    /// Asana workspace users for Director (and similar) dropdown
    @State private var asanaUsers: [AsanaUser] = []
    @State private var asanaUsersLoadError: String?
    @FocusState private var focusedPushColumn: String?

    // Quick setup (when not configured)
    @StateObject private var oauthService = OAuthService()
    @State private var isConnectingAsana = false
    @State private var asanaConnectionError: String?
    @State private var showManualCodeEntry = false
    @State private var manualAuthCode = ""
    @State private var manualAuthURL: URL?
    @State private var manualAuthState = ""
    @State private var airtableTokenInput = ""
    @State private var airtableURLInput = ""
    
    // Asana workspace selection (when connected but workspace not set in settings)
    @State private var asanaWorkspaces: [AsanaWorkspace] = []
    @State private var isLoadingWorkspaces = false
    @State private var workspacesLoadError: String?
    
    private var settings: AppSettings { settingsManager.currentSettings }
    
    /// Column list used for field UI and pushes. Falls back to configured field names when live schema discovery is unavailable.
    private var effectiveAirtableColumns: [String] {
        let discovered = airtableColumnNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !discovered.isEmpty { return discovered }
        return configuredAirtableColumns()
    }
    
    private var needsWorkspaceSelection: Bool {
        let hasToken = SharedKeychainService.getAsanaAccessToken() != nil && !(SharedKeychainService.getAsanaAccessToken() ?? "").isEmpty
        let noWorkspace = settings.asanaWorkspaceID == nil || (settings.asanaWorkspaceID ?? "").isEmpty
        return hasToken && noWorkspace
    }
    
    private let contentPadding: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            producerHeader
            mainFlowContent
        }
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Only load data if user is logged in and configured for producer role
            guard isConfigured else { return }
            
            loadAirtableTablesIfNeeded()
            loadAirtableColumnsIfNeeded()
            tryLoadDocketsFromCache()
            loadInitialRecentProjectsIfNeeded()
        }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: .producerOpenRecentProject)) { notification in
            handleOpenRecentProjectNotification(notification)
        }
    }

    /// Staging-style header with MediaDash logo + DOCKETS (logo on staging area, not sidebar)
    private var producerHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                producerLogoImage
                Divider()
                    .frame(height: 28)
                HStack(spacing: 8) {
                    Image(systemName: "number.circle")
                        .foregroundColor(.blue)
                    Text("DOCKETS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    if !filteredDockets.isEmpty {
                        Text("\(filteredDockets.count)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, contentPadding)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
                .opacity(0.3)
        }
    }

    private var producerLogoImage: some View {
        Group {
            let base = Image("HeaderLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 32)
            if colorScheme == .light {
                base.colorInvert()
            } else {
                base
            }
        }
    }

    // MARK: - Main flow (search → project → section → task → push)

    private var mainFlowContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isConfigured {
                ScrollView {
                    configurationRequired
                        .padding(contentPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if needsWorkspaceSelection {
                ScrollView {
                    workspaceSelectorView
                        .padding(contentPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // Compact search bar (always visible when configured)
                producerSearchBar
                    .padding(.horizontal, contentPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))

                // Content area: list fills space (no ScrollView so List gets real height)
                Group {
                    if let task = taskDetail, let proj = selectedProject {
                        ScrollView {
                            taskDetailView(task: task, project: proj)
                                .padding(contentPadding)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if selectedTask != nil && taskDetail == nil {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Loading task…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !sectionTasks.isEmpty, let section = selectedSection {
                        taskListView(tasks: filteredSectionTasks, section: section)
                    } else if !sections.isEmpty, let proj = selectedProject {
                        sectionListView(sections: sections, project: proj)
                    } else if !filteredDockets.isEmpty {
                        docketListView(dockets: filteredDockets)
                    } else if isSearching || isLoadingDockets {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text(statusMessage ?? (isLoadingDockets ? "Loading dockets from Asana…" : "Searching Asana..."))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let err = searchError ?? docketsLoadError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(contentPadding)
                    } else {
                        Text("Enter a docket number or name and tap Search.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Single-line search bar + status (compact, no wasted space)
    private var producerSearchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Back button appears only when showing search results
                if isInSearchResultsMode {
                    Button(action: goBackToBrowse) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Back to Recent Projects")
                }
                
                TextField("Search by docket or project name...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                
                // Sort picker is hidden when viewing search results
                if !isInSearchResultsMode {
                    Picker("Sort", selection: $projectSortMode) {
                        ForEach(ProducerProjectSortMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 170)
                    .onChange(of: projectSortMode) { _, _ in
                        handleProjectSortModeChange()
                    }
                }
                
                Button("Search") { runSearch() }
                    .disabled(searchText.isEmpty || isSearching || isLoadingDockets || needsWorkspaceSelection)
            }
            if let searchError = searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundColor(.red)
            } else if isSearching || isLoadingDockets {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text(statusMessage ?? "Searching Asana...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// List of dockets from search — fills available space so rows are visible (no List-in-ScrollView)
    private func docketListView(dockets: [DocketInfo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Select a docket")
                    .font(.subheadline.weight(.medium))
                Text("\(dockets.count) match(es)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)

            List(dockets, id: \.id) { docket in
                let hovered = hoveredDocketId == docket.id
                Button {
                    selectDocket(docket)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(docket.fullName)
                            .font(.system(size: 13, weight: .medium))
                        Text("\(docket.number) · \(docket.jobName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
                .background(hovered ? Color.accentColor.opacity(0.12) : Color.clear)
                .onHover { hovering in
                    hoveredDocketId = hovering ? docket.id : nil
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, contentPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private func selectDocket(_ docket: DocketInfo) {
        searchError = nil
        statusMessage = nil
        sections = []
        selectedSection = nil
        sectionTasks = []
        selectedTask = nil
        taskDetail = nil
        isSearching = true
        
        // Prefer project from docket metadata (always set when sync uses fetch-by-project)
        let projectGid = docket.projectMetadata?.projectGid
        if let gid = projectGid {
            statusMessage = "Loading project..."
            loadProjectAndSections(projectGid: gid, sourceDocket: docket)
            return
        }
        
        // Fallback 1: docket from cache may lack projectMetadata — if we have the underlying task GID, resolve the project from task memberships
        guard let workspaceID = settings.asanaWorkspaceID, !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchError = "Set Asana workspace in Settings."
            isSearching = false
            return
        }
        Task {
            do {
                if let taskGid = docket.taskGid, !taskGid.isEmpty {
                    await MainActor.run { statusMessage = "Looking up task info..." }
                    let task = try await asanaService.fetchTask(taskGid: taskGid)
                    if let projectGid = task.memberships?.compactMap({ $0.project?.gid }).first {
                        await MainActor.run {
                            persistResolvedProject(docket: docket, projectGid: projectGid)
                            loadProjectAndSections(projectGid: projectGid, sourceDocket: docket)
                        }
                        return
                    }
                }
                
                // Fallback 2: find project by docket number / job name in this workspace
                await MainActor.run { statusMessage = "Searching for project..." }
                let match = try await asanaService.findProjectForDocket(
                    workspaceID: workspaceID,
                    docketNumber: docket.number,
                    jobName: docket.jobName
                )
                
                if let m = match {
                    await MainActor.run {
                        persistResolvedProject(docket: docket, projectGid: m.gid)
                        loadProjectAndSections(projectGid: m.gid, sourceDocket: docket)
                    }
                } else {
                    await MainActor.run {
                        searchError = "No project found for docket \(docket.number) in this workspace. Try a different workspace in Settings."
                        isSearching = false
                        statusMessage = nil
                    }
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                    isSearching = false
                    statusMessage = nil
                }
            }
        }
    }
    
    /// Persist docket→project on the server and update in-memory list so backing out and clicking again doesn't need a full sync.
    private func persistResolvedProject(docket: DocketInfo, projectGid: String) {
        asanaCacheManager.saveDocketProjectMapping(fullName: docket.fullName, projectGid: projectGid)
        let meta = ProjectMetadata(projectGid: projectGid, projectName: nil, createdBy: nil, owner: nil, notes: nil, color: nil, dueDate: nil, team: nil, customFields: [:])
        let updated = DocketInfo(id: docket.id, number: docket.number, jobName: docket.jobName, fullName: docket.fullName, updatedAt: docket.updatedAt, createdAt: docket.createdAt, metadataType: docket.metadataType, subtasks: docket.subtasks, projectMetadata: meta, dueDate: docket.dueDate, taskGid: docket.taskGid, studio: docket.studio, studioColor: docket.studioColor, completed: docket.completed)
        if let idx = allDockets.firstIndex(where: { $0.fullName == docket.fullName }) {
            allDockets[idx] = updated
        }
        applyProducerSearchFilter(query: searchText.trimmingCharacters(in: .whitespaces))
    }
    
    private func loadProjectAndSections(projectGid: String, sourceDocket: DocketInfo? = nil) {
        Task {
            do {
                await MainActor.run { statusMessage = "Loading project..." }
                let project = try await asanaService.fetchProject(projectGid: projectGid)
                await MainActor.run {
                    recordRecentProject(project: project, sourceDocket: sourceDocket)
                    selectedProject = project
                    statusMessage = "Loading sections..."
                }
                loadSections(projectID: project.gid)
                await MainActor.run {
                    isSearching = false
                    statusMessage = nil
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                    isSearching = false
                    statusMessage = nil
                }
            }
        }
    }
    
    private func handleOpenRecentProjectNotification(_ notification: Foundation.Notification) {
        guard let userInfo = notification.userInfo else { return }
        guard let projectGid = userInfo["projectGid"] as? String, !projectGid.isEmpty else { return }
        
        let fullName = (userInfo["fullName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? projectGid
        let docketNumber = (userInfo["docketNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobName = (userInfo["jobName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        searchError = nil
        statusMessage = nil
        docketsLoadError = nil
        selectedProject = nil
        sections = []
        selectedSection = nil
        sectionTasks = []
        selectedTask = nil
        taskDetail = nil
        isSearching = true
        
        let parsed = asanaService.parseDocketFromString(fullName)
        let normalizedDocket = {
            let value = docketNumber ?? ""
            if !value.isEmpty { return value }
            return parsed.docket ?? "—"
        }()
        let normalizedJob = {
            let value = jobName ?? ""
            if !value.isEmpty { return value }
            return parsed.jobName
        }()
        
        let meta = ProjectMetadata(projectGid: projectGid, projectName: fullName, createdBy: nil, owner: nil, notes: nil, color: nil, dueDate: nil, team: nil, customFields: [:])
        let recentDocket = DocketInfo(
            number: normalizedDocket,
            jobName: normalizedJob,
            fullName: fullName,
            updatedAt: nil,
            createdAt: nil,
            metadataType: parsed.metadataType,
            subtasks: nil,
            projectMetadata: meta,
            dueDate: nil,
            taskGid: nil,
            studio: nil,
            studioColor: nil,
            completed: nil
        )
        mergeSearchedProjects([recentDocket])
        applyProducerSearchFilter(query: searchText.trimmingCharacters(in: .whitespaces))
        
        loadProjectAndSections(projectGid: projectGid, sourceDocket: recentDocket)
    }
    
    private func recordRecentProject(project: AsanaProject, sourceDocket: DocketInfo?) {
        let parsed = asanaService.parseDocketFromString(project.name)
        let sourceNumber = sourceDocket?.number.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceJob = sourceDocket?.jobName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        let number: String?
        if !sourceNumber.isEmpty, sourceNumber != "—" {
            number = sourceNumber
        } else {
            number = parsed.docket
        }
        
        let job: String?
        if !sourceJob.isEmpty {
            job = sourceJob
        } else if !parsed.jobName.isEmpty {
            job = parsed.jobName
        } else {
            job = nil
        }
        
        var s = settingsManager.currentSettings
        var recents = s.producerRecentProjects ?? []
        recents.removeAll { $0.projectGid == project.gid }
        recents.insert(
            ProducerRecentProject(
                projectGid: project.gid,
                fullName: project.name,
                docketNumber: number,
                jobName: job,
                lastOpenedAt: Date()
            ),
            at: 0
        )
        if recents.count > 25 {
            recents = Array(recents.prefix(25))
        }
        s.producerRecentProjects = recents
        settingsManager.currentSettings = s
    }
    
    private var workspaceSelectorView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose your Asana workspace")
                .font(.subheadline.weight(.medium))
            if isLoadingWorkspaces {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Loading workspaces...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let err = workspacesLoadError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                Button("Retry") { loadAsanaWorkspaces() }
                    .buttonStyle(.bordered)
            } else if asanaWorkspaces.isEmpty {
                Text("No workspaces found.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("Workspace", selection: Binding(
                    get: { settings.asanaWorkspaceID ?? "" },
                    set: { saveSelectedWorkspace($0) }
                )) {
                    Text("Select a workspace…")
                        .tag("")
                    ForEach(asanaWorkspaces) { ws in
                        Text(ws.name).tag(ws.gid)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 320)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
        .onAppear { loadAsanaWorkspaces() }
    }
    
    private func loadAsanaWorkspaces() {
        guard needsWorkspaceSelection else { return }
        isLoadingWorkspaces = true
        workspacesLoadError = nil
        Task {
            do {
                let list = try await asanaService.fetchWorkspaces()
                await MainActor.run {
                    asanaWorkspaces = list
                    isLoadingWorkspaces = false
                    if list.count == 1, let first = list.first {
                        saveSelectedWorkspace(first.gid)
                    }
                }
            } catch {
                await MainActor.run {
                    workspacesLoadError = error.localizedDescription
                    isLoadingWorkspaces = false
                }
            }
        }
    }
    
    private func saveSelectedWorkspace(_ workspaceGid: String) {
        guard !workspaceGid.isEmpty else { return }
        var s = settingsManager.currentSettings
        s.asanaWorkspaceID = workspaceGid
        settingsManager.currentSettings = s
        sessionManager.updateProfile(settings: s)
    }
    
    private func sectionListView(sections: [AsanaSection], project: AsanaProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: {
                    selectedProject = nil
                    self.sections = []
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .background(hoveredBackFromSections ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredBackFromSections = hovering
                }
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text("Select a section (e.g. POSTINGS for music briefs)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            List(sections, id: \.gid) { sec in
                let hovered = hoveredSectionGid == sec.gid
                Button {
                    selectedSection = sec
                    sectionTasks = []
                    selectedTask = nil
                    taskDetail = nil
                    loadTasksForSection(sectionID: sec.gid)
                } label: {
                    Text(sec.name ?? sec.gid)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
                .background(hovered ? Color.accentColor.opacity(0.12) : Color.clear)
                .onHover { hovering in
                    hoveredSectionGid = hovering ? sec.gid : nil
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private func taskListView(tasks: [AsanaTask], section: AsanaSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: {
                    selectedSection = nil
                    sectionTasks = []
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .background(hoveredBackFromTasks ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredBackFromTasks = hovering
                }
                Text(section.name ?? "Tasks")
                    .font(.headline)
            }
            Text("Select a task to view description and push to Airtable")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // Filter: organize by tag, assignee, or created by
            HStack(spacing: 8) {
                Picker("Filter", selection: $taskListFilterKind) {
                    ForEach(TaskListFilterKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 120)
                if taskListFilterKind != .none {
                    Picker("Value", selection: $taskListFilterValue) {
                    Text("— All —").tag("")
                    switch taskListFilterKind {
                    case .none:
                        EmptyView()
                    case .tag:
                        ForEach(sectionTaskTagNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    case .assignee:
                        ForEach(sectionTaskAssigneeNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    case .createdBy:
                        ForEach(sectionTaskCreatedByNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
            
            List(tasks, id: \.gid) { task in
                let hovered = hoveredTaskGid == task.gid
                HStack(spacing: 8) {
                    Button {
                        selectedTask = task
                        taskDetail = nil
                        loadTaskDetail(taskGid: task.gid)
                    } label: {
                        Text(task.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    // Reserve space so row doesn't resize on hover; show button with opacity
                    ZStack {
                        Button("Push") {
                            openPushSheet(for: task)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        .opacity(hovered ? 1 : 0)
                        .allowsHitTesting(hovered)
                    }
                    .frame(width: 56, height: 28)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
                .background(hovered ? Color.accentColor.opacity(0.12) : Color.clear)
                .padding(.horizontal, 4)
                .onHover { hovering in
                    hoveredTaskGid = hovering ? task.gid : nil
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $pushSheetTask) { task in
            pushConfirmSheet(task: task)
        }
    }
    
    private func openPushSheet(for task: AsanaTask) {
        loadAirtableColumnsIfNeeded()
        loadAsanaUsersIfNeeded()
        pushSheetJobName = parseJobNameFromProjectName(selectedProject?.name ?? "") ?? ""
        var checkboxes: [String: Bool] = [:]
        var values: [String: String] = [:]
        let docketNumber = selectedProject.map { parseDocketFromProjectName($0.name) } ?? ""
        let jobName = pushSheetJobName
        for col in effectiveAirtableColumns {
            checkboxes[col] = true
            let auto = autoValueForColumn(col, task: task, project: selectedProject, docketNumber: docketNumber, jobName: jobName)
            if !auto.isEmpty { values[col] = auto }
        }
        pushSheetCheckboxes = checkboxes
        pushSheetFieldValues = values
        pushSheetTask = task
    }
    
    private func pushConfirmSheet(task: AsanaTask) -> some View {
        let docketNumber = selectedProject.map { parseDocketFromProjectName($0.name) } ?? ""
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Push to Airtable")
                    .font(.headline)
                Spacer()
                Button("Cancel") { pushSheetTask = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Text("Confirm which fields to update. Row is matched by docket number.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Job name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Job name (required)", text: $pushSheetJobName)
                    .textFieldStyle(.roundedBorder)
                if pushSheetJobName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Enter the job name to push to Airtable.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sortedPushColumnNames(), id: \.self) { col in
                        dynamicPushFieldRow(
                            columnName: col,
                            task: task,
                            project: selectedProject,
                            docketNumber: docketNumber,
                            jobName: pushSheetJobName.trimmingCharacters(in: .whitespaces),
                            checked: Binding(
                                get: { pushSheetCheckboxes[col] ?? true },
                                set: { pushSheetCheckboxes[col] = $0 }
                            ),
                            value: Binding(
                                get: { pushSheetFieldValues[col] ?? "" },
                                set: { pushSheetFieldValues[col] = $0 }
                            )
                        )
                    }
                }
            }
            .frame(maxHeight: 280)
            if effectiveAirtableColumns.isEmpty {
                Text("Load columns in the main view first to choose fields.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack {
                if isPushing {
                    ProgressView().scaleEffect(0.9)
                    Text("Pushing…")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Button("Confirm Push") {
                        let jobName = pushSheetJobName.trimmingCharacters(in: .whitespaces)
                        pushToAirtable(docketNumber: docketNumber, projectTitle: jobName, task: task, checkboxesOverride: pushSheetCheckboxes, fieldValuesOverride: pushSheetFieldValues) {
                            pushSheetTask = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isConfigured || effectiveAirtableColumns.isEmpty || pushSheetJobName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Spacer()
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 320)
    }
    
    private func taskDetailView(task: AsanaTask, project: AsanaProject) -> some View {
        let docketNumber = parseDocketFromProjectName(project.name)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: {
                    selectedTask = nil
                    taskDetail = nil
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                        .background(hoveredBackFromTaskDetail ? Color.accentColor.opacity(0.12) : Color.clear)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredBackFromTaskDetail = hovering
                }
                Text(task.name)
                    .font(.headline)
            }
            .onAppear {
                jobNameForPush = parseJobNameFromProjectName(project.name) ?? ""
                loadAsanaUsersIfNeeded()
                for col in airtableColumnNames where pushColumnType(col) == "projectTitle" {
                    pushFieldValues[col] = jobNameForPush
                }
            }
            .onChange(of: jobNameForPush) { _, newJob in
                for col in airtableColumnNames where pushColumnType(col) == "projectTitle" {
                    pushFieldValues[col] = newJob
                }
            }

            // Job name (for Airtable) — parsed from project name; user can change if wrong
            VStack(alignment: .leading, spacing: 6) {
                Text("Job name")
                    .font(.subheadline.weight(.medium))
                TextField("Job name (required for Airtable)", text: $jobNameForPush)
                    .textFieldStyle(.roundedBorder)
                if jobNameForPush.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Enter the job name to push to Airtable.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            // Description (music brief)
            if let notes = task.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.subheadline.weight(.medium))
                    ScrollView {
                        Text(notes)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                    }
                    .frame(maxHeight: 200)
                }
            } else if let html = task.html_notes, !html.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(.subheadline.weight(.medium))
                    Text(html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
                        .font(.body)
                        .lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
            }
            
            // Target table and columns
            VStack(alignment: .leading, spacing: 8) {
                Text("Import to table")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isLoadingTables {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading tables…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if !airtableTables.isEmpty {
                    Picker("", selection: Binding(
                        get: { settings.airtableTableID ?? "" },
                        set: { newTableID in
                            guard !newTableID.isEmpty else { return }
                            var s = settingsManager.currentSettings
                            s.airtableTableID = newTableID
                            settingsManager.currentSettings = s
                            sessionManager.updateProfile(settings: s)
                            airtableColumnNames = []
                            columnLoadError = nil
                            loadAirtableColumnsIfNeeded()
                        }
                    )) {
                        ForEach(airtableTables) { table in
                            Text(table.name).tag(table.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } else {
                    let baseId = settings.airtableBaseID ?? "—"
                    let tableId = settings.airtableTableID ?? "—"
                    Text("Base \(baseId) · Table \(tableId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Paste a different table URL in Settings to switch table.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text("Columns in this table: \(effectiveAirtableColumns.isEmpty ? "Load columns below to see." : effectiveAirtableColumns.sorted().joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)

            // Checkboxes: all Airtable columns; auto-fill where we can, else editable; Director shows Asana users dropdown
            VStack(alignment: .leading, spacing: 10) {
                Text("Push to Airtable — select fields to update")
                    .font(.subheadline.weight(.medium))
                Text("Checked fields are written to the Airtable table. Row is matched by docket number. Type in a field to override or pick from suggestions (e.g. Director).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(sortedPushColumnNames(), id: \.self) { col in
                    dynamicPushFieldRow(
                        columnName: col,
                        task: task,
                        project: project,
                        docketNumber: docketNumber,
                        jobName: jobNameForPush.trimmingCharacters(in: .whitespaces),
                        checked: bindingForField(col),
                        value: Binding(
                            get: { pushFieldValues[col] ?? "" },
                            set: { pushFieldValues[col] = $0 }
                        )
                    )
                }
                
                if loadingColumns {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading columns…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if let err = columnLoadError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                    Button("Load columns") { loadAirtableColumnsIfNeeded() }
                        .buttonStyle(.bordered)
                } else if effectiveAirtableColumns.isEmpty {
                    Text("Load Airtable table columns to see available fields.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Load columns") { loadAirtableColumnsIfNeeded() }
                        .buttonStyle(.bordered)
                }
            }
            
            // Push button
            Button(action: {
                let jobName = jobNameForPush.trimmingCharacters(in: .whitespaces)
                pushToAirtable(
                    docketNumber: docketNumber,
                    projectTitle: jobName,
                    task: task
                )
            }) {
                HStack {
                    if isPushing {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(isPushing ? "Pushing..." : "Push to Airtable")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPushing || effectiveAirtableColumns.isEmpty || jobNameForPush.trimmingCharacters(in: .whitespaces).isEmpty)
            
            if let pushMessage = pushMessage {
                Text(pushMessage)
                    .font(.caption)
                    .foregroundColor(.green)
            }
            if let pushError = pushError {
                Text(pushError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.06))
        .cornerRadius(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    
    private func bindingForField(_ columnName: String) -> Binding<Bool> {
        Binding(
            get: { pushCheckboxes[columnName] ?? true },
            set: { pushCheckboxes[columnName] = $0 }
        )
    }

    /// One row: checkbox label, target column name, and preview of value we’ll send.
    private func pushFieldRow(label: String, columnName: String, valuePreview: String, binding: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: binding) {
                Text(label)
            }
            .toggleStyle(.checkbox)
            HStack(alignment: .top, spacing: 6) {
                Text("→ Airtable column:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(columnName)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            if !valuePreview.isEmpty {
                Text(valuePreview)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }

    /// One row per Airtable column: checkbox + value (auto or editable); Director type shows Asana users dropdown as you type.
    private func dynamicPushFieldRow(
        columnName: String,
        task: AsanaTask,
        project: AsanaProject?,
        docketNumber: String,
        jobName: String,
        checked: Binding<Bool>,
        value: Binding<String>
    ) -> some View {
        let autoValue = autoValueForColumn(columnName, task: task, project: project, docketNumber: docketNumber, jobName: jobName)
        let isDirector = pushColumnType(columnName) == "director"
        let query = value.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        let suggestions = isDirector && !query.isEmpty ? asanaUsers.filter { user in
            let name = (user.name ?? "").lowercased()
            return name.contains(query) || (user.email ?? "").lowercased().contains(query)
        }.prefix(15) : []
        let showDropdown = isDirector && focusedPushColumn == columnName && !query.isEmpty && !suggestions.isEmpty

        return VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: checked) {
                Text(columnName)
            }
            .toggleStyle(.checkbox)
            if checked.wrappedValue {
                TextField(autoValue.isEmpty ? "Enter \(columnName)…" : "", text: value)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedPushColumn, equals: columnName)
                    .onAppear {
                        if value.wrappedValue.isEmpty && !autoValue.isEmpty {
                            value.wrappedValue = autoValue
                        }
                    }
                if showDropdown {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions), id: \.gid) { user in
                            Button {
                                value.wrappedValue = user.name ?? user.email ?? ""
                                focusedPushColumn = nil
                            } label: {
                                HStack {
                                    Text(user.name ?? user.email ?? "?")
                                        .font(.caption)
                                    if let email = user.email, !email.isEmpty {
                                        Text(email)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxHeight: 180)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3), lineWidth: 1))
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }

    /// Preview of Brief value we’d push (task notes / description).
    private func briefPreviewForTask(_ task: AsanaTask) -> String {
        let text = task.notes ?? (task.html_notes?.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) ?? "")
        if text.isEmpty { return "(no description)" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }

    /// Preview of Music Type value we’d push (first Asana tag matching configured Music Type tags).
    private func musicTypePreviewForTask(_ task: AsanaTask) -> String {
        let tagNames = musicTypeTagNamesFromSettings()
        guard let tags = task.tags, !tags.isEmpty else { return "(no tags on this task)" }
        let match = tags.first { tag in
            guard let name = tag.name, !name.isEmpty else { return false }
            return tagNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard let tag = match, let name = tag.name, !name.isEmpty else {
            return "(no Music Type tag; expected one of: \(tagNames.joined(separator: ", ")))"
        }
        return name
    }

    /// Configured Music Type tag names (from Settings → Advanced, or default "Original Music", "Stock Music", "Licensed Music").
    private func musicTypeTagNamesFromSettings() -> [String] {
        let raw = settings.airtableMusicTypeTags ?? "Original Music, Stock Music, Licensed Music"
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var configurationRequired: some View {
        producerQuickSetup
    }

    // MARK: - Producer Quick Setup (one-click style)

    private var producerQuickSetup: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Get started in two steps")
                    .font(.title2.weight(.semibold))
                Text("Connect Asana and Airtable—like signing in with Google.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Step 1: Asana
            quickSetupStep(number: 1, done: SharedKeychainService.getAsanaAccessToken() != nil) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Asana")
                        .font(.subheadline.weight(.medium))
                    if SharedKeychainService.getAsanaAccessToken() != nil {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Connected").font(.subheadline).foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: connectToAsana) {
                            HStack {
                                if isConnectingAsana { ProgressView().scaleEffect(0.8) }
                                else { Image(systemName: "link") }
                                Text(isConnectingAsana ? "Connecting…" : "Connect to Asana")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isConnectingAsana || !OAuthConfig.isAsanaConfigured)
                        if let err = asanaConnectionError {
                            Text(err).font(.caption).foregroundColor(.red)
                        }
                    }
                }
            }

            // Step 2: Airtable
            quickSetupStep(number: 2, done: isAirtableConfiguredForQuickSetup) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Airtable")
                        .font(.subheadline.weight(.medium))
                    if isAirtableConfiguredForQuickSetup {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("Connected").font(.subheadline).foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: openAirtableTokenPage) {
                            HStack { Image(systemName: "safari"); Text("Open Airtable to get your token") }
                        }
                        .buttonStyle(.bordered)
                        SecureField("Paste your Airtable token here", text: $airtableTokenInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save token") {
                            saveAirtableTokenFromQuickSetup()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(airtableTokenInput.isEmpty)
                        Text("Paste your Airtable table URL to fill Base & Table ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("https://airtable.com/app.../tbl...", text: $airtableURLInput)
                                .textFieldStyle(.roundedBorder)
                            Button("Fill") { applyAirtableURLInQuickSetup() }
                                .buttonStyle(.bordered)
                                .disabled(airtableURLInput.isEmpty)
                        }
                    }
                }
            }

            Button("Open full Settings") {
                Foundation.NotificationCenter.default.post(name: Foundation.Notification.Name("OpenSettings"), object: nil)
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(16)
        .sheet(isPresented: $showManualCodeEntry) {
            manualCodeSheet
        }
    }

    private func quickSetupStep<Content: View>(number: Int, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(done ? Color.green : Color.orange).frame(width: 32, height: 32)
                Text("\(number)").font(.system(size: 16, weight: .bold)).foregroundColor(.white)
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(12)
    }

    private var manualCodeSheet: some View {
        VStack(spacing: 20) {
            Text("Paste the code from Asana")
                .font(.headline)
            if let url = manualAuthURL {
                Text("If a browser didn’t open, go to:")
                    .font(.caption)
                Text(url.absoluteString)
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            TextField("Paste code here", text: $manualAuthCode)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button("Cancel") {
                    showManualCodeEntry = false
                    manualAuthCode = ""
                }
                .buttonStyle(.bordered)
                Button("Continue") { submitManualAsanaCode() }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualAuthCode.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var isAirtableConfiguredForQuickSetup: Bool {
        let hasKey = SharedKeychainService.getAirtableAPIKey() != nil && !(SharedKeychainService.getAirtableAPIKey() ?? "").isEmpty
        let hasBase = (settings.airtableBaseID ?? "").isEmpty == false
        let hasTable = (settings.airtableTableID ?? "").isEmpty == false
        return hasKey && hasBase && hasTable
    }

    private func connectToAsana() {
        guard OAuthConfig.isAsanaConfigured else {
            asanaConnectionError = "Asana OAuth is not configured for this app."
            return
        }
        isConnectingAsana = true
        asanaConnectionError = nil
        Task {
            do {
                let token = try await oauthService.authenticateAsana(useOutOfBand: false)
                oauthService.storeTokens(accessToken: token.accessToken, refreshToken: token.refreshToken, for: "asana")
                await MainActor.run {
                    isConnectingAsana = false
                }
            } catch OAuthError.manualCodeRequired(_, let authURL) {
                await MainActor.run {
                    isConnectingAsana = false
                    manualAuthURL = authURL
                    showManualCodeEntry = true
                    NSWorkspace.shared.open(authURL)
                }
            } catch {
                await MainActor.run {
                    isConnectingAsana = false
                    asanaConnectionError = error.localizedDescription
                }
            }
        }
    }

    private func submitManualAsanaCode() {
        guard !manualAuthCode.isEmpty else { return }
        isConnectingAsana = true
        Task {
            do {
                let token = try await oauthService.exchangeCodeForTokenManually(code: manualAuthCode.trimmingCharacters(in: .whitespaces))
                oauthService.storeTokens(accessToken: token.accessToken, refreshToken: token.refreshToken, for: "asana")
                await MainActor.run {
                    isConnectingAsana = false
                    showManualCodeEntry = false
                    manualAuthCode = ""
                }
            } catch {
                await MainActor.run {
                    isConnectingAsana = false
                    asanaConnectionError = error.localizedDescription
                }
            }
        }
    }

    private func openAirtableTokenPage() {
        if let url = URL(string: "https://airtable.com/create/tokens") {
            NSWorkspace.shared.open(url)
        }
    }

    private func saveAirtableTokenFromQuickSetup() {
        guard !airtableTokenInput.isEmpty else { return }
        _ = KeychainService.store(key: "airtable_api_key", value: airtableTokenInput)
        if SharedKeychainService.isCurrentUserGraysonEmployee() {
            _ = SharedKeychainService.setSharedKey(airtableTokenInput, for: .airtableAPIKey)
        }
        airtableTokenInput = ""
    }

    private func applyAirtableURLInQuickSetup() {
        let (baseID, tableID) = AirtableURLParser.parse(airtableURLInput)
        var s = settingsManager.currentSettings
        if let b = baseID { s.airtableBaseID = b }
        if let t = tableID { s.airtableTableID = t }
        settingsManager.currentSettings = s
        sessionManager.updateProfile(settings: s)
    }
    
    // MARK: - Helpers
    
    private var isConfigured: Bool {
        SharedKeychainService.getAsanaAccessToken() != nil
            && settings.airtableBaseID != nil
            && !(settings.airtableBaseID ?? "").isEmpty
            && settings.airtableTableID != nil
            && !(settings.airtableTableID ?? "").isEmpty
            && SharedKeychainService.getAirtableAPIKey() != nil
    }
    
    /// Load dockets from shared cache (same as media team) so search is instant when cache is available
    private func tryLoadDocketsFromCache() {
        guard isConfigured else { return }
        let cached = asanaCacheManager.loadCachedDockets()
        if !cached.isEmpty {
            allDockets = cached
            applyProducerSearchFilter(query: searchText.trimmingCharacters(in: .whitespaces))
        }
    }
    
    /// Search producer projects with targeted Asana queries (no workspace-wide docket sync).
    private func runSearch(forceRefreshRecent: Bool = false) {
        guard let workspaceID = settings.asanaWorkspaceID, !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchError = "Set Asana workspace in Settings."
            return
        }
        searchError = nil
        statusMessage = nil
        docketsLoadError = nil
        // Clear selection so we show docket list again
        selectedProject = nil
        selectedSection = nil
        sectionTasks = []
        selectedTask = nil
        taskDetail = nil
        
        let query = searchText.trimmingCharacters(in: .whitespaces)
        
        // Use the same shared cache as the media team view.
        if allDockets.isEmpty {
            tryLoadDocketsFromCache()
        }
        
        // Apply sort and filter to cache (Creation Time or Last Modified, same data source as media team).
        applyProducerSearchFilter(query: query)
        
        if query.isEmpty {
            if forceRefreshRecent {
                applyProducerSearchFilter(query: query)
            }
            isSearching = false
            isLoadingDockets = false
            isInSearchResultsMode = false
            return
        }
        
        // Explicit search: run Asana project search and merge into local list.
        isInSearchResultsMode = true
        isSearching = true
        isLoadingDockets = true
        statusMessage = "Searching Asana for \"\(query)\"..."
        Task {
            do {
                let projects = try await asanaService.searchProjects(workspaceID: workspaceID, query: query, maxResults: 50)
                let incomingDockets = projects.map { docketInfo(from: $0) }
                await MainActor.run {
                    mergeSearchedProjects(incomingDockets)
                    isLoadingDockets = false
                    isSearching = false
                    statusMessage = nil
                    applyProducerSearchFilter(query: searchText.trimmingCharacters(in: .whitespaces))
                }
            } catch {
                await MainActor.run {
                    docketsLoadError = error.localizedDescription
                    isLoadingDockets = false
                    isSearching = false
                    statusMessage = nil
                }
            }
        }
    }
    
    /// Load initial producer list from the same cache as the media team view.
    private func loadInitialRecentProjectsIfNeeded() {
        guard !didLoadInitialProjects else { return }
        guard isConfigured, !needsWorkspaceSelection else { return }
        didLoadInitialProjects = true
        tryLoadDocketsFromCache()
        applyProducerSearchFilter(query: searchText.trimmingCharacters(in: .whitespaces))
    }
    
    private func docketInfo(from project: AsanaProject) -> DocketInfo {
        let parsed = asanaService.parseDocketFromString(project.name)
        let projectMetadata = asanaService.createProjectMetadata(from: project)
        return DocketInfo(
            number: parsed.docket ?? "—",
            jobName: parsed.jobName,
            fullName: project.name,
            updatedAt: parseAsanaTimestamp(project.modified_at),
            createdAt: parseAsanaTimestamp(project.created_at),
            metadataType: parsed.metadataType,
            subtasks: nil,
            projectMetadata: projectMetadata,
            dueDate: project.due_date,
            taskGid: nil,
            studio: nil,
            studioColor: nil,
            completed: nil
        )
    }
    
    private func mergeSearchedProjects(_ incoming: [DocketInfo]) {
        for docket in incoming {
            if let idx = allDockets.firstIndex(where: { $0.fullName == docket.fullName }) {
                allDockets[idx] = mergeDockets(existing: allDockets[idx], incoming: docket)
            } else {
                allDockets.append(docket)
            }
        }
    }
    
    private func mergeDockets(existing: DocketInfo, incoming: DocketInfo) -> DocketInfo {
        let existingNumber = existing.number.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedNumber = (existingNumber.isEmpty || existingNumber == "—") ? incoming.number : existing.number
        let resolvedUpdatedAt = latestDate(existing.updatedAt, incoming.updatedAt)
        
        return DocketInfo(
            id: existing.id,
            number: resolvedNumber,
            jobName: existing.jobName.isEmpty ? incoming.jobName : existing.jobName,
            fullName: existing.fullName,
            updatedAt: resolvedUpdatedAt,
            createdAt: existing.createdAt ?? incoming.createdAt,
            metadataType: existing.metadataType ?? incoming.metadataType,
            subtasks: existing.subtasks ?? incoming.subtasks,
            projectMetadata: existing.projectMetadata ?? incoming.projectMetadata,
            dueDate: existing.dueDate ?? incoming.dueDate,
            taskGid: existing.taskGid ?? incoming.taskGid,
            studio: existing.studio ?? incoming.studio,
            studioColor: existing.studioColor ?? incoming.studioColor,
            completed: existing.completed ?? incoming.completed
        )
    }
    
    private func latestDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (.some(left), .some(right)):
            return max(left, right)
        case let (.some(left), .none):
            return left
        case let (.none, .some(right)):
            return right
        case (.none, .none):
            return nil
        }
    }
    
    private func handleProjectSortModeChange() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // When switching to Creation Time with empty search, fetch from API so the list matches Asana's "Browse projects" by creation time.
        if projectSortMode == .creationTime && query.isEmpty {
            runSearch(forceRefreshRecent: true)
            return
        }
        // Otherwise re‑apply filter/sort on the existing data (Last Modified or search results).
        applyProducerSearchFilter(query: query)
    }
    
    /// Go back from search results to the initial recent projects browse view.
    private func goBackToBrowse() {
        searchText = ""
        searchError = nil
        statusMessage = nil
        isSearching = false
        isLoadingDockets = false
        isInSearchResultsMode = false
        selectedProject = nil
        selectedSection = nil
        sectionTasks = []
        selectedTask = nil
        taskDetail = nil
        applyProducerSearchFilter(query: "")
    }
    
    private func parseAsanaTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) {
            return parsed
        }
        
        // Fallback without fractional seconds
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        if let parsed = fallback.date(from: value) {
            return parsed
        }
        
        // Last resort: try basic date parsing
        let basicFormatter = DateFormatter()
        basicFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return basicFormatter.date(from: value)
    }
    
    /// Filter and sort dockets for producer search/default list.
    private func applyProducerSearchFilter(query: String) {
        // Filtering and sorting may iterate over hundreds or thousands of
        // items; do the work off the main actor so the UI stays responsive.
        // Capture necessary state locally so the coroutine doesn't race with
        // future mutations.
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortMode = projectSortMode
        let all = allDockets

        Task.detached(priority: .userInitiated) {
            let searchLower = q.lowercased()
            let result: [DocketInfo]

            if searchLower.isEmpty {
                result = Array(all.sorted(by: { ProducerView.producerDocketSort($0, $1, sortMode: sortMode) }).prefix(10))
            } else {
                let isNumericQuery = q.allSatisfy { $0.isNumber }
                let matched = all.filter { docket in
                    // compute lowercase once per docket
                    let full = docket.fullName.lowercased()
                    let num = docket.number.lowercased()
                    let job = docket.jobName.lowercased()

                    if isNumericQuery {
                        return full.contains(searchLower) ||
                            num.hasPrefix(searchLower) ||
                            job.contains(searchLower)
                    } else {
                        return full.contains(searchLower) ||
                            num.contains(searchLower) ||
                            job.contains(searchLower)
                    }
                }
                result = matched.sorted(by: { ProducerView.producerDocketSort($0, $1, sortMode: sortMode) })
            }

            await MainActor.run {
                self.filteredDockets = result
            }
        }
    }
    
    /// Comparison routine that can be invoked off the main actor by
    /// passing in an explicit sort mode.  The original method always read
    /// `projectSortMode` which forced callers to hop back to the main actor
    /// before sorting; the new variant lets the background task cache the
    /// sorting parameter up front.
    // Sorting routine is stateless and may be called from background tasks,
    // so make it a static, nonisolated helper to avoid actor hops.
    private nonisolated static func producerDocketSort(_ d1: DocketInfo, _ d2: DocketInfo, sortMode: ProducerProjectSortMode) -> Bool {
        let date1: Date
        let date2: Date
        switch sortMode {
        case .lastModified:
            date1 = d1.updatedAt ?? d1.createdAt ?? .distantPast
            date2 = d2.updatedAt ?? d2.createdAt ?? .distantPast
        case .creationTime:
            date1 = d1.createdAt ?? d1.updatedAt ?? .distantPast
            date2 = d2.createdAt ?? d2.updatedAt ?? .distantPast
        }
        if date1 != date2 { return date1 > date2 }
        
        if let n1 = Int(d1.number.filter { $0.isNumber }),
           let n2 = Int(d2.number.filter { $0.isNumber }) {
            if n1 == n2 { return d1.jobName < d2.jobName }
            return n1 > n2
        }
        if d1.number != d2.number { return d1.number > d2.number }
        return d1.fullName.localizedCaseInsensitiveCompare(d2.fullName) == .orderedAscending
    }
    
    /// Task list filtered by current filter (tag, assignee, created by)
    private var filteredSectionTasks: [AsanaTask] {
        let value = taskListFilterValue.trimmingCharacters(in: .whitespaces)
        switch taskListFilterKind {
        case .none:
            return sectionTasks
        case .tag:
            guard !value.isEmpty else { return sectionTasks }
            return sectionTasks.filter { task in
                task.tags?.contains { ($0.name ?? "").caseInsensitiveCompare(value) == .orderedSame } ?? false
            }
        case .assignee:
            guard !value.isEmpty else { return sectionTasks }
            return sectionTasks.filter { ($0.assignee?.name ?? "").caseInsensitiveCompare(value) == .orderedSame }
        case .createdBy:
            guard !value.isEmpty else { return sectionTasks }
            return sectionTasks.filter { ($0.created_by?.name ?? "").caseInsensitiveCompare(value) == .orderedSame }
        }
    }
    
    /// Unique tag names from current section tasks (for filter dropdown)
    private var sectionTaskTagNames: [String] {
        var names = Set<String>()
        for task in sectionTasks {
            task.tags?.forEach { if let n = $0.name, !n.isEmpty { names.insert(n) } }
        }
        return names.sorted()
    }
    
    /// Unique assignee names from current section tasks
    private var sectionTaskAssigneeNames: [String] {
        var names = Set<String>()
        for task in sectionTasks {
            if let n = task.assignee?.name, !n.isEmpty { names.insert(n) }
        }
        return names.sorted()
    }
    
    /// Unique created-by names from current section tasks
    private var sectionTaskCreatedByNames: [String] {
        var names = Set<String>()
        for task in sectionTasks {
            if let n = task.created_by?.name, !n.isEmpty { names.insert(n) }
        }
        return names.sorted()
    }
    
    private func loadSections(projectID: String) {
        Task {
            do {
                let list = try await asanaService.fetchSections(projectID: projectID)
                await MainActor.run { sections = list }
            } catch {
                await MainActor.run { searchError = error.localizedDescription }
            }
        }
    }
    
    private func loadTasksForSection(sectionID: String) {
        Task {
            do {
                let list = try await asanaService.fetchTasksForSection(sectionID: sectionID)
                await MainActor.run { sectionTasks = list }
            } catch {
                await MainActor.run { searchError = error.localizedDescription }
            }
        }
    }
    
    private func loadTaskDetail(taskGid: String) {
        isLoadingTaskDetail = true
        Task {
            do {
                let task = try await asanaService.fetchTask(taskGid: taskGid)
                await MainActor.run {
                    taskDetail = task
                    pushMessage = nil
                    pushError = nil
                    pushCheckboxes = [:]
                    pushFieldValues = [:]
                    isLoadingTaskDetail = false
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                    isLoadingTaskDetail = false
                }
            }
        }
    }
    
    private func loadAirtableTablesIfNeeded() {
        guard let baseID = settings.airtableBaseID, !baseID.isEmpty else { return }
        isLoadingTables = true
        Task {
            let tables = await airtableService.fetchTablesInBase(baseID: baseID)
            await MainActor.run {
                airtableTables = tables
                isLoadingTables = false
            }
        }
    }

    private func loadAirtableColumnsIfNeeded() {
        guard isConfigured,
              let baseID = settings.airtableBaseID, !baseID.isEmpty,
              let tableID = settings.airtableTableID, !tableID.isEmpty else {
            columnLoadError = "Set Airtable Base ID and Table ID in Settings first."
            return
        }
        columnLoadError = nil
        loadingColumns = true
        Task {
            // Prefer Meta API schema so we get exact Airtable column names for every field (including empty columns).
            // Fall back to record-derived names if Meta scope isn’t available.
            var names = await airtableService.fetchTableFieldNamesFromMeta(baseID: baseID, tableID: tableID)
            if names.isEmpty {
                do {
                    names = try await airtableService.fetchTableFieldNames(baseID: baseID, tableID: tableID)
                } catch {
                    await MainActor.run {
                        airtableColumnNames = configuredAirtableColumns()
                        loadingColumns = false
                        columnLoadError = error.localizedDescription
                    }
                    return
                }
            }
            await MainActor.run {
                airtableColumnNames = mergeAirtableColumns(discovered: names)
                loadingColumns = false
                if airtableColumnNames.isEmpty {
                    columnLoadError = "No columns found. Check that the table has records and the Base/Table IDs are correct."
                }
            }
        }
    }

    private func loadAsanaUsersIfNeeded() {
        guard let workspaceID = settings.asanaWorkspaceID, !workspaceID.isEmpty else { return }
        Task {
            do {
                let users = try await asanaService.fetchWorkspaceUsers(workspaceID: workspaceID)
                await MainActor.run {
                    asanaUsers = users
                    asanaUsersLoadError = nil
                }
            } catch {
                await MainActor.run {
                    asanaUsers = []
                    asanaUsersLoadError = error.localizedDescription
                }
            }
        }
    }
    
    /// Parse docket from project name (e.g. "BET 365... - 26042-US (VML)" -> "26042-US")
    private func parseDocketFromProjectName(_ name: String) -> String {
        let pattern = #"\b(\d{5}(?:-[A-Z]{1,3})?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else {
            return name
        }
        return String(name[range])
    }

    /// Preferred order for push-to-Airtable fields (top to bottom). Docket Prefix and Source Docket are last (manual-only).
    private static let pushColumnDisplayOrder: [String] = [
        "Docket", "Project Title", "Client", "Brand", "Agency",
        "Director", "Music Supervisor", "Brief", "Music",
        "Docket Prefix", "Source Docket"
    ]

    private func sortedPushColumnNames() -> [String] {
        let order = Self.pushColumnDisplayOrder
        // Use longest matching order entry so "Docket Prefix 26?" matches "Docket Prefix" not "Docket", and "Source Docket" matches "Source Docket" not "Docket".
        func orderIndex(for name: String) -> Int {
            let lower = name.lowercased()
            let matches = order.enumerated().filter { idx, entry in
                let e = entry.lowercased()
                return lower.contains(e) || e.contains(lower)
            }
            guard let best = matches.max(by: { $0.element.count < $1.element.count }) else { return order.count }
            return best.offset
        }
        return effectiveAirtableColumns.sorted { a, b in
            let aIndex = orderIndex(for: a)
            let bIndex = orderIndex(for: b)
            if aIndex != bIndex { return aIndex < bIndex }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Infer column "type" from Airtable column name for auto-fill and dropdown behavior.
    private func pushColumnType(_ columnName: String) -> String {
        let lower = columnName.lowercased()
        if lower.contains("brief") || lower.contains("description") { return "brief" }
        // Music Type: column named "Music", "Music...", "Music Type" etc. (but not "Music Supervisor")
        if lower.contains("music") && !lower.contains("supervisor") { return "musicType" }
        // Manual-only: Source Docket and Docket Prefix (check before generic "docket")
        if lower.contains("source") && lower.contains("docket") { return "sourceDocket" }
        if lower.contains("prefix") && lower.contains("docket") { return "docketPrefix" }
        if lower.contains("docket") { return "docket" }
        // Project Title / Job: autopopulate with job name (parsed from project name)
        if lower.contains("project") || lower.contains("job") { return "projectTitle" }
        if lower.contains("director") { return "director" }
        return "other"
    }

    /// Auto-filled value for a column (task, project, docket number, job name context). Empty string if none.
    /// Source Docket and Docket Prefix are manual-only (no auto-fill).
    private func autoValueForColumn(_ columnName: String, task: AsanaTask, project: AsanaProject?, docketNumber: String, jobName: String) -> String {
        switch pushColumnType(columnName) {
        case "brief":
            return task.notes ?? (task.html_notes?.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) ?? "")
        case "musicType":
            let tagNamesRaw = settings.airtableMusicTypeTags ?? "Original Music, Stock Music, Licensed Music"
            let tagNames = tagNamesRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return task.tags?.first { tag in
                guard let name = tag.name, !name.isEmpty else { return false }
                return tagNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }?.name ?? ""
        case "docket":
            return docketNumber
        case "projectTitle":
            return jobName
        case "director":
            return task.assignee?.name ?? ""
        case "sourceDocket", "docketPrefix":
            return "" // Manual-only; do not auto-fill
        default:
            return ""
        }
    }

    /// Job name = everything before " - {docketNumber}" or " - {docketNumber}-US" (e.g. "KPMG Make the First Move - 26048 (Grey) - CM" -> "KPMG Make the First Move"). Returns nil if pattern not found.
    private func parseJobNameFromProjectName(_ name: String) -> String? {
        let pattern = #" \-\s*(\d{5}(?:-[A-Z]{1,3})?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let prefixRange = Range(NSRange(location: 0, length: match.range(at: 0).location), in: name) else {
            return nil
        }
        let job = String(name[prefixRange]).trimmingCharacters(in: .whitespaces)
        return job.isEmpty ? nil : job
    }
    
    private func pushToAirtable(docketNumber: String, projectTitle: String, task: AsanaTask, checkboxesOverride: [String: Bool]? = nil, fieldValuesOverride: [String: String]? = nil, onComplete: (() -> Void)? = nil) {
        guard isConfigured,
              let baseID = settings.airtableBaseID, !baseID.isEmpty,
              let tableID = settings.airtableTableID, !tableID.isEmpty else { return }
        
        var docketCol = settings.airtableDocketNumberField
        if docketCol == "Docket Number" {
            docketCol = "Docket"
            var s = settingsManager.currentSettings
            s.airtableDocketNumberField = "Docket"
            settingsManager.currentSettings = s
        }
        var titleCol = settings.airtableProjectTitleField ?? settings.airtableJobNameField
        if titleCol == "Job Name" {
            titleCol = "Project Title"
            var s = settingsManager.currentSettings
            s.airtableJobNameField = "Project Title"
            settingsManager.currentSettings = s
        }
        let checkboxes = checkboxesOverride ?? pushCheckboxes
        let fieldValues = fieldValuesOverride ?? pushFieldValues
        let project = selectedProject
        let columnsToPush = effectiveAirtableColumns
        
        if columnsToPush.isEmpty {
            pushError = "Load Airtable columns first so MediaDash knows which fields to write."
            onComplete?()
            return
        }
        
        var fieldsToPush: [String: Any] = [:]
        for col in columnsToPush {
            // UI defaults each checkbox to checked when there is no explicit value yet.
            // Treat missing entries as checked so displayed state matches push behavior.
            guard checkboxes[col] ?? true else { continue }
            var val = fieldValues[col]?.trimmingCharacters(in: .whitespaces) ?? ""
            if val.isEmpty {
                val = autoValueForColumn(col, task: task, project: project, docketNumber: docketNumber, jobName: projectTitle)
            }
            if !val.isEmpty { fieldsToPush[col] = val }
        }
        
        isPushing = true
        pushMessage = nil
        pushError = nil
        
        Task {
            do {
                let result = try await airtableService.pushSelectedFields(
                    baseID: baseID,
                    tableID: tableID,
                    docketNumber: docketNumber,
                    projectTitle: projectTitle,
                    fieldsToPush: fieldsToPush,
                    docketNumberField: docketCol,
                    projectTitleField: titleCol,
                    existingColumnNames: columnsToPush
                )
                await MainActor.run {
                    isPushing = false
                    pushMessage = result == "created" ? "Created new row in Airtable." : "Updated existing row in Airtable."
                    onComplete?()
                }
            } catch {
                await MainActor.run {
                    isPushing = false
                    pushError = error.localizedDescription
                    onComplete?()
                }
            }
        }
    }
    
    private func configuredAirtableColumns() -> [String] {
        let configured: [String] = [
            settings.airtableDocketNumberField,
            settings.airtableProjectTitleField,
            settings.airtableJobNameField,
            settings.airtableFullNameField,
            settings.airtableDueDateField,
            settings.airtableClientField,
            settings.airtableProducerField,
            settings.airtableStudioField,
            settings.airtableCompletedField,
            settings.airtableLastUpdatedField,
            settings.airtableBriefField,
            settings.airtableMusicTypeField
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let uniqueConfigured = Set<String>(configured)
        return uniqueConfigured.sorted { a, b in
            a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }
    
    private func mergeAirtableColumns(discovered: [String]) -> [String] {
        let discoveredClean = discovered
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let merged = Set(discoveredClean).union(configuredAirtableColumns())
        return Array(merged).sorted { a, b in
            a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

#Preview {
    ProducerView()
        .environmentObject(SettingsManager())
        .environmentObject(SessionManager())
        .environmentObject(AsanaCacheManager())
}
