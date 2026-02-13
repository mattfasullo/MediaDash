//
//  AsanaTaskDetailView.swift
//  MediaDash
//
//  Task detail sheet: description, due date, subtasks. Demos = "Demos in by" / who's submitting; Post = "Send link by" / who wrote what (with tag colour).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

enum TaskDetailKind {
    case demos
    case post
    case other
}

struct AsanaTaskDetailView: View {
    let taskGid: String
    var taskName: String?
    let asanaService: AsanaService
    let onDismiss: () -> Void
    var config: AppConfig?
    var settingsManager: SettingsManager?
    /// When provided and the opened task is Demos, used to find the linked Post task (same day + same docket/project).
    var cacheManager: AsanaCacheManager?

    @State private var task: AsanaTask?
    @State private var subtasks: [AsanaTask] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var demosDocketFolder: String = ""
    @State private var composerFolderContents: [String: [String]] = [:]
    @State private var composerInitialsPromptName: String?
    @State private var composerInitialsPromptEntered: String = ""
    @State private var editFolderNameComposer: String?
    @State private var editFolderNameEntered: String = ""
    @State private var editDisplayNameForInitialsKey: String?
    @State private var editDisplayNameForInitialsEntered: String = ""
    @State private var newFolderPromptKey: String?
    @State private var newFolderPromptName: String = ""
    @State private var promptedNewFolderKeys: Set<String> = []
    @State private var demosDropError: String?
    @State private var demosFolderMissing: Bool = false
    @State private var isEditingDemosFolderName: Bool = false
    @State private var demosFolderNameEditText: String = ""
    @State private var expandedWriterNames: Set<String> = []
    @State private var trackInUse: [String: Set<String>] = [:] // composerName -> Set of filenames
    @State private var trackColors: [String: [String: String]] = [:] // composerName -> [filename: colorName]
    // Linked Post task (sibling of Demos): show combined Demos+Post and editable posting legend
    @State private var linkedPostTask: AsanaTask?
    @State private var postTaskDescriptionWithoutLegend: String = ""
    @State private var postingLegendText: String = ""
    @State private var isSavingPostNotes: Bool = false
    @State private var postSaveError: String?
    @State private var isCreatingSubtask = false
    @State private var createSubtaskError: String?
    @State private var isAddingWriter = false
    @State private var addWriterName = ""
    @State private var addWriterFolderName = ""
    @State private var savedWriters: [(name: String, folderName: String)] = []
    @State private var isAddingNewWriter = false
    @State private var whoSubmittingDropTargeted = false
    @State private var trackColorPopoverTarget: TrackColorPopoverTarget?
    @State private var isMarkingCurrentComplete = false
    @State private var isMarkingPostComplete = false
    @State private var markCompleteError: String?
    @State private var isDescriptionCollapsed: Bool = false
    @State private var isEditingPostingLegend: Bool = false
    @State private var editableTaskDescription: String = ""
    @State private var isSavingTaskDescription: Bool = false
    @State private var taskDescriptionSaveError: String?
    private static let demosDocketUserDefaultsKeyPrefix = "mediaDash.demosTaskDocket."
    private static let demosTrackInUseKeyPrefix = "mediaDash.demosTrackInUse."
    private static let demosTrackColorKeyPrefix = "mediaDash.demosTrackColor."

    private static let dueDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var taskKind: TaskDetailKind {
        guard let name = (task?.name ?? taskName)?.lowercased() else { return .other }
        // DEMOS and SUBMIT are synonymous (task naming is inconsistent)
        if name.contains("demos") || name.contains("demo ") || name.contains("submit") { return .demos }
        if name.contains("post") { return .post }
        return .other
    }

    private var dueLabel: String {
        switch taskKind {
        case .demos: return "Demos in by"
        case .post: return "Send link by"
        case .other: return "Due"
        }
    }

    private var subtasksSectionTitle: String {
        switch taskKind {
        case .demos: return "Who's submitting"
        case .post: return "Who wrote what"
        case .other: return "Subtasks"
        }
    }

    var body: some View {
        rootContent
    }

    private var rootContent: some View {
        contentWithAlerts
            .popover(item: $trackColorPopoverTarget) { target in
                trackColorChartPopover(target: target) { name in
                    setTrackColor(composerName: target.composerName, filename: target.filename, colorName: name)
                    trackColorPopoverTarget = nil
                }
            }
    }

    private var contentWithAlerts: some View {
        contentWithPostSaveAlert
            .alert("Create subtask", isPresented: createSubtaskErrorBinding) {
                Button("OK", role: .cancel) { createSubtaskError = nil }
            } message: { createSubtaskAlertMessage() }
            .alert("Save description", isPresented: taskDescriptionSaveErrorBinding) {
                Button("OK", role: .cancel) { taskDescriptionSaveError = nil }
            } message: { taskDescriptionSaveAlertMessage() }
    }

    private var taskDescriptionSaveErrorBinding: Binding<Bool> {
        Binding(
            get: { taskDescriptionSaveError != nil },
            set: { if !$0 { taskDescriptionSaveError = nil } }
        )
    }

    private var contentWithPostSaveAlert: some View {
        contentWithLifecycle
            .alert("Post task save", isPresented: postSaveErrorBinding) {
                Button("OK", role: .cancel) { postSaveError = nil }
            } message: { postSaveAlertMessage() }
    }

    /// Lifecycle modifiers split into separate steps so the type checker doesn't time out.
    private var contentWithLifecycle: some View {
        lifecycleWithSubtasksChange
    }

    private var lifecycleWithSubtasksChange: some View {
        lifecycleWithComposerFolderChange
            .onChange(of: subtasks.map(\.gid)) { _, _ in onChangeSubtasks(subtasks) }
    }

    private var lifecycleWithComposerFolderChange: some View {
        lifecycleWithTrackColorsChange
            .onChange(of: composerFolderContents) { _, _ in onChangeComposerFolderContents() }
    }

    private var lifecycleWithTrackColorsChange: some View {
        lifecycleWithTrackInUseChange
            .onChange(of: trackColors) { _, _ in onChangeTrackColors() }
    }

    private var lifecycleWithTrackInUseChange: some View {
        lifecycleWithTaskGidChange
            .onChange(of: trackInUse) { _, _ in onChangeTrackInUse() }
    }

    private var lifecycleWithTaskGidChange: some View {
        lifecycleWithOnAppear
            .onChange(of: task?.gid) { _, _ in onChangeTaskGid() }
    }

    private var lifecycleWithOnAppear: some View {
        AnyView(mainStackWithFrame)
            .onAppear(perform: onAppearAction)
    }

    private var mainStackWithFrame: some View {
        mainStack
            .frame(minWidth: 400, minHeight: 360)
    }

    private var postSaveErrorBinding: Binding<Bool> {
        Binding(
            get: { postSaveError != nil },
            set: { if !$0 { postSaveError = nil } }
        )
    }

    private var createSubtaskErrorBinding: Binding<Bool> {
        Binding(
            get: { createSubtaskError != nil },
            set: { if !$0 { createSubtaskError = nil } }
        )
    }

    @ViewBuilder
    private func postSaveAlertMessage() -> some View {
        if let err = postSaveError { Text(err) }
    }

    @ViewBuilder
    private func createSubtaskAlertMessage() -> some View {
        if let err = createSubtaskError { Text(err) }
    }

    @ViewBuilder
    private func taskDescriptionSaveAlertMessage() -> some View {
        if let err = taskDescriptionSaveError { Text(err) }
    }

    private func onAppearAction() {
        loadTaskAndSubtasks()
        demosDocketFolder = UserDefaults.standard.string(forKey: Self.demosDocketUserDefaultsKeyPrefix + taskGid) ?? ""
        loadTrackInUseAndColors()
        refreshComposerFolderContents()
    }

    private func onChangeTaskGid() {
        if task != nil {
            demosDocketFolder = UserDefaults.standard.string(forKey: Self.demosDocketUserDefaultsKeyPrefix + taskGid) ?? ""
            refreshComposerFolderContents()
        }
    }

    private func onChangeTrackInUse() {
        if !isEditingPostingLegend { postingLegendText = computedPostingLegendString() }
    }

    private func onChangeTrackColors() {
        if !isEditingPostingLegend { postingLegendText = computedPostingLegendString() }
    }

    private func onChangeComposerFolderContents() {
        if !isEditingPostingLegend { postingLegendText = computedPostingLegendString() }
        if taskKind == .demos, newFolderPromptKey == nil {
            let set = Set(subtasks.compactMap { $0.assignee?.name ?? $0.name }.filter { !$0.isEmpty })
            let other = composerFolderContents.keys.filter { !set.contains($0) && !knownComposerNames.contains($0) }
            if let first = other.first(where: { displayNameForInitials(for: $0).isEmpty && !promptedNewFolderKeys.contains($0) }) {
                newFolderPromptKey = first
                promptedNewFolderKeys.insert(first)
            }
        }
    }

    private func onChangeSubtasks(_ new: [AsanaTask]) {
        if taskKind == .demos, !new.isEmpty, composerInitialsPromptName == nil {
            if let first = new.first(where: { composerFolderName(for: $0.assignee?.name ?? $0.name).isEmpty }) {
                let name = first.assignee?.name ?? first.name
                if !name.isEmpty { composerInitialsPromptName = name }
            }
        }
        if taskKind == .demos, !new.isEmpty {
            refreshComposerFolderContents()
        }
    }

    /// Type-erased body so the compiler doesn't time out on the conditional (loading / error / task content).
    private var mainContentBody: AnyView {
        if isLoading {
            AnyView(loadingView)
        } else if let err = loadError {
            AnyView(errorView(err))
        } else if let task = task {
            AnyView(taskLoadedContent(task: task))
        } else {
            AnyView(EmptyView())
        }
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainContentBody
        }
    }

    @ViewBuilder
    private func taskLoadedContent(task: AsanaTask) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                dueSection(task)
                if taskKind == .demos {
                    demosDocketSection
                    subtasksSection
                    demosPostingLegendSection
                    descriptionSection(task)
                    if linkedPostTask != nil {
                        postTaskSection
                    }
                } else {
                    descriptionSection(task)
                    subtasksSection
                }
            }
            .padding(20)
        }
        .sheet(isPresented: Binding(
            get: { composerInitialsPromptName != nil },
            set: { if !$0 { composerInitialsPromptName = nil; composerInitialsPromptEntered = "" } }
        )) {
            composerInitialsPromptSheet
        }
        .sheet(isPresented: Binding(
            get: { editFolderNameComposer != nil },
            set: { if !$0 { editFolderNameComposer = nil; editFolderNameEntered = "" } }
        )) {
            editFolderNameSheet
        }
        .sheet(isPresented: Binding(
            get: { editDisplayNameForInitialsKey != nil },
            set: { if !$0 { editDisplayNameForInitialsKey = nil; editDisplayNameForInitialsEntered = "" } }
        )) {
            editDisplayNameForInitialsSheet
        }
        .sheet(isPresented: Binding(
            get: { newFolderPromptKey != nil },
            set: { if !$0 { newFolderPromptKey = nil; newFolderPromptName = "" } }
        )) {
            newFolderPromptSheet
        }
        .sheet(isPresented: $isEditingDemosFolderName) {
            editDemosFolderNameSheet
        }
        .sheet(isPresented: $isAddingWriter) {
            AddWriterSheetWithSizing { addWriterSheet }
        }
        .sheet(isPresented: $isEditingPostingLegend) {
            postingLegendEditSheet
        }
        .alert("Demos drop error", isPresented: Binding(
            get: { demosDropError != nil },
            set: { if !$0 { demosDropError = nil } }
        )) {
            Button("OK", role: .cancel) { demosDropError = nil }
        } message: {
            if let err = demosDropError {
                Text(err)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(task?.name ?? taskName ?? "Task")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(2)
                    if task?.completed == true {
                        Text("Completed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer()
            if let task = task, task.completed != true {
                Button(action: markCurrentTaskComplete) {
                    if isMarkingCurrentComplete {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Text("Mark complete")
                    }
                }
                .disabled(isMarkingCurrentComplete)
                .buttonStyle(.borderedProminent)
            }
            Button("Close", action: onDismiss)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Mark complete", isPresented: Binding(
            get: { markCompleteError != nil },
            set: { if !$0 { markCompleteError = nil } }
        )) {
            Button("OK", role: .cancel) { markCompleteError = nil }
        } message: {
            if let err = markCompleteError { Text(err) }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(0.9)
            Text("Loading task...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func dueSection(_ task: AsanaTask) -> some View {
        Group {
            if let dateStr = task.effectiveDueDate, !dateStr.isEmpty {
                let formatted: String = {
                    if dateStr.count >= 10, let date = parseShortDate(String(dateStr.prefix(10))) {
                        return Self.dueDateFormatter.string(from: date)
                    }
                    return dateStr
                }()
                VStack(alignment: .leading, spacing: 4) {
                    Text(dueLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(formatted)
                        .font(.system(size: 14))
                }
            }
        }
    }

    private func descriptionSection(_ task: AsanaTask) -> some View {
        let text = effectiveDescription(from: task)
        let canEdit = taskKind == .post && task.completed != true
        return Group {
            if canEdit {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextEditor(text: $editableTaskDescription)
                        .font(.system(size: 12))
                        .frame(minHeight: 60, maxHeight: 200)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button(action: saveTaskDescription) {
                        if isSavingTaskDescription {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSavingTaskDescription)
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            } else if !text.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { !isDescriptionCollapsed },
                    set: { isDescriptionCollapsed = !$0 }
                )) {
                    Text(text)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } label: {
                    Text("Description")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
        }
    }

    private func saveTaskDescription() {
        guard taskKind == .post, let t = task else { return }
        isSavingTaskDescription = true
        Task {
            do {
                try await asanaService.updateTaskNotes(taskGid: t.gid, notes: editableTaskDescription)
                await MainActor.run {
                    isSavingTaskDescription = false
                    loadTaskAndSubtasks()
                }
            } catch {
                await MainActor.run {
                    isSavingTaskDescription = false
                    taskDescriptionSaveError = error.localizedDescription
                }
            }
        }
    }

    /// Unified POSTING LEGEND: one section, right-click to copy. Replaces separate summary + editable legend.
    private var demosPostingLegendSection: some View {
        let fullText = postingLegendText.isEmpty
            ? "POSTING LEGEND\n(No tracks in use yet)"
            : "POSTING LEGEND\n" + postingLegendText
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Posting legend")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if linkedPostTask != nil, linkedPostTask?.completed != true {
                    Button(action: saveToPostTask) {
                        if isSavingPostNotes {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Text("Push to Post task")
                        }
                    }
                    .disabled(isSavingPostNotes)
                    .buttonStyle(.borderedProminent)
                    .help("Save description and posting legend to the linked Post task in Asana")
                }
            }
            Text(fullText)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contextMenu {
                    Button("Copy") {
                        copyPostingLegendToPasteboard()
                    }
                    Button("Edit legend…") {
                        isEditingPostingLegend = true
                    }
                }
        }
    }

    private var demosDocketSection: some View {
        Group {
            if config != nil, settingsManager != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Docket folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Text(demosDocketFolder.isEmpty ? "Not set" : demosDocketFolder)
                            .font(.system(size: 13))
                            .foregroundColor(demosDocketFolder.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .contextMenu {
                                Button("Edit folder name…") {
                                    isEditingDemosFolderName = true
                                }
                            }
                        Button("Choose in Finder…") {
                            browseForDemosDocketFolder()
                        }
                        .buttonStyle(.bordered)
                        .help("Select the docket folder under Music Demos")
                    }
                    if demosFolderMissing {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Folder not found on server.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Button("Create folder") {
                                createDemosFolder()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("Folder under Music Demos for this task. Right-click to edit name. Set automatically from Asana when possible.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Sheet for editing the posting legend (opened via context menu).
    private var postingLegendEditSheet: some View {
        VStack(spacing: 12) {
            Text("Edit posting legend")
                .font(.headline)
            TextEditor(text: $postingLegendText)
                .font(.system(size: 11))
                .frame(minWidth: 360, minHeight: 120, maxHeight: 200)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy") {
                    copyPostingLegendToPasteboard()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Done") {
                    isEditingPostingLegend = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400, height: 280)
    }

    /// Post task card: name, description, Mark complete. Shown only when a linked Post task exists.
    private var postTaskSection: some View {
        Group {
            if let post = linkedPostTask {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Post task")
                            .font(.system(size: 12, weight: .bold))
                            .underline()
                        if post.completed == true {
                            Text("Completed")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        if post.completed != true {
                            Button(action: markPostTaskComplete) {
                                if isMarkingPostComplete {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    Text("Mark complete")
                                }
                            }
                            .disabled(isMarkingPostComplete)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    Text(post.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text("Description")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    TextEditor(text: $postTaskDescriptionWithoutLegend)
                        .font(.system(size: 12))
                        .frame(minHeight: 60, maxHeight: 200)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button(action: saveToPostTask) {
                        if isSavingPostNotes {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("Save description")
                        }
                    }
                    .disabled(isSavingPostNotes)
                    .buttonStyle(.borderedProminent)
                    .help("Save description and posting legend to the Post task in Asana")
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func saveToPostTask() {
        guard let post = linkedPostTask else { return }
        let fullNotes = postTaskDescriptionWithoutLegend.isEmpty
            ? "POSTING LEGEND\n" + postingLegendText
            : postTaskDescriptionWithoutLegend + "\n\nPOSTING LEGEND\n" + postingLegendText
        isSavingPostNotes = true
        postSaveError = nil
        Task {
            do {
                try await asanaService.updateTaskNotes(taskGid: post.gid, notes: fullNotes)
                await MainActor.run {
                    isSavingPostNotes = false
                    postTaskDescriptionWithoutLegend = postTaskDescriptionWithoutLegend.isEmpty ? "" : postTaskDescriptionWithoutLegend
                }
            } catch {
                await MainActor.run {
                    isSavingPostNotes = false
                    postSaveError = error.localizedDescription
                }
            }
        }
    }

    /// Copy Posting Legend to the clipboard (same format as saved: header + lines).
    private func copyPostingLegendToPasteboard() {
        let text = "POSTING LEGEND\n" + postingLegendText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func markCurrentTaskComplete() {
        isMarkingCurrentComplete = true
        markCompleteError = nil
        Task {
            do {
                try await asanaService.updateTaskCompleted(taskGid: taskGid, completed: true)
                await MainActor.run {
                    isMarkingCurrentComplete = false
                    loadTaskAndSubtasks()
                }
            } catch {
                await MainActor.run {
                    isMarkingCurrentComplete = false
                    markCompleteError = error.localizedDescription
                }
            }
        }
    }

    private func markPostTaskComplete() {
        guard let post = linkedPostTask else { return }
        isMarkingPostComplete = true
        markCompleteError = nil
        Task {
            do {
                try await asanaService.updateTaskCompleted(taskGid: post.gid, completed: true)
                await MainActor.run {
                    isMarkingPostComplete = false
                    loadTaskAndSubtasks()
                }
            } catch {
                await MainActor.run {
                    isMarkingPostComplete = false
                    markCompleteError = error.localizedDescription
                }
            }
        }
    }

    private var composerInitialsPromptSheet: some View {
        VStack(spacing: 16) {
            Text("Composer folder name")
                .font(.headline)
            if let name = composerInitialsPromptName {
                Text("Enter initials or nickname for \"\(name)\" (used as their demos folder name).")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            TextField("Initials or nickname", text: $composerInitialsPromptEntered)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            HStack(spacing: 12) {
                Button("Cancel") {
                    composerInitialsPromptName = nil
                    composerInitialsPromptEntered = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if !composerInitialsPromptEntered.isEmpty, let name = composerInitialsPromptName {
                        saveComposerInitials(name: name, initials: composerInitialsPromptEntered)
                    }
                    composerInitialsPromptName = nil
                    composerInitialsPromptEntered = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private var editFolderNameSheet: some View {
        VStack(spacing: 16) {
            Text("Edit folder initials")
                .font(.headline)
            if let name = editFolderNameComposer {
                Text("Folder/initials for \"\(name)\" (used in Music Demos and POSTING LEGEND).")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            TextField("Folder name or initials", text: $editFolderNameEntered)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            HStack(spacing: 12) {
                Button("Cancel") {
                    editFolderNameComposer = nil
                    editFolderNameEntered = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let name = editFolderNameComposer {
                        saveComposerInitials(name: name, initials: editFolderNameEntered)
                    }
                    editFolderNameComposer = nil
                    editFolderNameEntered = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private var addWriterSheet: some View {
        VStack(spacing: 16) {
            Text("Add writer")
                .font(.title2)
            if isAddingNewWriter {
                addNewWriterForm
            } else {
                savedWritersList
                Divider()
                Button("Add new writer…") {
                    addWriterName = ""
                    addWriterFolderName = ""
                    isAddingNewWriter = true
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    isAddingWriter = false
                    isAddingNewWriter = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: isAddingNewWriter ? 260 : 380)
        .onAppear { loadSavedWriters() }
        .onChange(of: isAddingNewWriter) { _, showingForm in
            if !showingForm { loadSavedWriters() }
        }
    }

    private var savedWritersList: some View {
        let currentNames = Set(subtasks.compactMap { $0.assignee?.name ?? $0.name }.filter { !$0.isEmpty })
        let available = savedWriters.filter { !currentNames.contains($0.name) }
        let allAlreadyAdded = !savedWriters.isEmpty && available.isEmpty
        return Group {
            if available.isEmpty {
                VStack(spacing: 12) {
                    if allAlreadyAdded {
                        Text("All saved writers are already added to this task.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No saved writers yet.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Writers are saved from Settings (Composer initials) or when you add a new writer below. Add one now, or open Settings to configure composer→folder mappings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        if settingsManager != nil {
                            HStack(spacing: 12) {
                                Button("Open Settings") {
                                    Foundation.NotificationCenter.default.post(name: Foundation.Notification.Name("OpenSettings"), object: nil)
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Refresh") {
                                    loadSavedWriters()
                                }
                                .buttonStyle(.bordered)
                                .help("Reload writers after adding them in Settings")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(available, id: \.name) { writer in
                            Button {
                                Task { await addWriterSubtask(name: writer.name, folderName: writer.folderName) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(writer.name)
                                            .font(.body)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        Text("Folder: \(writer.folderName)")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.accentColor)
                                }
                                .padding(12)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private var addNewWriterForm: some View {
        VStack(spacing: 16) {
            Text("Enter name and folder initials/nickname for the new writer.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            TextField("Writer name", text: $addWriterName)
                .textFieldStyle(.roundedBorder)
            TextField("Folder name (initials or nickname)", text: $addWriterFolderName)
                .textFieldStyle(.roundedBorder)
                .help("e.g. IC, JM, or Goldie")
            HStack(spacing: 12) {
                Button("Back") {
                    isAddingNewWriter = false
                }
                Button("Add") {
                    Task { await addWriterSubtask(name: addWriterName.trimmingCharacters(in: .whitespaces), folderName: addWriterFolderName.trimmingCharacters(in: .whitespaces)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addWriterName.trimmingCharacters(in: .whitespaces).isEmpty || addWriterFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func loadSavedWriters() {
        var fromServer: [(name: String, folderName: String)] = []
        if let config = config {
            fromServer = config.loadWritersFromServer()
        }
        if fromServer.isEmpty {
            var seen = Set<String>()
            let defaults = AppSettings.defaultComposerInitials
            let custom = settingsManager?.currentSettings.composerInitials ?? [:]
            let display = (settingsManager?.currentSettings.displayNameForInitials ?? [:])
                .merging(AppSettings.defaultDisplayNameForInitials) { _, preset in preset }
            let effectiveInitials = defaults.merging(custom) { _, user in user }
            for (name, folder) in effectiveInitials where !name.isEmpty && !folder.isEmpty && !seen.contains(name.lowercased()) {
                fromServer.append((name, folder))
                seen.insert(name.lowercased())
            }
            for (folder, name) in display where !folder.isEmpty && !name.isEmpty && !seen.contains(name.lowercased()) {
                fromServer.append((name, folder))
                seen.insert(name.lowercased())
            }
            if !fromServer.isEmpty, let config = config {
                for w in fromServer { config.saveWriterToServer(name: w.name, folderName: w.folderName) }
            }
        }
        savedWriters = fromServer.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var editDemosFolderNameSheet: some View {
        VStack(spacing: 16) {
            Text("Edit docket folder name")
                .font(.headline)
            Text("Folder under Music Demos (e.g. 26014_Coors).")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            TextField("e.g. 26014_Coors", text: $demosFolderNameEditText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack(spacing: 12) {
                Button("Cancel") {
                    isEditingDemosFolderName = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = demosFolderNameEditText.trimmingCharacters(in: .whitespaces)
                    demosDocketFolder = trimmed
                    UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: Self.demosDocketUserDefaultsKeyPrefix + taskGid)
                    refreshComposerFolderContents()
                    isEditingDemosFolderName = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear {
            demosFolderNameEditText = demosDocketFolder
        }
    }

    private var editDisplayNameForInitialsSheet: some View {
        VStack(spacing: 16) {
            Text("Edit display name")
                .font(.headline)
            if let initials = editDisplayNameForInitialsKey {
                Text("Display name for \"\(initials)\" (used as row title and when creating Asana subtasks).")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            TextField("Name", text: $editDisplayNameForInitialsEntered)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack(spacing: 12) {
                Button("Cancel") {
                    editDisplayNameForInitialsKey = nil
                    editDisplayNameForInitialsEntered = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let key = editDisplayNameForInitialsKey {
                        saveDisplayNameForInitials(initials: key, name: editDisplayNameForInitialsEntered)
                    }
                    editDisplayNameForInitialsKey = nil
                    editDisplayNameForInitialsEntered = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private var newFolderPromptSheet: some View {
        VStack(spacing: 16) {
            Text("New folder – save for future")
                .font(.headline)
            if let key = newFolderPromptKey {
                Text("Folder \"\(key)\" isn’t in your saved list. Enter the composer name to store so it links automatically next time.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            TextField("Composer name", text: $newFolderPromptName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack(spacing: 12) {
                Button("Skip") {
                    newFolderPromptKey = nil
                    newFolderPromptName = ""
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let key = newFolderPromptKey, !newFolderPromptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let name = newFolderPromptName.trimmingCharacters(in: .whitespacesAndNewlines)
                        saveDisplayNameForInitials(initials: key, name: name)
                        saveComposerInitials(name: name, initials: key)
                        promptedNewFolderKeys.remove(key)
                    }
                    newFolderPromptKey = nil
                    newFolderPromptName = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private var subtasksSection: some View {
        Group {
            if taskKind == .demos, config != nil, settingsManager != nil, !demosDocketFolder.isEmpty {
                let subtaskComposerNames = Set(subtasks.compactMap { $0.assignee?.name ?? $0.name }.filter { !$0.isEmpty })
                let knownFolderOnlyKeys = composerFolderContents.keys.filter { knownComposerNames.contains($0) && !subtaskComposerNames.contains($0) }.sorted()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(subtasksSectionTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Add writer…") {
                            addWriterName = ""
                            isAddingWriter = true
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    }
                    if taskKind == .demos, !writersNeedingInitials.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("\(writersNeedingInitials.count) writer(s) need initials set before folders can be created: \(writersNeedingInitials.joined(separator: ", ")).")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(spacing: 4) {
                        ForEach(subtasks, id: \.gid) { st in
                            subtaskRow(st)
                        }
                        ForEach(knownFolderOnlyKeys, id: \.self) { key in
                            demosKnownFolderRow(composerName: key)
                        }
                    }
                    .frame(minHeight: 20)
                    .onDrop(of: [.plainText], isTargeted: $whoSubmittingDropTargeted) { providers in
                        guard let provider = providers.first else { return false }
                        _ = provider.loadTransferable(type: String.self) { result in
                            switch result {
                            case .success(let string):
                                let prefix = "mediadash.otherfolder:"
                                guard string.hasPrefix(prefix), string.count > prefix.count else { return }
                                let folderKey = String(string.dropFirst(prefix.count))
                                if !folderKey.isEmpty { Task { await createSubtaskFromOtherFolder(folderKey) } }
                            case .failure:
                                break
                            }
                        }
                        return true
                    }
                    .background(whoSubmittingDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                    .animation(.easeInOut(duration: 0.15), value: whoSubmittingDropTargeted)
                    if subtasks.isEmpty && knownFolderOnlyKeys.isEmpty {
                        Text("Drop a composer from Other folders to add as Asana subtask")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
            } else if !subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(subtasksSectionTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    VStack(spacing: 4) {
                        ForEach(subtasks, id: \.gid) { st in
                            subtaskRow(st)
                        }
                    }
                }
            }
            if taskKind == .demos, config != nil, settingsManager != nil, !demosDocketFolder.isEmpty {
                let subtaskComposerNamesSet = Set(subtasks.compactMap { $0.assignee?.name ?? $0.name }.filter { !$0.isEmpty })
                let otherKeys = composerFolderContents.keys.filter { !subtaskComposerNamesSet.contains($0) && !knownComposerNames.contains($0) }.sorted()
                if !otherKeys.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Other folders (from Finder)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        VStack(spacing: 4) {
                            ForEach(otherKeys, id: \.self) { folderKey in
                                demosFolderOnlyRow(folderKey: folderKey)
                            }
                        }
                    }
                }
            }
        }
    }

    private func subtaskRow(_ st: AsanaTask) -> some View {
        let color = Self.asanaColorToSwiftUI(st.tags?.first?.color)
        let showColor = (taskKind == .post && st.tags?.first?.color != nil)
        let composerName = st.assignee?.name ?? st.name
        let isDemosWithDemos = taskKind == .demos && config != nil && settingsManager != nil && !demosDocketFolder.isEmpty

        return Group {
            if isDemosWithDemos {
                demosSubtaskRow(st, composerName: composerName, color: color)
            } else {
                plainSubtaskRow(st, showColor: showColor, color: color)
            }
        }
    }

    private func plainSubtaskRow(_ st: AsanaTask, showColor: Bool, color: Color) -> some View {
        HStack {
            if showColor {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(st.name)
                    .font(.system(size: 12, weight: .medium))
                if let assignee = st.assignee?.name, !assignee.isEmpty {
                    Text(assignee)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(showColor ? color.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func demosSubtaskRow(_ st: AsanaTask, composerName: String, color: Color) -> some View {
        let folderName = composerFolderName(for: composerName)
        let displayName = displayNameForInitials(for: folderName)
        let rowTitle = !displayName.isEmpty ? displayName : (!composerName.isEmpty ? composerName : st.name)
        let files = composerFolderContents[composerName] ?? []
        let isExpanded = expandedWriterNames.contains(composerName)
        let writerRow = HStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.6))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.system(size: 12, weight: .medium))
                if !composerName.isEmpty, composerName != st.name, composerName != rowTitle {
                    Text(composerName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                if !folderName.isEmpty {
                    Text("Folder: \(folderName)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else if !composerName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text("Needs initials")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Button("Set…") {
                            composerInitialsPromptName = composerName
                            composerInitialsPromptEntered = ""
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                    }
                }
            }
            Spacer()
            if !files.isEmpty {
                HStack(spacing: 3) {
                    ForEach(files, id: \.self) { filename in
                        Circle()
                            .fill(colorForTrackColorName(trackColor(composerName: composerName, filename: filename)))
                            .frame(width: 8, height: 8)
                    }
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Button("Add files…") {
                addFilesViaFinder(composerName: composerName)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit folder initials…") {
                editFolderNameComposer = composerName
                editFolderNameEntered = composerFolderName(for: composerName)
            }
            .help("Folder shorthand used in Music Demos path (e.g. JS, IC)")
            if !folderName.isEmpty {
                Button("Edit display name…") {
                    editDisplayNameForInitialsKey = folderName
                    editDisplayNameForInitialsEntered = displayNameForInitials(for: folderName)
                }
                .help("Name shown as row title and when creating Asana subtasks")
            }
        }
        .onDrop(of: [.fileURL, .audio], isTargeted: nil) { providers in
            handleDrop(providers: providers, composerName: composerName, folderNameOverride: nil)
        }

        if files.isEmpty {
            writerRow
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded { expandedWriterNames.remove(composerName) } else { expandedWriterNames.insert(composerName) }
                    }
                } label: {
                    writerRow
                }
                .buttonStyle(.plain)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(files, id: \.self) { filename in
                            HStack(spacing: 8) {
                                Toggle(isOn: Binding(
                                    get: { isTrackInUse(composerName: composerName, filename: filename) },
                                    set: { setTrackInUse(composerName: composerName, filename: filename, inUse: $0) }
                                )) {
                                    Text(filename)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .toggleStyle(.checkbox)
                                Button {
                                    trackColorPopoverTarget = TrackColorPopoverTarget(composerName: composerName, filename: filename)
                                } label: {
                                    Circle()
                                        .fill(colorForTrackColorName(trackColor(composerName: composerName, filename: filename)))
                                        .frame(width: 14, height: 14)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                            }
                            .padding(.vertical, 2)
                            .padding(.leading, 8)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.leading, 4)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    
    private func colorForTrackColorName(_ name: String) -> Color {
        guard !name.isEmpty else { return .gray }
        let lower = name.lowercased()
        return Self.trackColorOptions.first(where: { $0.name.lowercased() == lower })?.color ?? .gray
    }

    /// Track colour popover laid out like the spreadsheet: Composers (Composer | Colour 1–5) then Freelance/Extra (rows of Colour 1–5).
    @ViewBuilder
    private func trackColorChartPopover(target: TrackColorPopoverTarget, onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { onSelect("") }) {
                HStack(spacing: 6) {
                    Circle().fill(Color.gray).frame(width: 12, height: 12)
                    Text("— Unassigned")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    // Composers section: header + rows (Composer | Colour 1 … Colour 5)
                    Text("Composers")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    trackColorTableHeader(showComposerColumn: true)
                    ForEach(Array(Self.trackColorComposerRows.enumerated()), id: \.offset) { _, row in
                        trackColorTableRow(composerName: row.composerName, colourNames: row.colourNames, onSelect: onSelect)
                    }
                    Divider()
                        .padding(.vertical, 4)
                    // Freelance/Extra section: header + rows (Colour 1 … Colour 5)
                    Text("Freelance/Extra")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    trackColorTableHeader(showComposerColumn: false)
                    ForEach(Array(Self.trackColorFreelanceRows.enumerated()), id: \.offset) { _, colourNames in
                        trackColorTableRow(composerName: nil, colourNames: colourNames, onSelect: onSelect)
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(12)
        .frame(minWidth: 320)
    }

    private func trackColorTableHeader(showComposerColumn: Bool) -> some View {
        HStack(spacing: 6) {
            Text(showComposerColumn ? "Composer" : "Freelance/Extra")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            ForEach(1...5, id: \.self) { n in
                Text("Colour \(n)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(Color.yellow.opacity(0.2))
    }

    private func trackColorTableRow(composerName: String?, colourNames: [String], onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            if let name = composerName {
                Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)
            } else {
                Color.clear
                    .frame(width: 100)
            }
            ForEach(colourNames, id: \.self) { colourName in
                Button(action: { onSelect(colourName) }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(colorForTrackColorName(colourName))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                        Text(colourName)
                            .font(.system(size: 10))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            // Pad if fewer than 5 colours in row
            ForEach(0..<max(0, 5 - colourNames.count), id: \.self) { _ in
                Color.clear
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
    }

    /// Row for a folder that is keyed by a known composer name (saved initials link); no Asana subtask.
    @ViewBuilder
    private func demosKnownFolderRow(composerName: String) -> some View {
        let folderName = initialsForComposerName(composerName)
        let files = composerFolderContents[composerName] ?? []
        let isExpanded = expandedWriterNames.contains(composerName)
        let writerRow = HStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue.opacity(0.6))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(composerName)
                    .font(.system(size: 12, weight: .medium))
                if !folderName.isEmpty {
                    Text("Folder: \(folderName)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if !files.isEmpty {
                HStack(spacing: 3) {
                    ForEach(files, id: \.self) { filename in
                        Circle()
                            .fill(colorForTrackColorName(trackColor(composerName: composerName, filename: filename)))
                            .frame(width: 8, height: 8)
                    }
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Button("Add files…") {
                addFilesViaFinder(composerName: composerName, folderNameOverride: folderName.isEmpty ? nil : folderName)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit folder initials…") {
                editFolderNameComposer = composerName
                editFolderNameEntered = folderName
            }
            .help("Folder shorthand used in Music Demos path (e.g. JS, IC)")
            Button("Edit display name…") {
                editDisplayNameForInitialsKey = folderName
                editDisplayNameForInitialsEntered = composerName
            }
            .help("Name shown as row title and when creating Asana subtasks")
        }
        .onDrop(of: [.fileURL, .audio], isTargeted: nil) { providers in
            handleDrop(providers: providers, composerName: composerName, folderNameOverride: folderName.isEmpty ? nil : folderName)
        }
        if files.isEmpty {
            writerRow
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded { expandedWriterNames.remove(composerName) } else { expandedWriterNames.insert(composerName) }
                    }
                } label: {
                    writerRow
                }
                .buttonStyle(.plain)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(files, id: \.self) { filename in
                            HStack(spacing: 8) {
                                Toggle(isOn: Binding(
                                    get: { isTrackInUse(composerName: composerName, filename: filename) },
                                    set: { setTrackInUse(composerName: composerName, filename: filename, inUse: $0, folderNameOverride: folderName.isEmpty ? nil : folderName) }
                                )) {
                                    Text(filename)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .toggleStyle(.checkbox)
                                Button {
                                    trackColorPopoverTarget = TrackColorPopoverTarget(composerName: composerName, filename: filename)
                                } label: {
                                    Circle()
                                        .fill(colorForTrackColorName(trackColor(composerName: composerName, filename: filename)))
                                        .frame(width: 14, height: 14)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                            }
                            .padding(.vertical, 2)
                            .padding(.leading, 8)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.leading, 4)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Row for a writer folder that exists on disk but doesn't match a subtask (e.g. created manually in Finder).
    @ViewBuilder
    private func demosFolderOnlyRow(folderKey: String) -> some View {
        let displayName = displayNameForInitials(for: folderKey)
        let rowTitle = !displayName.isEmpty ? displayName : folderKey
        let files = composerFolderContents[folderKey] ?? []
        let isExpanded = expandedWriterNames.contains(folderKey)
        let writerRow = HStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.gray.opacity(0.6))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(rowTitle)
                    .font(.system(size: 12, weight: .medium))
                Text("Folder: \(folderKey)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !files.isEmpty {
                HStack(spacing: 3) {
                    ForEach(files, id: \.self) { filename in
                        Circle()
                            .fill(colorForTrackColorName(trackColor(composerName: folderKey, filename: filename)))
                            .frame(width: 8, height: 8)
                    }
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Button("Add files…") {
                addFilesViaFinder(composerName: folderKey, folderNameOverride: folderKey)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit folder initials…") {
                editFolderNameComposer = folderKey
                editFolderNameEntered = composerFolderName(for: folderKey).isEmpty ? folderKey : composerFolderName(for: folderKey)
            }
            .help("Folder shorthand used in Music Demos path (e.g. JS, IC)")
            Button("Edit display name…") {
                editDisplayNameForInitialsKey = folderKey
                editDisplayNameForInitialsEntered = displayNameForInitials(for: folderKey)
            }
            .help("Name shown as row title and when creating Asana subtasks")
        }
        .onDrop(of: [.fileURL, .audio], isTargeted: nil) { providers in
            handleDrop(providers: providers, composerName: folderKey, folderNameOverride: folderKey)
        }
        if files.isEmpty {
            writerRow
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .draggable(OtherFolderDragPayload.dragString(for: folderKey))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded { expandedWriterNames.remove(folderKey) } else { expandedWriterNames.insert(folderKey) }
                    }
                } label: {
                    writerRow
                }
                .buttonStyle(.plain)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(files, id: \.self) { filename in
                            HStack(spacing: 8) {
                                Toggle(isOn: Binding(
                                    get: { isTrackInUse(composerName: folderKey, filename: filename) },
                                    set: { setTrackInUse(composerName: folderKey, filename: filename, inUse: $0, folderNameOverride: folderKey) }
                                )) {
                                    Text(filename)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .toggleStyle(.checkbox)
                                Button {
                                    trackColorPopoverTarget = TrackColorPopoverTarget(composerName: folderKey, filename: filename)
                                } label: {
                                    Circle()
                                        .fill(colorForTrackColorName(trackColor(composerName: folderKey, filename: filename)))
                                        .frame(width: 14, height: 14)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                            }
                            .padding(.vertical, 2)
                            .padding(.leading, 8)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.leading, 4)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .draggable(OtherFolderDragPayload.dragString(for: folderKey))
        }
    }

    private static func asanaColorToSwiftUI(_ colorName: String?) -> Color {
        guard let name = colorName?.lowercased() else { return .blue }
        switch name {
        case "dark-pink", "hot-pink", "light-pink": return .pink
        case "dark-red", "red", "light-red": return .red
        case "dark-orange", "orange", "light-orange": return .orange
        case "dark-warm-gray", "warm-gray", "light-warm-gray": return Color(red: 0.6, green: 0.5, blue: 0.4)
        case "yellow", "light-yellow": return .yellow
        case "dark-green", "green", "light-green": return .green
        case "lime": return Color(red: 0.5, green: 0.8, blue: 0.3)
        case "dark-teal", "teal", "light-teal", "aqua": return .teal
        case "dark-blue", "blue", "light-blue": return .blue
        case "dark-purple", "purple", "light-purple", "fuchsia": return .purple
        case "dark-brown", "light-brown": return .brown
        case "cool-gray", "light-gray": return .gray
        default: return .blue
        }
    }

    private func effectiveDescription(from task: AsanaTask) -> String {
        if let notes = task.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return notes
        }
        if let html = task.html_notes, !html.isEmpty {
            return stripHTMLFromAsana(html)
        }
        return ""
    }

    private func stripHTMLFromAsana(_ html: String) -> String {
        var text = html
        if let scriptRegex = try? NSRegularExpression(pattern: #"<script[^>]*>.*?</script>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = scriptRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        if let styleRegex = try? NSRegularExpression(pattern: #"<style[^>]*>.*?</style>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            text = styleRegex.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseShortDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.date(from: s)
    }

    private func loadTaskAndSubtasks() {
        isLoading = true
        loadError = nil
        linkedPostTask = nil
        postTaskDescriptionWithoutLegend = ""
        postingLegendText = ""
        let cfg = config
        let sm = settingsManager
        let cache = cacheManager
        Task {
            do {
                async let taskResult = asanaService.fetchTask(taskGid: taskGid)
                async let subtasksResult = asanaService.fetchSubtasks(taskGid: taskGid)
                let (t, st) = try await (taskResult, subtasksResult)
                let isPost = t.name.lowercased().contains("post")
                await MainActor.run {
                    task = t
                    subtasks = st
                    isLoading = false
                    refreshComposerFolderContents()
                    if isPost {
                        editableTaskDescription = effectiveDescription(from: t)
                    } else {
                        editableTaskDescription = ""
                    }
                }
                let isDemos = (t.name.lowercased().contains("demos") || t.name.lowercased().contains("demo ") || t.name.lowercased().contains("submit"))
                // Resolve linked Post task (uses DemosPostLinkStore for manual overrides)
                if isDemos, let cache = await MainActor.run(body: { cache }) {
                    let demosDue = String((t.effectiveDueDate ?? "").prefix(10))
                    let candidates = await MainActor.run { cache.cachedTasksTwoWeeks }
                    let sameDay = candidates.filter { ($0.effectiveDueDate ?? "").prefix(10) == demosDue }
                    let postTasks = sameDay.filter { $0.name.lowercased().contains("post") }
                    if let postTask = DemosPostLinkStore.resolveLinkedPost(demos: t, sameDayPosts: postTasks) {
                        let fullPost = try? await asanaService.fetchTask(taskGid: postTask.gid)
                        if let full = fullPost {
                            let (descWithoutLegend, legendPart) = Self.parsePostNotesForLegend(full.notes ?? full.html_notes ?? "")
                            await MainActor.run {
                                linkedPostTask = full
                                postTaskDescriptionWithoutLegend = descWithoutLegend
                                postingLegendText = legendPart.isEmpty ? computedPostingLegendString() : legendPart
                            }
                        } else {
                            await MainActor.run {
                                linkedPostTask = postTask
                                postTaskDescriptionWithoutLegend = effectiveDescription(from: postTask)
                                postingLegendText = computedPostingLegendString()
                            }
                        }
                    }
                }
                // Auto-fill docket folder for Demos tasks when not already set (from Asana project/parent/custom fields/name)
                if isDemos, let cfg = cfg, sm != nil {
                    let currentFolder = await MainActor.run { demosDocketFolder }
                    guard currentFolder.isEmpty else { return }
                    if let resolved = try? await asanaService.resolveDocketFolder(
                        for: t,
                        docketField: sm?.currentSettings.asanaDocketField,
                        jobNameField: sm?.currentSettings.asanaJobNameField
                    ) {
                        // Create the {docket}_{jobName} folder under Music Demos if it doesn't exist
                        let year = t.effectiveDueDate.flatMap { parseShortDate(String($0.prefix(10))) }
                            .map { Calendar.current.component(.year, from: $0) }
                            ?? Calendar.current.component(.year, from: Date())
                        try? cfg.ensureMusicDemosDocketFolder(docketFolderName: resolved, forYear: year)
                        await MainActor.run {
                            demosDocketFolder = resolved
                            UserDefaults.standard.set(resolved, forKey: Self.demosDocketUserDefaultsKeyPrefix + taskGid)
                            refreshComposerFolderContents()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    /// Splits task notes into description (before POSTING LEGEND) and the legend lines. Case-insensitive "POSTING LEGEND" header.
    private static func parsePostNotesForLegend(_ notes: String) -> (descriptionWithoutLegend: String, legendLines: String) {
        guard let range = notes.range(of: "POSTING LEGEND", options: .caseInsensitive) else {
            return (notes.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let desc = String(notes[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let afterHeader = String(notes[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let firstNewline = afterHeader.firstIndex(of: "\n")
        let legendStart = firstNewline.map { afterHeader.index(after: $0) } ?? afterHeader.startIndex
        let legend = String(afterHeader[legendStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (desc, legend)
    }

    /// One line per in-use track: "COLOUR - INITIALS - FILENAME" (same format as POSTING LEGEND).
    private func computedPostingLegendString() -> String {
        var lines: [String] = []
        for key in composerFolderContents.keys.sorted() {
            guard let inUse = trackInUse[key], !inUse.isEmpty else { continue }
            let initials = composerFolderName(for: key).isEmpty ? key : composerFolderName(for: key)
            for filename in inUse.sorted() {
                let colorName = trackColor(composerName: key, filename: filename)
                let colorLabel = colorName.isEmpty ? "—" : colorName.uppercased()
                lines.append("\(colorLabel) - \(initials.uppercased()) - \(filename)")
            }
        }
        return lines.joined(separator: "\n")
    }
    
    private func createDemosFolder() {
        guard let config = config, !demosDocketFolder.isEmpty, let t = task else { return }
        let dueDate = t.effectiveDueDate.flatMap { parseShortDate(String($0.prefix(10))) } ?? Date()
        _ = try? config.getOrCreateDemosDateFolder(docketFolderName: demosDocketFolder, date: dueDate)
        refreshComposerFolderContents()
    }

    private func browseForDemosDocketFolder() {
        guard let config = config else { return }
        let year = task?.effectiveDueDate.flatMap { parseShortDate(String($0.prefix(10))) }
            .map { Calendar.current.component(.year, from: $0) }
            ?? Calendar.current.component(.year, from: Date())
        let musicDemosRoot = config.getMusicDemosRoot(for: year)
        let panel = NSOpenPanel()
        panel.title = "Choose Docket Folder"
        panel.message = "Select the docket folder under Music Demos (e.g. 26014_Coors)."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = musicDemosRoot
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rootPath = musicDemosRoot.path
        let selectedPath = url.path
        guard selectedPath.hasPrefix(rootPath) else { return }
        let suffix = String(selectedPath.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let firstComponent = suffix.split(separator: "/").first.map(String.init)
        let folderName = firstComponent ?? suffix
        guard !folderName.isEmpty else { return }
        demosDocketFolder = folderName
        UserDefaults.standard.set(folderName, forKey: Self.demosDocketUserDefaultsKeyPrefix + taskGid)
        refreshComposerFolderContents()
    }

    /// Folder name for this writer. Uses Settings (custom) then built-in preset; if not found, returns "" so the app will prompt for initials.
    private func composerFolderName(for composerName: String) -> String {
        guard !composerName.isEmpty else { return "" }
        let custom = settingsManager?.currentSettings.composerInitials ?? [:]
        let effective = AppSettings.defaultComposerInitials.merging(custom) { _, user in user }
        return effective[composerName] ?? ""
    }

    /// Display name for a folder/initials (e.g. "Goldie" → "Michael Goldchain"). Used as row title and for new subtask names.
    private func displayNameForInitials(for initials: String) -> String {
        guard !initials.isEmpty else { return "" }
        let custom = settingsManager?.currentSettings.displayNameForInitials ?? [:]
        let effective = AppSettings.defaultDisplayNameForInitials.merging(custom) { _, user in user }
        return effective[initials] ?? ""
    }

    /// Initials/folder name for a composer display name (reverse lookup). Used for "Folder: X" label on known rows.
    private func initialsForComposerName(_ name: String) -> String {
        if !name.isEmpty, !composerFolderName(for: name).isEmpty { return composerFolderName(for: name) }
        let custom = settingsManager?.currentSettings.displayNameForInitials ?? [:]
        let effective = AppSettings.defaultDisplayNameForInitials.merging(custom) { _, user in user }
        return effective.first(where: { $0.value == name })?.key ?? ""
    }

    /// Set of names we treat as "known" composers (have initials or are a display name for some initial). Used to link folders and avoid duplicate Other rows.
    /// Subtask writers (assignee name or task name) that don't have initials/nickname set yet.
    private var writersNeedingInitials: [String] {
        guard taskKind == .demos else { return [] }
        return subtasks
            .compactMap { $0.assignee?.name ?? $0.name }
            .filter { !$0.isEmpty && composerFolderName(for: $0).isEmpty }
    }

    private var knownComposerNames: Set<String> {
        let fromInitials = settingsManager?.currentSettings.composerInitials ?? [:]
        let fromDisplay = settingsManager?.currentSettings.displayNameForInitials ?? [:]
        let effectiveInitials = AppSettings.defaultComposerInitials.merging(fromInitials) { _, user in user }
        let effectiveDisplay = AppSettings.defaultDisplayNameForInitials.merging(fromDisplay) { _, user in user }
        return Set(effectiveInitials.keys).union(Set(effectiveDisplay.values))
    }

    private func saveComposerInitials(name: String, initials: String) {
        guard let sm = settingsManager else { return }
        config?.saveWriterToServer(name: name, folderName: initials)
        var settings = sm.currentSettings
        var map = settings.composerInitials ?? [:]
        map[name] = initials
        settings.composerInitials = map.isEmpty ? nil : map
        sm.currentSettings = settings
        sm.saveCurrentProfile()
        refreshComposerFolderContents()
    }

    private func saveDisplayNameForInitials(initials: String, name: String) {
        guard let sm = settingsManager else { return }
        var settings = sm.currentSettings
        var map = settings.displayNameForInitials ?? [:]
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            map.removeValue(forKey: initials)
        } else {
            map[initials] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        settings.displayNameForInitials = map.isEmpty ? nil : map
        sm.currentSettings = settings
        sm.saveCurrentProfile()
    }

    /// Create an Asana subtask for a writer (from list selection or "Add new writer" form).
    private func addWriterSubtask(name: String, folderName: String) async {
        guard !name.isEmpty, !folderName.isEmpty else { return }
        await MainActor.run {
            isAddingWriter = false
            isAddingNewWriter = false
            isCreatingSubtask = true
            createSubtaskError = nil
        }
        do {
            config?.saveWriterToServer(name: name, folderName: folderName)
            saveComposerInitials(name: name, initials: folderName)
            saveDisplayNameForInitials(initials: folderName, name: name)
            _ = try await asanaService.createSubtask(parentTaskGid: taskGid, name: name)
            // Create the composer folder on disk so it's ready for file drops
            if let config = config, !demosDocketFolder.isEmpty, let t = task {
                let dueDate = t.effectiveDueDate.flatMap { parseShortDate(String($0.prefix(10))) } ?? Date()
                if let dateFolder = try? config.getOrCreateDemosDateFolder(docketFolderName: demosDocketFolder, date: dueDate) {
                    let composerDir = dateFolder.appendingPathComponent(folderName)
                    let fm = FileManager.default
                    if !fm.fileExists(atPath: composerDir.path) {
                        try? fm.createDirectory(at: composerDir, withIntermediateDirectories: true, attributes: nil)
                    }
                }
            }
            await MainActor.run {
                isCreatingSubtask = false
                loadTaskAndSubtasks()
                refreshComposerFolderContents()
            }
        } catch {
            await MainActor.run {
                isCreatingSubtask = false
                createSubtaskError = error.localizedDescription
            }
        }
    }

    /// Create an Asana subtask from a dropped "Other folder" (e.g. "Goldie"); then refresh so it appears under Who's submitting.
    private func createSubtaskFromOtherFolder(_ folderKey: String) async {
        let nameToUse = displayNameForInitials(for: folderKey).isEmpty ? folderKey : displayNameForInitials(for: folderKey)
        await MainActor.run { isCreatingSubtask = true; createSubtaskError = nil }
        do {
            _ = try await asanaService.createSubtask(parentTaskGid: taskGid, name: nameToUse)
            await MainActor.run {
                isCreatingSubtask = false
                loadTaskAndSubtasks()
                refreshComposerFolderContents()
            }
        } catch {
            await MainActor.run {
                isCreatingSubtask = false
                createSubtaskError = error.localizedDescription
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider], composerName: String, folderNameOverride: String? = nil) -> Bool {
        guard let config = config, settingsManager != nil else { return false }
        let folderName = folderNameOverride ?? composerFolderName(for: composerName)
        if folderName.isEmpty && folderNameOverride == nil {
            composerInitialsPromptName = composerName
            composerInitialsPromptEntered = ""
            return false
        }
        guard !folderName.isEmpty else { return false }
        let custom = settingsManager?.currentSettings.composerInitials ?? [:]
        let wasDerived = folderNameOverride == nil && !custom.keys.contains(composerName)
        let dueDate = task?.effectiveDueDate.flatMap { s in parseShortDate(String(s.prefix(10))) } ?? Date()
        do {
            let dateFolder = try config.getOrCreateDemosDateFolder(docketFolderName: demosDocketFolder, date: dueDate)
            let composerDir = dateFolder.appendingPathComponent(folderName)
            let fm = FileManager.default
            if !fm.fileExists(atPath: composerDir.path) {
                try fm.createDirectory(at: composerDir, withIntermediateDirectories: true, attributes: nil)
            }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let fileURL = url else { return }
                    let dest = composerDir.appendingPathComponent(fileURL.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        try fm.copyItem(at: fileURL, to: dest)
                        DispatchQueue.main.async {
                            refreshComposerFolderContents()
                            if wasDerived { saveComposerInitials(name: composerName, initials: folderName) }
                        }
                    } catch {
                        DispatchQueue.main.async { demosDropError = error.localizedDescription }
                    }
                }
            }
            return true
        } catch {
            demosDropError = error.localizedDescription
            return false
        }
    }
    
    private func addFilesViaFinder(composerName: String, folderNameOverride: String? = nil) {
        guard let config = config, settingsManager != nil else { return }
        let folderName = folderNameOverride ?? composerFolderName(for: composerName)
        if folderName.isEmpty && folderNameOverride == nil {
            composerInitialsPromptName = composerName
            composerInitialsPromptEntered = ""
            return
        }
        guard !folderName.isEmpty else { return }
        let dueDate = task?.effectiveDueDate.flatMap { s in parseShortDate(String(s.prefix(10))) } ?? Date()
        let panel = NSOpenPanel()
        panel.title = "Add tracks for \(composerName)"
        panel.message = "Select audio files to add to this writer's folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let dateFolder = try config.getOrCreateDemosDateFolder(docketFolderName: demosDocketFolder, date: dueDate)
            let composerDir = dateFolder.appendingPathComponent(folderName)
            let fm = FileManager.default
            if !fm.fileExists(atPath: composerDir.path) {
                try fm.createDirectory(at: composerDir, withIntermediateDirectories: true, attributes: nil)
            }
            let custom = settingsManager?.currentSettings.composerInitials ?? [:]
            let wasDerived = folderNameOverride == nil && !custom.keys.contains(composerName)
            for url in panel.urls where url.isFileURL {
                let dest = composerDir.appendingPathComponent(url.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
                try? fm.copyItem(at: url, to: dest)
            }
            if wasDerived { saveComposerInitials(name: composerName, initials: folderName) }
            refreshComposerFolderContents()
        } catch {
            demosDropError = error.localizedDescription
        }
    }

    private func refreshComposerFolderContents() {
        guard let config = config, let t = task else {
            composerFolderContents = [:]
            demosFolderMissing = false
            return
        }
        guard !demosDocketFolder.isEmpty else {
            composerFolderContents = [:]
            demosFolderMissing = false
            return
        }
        let dueDate = t.effectiveDueDate.flatMap { s in parseShortDate(String(s.prefix(10))) } ?? Date()
        var contents: [String: [String]] = [:]
        var inUseFromDisk: [String: Set<String>] = [:]
        let fm = FileManager.default
        let subtaskComposerNames = Set(subtasks.compactMap { $0.assignee?.name ?? $0.name }.filter { !$0.isEmpty })
        // Use read-only lookup — never create folders when refreshing
        guard let dateFolder = config.getDemosDateFolderIfExists(docketFolderName: demosDocketFolder, date: dueDate) else {
            composerFolderContents = [:]
            demosFolderMissing = true
            return
        }
        demosFolderMissing = false
        // Auto-create writer folders for subtasks that have designated initials/nickname
        for composerName in subtaskComposerNames {
            let folderName = composerFolderName(for: composerName)
            if !folderName.isEmpty {
                let composerDir = dateFolder.appendingPathComponent(folderName)
                if !fm.fileExists(atPath: composerDir.path) {
                    _ = try? fm.createDirectory(at: composerDir, withIntermediateDirectories: true, attributes: nil)
                }
            }
        }
        guard let subdirs = try? fm.contentsOfDirectory(at: dateFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            composerFolderContents = [:]
            return
        }
        for subdir in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subdir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let folderName = subdir.lastPathComponent
            if let fileURLs = try? fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil) {
                let files = fileURLs.map { $0.lastPathComponent }.sorted()
                let key: String
                if let match = subtaskComposerNames.first(where: { composerFolderName(for: $0) == folderName }) {
                    key = match
                } else if !displayNameForInitials(for: folderName).isEmpty {
                    key = displayNameForInitials(for: folderName)
                } else {
                    key = folderName
                }
                contents[key] = files
                for url in fileURLs where !url.hasDirectoryPath {
                    let filename = url.lastPathComponent
                    if Self.fileHasGreyTag(at: url) {
                        inUseFromDisk[key, default: []].insert(filename)
                    }
                }
            }
        }
        composerFolderContents = contents
        trackInUse = inUseFromDisk
    }
    
    private func loadTrackInUseAndColors() {
        let keyInUse = Self.demosTrackInUseKeyPrefix + taskGid
        let keyColor = Self.demosTrackColorKeyPrefix + taskGid
        if let data = UserDefaults.standard.data(forKey: keyInUse),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            trackInUse = decoded.mapValues { Set($0) }
        } else {
            trackInUse = [:]
        }
        if let data = UserDefaults.standard.data(forKey: keyColor),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            trackColors = decoded
        } else {
            trackColors = [:]
        }
    }
    
    private func setTrackInUse(composerName: String, filename: String, inUse: Bool, folderNameOverride: String? = nil) {
        var set = trackInUse[composerName] ?? []
        if inUse { set.insert(filename) } else { set.remove(filename) }
        trackInUse[composerName] = set
        if let data = try? JSONEncoder().encode(trackInUse.mapValues { Array($0) }) {
            UserDefaults.standard.set(data, forKey: Self.demosTrackInUseKeyPrefix + taskGid)
        }
        // Sync to Finder: grey tag = in use
        if let url = fileURLForTrack(composerName: composerName, filename: filename, folderNameOverride: folderNameOverride) {
            Self.setFileGreyTag(at: url, inUse: inUse)
        }
    }
    
    private func setTrackColor(composerName: String, filename: String, colorName: String) {
        var dict = trackColors[composerName] ?? [:]
        dict[filename] = colorName
        trackColors[composerName] = dict
        if let data = try? JSONEncoder().encode(trackColors) {
            UserDefaults.standard.set(data, forKey: Self.demosTrackColorKeyPrefix + taskGid)
        }
    }
    
    private func isTrackInUse(composerName: String, filename: String) -> Bool {
        trackInUse[composerName]?.contains(filename) ?? false
    }
    
    private func trackColor(composerName: String, filename: String) -> String {
        if let stored = trackColors[composerName]?[filename] { return stored }
        if let fromFile = colorNameFromFilename(filename) { return fromFile }
        return ""
    }

    /// Detect a palette colour name in the filename (case-insensitive). Longer names tried first so e.g. "Crimson" wins over "Red".
    private func colorNameFromFilename(_ filename: String) -> String? {
        let lower = filename.lowercased()
        let byLength = Self.trackColorOptions.map(\.name).sorted { $0.count > $1.count }
        return byLength.first { name in
            lower.contains(name.lowercased())
        }
    }

    /// Composer names for the Composers table (matches spreadsheet: Composer | Colour 1–5).
    private static let trackColorComposerNames = [
        "Mark Domitric", "Jeff Milutinovic", "Andrew Austin", "Igor Correia",
        "Lowell Sostomi", "Tyson Kuteyi", "Tom Westin", "Kevin MacInnis"
    ]

    /// Composers table: one row per composer with 5 colour names. Indices 0..<40 from trackColorOptions.
    private static var trackColorComposerRows: [(composerName: String, colourNames: [String])] {
        let names = trackColorOptions.map(\.name)
        let composerCount = min(trackColorComposerNames.count, 8)
        let namesPerRow = 5
        return (0..<composerCount).map { i in
            let start = i * namesPerRow
            let end = min(start + namesPerRow, names.count)
            let colours = Array(names[start..<end])
            return (trackColorComposerNames[i], colours)
        }
    }

    /// Freelance/Extra table: rows of 5 colour names each. Indices 40+ from trackColorOptions.
    private static var trackColorFreelanceRows: [[String]] {
        let names = trackColorOptions.map(\.name)
        let startIndex = min(40, names.count)
        let remainder = Array(names.dropFirst(startIndex))
        let cols = 5
        return stride(from: 0, to: remainder.count, by: cols).map { start in
            let end = min(start + cols, remainder.count)
            return Array(remainder[start..<end])
        }
    }

    /// Track colour options from composer/freelance palette (POSTING LEGEND).
    private static let trackColorOptions: [(name: String, color: Color)] = [
        ("Cyan", Color(red: 0, green: 0.74, blue: 0.83)),
        ("Pink", Color(red: 1, green: 0.41, blue: 0.71)),
        ("Fuchsia", Color(red: 1, green: 0, blue: 1)),
        ("Emerald", Color(red: 0.31, green: 0.78, blue: 0.47)),
        ("Lily", Color(red: 0.9, green: 0.9, blue: 1)),
        ("Scarlet", Color(red: 1, green: 0.14, blue: 0)),
        ("Ochre", Color(red: 0.8, green: 0.47, blue: 0.13)),
        ("Saffron", Color(red: 0.96, green: 0.77, blue: 0.19)),
        ("Chestnut", Color(red: 0.58, green: 0.32, blue: 0.22)),
        ("Cucumber", Color(red: 0.48, green: 0.74, blue: 0.41)),
        ("Auburn", Color(red: 0.65, green: 0.16, blue: 0.16)),
        ("Olive", Color(red: 0.5, green: 0.5, blue: 0)),
        ("Amber", Color(red: 1, green: 0.75, blue: 0)),
        ("Crimson", Color(red: 0.86, green: 0.08, blue: 0.24)),
        ("Clover", Color(red: 0.28, green: 0.55, blue: 0.28)),
        ("Cobalt", Color(red: 0, green: 0.28, blue: 0.67)),
        ("Sienna", Color(red: 0.63, green: 0.32, blue: 0.18)),
        ("Cerulean", Color(red: 0.16, green: 0.48, blue: 0.72)),
        ("Khaki", Color(red: 0.76, green: 0.69, blue: 0.57)),
        ("Kiwi", Color(red: 0.56, green: 0.83, blue: 0.29)),
        ("Blue", .blue),
        ("Beige", Color(red: 0.96, green: 0.96, blue: 0.86)),
        ("White", .white),
        ("Mauve", Color(red: 0.88, green: 0.69, blue: 0.88)),
        ("Whirlpool", Color(red: 0.43, green: 0.71, blue: 0.72)),
        ("Grey", .gray),
        ("Black", .black),
        ("Azure", Color(red: 0.31, green: 0.59, blue: 1)),
        ("Lilac", Color(red: 0.78, green: 0.64, blue: 0.78)),
        ("Salmon", Color(red: 0.98, green: 0.5, blue: 0.45)),
        ("Teal", .teal),
        ("Turquoise", Color(red: 0.25, green: 0.88, blue: 0.82)),
        ("Taupe", Color(red: 0.52, green: 0.45, blue: 0.41)),
        ("Mango", Color(red: 1, green: 0.62, blue: 0.18)),
        ("Tangelo", Color(red: 0.98, green: 0.3, blue: 0)),
        ("Yellow", .yellow),
        ("Orange", .orange),
        ("Thistle", Color(red: 0.85, green: 0.75, blue: 0.85)),
        ("Shamrock", Color(red: 0, green: 0.62, blue: 0.38)),
        ("Eggshell", Color(red: 0.94, green: 0.92, blue: 0.84)),
        ("Maroon", Color(red: 0.5, green: 0, blue: 0)),
        ("Navy", Color(red: 0, green: 0, blue: 0.5)),
        ("Mint", Color(red: 0.6, green: 1, blue: 0.6)),
        ("Tangerine", Color(red: 1, green: 0.6, blue: 0)),
        ("Begonia", Color(red: 0.98, green: 0.42, blue: 0.54)),
        ("Purple", .purple),
        ("Magenta", Color(red: 1, green: 0, blue: 0.55)),
        ("Violet", Color(red: 0.58, green: 0, blue: 0.83)),
        ("Umber", Color(red: 0.39, green: 0.32, blue: 0.28)),
        ("Red", .red),
        ("Rose", Color(red: 1, green: 0.41, blue: 0.53)),
        ("Ruby", Color(red: 0.88, green: 0.07, blue: 0.37)),
        ("Aqua", Color(red: 0, green: 1, blue: 1)),
        ("Jade", Color(red: 0, green: 0.66, blue: 0.42)),
        ("Green", .green),
        ("Indigo", Color(red: 0.29, green: 0, blue: 0.51)),
        ("Brown", .brown),
        ("Cream", Color(red: 1, green: 0.99, blue: 0.82)),
        ("Periwinkle", Color(red: 0.8, green: 0.8, blue: 1)),
        ("Cherry", Color(red: 0.87, green: 0.19, blue: 0.39)),
        ("Burgundy", Color(red: 0.5, green: 0, blue: 0.13)),
        ("Orchid", Color(red: 0.85, green: 0.44, blue: 0.84)),
        ("Chamomile", Color(red: 0.98, green: 0.95, blue: 0.73)),
        ("Juniper", Color(red: 0.28, green: 0.36, blue: 0.33)),
        ("Lavender", Color(red: 0.9, green: 0.9, blue: 0.98)),
        ("Blush", Color(red: 0.87, green: 0.69, blue: 0.69)),
        ("Pumpkin", Color(red: 1, green: 0.46, blue: 0.09)),
        ("Mulberry", Color(red: 0.77, green: 0.29, blue: 0.55)),
        ("Tuscan", Color(red: 0.78, green: 0.64, blue: 0.54)),
        ("Coral", Color(red: 1, green: 0.5, blue: 0.31)),
        ("Lime", Color(red: 0.75, green: 1, blue: 0)),
        ("Pecan", Color(red: 0.55, green: 0.42, blue: 0.27)),
        ("Jasmine", Color(red: 0.97, green: 0.87, blue: 0.49)),
        ("Poppy", Color(red: 0.86, green: 0.23, blue: 0.21)),
        ("Cabernet", Color(red: 0.44, green: 0.19, blue: 0.27)),
        ("Honeyball", Color(red: 0.94, green: 0.78, blue: 0.31)),
        ("Dorado", Color(red: 0.72, green: 0.53, blue: 0.04)),
        ("Heliotrope", Color(red: 0.87, green: 0.45, blue: 1)),
        ("Ultramarine", Color(red: 0.25, green: 0, blue: 0.6)),
        ("Peach", Color(red: 1, green: 0.8, blue: 0.6)),
        ("Aquamarine", Color(red: 0.5, green: 1, blue: 0.83)),
        ("Canary", Color(red: 1, green: 1, blue: 0.6)),
    ]
    
    // MARK: - Finder grey tag ("in use")
    /// Finder grey label tag name (used to mark demos that are in use).
    private static let inUseTagName = "Gray"
    
    /// When folderNameOverride is set (e.g. for "other" writer folders found on disk), use it as the folder name; otherwise derive from composer name.
    private func fileURLForTrack(composerName: String, filename: String, folderNameOverride: String? = nil) -> URL? {
        guard let config = config, !demosDocketFolder.isEmpty, let t = task else { return nil }
        let dueDate = t.effectiveDueDate.flatMap { s in parseShortDate(String(s.prefix(10))) } ?? Date()
        guard let dateFolder = try? config.getOrCreateDemosDateFolder(docketFolderName: demosDocketFolder, date: dueDate) else { return nil }
        let folderName = folderNameOverride ?? composerFolderName(for: composerName)
        guard !folderName.isEmpty else { return nil }
        return dateFolder.appendingPathComponent(folderName).appendingPathComponent(filename)
    }
    
    private static func fileHasGreyTag(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let nsurl = url as NSURL
        guard let values = try? nsurl.resourceValues(forKeys: [.tagNamesKey]) else { return false }
        let tagNames = values[.tagNamesKey] as? [String]
        return tagNames?.contains(inUseTagName) ?? false
    }
    
    private static func setFileGreyTag(at url: URL, inUse: Bool) {
        guard url.isFileURL else { return }
        let nsurl = url as NSURL
        let values: [URLResourceKey: Any] = (try? nsurl.resourceValues(forKeys: [.tagNamesKey])) ?? [:]
        var tags = (values[.tagNamesKey] as? [String]) ?? []
        if inUse {
            if !tags.contains(inUseTagName) { tags.append(inUseTagName) }
        } else {
            tags.removeAll { $0 == inUseTagName }
        }
        try? nsurl.setResourceValue(tags, forKey: .tagNamesKey)
    }
}

// MARK: - Add writer sheet with conditional presentation sizing

private struct AddWriterSheetWithSizing<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(macOS 15.0, *) {
            content
                .presentationSizing(.fitted)
        } else {
            content
        }
    }
}

// MARK: - Track colour popover target

private struct TrackColorPopoverTarget: Identifiable {
    let composerName: String
    let filename: String
    var id: String { "\(composerName)|\(filename)" }
}

// MARK: - Drag from Other folders to create Asana subtask

enum OtherFolderDragPayload {
    static let prefix = "mediadash.otherfolder:"
    static func dragString(for folderKey: String) -> String {
        "\(prefix)\(folderKey)"
    }
}
