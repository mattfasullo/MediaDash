import SwiftUI
import AppKit

struct SimianArchiverView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var settingsManager: SettingsManager
    @StateObject private var simianService = SimianService()
    @StateObject private var archiveManager = SimianArchiveManager()
    
    @State private var projects: [SimianProject] = []
    @State private var projectInfos: [String: SimianProjectInfo] = [:]
    @State private var selectedProjectIds: Set<String> = []
    @State private var isLoading = false
    @State private var loadProgress: Double = 0
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var dateField: SimianProjectDateField = .lastAccess
    @State private var fromDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate: Date = Date()
    @State private var loadTask: Task<Void, Never>?
    
    /// Debounced search so filtering doesn’t run on every keystroke (avoids hangs).
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    
    /// Cached filtered list; computed off main thread so UI stays responsive.
    @State private var displayedProjects: [SimianProject] = []
    @State private var displayRefreshTask: Task<Void, Never>?
    
    // GM archives comparison
    @State private var archivedProjectIds: Set<String> = []
    @State private var archiveLocations: [String: URL] = [:] // projectId -> folder containing the zip
    @State private var isScanningArchives = false
    @State private var archiveScanError: String?
    @State private var archiveFilter: ArchiveFilter = .all
    /// Project IDs in the current download run (downloading + in queue). Cleared when run ends.
    @State private var projectsInCurrentRun: Set<String> = []
    
    /// When non-nil, user must confirm whether to include projects with unclear docket numbers (e.g. 24xxx, 25XXX).
    @State private var ambiguousDocketConfirmation: AmbiguousDocketContext?
    
    /// Delete from Simian: only available for archived projects; requires typing "DELETE". Can be multiple when multiple are selected.
    @State private var projectsToDelete: IdentifiableProjects?
    @State private var deleteProjectError: String?
    @State private var isDeletingFromSimian = false
    /// When non-nil, (completedCount, totalCount) for progress text e.g. "Deleting 2 of 5…"
    @State private var deletionProgress: (Int, Int)?
    
    private struct IdentifiableProjects: Identifiable {
        let id = UUID()
        let projects: [SimianProject]
    }

    /// Context for confirming archive when some projects have unclear docket numbers.
    private struct AmbiguousDocketContext: Identifiable {
        let id = UUID()
        let allProjects: [SimianProject]
        let flaggedProjects: [SimianProject]
    }
    
    private enum ArchiveFilter: String, CaseIterable {
        case all = "All"
        case notArchived = "Not archived"
        case archived = "Archived"
        case queue = "Queue"
    }
    
    /// List to show in the table (Queue filter applied in view; others from displayedProjects).
    private var listProjectsForDisplay: [SimianProject] {
        if archiveFilter == .queue {
            return displayedProjects.filter { projectsInCurrentRun.contains($0.id) }
        }
        return displayedProjects
    }

    private var downloadProjects: [SimianProject] {
        if selectedProjectIds.isEmpty {
            return listProjectsForDisplay
        }
        return listProjectsForDisplay.filter { selectedProjectIds.contains($0.id) }
    }

    /// Total size of projects that would be downloaded (selected, or all in range if none selected). Nil if no sizes known.
    private var totalDownloadSizeBytes: Int64? {
        let projs = downloadProjects
        guard !projs.isEmpty else { return nil }
        let total = projs.reduce(Int64(0)) { sum, project in
            sum + (projectInfos[project.id]?.projectSizeBytes ?? 0)
        }
        return total > 0 ? total : nil
    }
    
    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                header
                
                filterControls
                
                projectList
                
                footer
            }
            .padding(20)
            .frame(minWidth: 820, minHeight: 640)
            .disabled(isLoading)
            
            if isLoading {
                loadingOverlay
            }
        }
        .onAppear {
            updateSimianServiceConfiguration()
            loadProjects()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
        .onChange(of: settingsManager.currentSettings.simianAPIBaseURL) { _, _ in
            updateSimianServiceConfiguration()
        }
        .onChange(of: dateField) { _, _ in
            pruneSelection()
        }
        .onChange(of: fromDate) { _, _ in
            pruneSelection()
        }
        .onChange(of: toDate) { _, _ in
            pruneSelection()
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run { debouncedSearchText = newValue }
            }
            pruneSelection()
        }
        .onChange(of: debouncedSearchText) { _, _ in refreshDisplayedProjects() }
        .onChange(of: fromDate) { _, _ in refreshDisplayedProjects() }
        .onChange(of: toDate) { _, _ in refreshDisplayedProjects() }
        .onChange(of: dateField) { _, _ in refreshDisplayedProjects() }
        .onChange(of: archiveFilter) { _, _ in refreshDisplayedProjects() }
        .onChange(of: archivedProjectIds) { _, _ in refreshDisplayedProjects() }
        .onChange(of: archiveManager.isRunning) { _, isRunning in
            if !isRunning {
                projectsInCurrentRun = []
            }
        }
        // Don’t refresh on every projects/projectInfos change during load; we refresh once when load completes.
        .sheet(item: $ambiguousDocketConfirmation) { context in
            AmbiguousDocketSheet(
                flaggedProjects: context.flaggedProjects,
                onIncludeAll: {
                    ambiguousDocketConfirmation = nil
                    startArchive(with: context.allProjects)
                },
                onExcludeFlagged: {
                    let flaggedIds = Set(context.flaggedProjects.map(\.id))
                    let rest = context.allProjects.filter { !flaggedIds.contains($0.id) }
                    ambiguousDocketConfirmation = nil
                    if !rest.isEmpty { startArchive(with: rest) }
                },
                onCancel: {
                    ambiguousDocketConfirmation = nil
                }
            )
            .compactSheetContent()
            .sheetBorder()
        }
        .sheet(item: $projectsToDelete) { item in
            DeleteProjectConfirmationSheet(
                projects: item.projects,
                errorMessage: $deleteProjectError,
                isDeleting: isDeletingFromSimian,
                deletionProgress: deletionProgress,
                onConfirm: {
                    confirmDeleteProjects(item.projects)
                },
                onCancel: {
                    if !isDeletingFromSimian {
                        projectsToDelete = nil
                        deleteProjectError = nil
                    }
                }
            )
            .compactSheetContent()
            .sheetBorder()
        }
    }
    
    private func confirmDeleteProjects(_ projectsToDeleteList: [SimianProject]) {
        deleteProjectError = nil
        isDeletingFromSimian = true
        deletionProgress = (0, projectsToDeleteList.count)
        Task {
            var failed = false
            let total = projectsToDeleteList.count
            for (index, project) in projectsToDeleteList.enumerated() {
                do {
                    try await simianService.deleteProject(projectId: project.id)
                    await MainActor.run {
                        deletionProgress = (index + 1, total)
                    }
                } catch {
                    await MainActor.run {
                        deleteProjectError = error.localizedDescription
                        isDeletingFromSimian = false
                        deletionProgress = nil
                    }
                    failed = true
                    break
                }
            }
            if !failed {
                let idsToRemove = Set(projectsToDeleteList.map(\.id))
                await MainActor.run {
                    projects.removeAll { idsToRemove.contains($0.id) }
                    idsToRemove.forEach { projectInfos.removeValue(forKey: $0) }
                    selectedProjectIds.subtract(idsToRemove)
                    archivedProjectIds.subtract(idsToRemove)
                    projectsToDelete = nil
                    isDeletingFromSimian = false
                    deletionProgress = nil
                }
            }
        }
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Simian Archiver")
                    .font(.title2.weight(.semibold))
                Text("Select a date range and download project contents as ZIP folders.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Close") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
        }
    }
    
    private var filterControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("Sort By", selection: $dateField) {
                    ForEach(SimianProjectDateField.allCases) { field in
                        Text(field.label).tag(field)
                    }
                }
                .frame(width: 180)
                
                DatePicker("From", selection: $fromDate, displayedComponents: [.date])
                DatePicker("To", selection: $toDate, displayedComponents: [.date])
                
                Spacer()
                
                Button("Refresh Projects") {
                    loadProjects()
                }
                .disabled(isLoading || archiveManager.isRunning)
            }
            
            HStack {
                TextField("Search projects", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                
                Spacer()
                
                if isLoading {
                    ProgressView(value: loadProgress)
                        .frame(width: 140)
                }
            }
            
            // Compare with GM DATA BACKUPS
            HStack(spacing: 12) {
                Text("GM archives:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button("Scan DATA BACKUPS") {
                    scanGMArchives()
                }
                .disabled(isScanningArchives || archiveManager.isRunning)
                if isScanningArchives {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Scanning…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !archivedProjectIds.isEmpty {
                    Text("\(archivedProjectIds.count) projects found in GM DATA BACKUPS")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Picker("Show", selection: $archiveFilter) {
                    ForEach(ArchiveFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .frame(width: 120)
                Spacer()
            }
            if let archiveScanError = archiveScanError {
                Text(archiveScanError)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if !simianService.isConfigured {
                Text("Simian is not configured. Add your credentials in Settings to enable archiving.")
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text("Loading Simian projects…")
                    .font(.headline)
                ProgressView(value: loadProgress)
                    .frame(width: 240)
                Text("\(Int(loadProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(20)
            .background(.thinMaterial)
            .cornerRadius(12)
        }
        .transition(.opacity)
    }
    
    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects in range: \(listProjectsForDisplay.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Select All") {
                    selectedProjectIds = Set(listProjectsForDisplay.map(\.id))
                }
                .disabled(listProjectsForDisplay.isEmpty)
                
                Button("Clear") {
                    selectedProjectIds.removeAll()
                }
                .disabled(selectedProjectIds.isEmpty)
            }
            
            List(selection: $selectedProjectIds) {
                ForEach(listProjectsForDisplay) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.body)
                            Text("ID \(project.id)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(sizeLabel(for: project))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        archiveStatusBadge(project: project)
                        
                        Text(dateLabel(for: project))
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(project.id)
                    .contextMenu {
                        if archivedProjectIds.contains(project.id) {
                            if archiveLocations[project.id] != nil {
                                Button("Open archive location") {
                                    openArchiveLocation(for: project.id)
                                }
                            }
                            Button(role: .destructive) {
                                let toDelete = projectsToDeleteFromSelection(including: project)
                                if !toDelete.isEmpty {
                                    projectsToDelete = IdentifiableProjects(projects: toDelete)
                                }
                            } label: {
                                Text(cheapDeleteContextMenuLabel(including: project))
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
    
    private var footer: some View {
        VStack(spacing: 12) {
            if archiveManager.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: min(max(Double(archiveManager.completedProjects), 0), Double(max(archiveManager.totalProjects, 1))),
                                 total: Double(max(archiveManager.totalProjects, 1)))
                    Text(archiveManager.statusMessage)
                        .font(.subheadline)
                    
                    if !archiveManager.currentProjectNames.isEmpty {
                        Text("Downloading: \(archiveManager.currentProjectNames.sorted().joined(separator: ", "))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                    
                    if archiveManager.totalBytes > 0 {
                        let total = max(Double(archiveManager.totalBytes), 1)
                        let value = min(max(Double(archiveManager.downloadedBytes), 0), total)
                        ProgressView(value: value, total: total)
                        Text("Downloaded \(formatBytesForProgress(archiveManager.downloadedBytes)) of \(formatBytesForProgress(archiveManager.totalBytes))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView()
                        Text("Preparing downloads…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Button("Cancel Archive") {
                    archiveManager.cancel()
                }
            }
            
            if !archiveManager.isRunning, !archiveManager.statusMessage.isEmpty {
                Text(archiveManager.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if let archiveError = archiveManager.errorMessage {
                Text(archiveError)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if let failures = archiveManager.lastRunFailures, !failures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(failures.count) project(s) failed to archive:")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.orange)
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.projectName)
                                .font(.caption)
                            Text(f.errorMessage)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Retry failed") {
                        retryFailedProjects()
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected: \(downloadProjects.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if let total = totalDownloadSizeBytes {
                        Text("Total size: \(formatBytes(total))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Button("Download Project Contents as ZIP Folders") {
                    chooseDestinationAndStartArchive()
                }
                .disabled(downloadProjects.isEmpty || archiveManager.isRunning || !simianService.isConfigured)
            }
        }
    }
    
    @ViewBuilder
    private func archiveStatusBadge(project: SimianProject) -> some View {
        if archivedProjectIds.contains(project.id) {
            Text("Archived")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.9))
                .cornerRadius(4)
        } else if projectsInCurrentRun.contains(project.id) {
            if archiveManager.currentProjectNames.contains(project.name) {
                Text("Downloading")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor)
                    .cornerRadius(4)
            } else {
                Text("In queue")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if !archivedProjectIds.isEmpty {
            Text("Not archived")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("—")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func openArchiveLocation(for projectId: String) {
        guard let url = archiveLocations[projectId] else { return }
        NSWorkspace.shared.open(url)
    }
    
    private func scanGMArchives() {
        let settings = settingsManager.currentSettings
        let basePath = settings.serverBasePath
        let yearPrefix = settings.yearPrefix
        guard !basePath.isEmpty else {
            archiveScanError = "GM server path not set in Settings."
            return
        }
        archiveScanError = nil
        isScanningArchives = true
        Task {
            let service = SimianArchiveComparisonService(serverBasePath: basePath, yearPrefix: yearPrefix)
            let (ids, locations) = service.scanArchivedProjectIds()
            await MainActor.run {
                archivedProjectIds = ids
                for (projectId, fileURLs) in locations {
                    if let zipURL = fileURLs.first {
                        archiveLocations[projectId] = zipURL.deletingLastPathComponent()
                    }
                }
                isScanningArchives = false
            }
        }
    }
    
    private func dateLabel(for project: SimianProject) -> String {
        guard let info = projectInfos[project.id],
              let date = info.dateValue(for: dateField) else {
            return "No date"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func sizeLabel(for project: SimianProject) -> String {
        guard let info = projectInfos[project.id] else {
            return "Size: --"
        }
        if let bytes = info.projectSizeBytes {
            return "Size: \(formatBytes(bytes))"
        }
        if let raw = info.projectSize, !raw.isEmpty {
            return "Size: \(raw)"
        }
        return "Size: --"
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// For download progress: under 1 GB show whole MB (e.g. "662 MB"), no decimals.
    private func formatBytesForProgress(_ bytes: Int64) -> String {
        let oneGB: Int64 = 1_000_000_000
        if bytes >= oneGB {
            return formatBytes(bytes)
        }
        let mb = Int(round(Double(bytes) / 1_000_000))
        return "\(mb) MB"
    }
    
    
    private func chooseDestinationAndStartArchive() {
        let projs = downloadProjects
        guard !projs.isEmpty else { return }
        let flagged = projs.filter { hasAmbiguousDocket(projectName: $0.name) }
        if !flagged.isEmpty {
            ambiguousDocketConfirmation = AmbiguousDocketContext(allProjects: projs, flaggedProjects: flagged)
            return
        }
        startArchive(with: projs)
    }

    /// True if the name’s docket prefix is not clearly 5 digits or 5 digits + "-US" (e.g. 2xxxx, 24xxx, 25XXX).
    private func hasAmbiguousDocket(projectName: String) -> Bool {
        let prefix: String
        if let idx = projectName.firstIndex(where: { $0 == "_" || $0 == "/" }) {
            prefix = String(projectName[..<idx])
        } else {
            prefix = projectName
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Clear: exactly 5 digits, or 5 digits + "-US"
        if trimmed.count == 5, trimmed.allSatisfy(\.isNumber) { return false }
        if trimmed.count == 8, trimmed.prefix(5).allSatisfy(\.isNumber), trimmed.dropFirst(5).uppercased() == "-US" { return false }
        // Has digits but didn’t match -> ambiguous (e.g. 2xxxx, 24xxx, 25XXX)
        if trimmed.contains(where: \.isNumber) { return true }
        return false
    }

    private func startArchive(with projs: [SimianProject]) {
        guard !projs.isEmpty else { return }
        let settings = settingsManager.currentSettings
        let basePath = settings.serverBasePath
        let yearPrefix = settings.yearPrefix
        let service = SimianArchiveComparisonService(serverBasePath: basePath, yearPrefix: yearPrefix)

        if service.isServerAvailable() {
            var destinationByProjectId: [String: URL] = [:]
            for project in projs {
                let year = projectYear(for: project)
                guard let url = service.dataBackupsURL(for: year) else {
                    showFolderPickerAndArchive(projects: projs)
                    return
                }
                destinationByProjectId[project.id] = url
            }
            projectsInCurrentRun = Set(projs.map(\.id))
            for (id, url) in destinationByProjectId {
                archiveLocations[id] = url
            }
            let estimatedTotal = projs.reduce(Int64(0)) { $0 + (projectInfos[$1.id]?.projectSizeBytes ?? 0) }
            archiveManager.startArchive(
                projects: projs,
                destinationByProjectId: destinationByProjectId,
                simianService: simianService,
                estimatedTotalBytes: estimatedTotal > 0 ? estimatedTotal : nil
            ) { ids in
                archivedProjectIds = archivedProjectIds.union(ids)
            }
            return
        }

        showFolderPickerAndArchive(projects: projs)
    }

    /// Year for routing to DATA BACKUPS (from project date or current year).
    private func projectYear(for project: SimianProject) -> Int {
        let calendar = Calendar.current
        guard let info = projectInfos[project.id],
              let date = info.dateValue(for: dateField) else {
            return calendar.component(.year, from: Date())
        }
        return calendar.component(.year, from: date)
    }

    private func retryFailedProjects() {
        guard let failures = archiveManager.lastRunFailures, !failures.isEmpty else { return }
        let failedIds = Set(failures.map(\.projectId))
        let toRetry = projects.filter { failedIds.contains($0.id) }
        guard !toRetry.isEmpty else { return }
        archiveManager.lastRunFailures = nil
        startArchive(with: toRetry)
    }

    private func showFolderPickerAndArchive(projects: [SimianProject]) {
        let panel = NSOpenPanel()
        panel.title = "Select Destination"
        panel.message = "Choose a folder to save ZIP archives."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let destinationURL = panel.url {
            projectsInCurrentRun = Set(projects.map(\.id))
            for project in projects {
                archiveLocations[project.id] = destinationURL
            }
            let estimatedTotal = projects.reduce(Int64(0)) { $0 + (projectInfos[$1.id]?.projectSizeBytes ?? 0) }
            archiveManager.startArchive(
                projects: projects,
                destinationURL: destinationURL,
                simianService: simianService,
                estimatedTotalBytes: estimatedTotal > 0 ? estimatedTotal : nil
            )
        }
    }
    
    private func updateSimianServiceConfiguration() {
        let settings = settingsManager.currentSettings
        if let baseURL = settings.simianAPIBaseURL, !baseURL.isEmpty {
            simianService.setBaseURL(baseURL)
        }
        
        if let username = SharedKeychainService.getSimianUsername(),
           let password = SharedKeychainService.getSimianPassword() {
            simianService.setCredentials(username: username, password: password)
        }
    }
    
    private func loadProjects() {
        loadTask?.cancel()
        errorMessage = nil
        isLoading = true
        loadProgress = 0
        projects = []
        projectInfos = [:]
        
        guard simianService.isConfigured else {
            isLoading = false
            errorMessage = "Simian is not configured."
            return
        }
        
        loadTask = Task {
            do {
                let list = try await simianService.getProjectList()
                await MainActor.run {
                    projects = list
                }
                
                if list.isEmpty {
                    await MainActor.run {
                        isLoading = false
                        refreshDisplayedProjects()
                    }
                    return
                }
                
                var completed = 0
                for project in list {
                    try Task.checkCancellation()
                    let info = try await simianService.getProjectInfoDetails(projectId: project.id)
                    completed += 1
                    await MainActor.run {
                        projectInfos[project.id] = info
                        loadProgress = Double(completed) / Double(list.count)
                    }
                }
                
                await MainActor.run {
                    isLoading = false
                    refreshDisplayedProjects()
                }
            } catch is CancellationError {
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func normalizedDateRange() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let startDate = min(fromDate, toDate)
        let endDate = max(fromDate, toDate)
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate
        return (start, end)
    }
    
    /// Runs filter/sort off the main thread so the UI stays responsive; updates displayedProjects when done.
    private func refreshDisplayedProjects() {
        displayRefreshTask?.cancel()
        let projs = projects
        let infos = projectInfos
        let search = debouncedSearchText
        let from = fromDate
        let to = toDate
        let field = dateField
        let filter = archiveFilter
        let archived = archivedProjectIds
        displayRefreshTask = Task.detached(priority: .userInitiated) {
            let result = Self.computeFilteredProjects(
                projects: projs,
                projectInfos: infos,
                searchText: search,
                fromDate: from,
                toDate: to,
                dateField: field,
                archiveFilter: filter,
                archivedProjectIds: archived
            )
            await MainActor.run {
                displayedProjects = result
            }
        }
    }
    
    /// Pure filter/sort so it can run off main thread.
    private nonisolated static func computeFilteredProjects(
        projects: [SimianProject],
        projectInfos: [String: SimianProjectInfo],
        searchText: String,
        fromDate: Date,
        toDate: Date,
        dateField: SimianProjectDateField,
        archiveFilter: ArchiveFilter,
        archivedProjectIds: Set<String>
    ) -> [SimianProject] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current
        let startDate = min(fromDate, toDate)
        let endDate = max(fromDate, toDate)
        let rangeStart = calendar.startOfDay(for: startDate)
        let rangeEnd = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endDate) ?? endDate
        var list = projects.filter { project in
            if project.id == "91" || project.id == "459" || project.name == "Misc/UNARCHIVE_Delete Every 3 Months" {
                return false
            }
            if !normalizedSearch.isEmpty && !project.name.lowercased().contains(normalizedSearch) {
                return false
            }
            guard let info = projectInfos[project.id],
                  let date = info.dateValue(for: dateField) else {
                return false
            }
            return date >= rangeStart && date <= rangeEnd
        }
        list.sort { lhs, rhs in
            (projectInfos[lhs.id]?.dateValue(for: dateField) ?? .distantPast) >
                (projectInfos[rhs.id]?.dateValue(for: dateField) ?? .distantPast)
        }
        switch archiveFilter {
        case .all, .queue:
            break
        case .notArchived:
            list = list.filter { !archivedProjectIds.contains($0.id) }
        case .archived:
            list = list.filter { archivedProjectIds.contains($0.id) }
        }
        return list
    }
    
    private func pruneSelection() {
        let filteredIds = Set(listProjectsForDisplay.map(\.id))
        selectedProjectIds = selectedProjectIds.intersection(filteredIds)
    }
    
    /// Projects that would be deleted: if the given project is in the current selection, all selected-and-archived; otherwise just this project.
    private func projectsToDeleteFromSelection(including project: SimianProject) -> [SimianProject] {
        if selectedProjectIds.contains(project.id) {
            return displayedProjects.filter { selectedProjectIds.contains($0.id) && archivedProjectIds.contains($0.id) }
        }
        return [project]
    }
    
    /// Label for context menu only. Kept cheap so right-click doesn’t hang.
    private func cheapDeleteContextMenuLabel(including project: SimianProject) -> String {
        if selectedProjectIds.contains(project.id), selectedProjectIds.count > 1 {
            return "Delete selected projects from Simian"
        }
        return "Delete from Simian"
    }

}

// MARK: - Delete project confirmation (type "DELETE" to confirm)
private struct DeleteProjectConfirmationSheet: View {
    let projects: [SimianProject]
    @Binding var errorMessage: String?
    let isDeleting: Bool
    let deletionProgress: (Int, Int)?
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    @State private var confirmationText = ""
    
    private var canConfirm: Bool {
        !isDeleting && confirmationText == "DELETE"
    }
    
    private var deleteButtonTitle: String {
        projects.count > 1 ? "Delete \(projects.count) projects from Simian" : "Delete from Simian"
    }
    
    private var progressLabel: String {
        guard let (current, total) = deletionProgress else { return "Deleting…" }
        if total == 1 { return "Deleting…" }
        return "Deleting \(current) of \(total)…"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete from Simian")
                .font(.headline)
            if isDeleting {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text(progressLabel)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else if projects.count == 1, let p = projects.first {
                Text("This will permanently delete the project \"\(p.name)\" (ID \(p.id)) from Simian. This cannot be undone.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This will permanently delete \(projects.count) projects from Simian. This cannot be undone.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(projects) { p in
                            Text("• \(p.name) (ID \(p.id))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            if !isDeleting {
                Text("To confirm, type DELETE below:")
                    .font(.subheadline)
                TextField("DELETE", text: $confirmationText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: confirmationText) { _, _ in
                        errorMessage = nil
                    }
            }
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .disabled(isDeleting)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button(deleteButtonTitle) {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 360)
    }
}

// MARK: - Unclear docket number warning
private struct AmbiguousDocketSheet: View {
    let flaggedProjects: [SimianProject]
    let onIncludeAll: () -> Void
    let onExcludeFlagged: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unclear docket numbers")
                .font(.headline)
            Text("The following projects have docket-like prefixes that aren’t clearly 5 digits or 5 digits + \"-US\" (e.g. 2xxxx, 24xxx, 25XXX). Include them in the archive?")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(flaggedProjects) { p in
                        Text("• \(p.name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            HStack(spacing: 10) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Exclude these") {
                    onExcludeFlagged()
                }
                Button("Include all") {
                    onIncludeAll()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

