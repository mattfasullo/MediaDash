import SwiftUI
import AppKit

struct DocketHubView: View {
    let docket: DocketInfo
    @Binding var isPresented: Bool
    @ObservedObject var metadataManager: DocketMetadataManager
    @EnvironmentObject var settingsManager: SettingsManager
    var cacheManager: AsanaCacheManager?
    
    @State private var hubData: DocketHubData?
    @State private var isLoading = false
    @State private var loadingProgress: [HubTab: Bool] = [:]
    @State private var selectedTab: HubTab = .overview
    @State private var metadata: DocketMetadata
    @FocusState private var isTabFocused: Bool
    @FocusState private var isListFocused: Bool
    @State private var selectedAsanaIndex: Int? = nil
    @State private var selectedSimianIndex: Int? = nil
    @State private var selectedServerIndex: Int? = nil
    // Services - will be created with proper dependencies (no Gmail/email; that lives in notification centre only)
    private var hubService: DocketHubService {
        DocketHubService(asanaCacheManager: cacheManager)
    }
    
    enum HubTab: String, CaseIterable {
        case overview = "Overview"
        case asana = "Asana"
        case simian = "Simian"
        case server = "Server"
        case metadata = "Metadata"
    }
    
    init(docket: DocketInfo, isPresented: Binding<Bool>, metadataManager: DocketMetadataManager, cacheManager: AsanaCacheManager? = nil) {
        self.docket = docket
        self._isPresented = isPresented
        self.metadataManager = metadataManager
        self.cacheManager = cacheManager
        
        // Initialize metadata
        var initialMetadata = metadataManager.getMetadata(forId: docket.fullName)
        if let customFields = docket.projectMetadata?.customFields {
            initialMetadata = DocketMetadataEditorView.populateMetadataFromCustomFields(initialMetadata, customFields: customFields)
        }
        self._metadata = State(initialValue: initialMetadata)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Tab bar
            tabBarView
            
            Divider()
            
            // Content
            if isLoading {
                loadingView
            } else if let data = hubData {
                tabContentView(data: data)
            } else {
                emptyStateView
            }
            
            Divider()
            
            // Footer
            footerView
        }
        .frame(width: 700, height: 700)
        .keyboardNavigationHandler(handleKey: { event in
            switch event.keyCode {
            case 123: // left
                if isTabFocused {
                    let tabs = HubTab.allCases
                    if let i = tabs.firstIndex(of: selectedTab), i > 0 { selectedTab = tabs[i - 1] }
                }
                return true
            case 124: // right
                if isTabFocused {
                    let tabs = HubTab.allCases
                    if let i = tabs.firstIndex(of: selectedTab), i < tabs.count - 1 { selectedTab = tabs[i + 1] }
                }
                return true
            case 125: // down
                if isTabFocused {
                    isTabFocused = false
                    isListFocused = true
                    selectFirstItemInTab()
                } else if isListFocused { moveSelectionInTab(direction: 1) }
                return true
            case 126: // up
                if isListFocused { moveSelectionInTab(direction: -1) }
                else if !isTabFocused {
                    isListFocused = false
                    isTabFocused = true
                    clearSelectionInTab()
                }
                return true
            case 36: // return
                if isListFocused { activateSelectedItem() }
                else if isTabFocused {
                    isTabFocused = false
                    isListFocused = true
                    selectFirstItemInTab()
                }
                return true
            default: return false
            }
        })
        .onAppear {
            loadHubData()
            isTabFocused = true
        }
        // Keyboard navigation
        .onKeyPress(.leftArrow) {
            if isTabFocused {
                let tabs = HubTab.allCases
                if let currentIndex = tabs.firstIndex(of: selectedTab), currentIndex > 0 {
                    selectedTab = tabs[currentIndex - 1]
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if isTabFocused {
                let tabs = HubTab.allCases
                if let currentIndex = tabs.firstIndex(of: selectedTab), currentIndex < tabs.count - 1 {
                    selectedTab = tabs[currentIndex + 1]
                }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if isTabFocused {
                // Move focus to list when pressing down
                isTabFocused = false
                isListFocused = true
                // Select first item in current tab
                selectFirstItemInTab()
                return .handled
            } else if isListFocused {
                moveSelectionInTab(direction: 1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            if isListFocused {
                moveSelectionInTab(direction: -1)
                return .handled
            } else if !isTabFocused {
                // Move focus back to tabs
                isListFocused = false
                isTabFocused = true
                clearSelectionInTab()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.return) {
            if isListFocused {
                activateSelectedItem()
                return .handled
            } else if isTabFocused {
                // Enter on tab selects it (already selected, but move to list)
                isTabFocused = false
                isListFocused = true
                selectFirstItemInTab()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onKeyPress(.tab) {
            // Tab cycles between tabs and list
            if isTabFocused {
                isTabFocused = false
                isListFocused = true
                selectFirstItemInTab()
            } else {
                isListFocused = false
                isTabFocused = true
                clearSelectionInTab()
            }
            return .handled
        }
    }
    
    private func selectFirstItemInTab() {
        guard let data = hubData else { return }
        switch selectedTab {
        case .asana:
            selectedAsanaIndex = data.asanaTasks.isEmpty ? nil : 0
        case .simian:
            selectedSimianIndex = data.simianProjects.isEmpty ? nil : 0
        case .server:
            selectedServerIndex = data.serverFolders.isEmpty ? nil : 0
        default:
            break
        }
    }
    
    private func clearSelectionInTab() {
        selectedAsanaIndex = nil
        selectedSimianIndex = nil
        selectedServerIndex = nil
    }
    
    private func moveSelectionInTab(direction: Int) {
        guard let data = hubData else { return }
        switch selectedTab {
        case .asana:
            guard !data.asanaTasks.isEmpty else { return }
            let current = selectedAsanaIndex ?? -1
            let newIndex = max(0, min(data.asanaTasks.count - 1, current + direction))
            selectedAsanaIndex = newIndex >= 0 ? newIndex : nil
        case .simian:
            guard !data.simianProjects.isEmpty else { return }
            let current = selectedSimianIndex ?? -1
            let newIndex = max(0, min(data.simianProjects.count - 1, current + direction))
            selectedSimianIndex = newIndex >= 0 ? newIndex : nil
        case .server:
            guard !data.serverFolders.isEmpty else { return }
            let current = selectedServerIndex ?? -1
            let newIndex = max(0, min(data.serverFolders.count - 1, current + direction))
            selectedServerIndex = newIndex >= 0 ? newIndex : nil
        default:
            break
        }
    }
    
    private func activateSelectedItem() {
        guard let data = hubData else { return }
        switch selectedTab {
        case .asana:
            if let index = selectedAsanaIndex, index < data.asanaTasks.count {
                let task = data.asanaTasks[index]
                if let url = task.url {
                    NSWorkspace.shared.open(url)
                }
            }
        case .simian:
            // Could open Simian project if we had URL
            break
        case .server:
            if let index = selectedServerIndex, index < data.serverFolders.count {
                let folder = data.serverFolders[index]
                NSWorkspace.shared.selectFile(folder.path.path, inFileViewerRootedAtPath: "")
            }
        default:
            break
        }
    }
    
    private var headerView: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(docket.displayNumber)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue)
                .cornerRadius(4)
            
            Text(docket.jobName)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)
            
            Spacer()
            
            // Quick actions
            HStack(spacing: 8) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(docket.fullName, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy Docket Name")
                
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(docket.number, forType: .string)
                }) {
                    Image(systemName: "number")
                }
                .buttonStyle(.borderless)
                .help("Copy Docket Number")
                
                Button(action: {
                    loadHubData()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
                .help("Refresh")
            }
            
            Button("Done") {
                metadataManager.saveMetadata(metadata)
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var tabBarView: some View {
        HStack(spacing: 0) {
            ForEach(HubTab.allCases, id: \.self) { tab in
                Button(action: {
                    selectedTab = tab
                    isTabFocused = true
                    clearSelectionInTab()
                }) {
                    VStack(spacing: 4) {
                        Text(tab.rawValue)
                            .font(.system(size: 12))
                        
                        if let data = hubData {
                            Text("\(tab.count(for: data))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        (selectedTab == tab && isTabFocused) ? Color.accentColor.opacity(0.3) :
                        (selectedTab == tab) ? Color.accentColor.opacity(0.2) : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading docket data...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "info.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No data available")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private func tabContentView(data: DocketHubData) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch selectedTab {
                case .overview:
                    overviewTab(data: data)
                case .asana:
                    asanaTab(data: data)
                case .simian:
                    simianTab(data: data)
                case .server:
                    serverTab(data: data)
                case .metadata:
                    metadataTab(data: data)
                }
            }
            .padding()
        }
    }
    
    private func overviewTab(data: DocketHubData) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Quick Stats
            HStack(spacing: 20) {
                StatCard(title: "Asana Tasks", count: data.asanaTasks.count, icon: "square.stack.3d.up.fill", color: .blue)
                StatCard(title: "Simian Projects", count: data.simianProjects.count, icon: "folder.fill", color: .green)
                StatCard(title: "Server Folders", count: data.serverFolders.count, icon: "externaldrive.fill", color: .orange)
            }
            
            Divider()
            
            // Basic Info
            VStack(alignment: .leading, spacing: 12) {
                Text("Basic Information")
                    .font(.headline)
                
                InfoRow(label: "Docket Number", value: data.docketNumber)
                InfoRow(label: "Job Name", value: data.jobName)
                
                if let updatedAt = docket.updatedAt {
                    InfoRow(label: "Last Updated", value: formatDate(updatedAt))
                }
            }
            
        }
    }
    
    private func asanaTab(data: DocketHubData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if data.asanaTasks.isEmpty {
                EmptyStateView(message: "No Asana tasks found for this docket")
            } else {
                ForEach(Array(data.asanaTasks.enumerated()), id: \.element.id) { index, task in
                    AsanaTaskCard(task: task)
                        .background(selectedAsanaIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                }
            }
        }
    }
    
    private func simianTab(data: DocketHubData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if data.simianProjects.isEmpty {
                EmptyStateView(message: "No Simian projects found for this docket")
            } else {
                ForEach(Array(data.simianProjects.enumerated()), id: \.element.id) { index, project in
                    SimianProjectCard(project: project)
                        .background(selectedSimianIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                }
            }
        }
    }
    
    private func serverTab(data: DocketHubData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if data.serverFolders.isEmpty {
                EmptyStateView(message: "No server folders found for this docket")
            } else {
                ForEach(Array(data.serverFolders.enumerated()), id: \.element.id) { index, folder in
                    ServerFolderCard(folder: folder)
                        .background(selectedServerIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                        .cornerRadius(6)
                }
            }
        }
    }
    
    private func metadataTab(data: DocketHubData) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // Basic Information Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("Basic Information")
                        .font(.headline)
                }
                
                HStack(spacing: 16) {
                    ReadOnlyMetadataField(label: "Docket Number", icon: "123.rectangle", value: docket.number)
                    if let metadataType = docket.metadataType, !metadataType.isEmpty {
                        ReadOnlyMetadataField(label: "Type", icon: "tag", value: metadataType)
                    }
                }
                
                ReadOnlyMetadataField(label: "Job Name", icon: "briefcase.fill", value: docket.jobName)
                
                if let updatedAt = docket.updatedAt {
                    ReadOnlyMetadataField(label: "Last Updated", icon: "clock", value: formatDate(updatedAt))
                }
            }
            .padding()
            .background(Color.green.opacity(0.05))
            .cornerRadius(8)
            
            Divider()
            
            // Job Details Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Job Details")
                    .font(.headline)
                
                MetadataField(label: "Client", icon: "building.2", text: $metadata.client)
                MetadataField(label: "Agency", icon: "briefcase", text: $metadata.agency)
                MetadataField(label: "License Total", icon: "dollarsign.circle", text: $metadata.licenseTotal)
                MetadataField(label: "Currency", icon: "banknote", text: $metadata.currency)
            }
            
            Divider()
            
            // Production Team Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Production Info")
                    .font(.headline)
                
                MetadataField(label: "Producer", icon: "person", text: $metadata.producer)
                MetadataField(label: "Agency Producer", icon: "person.badge.key", text: $metadata.agencyProducer)
                MetadataField(label: "Status", icon: "checkmark.circle", text: $metadata.status)
                MetadataField(label: "Music Type", icon: "music.note", text: $metadata.musicType)
                MetadataField(label: "Track", icon: "waveform", text: $metadata.track)
                MetadataField(label: "Media", icon: "tv", text: $metadata.media)
            }
            
            Divider()
            
            // Notes Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.headline)
                
                TextEditor(text: $metadata.notes)
                    .frame(minHeight: 100)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
        }
    }
    
    private var footerView: some View {
        HStack {
            Spacer()
            
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            
            Button("Save") {
                metadataManager.saveMetadata(metadata)
                isPresented = false
            }
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private func loadHubData() {
        isLoading = true
        
        let metadata = metadataManager.getMetadata(forId: docket.fullName)
        hubData = DocketHubData(
            docketNumber: docket.number,
            jobName: docket.jobName,
            asanaTasks: [],
            simianProjects: [],
            serverFolders: [],
            metadata: metadata
        )
        
        Task {
            do {
                async let asanaTasks = hubService.searchAsanaTasks(docketNumber: docket.number)
                async let simianProjects = hubService.searchSimianProjects(docketNumber: docket.number)
                async let serverFolders = hubService.searchServerFolders(docketNumber: docket.number)
                
                let (asanaResults, simianResults, serverResults) = try await (asanaTasks, simianProjects, serverFolders)
                
                await MainActor.run {
                    if let currentData = self.hubData {
                        self.hubData = DocketHubData(
                            docketNumber: currentData.docketNumber,
                            jobName: currentData.jobName,
                            asanaTasks: asanaResults,
                            simianProjects: simianResults,
                            serverFolders: serverResults,
                            metadata: currentData.metadata
                        )
                    }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    print("Error loading hub data: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text("\(count)")
                .font(.title3)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        }
    }
}

struct EmptyStateView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(message)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct AsanaTaskCard: View {
    let task: DocketHubAsanaTask
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name)
                        .font(.headline)
                        .lineLimit(2)
                    
                    if let projectName = task.projectName {
                        Text(projectName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    if task.completed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)
                    }
                    
                    if let url = task.url {
                        Link(destination: url) {
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            // Metadata in a compact horizontal layout
            HStack(spacing: 16) {
                if let dueDate = task.dueDate {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(dueDate)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                
                if let assignee = task.assignee {
                    HStack(spacing: 4) {
                        Image(systemName: "person")
                            .font(.caption2)
                        Text(assignee)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundColor(.secondary)
                }
            }
            
            if !task.customFields.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom Fields")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    // Use a grid layout for custom fields
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(Array(task.customFields.keys.sorted()), id: \.self) { key in
                            if let value = task.customFields[key], !value.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(value)
                                        .font(.caption)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }
}

struct SimianProjectCard: View {
    let project: DocketHubSimianProject
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(2)
                
                if let projectNumber = project.projectNumber {
                    Text("Project #: \(projectNumber)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Details in a more compact grid layout
            VStack(spacing: 12) {
                HStack(spacing: 24) {
                    if let uploadDate = project.uploadDate {
                        CompactInfoField(label: "Uploaded", value: formatDate(uploadDate))
                    }
                    
                    if let lastAccess = project.lastAccess {
                        CompactInfoField(label: "Last Access", value: formatDate(lastAccess))
                    }
                    
                    CompactInfoField(label: "Files", value: "\(project.fileCount)")
                    
                    if let projectSize = project.projectSize {
                        CompactInfoField(label: "Size", value: formatSize(projectSize))
                    }
                }
                
                if let startDate = project.startDate {
                    HStack(spacing: 24) {
                        CompactInfoField(label: "Start Date", value: formatDate(startDate))
                        
                        if let completeDate = project.completeDate {
                            CompactInfoField(label: "Complete Date", value: formatDate(completeDate))
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.green.opacity(0.05))
        .cornerRadius(8)
    }
    
    private func formatDate(_ dateString: String) -> String {
        // Try to parse and reformat the date to prevent awkward line breaks
        let inputFormats = [
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd hh:mm a",
            "yyyy-MM-dd HH:mm:ss",
            "MM/dd/yyyy",
            "MM/dd/yy"
        ]
        
        let outputFormatter = DateFormatter()
        outputFormatter.dateStyle = .medium
        outputFormatter.timeStyle = .short
        
        for format in inputFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: dateString) {
                return outputFormatter.string(from: date)
            }
        }
        
        // If parsing fails, return original but ensure it doesn't break awkwardly
        return dateString.replacingOccurrences(of: "\n", with: " ")
    }
    
    private func formatSize(_ sizeString: String) -> String {
        // Remove any line breaks and format numbers better
        let cleaned = sizeString.replacingOccurrences(of: "\n", with: "")
        
        // If it's a large number, add commas
        if let number = Int64(cleaned.replacingOccurrences(of: ",", with: "")) {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            return formatter.string(from: NSNumber(value: number)) ?? cleaned
        }
        
        return cleaned
    }
}

struct CompactInfoField: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(2)
        }
        .frame(minWidth: 120, alignment: .leading)
    }
}

struct ServerFolderCard: View {
    let folder: DocketHubServerFolder
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.folderName)
                        .font(.headline)
                        .lineLimit(2)
                    
                    Text(folder.path.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                // Quick actions
                HStack(spacing: 8) {
                    Button(action: {
                        NSWorkspace.shared.selectFile(folder.path.path, inFileViewerRootedAtPath: "")
                    }) {
                        Image(systemName: "folder")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                    
                    Button(action: {
                        NSWorkspace.shared.open(folder.path)
                    }) {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Open Folder")
                    
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(folder.path.path, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy Path")
                }
            }
            
            Divider()
            
            // Metadata in compact horizontal layout
            HStack(spacing: 24) {
                CompactInfoField(label: "Files", value: "\(folder.fileCount)")
                
                if let folderType = folder.folderType {
                    CompactInfoField(label: "Type", value: folderType)
                }
                
                if let lastModified = folder.lastModified {
                    CompactInfoField(label: "Modified", value: formatDate(lastModified))
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(8)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - HubTab Extension

extension DocketHubView.HubTab {
    func count(for data: DocketHubData) -> Int {
        switch self {
        case .overview:
            return 0
        case .asana:
            return data.asanaTasks.count
        case .simian:
            return data.simianProjects.count
        case .server:
            return data.serverFolders.count
        case .metadata:
            return data.metadata != nil ? 1 : 0
        }
    }
}
