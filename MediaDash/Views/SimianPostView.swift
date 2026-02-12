//
//  SimianPostView.swift
//  MediaDash
//
//  Post to Simian: search projects, navigate folders, choose local folder and post.
//

import SwiftUI
import AppKit

struct SimianPostView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var sessionManager: SessionManager
    @StateObject private var simianService = SimianService()

    @State private var searchText = ""
    @State private var allProjects: [SimianProject] = []
    @State private var isLoadingProjects = false
    @State private var projectLoadError: String?
    @State private var selectedProjectId: String?
    @State private var selectedProjectName: String?

    // Folder navigation: (folderId, name); empty = project root
    @State private var folderBreadcrumb: [(id: String, name: String)] = []
    @State private var currentFolders: [SimianFolder] = []
    @State private var isLoadingFolders = false
    @State private var selectedDestinationFolderId: String? = nil // nil = project root

    @State private var localFolderURL: URL?
    @State private var docketNumber = ""
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
        if term.isEmpty { return allProjects }
        return allProjects.filter { $0.name.lowercased().contains(term) }
    }

    private var currentParentFolderId: String? {
        folderBreadcrumb.last?.id
    }

    private var destinationSummary: String {
        guard let name = selectedProjectName else { return "" }
        if folderBreadcrumb.isEmpty {
            return "\(name) (root)"
        }
        return name + " / " + folderBreadcrumb.map(\.name).joined(separator: " / ")
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if let err = projectLoadError, allProjects.isEmpty {
                unavailableView(message: err)
            } else {
                searchBarView
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
        .onAppear {
            updateSimianServiceConfiguration()
            loadProjects()
            isSearchFocused = true
        }
        .onChange(of: settingsManager.currentSettings.simianAPIBaseURL) { _, _ in
            updateSimianServiceConfiguration()
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Post to Simian")
                    .font(.title2.weight(.semibold))
                Text("Search by docket or project name, select a project and folder, then choose a local folder to post.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
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

    private var searchBarView: some View {
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
        }
        .padding()
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
                }) {
                    Label("Back to projects", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Text("→")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        Button(projectName) {
                            folderBreadcrumb = []
                            selectedDestinationFolderId = nil
                            loadFolders(projectId: projectId, parentFolderId: nil)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)

                        ForEach(Array(folderBreadcrumb.enumerated()), id: \.offset) { index, item in
                            Text(" / ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(item.name) {
                                folderBreadcrumb = Array(folderBreadcrumb.prefix(index + 1))
                                selectedDestinationFolderId = nil
                                let parentId = index == 0 ? nil : folderBreadcrumb[index - 1].id
                                loadFolders(projectId: projectId, parentFolderId: parentId)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
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
                    Text("Click a folder to open it and see subfolders; use \"Use here\" to set as upload destination.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)

                    List {
                        Button(action: {
                            selectedDestinationFolderId = nil
                        }) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
                                Text("Project root (use as destination)")
                                    .font(.system(size: 14))
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)

                        ForEach(currentFolders, id: \.id) { folder in
                            HStack {
                                Button(action: {
                                    folderBreadcrumb.append((id: folder.id, name: folder.name))
                                    selectedDestinationFolderId = folder.id
                                    loadFolders(projectId: projectId, parentFolderId: folder.id)
                                }) {
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(folder.name)
                                            .font(.system(size: 14))
                                        Spacer()
                                        Text("Open")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button("Use here") {
                                    selectedDestinationFolderId = folder.id
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
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
                if let url = localFolderURL {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(url.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change") { chooseLocalFolder() }
                            .font(.caption)
                        Button("Clear", role: .destructive) { localFolderURL = nil }
                            .font(.caption)
                    }
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Button(action: { chooseLocalFolder() }) {
                        Label("Choose local folder…", systemImage: "folder.badge.plus")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }

                TextField("Docket (optional)", text: $docketNumber)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
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
            .disabled(selectedProjectId == nil || localFolderURL == nil || isUploading)
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
                }
            } catch {
                await MainActor.run {
                    projectLoadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isLoadingProjects = false
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

    /// Recursively collect all file URLs under a directory (skips hidden and .DS_Store).
    private func collectFileURLs(in directoryURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent != ".DS_Store" else { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files.append(url)
        }
        return files
    }

    private func performPost() {
        guard let projectId = selectedProjectId,
              let folderURL = localFolderURL else { return }
        let folderId = selectedDestinationFolderId
        let fileURLs = collectFileURLs(in: folderURL)
        if fileURLs.isEmpty {
            statusMessage = "No files found in the selected folder."
            statusIsError = true
            return
        }

        isUploading = true
        statusMessage = ""
        statusIsError = false
        uploadTotal = fileURLs.count
        uploadCurrent = 0
        uploadFileName = ""

        Task {
            var uploaded = 0
            for (index, fileURL) in fileURLs.enumerated() {
                await MainActor.run {
                    uploadCurrent = index + 1
                    uploadFileName = fileURL.lastPathComponent
                }
                do {
                    _ = try await simianService.uploadFile(projectId: projectId, folderId: folderId, fileURL: fileURL)
                    uploaded += 1
                } catch {
                    await MainActor.run {
                        isUploading = false
                        statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        statusIsError = true
                    }
                    return
                }
            }
            await MainActor.run {
                isUploading = false
                statusMessage = "Uploaded \(uploaded) file(s) to \(destinationSummary)."
                statusIsError = false
            }
        }
    }
}
