import SwiftUI
import AppKit

// MARK: - Rename Token

enum RenameToken: String, CaseIterable {
    case original = "{original}"
    case docket = "{docket}"
    case date = "{date}"
    case sequence = "{seq}"
    case extension_ = "{ext}"
    
    var description: String {
        switch self {
        case .original: return "Original filename (without extension)"
        case .docket: return "Current docket number"
        case .date: return "Today's date (MMM.d.yy)"
        case .sequence: return "Sequence number (01, 02, ...)"
        case .extension_: return "File extension"
        }
    }
    
    var example: String {
        switch self {
        case .original: return "MyVideo"
        case .docket: return "25001_ProjectName"
        case .date: return "Nov27.25"
        case .sequence: return "01"
        case .extension_: return "mov"
        }
    }
}

// MARK: - Rename Preview Item

struct RenamePreviewItem: Identifiable {
    let id: UUID
    let originalName: String
    let newName: String
    let url: URL
    let hasConflict: Bool
}

// MARK: - Batch Rename Sheet

struct BatchRenameSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var manager: MediaManager
    let filesToRename: [FileItem]
    
    @State private var pattern: String = "{original}"
    @State private var docketName: String = ""
    @State private var startingNumber: Int = 1
    @State private var sequenceDigits: Int = 2
    @State private var showTokenHelp: Bool = false
    @State private var isRenaming: Bool = false
    @State private var renameError: String?
    
    // Preview of renamed files
    private var previewItems: [RenamePreviewItem] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM.d.yy"
        let dateString = dateFormatter.string(from: Date())
        
        var previews: [RenamePreviewItem] = []
        var usedNames: Set<String> = []
        
        for (index, file) in filesToRename.enumerated() {
            let originalName = file.url.deletingPathExtension().lastPathComponent
            let ext = file.url.pathExtension
            
            // Build new name from pattern
            var newName = pattern
            newName = newName.replacingOccurrences(of: "{original}", with: originalName)
            newName = newName.replacingOccurrences(of: "{docket}", with: docketName.isEmpty ? "DOCKET" : docketName)
            newName = newName.replacingOccurrences(of: "{date}", with: dateString)
            
            // Handle sequence number
            let seqNumber = startingNumber + index
            let seqFormat = "%0\(sequenceDigits)d"
            let seqString = String(format: seqFormat, seqNumber)
            newName = newName.replacingOccurrences(of: "{seq}", with: seqString)
            
            // Handle extension token
            newName = newName.replacingOccurrences(of: "{ext}", with: ext)
            
            // Add extension if not already in pattern
            let finalName: String
            if !newName.hasSuffix(".\(ext)") && !pattern.contains("{ext}") {
                finalName = "\(newName).\(ext)"
            } else {
                finalName = newName
            }
            
            // Check for conflicts
            let hasConflict = usedNames.contains(finalName)
            usedNames.insert(finalName)
            
            previews.append(RenamePreviewItem(
                id: file.id,
                originalName: file.name,
                newName: finalName,
                url: file.url,
                hasConflict: hasConflict
            ))
        }
        
        return previews
    }
    
    private var hasConflicts: Bool {
        previewItems.contains { $0.hasConflict }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Batch Rename")
                        .font(.system(size: 20, weight: .bold))
                    Text("\(filesToRename.count) file(s) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Pattern Builder
            VStack(alignment: .leading, spacing: 16) {
                // Pattern input
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Rename Pattern")
                            .font(.headline)
                        
                        Button(action: { showTokenHelp.toggle() }) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showTokenHelp) {
                            TokenHelpView()
                        }
                    }
                    
                    TextField("e.g., {docket}_{original}_{seq}", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, design: .monospaced))
                }
                
                // Token buttons
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RenameToken.allCases, id: \.rawValue) { token in
                            Button(action: {
                                pattern += token.rawValue
                            }) {
                                Text(token.rawValue)
                                    .font(.system(size: 12, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .help(token.description)
                        }
                    }
                }
                
                // Options
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Docket Name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Optional", text: $docketName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start Number")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("1", value: $startingNumber, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Digits")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: $sequenceDigits) {
                            Text("1").tag(1)
                            Text("2").tag(2)
                            Text("3").tag(3)
                            Text("4").tag(4)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                    
                    Spacer()
                }
            }
            .padding()
            
            Divider()
            
            // Preview
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Preview")
                        .font(.headline)
                    
                    Spacer()
                    
                    if hasConflicts {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Duplicate names detected")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                
                List(previewItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.originalName)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .strikethrough()
                            
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                
                                Text(item.newName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(item.hasConflict ? .orange : .primary)
                            }
                        }
                        
                        Spacer()
                        
                        if item.hasConflict {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 14))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            
            // Error message
            if let error = renameError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal)
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Reset") {
                    pattern = "{original}"
                    docketName = ""
                    startingNumber = 1
                    sequenceDigits = 2
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Rename Files") {
                    performRename()
                }
                .buttonStyle(.borderedProminent)
                .disabled(filesToRename.isEmpty || hasConflicts || isRenaming)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 550, height: 500)
    }
    
    private func performRename() {
        isRenaming = true
        renameError = nil
        
        let fm = FileManager.default
        var renamedCount = 0
        var errors: [String] = []
        
        for preview in previewItems {
            let originalURL = preview.url
            let newURL = originalURL.deletingLastPathComponent().appendingPathComponent(preview.newName)
            
            // Skip if names are the same
            guard preview.originalName != preview.newName else {
                continue
            }
            
            do {
                try fm.moveItem(at: originalURL, to: newURL)
                renamedCount += 1
                
                // Update the file in manager's selectedFiles
                if let index = manager.selectedFiles.firstIndex(where: { $0.id == preview.id }) {
                    manager.selectedFiles[index] = FileItem(url: newURL)
                }
            } catch {
                errors.append("\(preview.originalName): \(error.localizedDescription)")
            }
        }
        
        isRenaming = false
        
        if errors.isEmpty {
            dismiss()
        } else {
            renameError = "Failed to rename \(errors.count) file(s)"
        }
    }
}

// MARK: - Token Help View

struct TokenHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Tokens")
                .font(.headline)
            
            ForEach(RenameToken.allCases, id: \.rawValue) { token in
                HStack(alignment: .top, spacing: 12) {
                    Text(token.rawValue)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.blue)
                        .frame(width: 80, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(token.description)
                            .font(.system(size: 12))
                        Text("Example: \(token.example)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Example Patterns")
                    .font(.subheadline.bold())
                
                Text("{docket}_{original}")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("→ 25001_ProjectName_MyVideo.mov")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Text("{docket}_{date}_{seq}")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                Text("→ 25001_ProjectName_Nov27.25_01.mov")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 350)
    }
}

// MARK: - Preview

#Preview {
    BatchRenameSheet(
        manager: MediaManager(
            settingsManager: SettingsManager(),
            metadataManager: DocketMetadataManager(settings: .default)
        ),
        filesToRename: []
    )
}

