import SwiftUI
import UniformTypeIdentifiers

/// Right-hand panel mode: folder preview (default) or checklist.
enum PrepRightViewMode: String, CaseIterable {
    case folderPreview = "Folder Preview"
    case checklist = "Checklist"
}

struct ManualPrepSheet: View {
    @ObservedObject var manager: MediaManager
    @Binding var isPresented: Bool
    let docket: String
    let wpDate: Date
    let prepDate: Date
    
    @State private var prepRightViewMode: PrepRightViewMode = .folderPreview
    @State private var fileClassificationOverrides: [UUID: String] = [:]
    @State private var customClassifications: [String] = []
    
    @State private var checklistText: String = ""
    @State private var items: [PrepChecklistItem] = []
    @State private var showFilePickerForItem: PrepChecklistItem?
    @State private var tempSelection: Set<UUID> = []
    @State private var draggedFileId: UUID?
    @State private var showAddClassificationSheet = false
    @State private var newClassificationName = ""
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .sheet(item: $showFilePickerForItem, onDismiss: {
            showFilePickerForItem = nil
            tempSelection.removeAll()
        }) { item in
            ChecklistFilePickerSheet(
                files: manager.selectedFiles,
                selection: $tempSelection,
                title: item.title,
                onDone: {
                    applySelection(to: item.id)
                }
            )
        }
        .sheet(isPresented: $showAddClassificationSheet, onDismiss: {
            newClassificationName = ""
        }) {
            addClassificationSheet
        }
    }
    
    private var addClassificationSheet: some View {
        VStack(spacing: 16) {
            Text("New Classification")
                .font(.headline)
            TextField("Folder name", text: $newClassificationName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Button("Cancel") {
                    newClassificationName = ""
                    showAddClassificationSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let name = newClassificationName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, !allClassifications.contains(name) {
                        customClassifications.append(name)
                    }
                    newClassificationName = ""
                    showAddClassificationSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newClassificationName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300)
    }
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prep Files")
                    .font(.title2)
                Text("Docket \(docket)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(manager.selectedFiles.count) file\(manager.selectedFiles.count == 1 ? "" : "s") staged")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
    
    private var content: some View {
        HStack(spacing: 0) {
            stagedFilesPanel
            Divider()
            rightPanel
        }
    }
    
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("View", selection: $prepRightViewMode) {
                    ForEach(PrepRightViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
                .labelsHidden()
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            switch prepRightViewMode {
            case .folderPreview:
                folderPreviewPanel
            case .checklist:
                checklistPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private var stagedFilesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Staged Files")
                .font(.headline)
            
            Text("Drag files to checklist items, or just run prep to auto-organize by file type.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            List {
                ForEach(manager.selectedFiles) { file in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                            .resizable()
                            .frame(width: 20, height: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.displayName)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            
                            HStack(spacing: 8) {
                                if let size = file.formattedSize {
                                    Text(size)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                if file.isDirectory {
                                    Text("\(file.fileCount) files")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        Spacer()
                        
                        // Show classification (folder preview) or checklist assignment count
                        if prepRightViewMode == .folderPreview, let cat = fileClassificationOverrides[file.id] {
                            Text(cat)
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .cornerRadius(4)
                        } else {
                            let assignedCount = items.filter { $0.assignedFileIds.contains(file.id) }.count
                            if assignedCount > 0 {
                                Text("\(assignedCount)")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor)
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .contextMenu {
                        if prepRightViewMode == .folderPreview, fileClassificationOverrides[file.id] != nil {
                            Button("Clear classification") {
                                fileClassificationOverrides.removeValue(forKey: file.id)
                            }
                        }
                    }
                    .onDrag {
                        draggedFileId = file.id
                        return NSItemProvider(object: file.id.uuidString as NSString)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding()
        .frame(minWidth: 280, idealWidth: 320)
    }
    
    // MARK: - Folder Preview (default right panel)
    
    private var standardClassificationNames: [String] {
        let s = manager.config.settings
        return [s.pictureFolderName, s.aafOmfFolderName, s.musicFolderName, "STINGS", "VO REFS", "MNEMONIC", s.otherFolderName]
    }
    
    private var allClassifications: [String] {
        let seen = Set(standardClassificationNames)
        let extra = customClassifications.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !seen.contains($0) }
        return standardClassificationNames + extra
    }
    
    private func autoCategory(for url: URL) -> String {
        let s = manager.config.settings
        let ext = url.pathExtension.lowercased()
        if s.pictureExtensions.contains(ext) { return s.pictureFolderName }
        if s.musicExtensions.contains(ext) { return s.musicFolderName }
        if s.aafOmfExtensions.contains(ext) { return s.aafOmfFolderName }
        return s.otherFolderName
    }
    
    /// (flatFileURL, sourceId, resolvedCategory) for preview
    private var flattenedPreview: [(url: URL, sourceId: UUID, category: String)] {
        var result: [(url: URL, sourceId: UUID, category: String)] = []
        for file in manager.selectedFiles {
            let flatURLs = MediaLogic.getAllFiles(at: file.url)
            for flatURL in flatURLs {
                let category = fileClassificationOverrides[file.id] ?? autoCategory(for: flatURL)
                result.append((flatURL, file.id, category))
            }
        }
        return result
    }
    
    private func filesInCategory(_ category: String) -> [(url: URL, sourceId: UUID)] {
        flattenedPreview
            .filter { $0.category == category }
            .map { ($0.url, $0.sourceId) }
    }
    
    private var folderPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Drag files from the left to classify. Others are auto-classified by type.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            List {
                ForEach(allClassifications, id: \.self) { classification in
                    folderPreviewRow(classification: classification)
                }
                Section {
                    addClassificationRow
                }
            }
            .listStyle(.inset)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private func folderPreviewRow(classification: String) -> some View {
        let files = filesInCategory(classification)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(classification)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(files.prefix(8).enumerated()), id: \.element.url.path) { _, pair in
                        Text(pair.url.lastPathComponent)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if files.count > 8 {
                        Text("+ \(files.count - 8) more")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let uuidString = string as? String, let uuid = UUID(uuidString: uuidString) {
                    DispatchQueue.main.async {
                        fileClassificationOverrides[uuid] = classification
                    }
                }
            }
            return true
        }
    }
    
    private var addClassificationRow: some View {
        HStack {
            Image(systemName: "plus.circle")
                .foregroundColor(.accentColor)
            Text("Add classification…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onTapGesture {
            addNewClassification()
        }
    }
    
    private func addNewClassification() {
        newClassificationName = ""
        showAddClassificationSheet = true
    }
    
    private var checklistPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Checklist (Optional)")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    checklistText = ""
                    items = []
                }
                .disabled(checklistText.isEmpty && items.isEmpty)
            }
            
            Text("Paste your session checklist here to organize files by item.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            TextEditor(text: $checklistText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            
            HStack {
                Button("Parse Checklist") {
                    items = PrepChecklistParser.parseItems(from: checklistText)
                }
                .disabled(checklistText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
                Spacer()
                
                if !items.isEmpty {
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            checklistItemsList
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    private var checklistItemsList: some View {
        List {
            if items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No checklist items")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Without a checklist, files will be auto-organized by type (Music, VO, SFX, etc.)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(items) { item in
                    checklistItemRow(item)
                }
            }
        }
        .listStyle(.inset)
    }
    
    @ViewBuilder
    private func checklistItemRow(_ item: PrepChecklistItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(assignmentSummary(for: item))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 8) {
                Button("Assign Files") {
                    beginAssigningFiles(to: item)
                }
                .disabled(manager.selectedFiles.isEmpty)
                
                if !item.assignedFileIds.isEmpty {
                    Button("Clear") {
                        clearAssignments(for: item.id)
                    }
                }
            }
            
            // Show assigned files
            if !item.assignedFileIds.isEmpty {
                let assignedFiles = manager.selectedFiles.filter { item.assignedFileIds.contains($0.id) }
                ForEach(assignedFiles) { file in
                    HStack {
                        Image(systemName: "doc")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(file.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let uuidString = string as? String,
                   let uuid = UUID(uuidString: uuidString) {
                    DispatchQueue.main.async {
                        assignFile(uuid, to: item.id)
                    }
                }
            }
            return true
        }
    }
    
    private var footer: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                if prepRightViewMode == .folderPreview {
                    if fileClassificationOverrides.isEmpty {
                        Text("Files will be auto-classified by type")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(fileClassificationOverrides.count) manual classification\(fileClassificationOverrides.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if items.isEmpty {
                    Text("Files will be organized by type")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    let assignedCount = items.reduce(0) { $0 + $1.assignedFileIds.count }
                    Text("\(assignedCount) file assignment\(assignedCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Button("Run Prep") {
                runPrep()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(manager.selectedFiles.isEmpty)
        }
        .padding()
    }
    
    // MARK: - Helper Methods
    
    private func beginAssigningFiles(to item: PrepChecklistItem) {
        tempSelection = item.assignedFileIds
        showFilePickerForItem = item
    }
    
    private func applySelection(to itemId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].assignedFileIds = tempSelection
        showFilePickerForItem = nil
    }
    
    private func assignFile(_ fileId: UUID, to itemId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].assignedFileIds.insert(fileId)
    }
    
    private func clearAssignments(for itemId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].assignedFileIds.removeAll()
    }
    
    private func assignmentSummary(for item: PrepChecklistItem) -> String {
        let count = item.assignedFileIds.count
        if count == 0 {
            return "Drop files here"
        }
        return "\(count) file\(count == 1 ? "" : "s")"
    }
    
    private func runPrep() {
        // Folder preview overrides: fileId -> classification folder name (only used classifications get folders when files are copied)
        if !fileClassificationOverrides.isEmpty {
            manager.pendingPrepFileOverrides = fileClassificationOverrides
        } else {
            manager.pendingPrepFileOverrides = nil
        }
        
        // Checklist session (when user switched to Checklist view and parsed/assigned items)
        if prepRightViewMode == .checklist, !items.isEmpty {
            let session = PrepChecklistSession(
                docket: docket,
                items: items,
                rawChecklistText: checklistText
            )
            manager.pendingPrepChecklistSession = session
        } else {
            manager.pendingPrepChecklistSession = nil
        }
        
        isPresented = false
        
        manager.runJob(
            type: .prep,
            docket: docket,
            wpDate: wpDate,
            prepDate: prepDate
        )
    }
}

// MARK: - File Picker Sheet

struct ChecklistFilePickerSheet: View {
    let files: [FileItem]
    @Binding var selection: Set<UUID>
    let title: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assign Files")
                        .font(.title3)
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Select All") {
                    selection = Set(files.map { $0.id })
                }
                .disabled(files.isEmpty)
                Button("Clear") {
                    selection.removeAll()
                }
                .disabled(selection.isEmpty)
            }
            .padding()
            
            Divider()
            
            List {
                ForEach(files) { file in
                    Toggle(isOn: binding(for: file.id)) {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(file.displayName)
                                .font(.system(size: 12))
                            Spacer()
                            if let size = file.formattedSize {
                                Text(size)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if file.isDirectory {
                                Text("\(file.fileCount) files")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            
            Divider()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text("\(selection.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Done") {
                    onDone()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }
    
    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isSelected in
                if isSelected {
                    selection.insert(id)
                } else {
                    selection.remove(id)
                }
            }
        )
    }
}
