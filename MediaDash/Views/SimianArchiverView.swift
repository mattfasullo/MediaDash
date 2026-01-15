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
    @State private var dateField: SimianProjectDateField = .uploadDate
    @State private var sortOption: ProjectSortOption = .dateDesc
    @State private var fromDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var toDate: Date = Date()
    @State private var loadTask: Task<Void, Never>?
    @State private var projectSizes: [String: Int64] = [:]
    @State private var sizeLoadingIds: Set<String> = []
    
    private var filteredProjects: [SimianProject] {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let range = normalizedDateRange()
        
        let filtered = projects.filter { project in
            if !normalizedSearch.isEmpty && !project.name.lowercased().contains(normalizedSearch) {
                return false
            }
            guard let info = projectInfos[project.id],
                  let date = info.dateValue(for: dateField) else {
                return false
            }
            return date >= range.start && date <= range.end
        }
        
        return filtered.sorted { lhs, rhs in
            switch sortOption {
            case .nameAsc:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .nameDesc:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            case .dateAsc:
                return (projectInfos[lhs.id]?.dateValue(for: dateField) ?? .distantPast) <
                    (projectInfos[rhs.id]?.dateValue(for: dateField) ?? .distantPast)
            case .dateDesc:
                return (projectInfos[lhs.id]?.dateValue(for: dateField) ?? .distantPast) >
                    (projectInfos[rhs.id]?.dateValue(for: dateField) ?? .distantPast)
            case .lastAccessAsc:
                return (projectInfos[lhs.id]?.dateValue(for: .lastAccess) ?? .distantPast) <
                    (projectInfos[rhs.id]?.dateValue(for: .lastAccess) ?? .distantPast)
            case .lastAccessDesc:
                return (projectInfos[lhs.id]?.dateValue(for: .lastAccess) ?? .distantPast) >
                    (projectInfos[rhs.id]?.dateValue(for: .lastAccess) ?? .distantPast)
            }
        }
    }
    
    private var downloadProjects: [SimianProject] {
        if selectedProjectIds.isEmpty {
            return filteredProjects
        }
        return filteredProjects.filter { selectedProjectIds.contains($0.id) }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            header
            
            filterControls
            
            projectList
            
            footer
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 640)
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
        .onChange(of: searchText) { _, _ in
            pruneSelection()
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
                Picker("Date Field", selection: $dateField) {
                    ForEach(SimianProjectDateField.allCases) { field in
                        Text(field.label).tag(field)
                    }
                }
                .frame(width: 160)
                
                Picker("Sort", selection: $sortOption) {
                    ForEach(ProjectSortOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .frame(width: 170)
                
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
    
    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects in range: \(filteredProjects.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Select All") {
                    selectedProjectIds = Set(filteredProjects.map(\.id))
                }
                .disabled(filteredProjects.isEmpty)
                
                Button("Clear") {
                    selectedProjectIds.removeAll()
                }
                .disabled(selectedProjectIds.isEmpty)
            }
            
            List(selection: $selectedProjectIds) {
                ForEach(filteredProjects) { project in
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
                        
                        Text(dateLabel(for: project))
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(project.id)
                    .task {
                        await loadProjectSizeIfNeeded(projectId: project.id)
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
                    ProgressView(value: Double(archiveManager.completedProjects),
                                 total: Double(max(archiveManager.totalProjects, 1)))
                    Text(archiveManager.statusMessage)
                        .font(.subheadline)
                    
                    if let projectName = archiveManager.currentProjectName {
                        Text("Project: \(projectName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let fileName = archiveManager.currentFileName {
                        Text("File: \(fileName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let folderPath = archiveManager.currentFolderPath {
                        Text("Folder: \(folderPath)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Folders scanned: \(archiveManager.scannedFolders)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if archiveManager.totalFiles == 0 && archiveManager.completedFiles == 0 {
                        Text("Files: calculating...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Files: \(archiveManager.completedFiles)/\(max(archiveManager.totalFiles, 0))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if archiveManager.totalBytes > 0 {
                        ProgressView(value: Double(archiveManager.downloadedBytes),
                                     total: Double(archiveManager.totalBytes))
                        Text("Downloaded \(formatBytes(archiveManager.downloadedBytes)) of \(formatBytes(archiveManager.totalBytes))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Button("Cancel Archive") {
                    archiveManager.cancel()
                }
            }
            
            if let archiveError = archiveManager.errorMessage {
                Text(archiveError)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            HStack {
                Text("Selected: \(downloadProjects.count)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Download Project Contents as ZIP Folders") {
                    chooseDestinationAndStartArchive()
                }
                .disabled(downloadProjects.isEmpty || archiveManager.isRunning || !simianService.isConfigured)
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
        if let size = projectSizes[project.id] {
            return "Size: \(formatBytes(size))"
        }
        if sizeLoadingIds.contains(project.id) {
            return "Size: calculating..."
        }
        return "Size: --"
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    
    private func chooseDestinationAndStartArchive() {
        let panel = NSOpenPanel()
        panel.title = "Select Destination"
        panel.message = "Choose a folder to save ZIP archives."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let destinationURL = panel.url {
            archiveManager.startArchive(
                projects: downloadProjects,
                destinationURL: destinationURL,
                simianService: simianService
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
    
    private func pruneSelection() {
        let filteredIds = Set(filteredProjects.map(\.id))
        selectedProjectIds = selectedProjectIds.intersection(filteredIds)
    }

    private func loadProjectSizeIfNeeded(projectId: String) async {
        let shouldLoad = await MainActor.run { () -> Bool in
            guard projectSizes[projectId] == nil,
                  !sizeLoadingIds.contains(projectId),
                  simianService.isConfigured else {
                return false
            }
            sizeLoadingIds.insert(projectId)
            return true
        }
        
        guard shouldLoad else { return }
        defer {
            Task { @MainActor in
                sizeLoadingIds.remove(projectId)
            }
        }
        
        do {
            let size = try await computeProjectSize(projectId: projectId)
            await MainActor.run {
                projectSizes[projectId] = size
            }
        } catch {
            await MainActor.run {
                projectSizes[projectId] = 0
            }
        }
    }
    
    private func computeProjectSize(projectId: String) async throws -> Int64 {
        var total: Int64 = 0
        
        let rootFiles = try await simianService.getProjectFiles(projectId: projectId, folderId: nil)
        total += try await sumFileSizes(projectId: projectId, files: rootFiles)
        
        let folders = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: nil)
        for folder in folders {
            total += try await computeFolderSize(projectId: projectId, folderId: folder.id)
        }
        
        return total
    }
    
    private func computeFolderSize(projectId: String, folderId: String) async throws -> Int64 {
        var total: Int64 = 0
        let files = try await simianService.getProjectFiles(projectId: projectId, folderId: folderId)
        total += try await sumFileSizes(projectId: projectId, files: files)
        
        let subfolders = try await simianService.getProjectFolders(projectId: projectId, parentFolderId: folderId)
        for folder in subfolders {
            total += try await computeFolderSize(projectId: projectId, folderId: folder.id)
        }
        
        return total
    }
    
    private func sumFileSizes(projectId: String, files: [SimianFile]) async throws -> Int64 {
        var total: Int64 = 0
        for file in files {
            do {
                let info = try await simianService.getFileInfo(projectId: projectId, fileId: file.id)
                if let bytes = info.mediaSizeBytes {
                    total += bytes
                }
            } catch {
                continue
            }
        }
        return total
    }
}

private enum ProjectSortOption: String, CaseIterable, Identifiable {
    case dateDesc
    case dateAsc
    case lastAccessDesc
    case lastAccessAsc
    case nameAsc
    case nameDesc
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .dateDesc:
            return "Date (Newest)"
        case .dateAsc:
            return "Date (Oldest)"
        case .lastAccessDesc:
            return "Last Accessed (Newest)"
        case .lastAccessAsc:
            return "Last Accessed (Oldest)"
        case .nameAsc:
            return "Name (A-Z)"
        case .nameDesc:
            return "Name (Z-A)"
        }
    }
}

