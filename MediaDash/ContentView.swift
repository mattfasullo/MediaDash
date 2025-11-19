import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject var settingsManager = SettingsManager()
    @StateObject var manager: MediaManager
    @State private var selectedDocket: String = ""
    @State private var wpDate = Date()
    @State private var prepDate = Date().addingTimeInterval(86400)
    @State private var showNewDocketSheet = false
    @State private var showSearchSheet = false
    @State private var showSettingsSheet = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var hoverInfo: String = "Ready."
    @State private var initialSearchText = ""
    @FocusState private var mainViewFocused: Bool

    // Logic for auto-docket selection
    @State private var showDocketSelectionSheet = false
    @State private var pendingJobType: JobType? = nil

    // Focus management for action buttons
    enum ActionButtonFocus: Hashable {
        case file, prep, both
    }
    @FocusState private var focusedButton: ActionButtonFocus?

    init() {
        let settings = SettingsManager()
        _settingsManager = StateObject(wrappedValue: settings)
        _manager = StateObject(wrappedValue: MediaManager(settingsManager: settings))
    }
    
    // Date formatter for better date display
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    
    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            VStack(alignment: .leading, spacing: 20) {
                // App Title with gradient
                VStack(alignment: .leading, spacing: 4) {
                    Text("MediaDash")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text("Professional Media Manager")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 10)
                
                // MARK: Project Selection
                VStack(alignment: .leading, spacing: 5) {
                    Text("PROJECT")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.gray)
                    
                    HStack {
                        Menu {
                            if manager.isScanningDockets {
                                Button("Populating Dockets...") {}
                                    .disabled(true)
                            } else if manager.dockets.isEmpty {
                                Button("No Dockets Found") {}
                                    .disabled(true)
                            } else {
                                ForEach(manager.dockets, id: \.self) { d in
                                    Button(d) { selectedDocket = d }
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedDocket.isEmpty ? "Select..." : selectedDocket)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if manager.isScanningDockets {
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 10, height: 10)
                                }
                            }
                        }
                        .menuStyle(BorderedButtonMenuStyle())
                        
                        Button(action: { manager.refreshDockets() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh dockets")
                        .accessibilityHint("Updates the list of available project dockets")
                        .keyboardShortcut("r", modifiers: .command)
                        
                        Button(action: { showNewDocketSheet = true }) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Create new docket")
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
                
                // MARK: Date Selection
                VStack(alignment: .leading, spacing: 5) {
                    Text("DATES")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.gray)
                    
                    HStack {
                        Text("Work Pic:")
                        Spacer()
                        DatePicker("", selection: $wpDate, displayedComponents: .date)
                            .labelsHidden()
                            .accessibilityLabel("Work picture date")
                    }
                    
                    HStack {
                        Text("Prep:")
                        Spacer()
                        DatePicker("", selection: $prepDate, displayedComponents: .date)
                            .labelsHidden()
                            .accessibilityLabel("Preparation date")
                    }
                }
                
                Divider().background(Color.gray)
                
                // MARK: Action Buttons
                VStack(spacing: 10) {
                    ActionButtonWithShortcut(
                        title: "FILE",
                        subtitle: "Work Picture",
                        shortcut: "⌘1",
                        color: .blue.opacity(0.8),
                        isPrimary: false,
                        isFocused: focusedButton == .file
                    ) {
                        attempt(type: .workPicture)
                    }
                    .focused($focusedButton, equals: .file)
                    .onHover { hovering in
                        hoverInfo = hovering ?
                            "Files to Work Picture (\(dateFormatter.string(from: wpDate)))" :
                            "Ready."
                    }
                    .keyboardShortcut("1", modifiers: .command)

                    ActionButtonWithShortcut(
                        title: "PREP",
                        subtitle: "Session Prep",
                        shortcut: "⌘2",
                        color: .purple.opacity(0.8),
                        isPrimary: false,
                        isFocused: focusedButton == .prep
                    ) {
                        attempt(type: .prep)
                    }
                    .focused($focusedButton, equals: .prep)
                    .onHover { hovering in
                        hoverInfo = hovering ?
                            "Files to Session Prep (\(dateFormatter.string(from: prepDate)))" :
                            "Ready."
                    }
                    .keyboardShortcut("2", modifiers: .command)

                    ActionButtonWithShortcut(
                        title: "FILE + PREP",
                        subtitle: "Both",
                        shortcut: "⌘3 or ↵",
                        color: .green.opacity(0.8),
                        isPrimary: false,
                        isFocused: focusedButton == .both
                    ) {
                        attempt(type: .both)
                    }
                    .focused($focusedButton, equals: .both)
                    .onHover { hovering in
                        hoverInfo = hovering ?
                            "Processes both Work Picture and Prep" :
                            "Ready."
                    }
                    .keyboardShortcut("3", modifiers: .command)
                }
                .onKeyPress(.upArrow) {
                    moveFocus(direction: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveFocus(direction: 1)
                    return .handled
                }
                .onKeyPress(.return) {
                    activateFocusedButton()
                    return .handled
                }
                
                Spacer()

                Divider()

                // Bottom actions
                VStack(spacing: 12) {
                    ModernLinkButton(icon: "magnifyingglass", title: "Search Sessions", shortcut: "⌘F") {
                        showSearchSheet = true
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    ModernLinkButton(icon: "gearshape", title: "Settings", shortcut: "⌘,") {
                        showSettingsSheet = true
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
            .padding(20)
            .frame(width: 300)
            .background(
                LinearGradient(
                    colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            Divider()
            
            // MARK: - Main Content Area
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "tray.2")
                            .foregroundColor(.blue)
                        Text("STAGING")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)

                        if !manager.selectedFiles.isEmpty {
                            Text("\(manager.selectedFiles.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .cornerRadius(10)
                        }
                    }

                    Spacer()

                    if !manager.selectedFiles.isEmpty {
                        Button(action: { manager.clearFiles() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                Text("Clear")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("w", modifiers: .command)
                    }

                    Button("Add Files") {
                        manager.pickFiles()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                
                // File List or Empty State
                ZStack {
                    if manager.selectedFiles.isEmpty {
                        // Empty State
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.1))
                                    .frame(width: 100, height: 100)
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            }

                            VStack(spacing: 6) {
                                Text("No files staged")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("Drop files here or click 'Add Files'")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // File List
                        List(manager.selectedFiles) { f in
                            HStack {
                                Image(nsImage: getIcon(f.url))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(f.name)
                                Spacer()
                                // Show file size if available
                                if let size = getFileSize(f.url) {
                                    Text(size)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                    }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                    return true
                }
                
                // Status Bar
                HStack {
                    // Left side - Indexing indicator
                    if manager.isIndexing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                            Text("Indexing sessions...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }

                    Spacer()

                    // Center/Right - Processing or hover info
                    if manager.isProcessing {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                ProgressView(value: manager.progress)
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 200)
                                Text("\(Int(manager.progress * 100))%")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                                Button("Cancel") {
                                    manager.cancelProcessing()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Text(manager.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(hoverInfo)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: 900, height: 650)
        .focusable()
        .focused($mainViewFocused)
        .alert("Missing Information", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .alert("Error", isPresented: $manager.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = manager.errorMessage {
                Text(errorMessage)
            }
        }
        .sheet(isPresented: $showNewDocketSheet) {
            NewDocketView(
                isPresented: $showNewDocketSheet,
                selectedDocket: $selectedDocket,
                manager: manager,
                settingsManager: settingsManager
            )
        }
        .sheet(isPresented: $showSearchSheet) {
            SearchView(manager: manager, isPresented: $showSearchSheet, initialText: initialSearchText)
        }
        // New Docket Selection Sheet
        .sheet(isPresented: $showDocketSelectionSheet) {
            DocketSearchView(
                manager: manager,
                isPresented: $showDocketSelectionSheet,
                selectedDocket: $selectedDocket,
                onConfirm: {
                    // Execute pending job once docket is selected
                    if let type = pendingJobType {
                        manager.runJob(
                            type: type,
                            docket: selectedDocket,
                            wpDate: wpDate,
                            prepDate: prepDate
                        )
                        pendingJobType = nil
                    }
                }
            )
        }
        .onChange(of: showSearchSheet) { oldValue, newValue in
            if !newValue {
                // Clear initial search text and refocus main view when search closes
                initialSearchText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    mainViewFocused = true
                }
            }
        }
        .onChange(of: showSettingsSheet) { oldValue, newValue in
            if !newValue {
                // Refocus main view when settings closes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    mainViewFocused = true
                }
            }
        }
        .onChange(of: manager.selectedFiles.count) { oldValue, newValue in
            // Auto-focus first button when files are added and docket is selected
            if newValue > 0 && !selectedDocket.isEmpty && focusedButton == nil {
                focusedButton = .file
            }
        }
        .onKeyPress { press in
            // Only handle typing when search isn't already open
            guard !showSearchSheet && !showSettingsSheet && !showNewDocketSheet && !showDocketSelectionSheet else {
                return .ignored
            }

            // Auto-search when typing in main view
            if press.characters.count == 1 {
                let char = press.characters.first!
                if char.isLetter || char.isNumber {
                    initialSearchText = String(char)
                    showSearchSheet = true
                    return .handled
                }
            }
            return .ignored
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(settingsManager: settingsManager, isPresented: $showSettingsSheet)
        }
        .onChange(of: settingsManager.currentSettings) { oldValue, newValue in
            // Update manager's config when settings change
            manager.updateConfig(settings: newValue)
        }
        .onAppear {
            if let firstDocket = manager.dockets.first {
                selectedDocket = firstDocket
            }
            // Focus main view to receive keyboard events
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                mainViewFocused = true
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func getIcon(_ url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
    
    private func getFileSize(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? Int64 else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
    
    private func handleFileDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error = error {
                    print("Error loading file: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.manager.errorMessage = "Failed to load dropped file: \(error.localizedDescription)"
                        self.manager.showError = true
                    }
                    return
                }

                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    print("Invalid file data")
                    DispatchQueue.main.async {
                        self.manager.errorMessage = "Invalid file data in drop operation"
                        self.manager.showError = true
                    }
                    return
                }

                DispatchQueue.main.async {
                    // Check if file already exists in list
                    if !manager.selectedFiles.contains(where: { $0.url == url }) {
                        withAnimation(.spring(response: 0.3)) {
                            manager.selectedFiles.append(FileItem(url: url))
                        }
                    }
                }
            }
        }
    }
    
    private func attempt(type: JobType) {
        // 1. Validate file selection FIRST
        guard !manager.selectedFiles.isEmpty else {
            alertMessage = "Please add at least one file to the staging area."
            showAlert = true
            return
        }

        // 2. Check if docket is selected
        if selectedDocket.isEmpty {
            // Store the intended job and show selection sheet
            pendingJobType = type
            showDocketSelectionSheet = true
            return
        }
        
        // 3. If docket exists, run the job immediately
        manager.runJob(
            type: type,
            docket: selectedDocket,
            wpDate: wpDate,
            prepDate: prepDate
        )
    }

    private func moveFocus(direction: Int) {
        let buttons: [ActionButtonFocus] = [.file, .prep, .both]

        if let current = focusedButton,
           let currentIndex = buttons.firstIndex(of: current) {
            let newIndex = (currentIndex + direction + buttons.count) % buttons.count
            focusedButton = buttons[newIndex]
        } else {
            focusedButton = .file
        }
    }

    private func activateFocusedButton() {
        guard let focused = focusedButton else { return }

        switch focused {
        case .file:
            attempt(type: .workPicture)
        case .prep:
            attempt(type: .prep)
        case .both:
            attempt(type: .both)
        }
    }
}

// MARK: - Modern Link Button

struct ModernLinkButton: View {
    let icon: String
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isHovered ? .blue : .secondary)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? .primary : .secondary)

                Spacer()

                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: isHovered ? [color, color.opacity(0.8)] : [color.opacity(0.9), color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(10)
            .shadow(color: color.opacity(0.4), radius: isHovered ? 8 : 4, y: isHovered ? 4 : 2)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Action Button With Keyboard Shortcut

struct ActionButtonWithShortcut: View {
    let title: String
    let subtitle: String
    let shortcut: String
    let color: Color
    let isPrimary: Bool
    let isFocused: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: isPrimary ? 6 : 4) {
                Text(title)
                    .font(.system(size: isPrimary ? 16 : 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                if isPrimary {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }

                Text(shortcut)
                    .font(.system(size: isPrimary ? 11 : 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, isPrimary ? 16 : 12)
            .background(
                LinearGradient(
                    colors: isHovered || isFocused ? [color, color.opacity(0.8)] : [color.opacity(0.9), color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white, lineWidth: isFocused ? 3 : 0)
            )
            .shadow(color: color.opacity(0.4), radius: (isHovered || isFocused) ? 10 : 5, y: (isHovered || isFocused) ? 5 : 3)
            .scaleEffect((isHovered || isFocused) ? 1.03 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - New Docket View

struct NewDocketView: View {
    @Binding var isPresented: Bool
    @Binding var selectedDocket: String
    @ObservedObject var manager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @State private var number = ""
    @State private var jobName = ""
    @State private var showValidationError = false
    @State private var validationMessage = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("New Docket")
                .font(.headline)
            
            Form {
                TextField("Number", text: $number)
                    .textFieldStyle(.roundedBorder)
                TextField("Job Name", text: $jobName)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 300)
            
            if showValidationError {
                Text(validationMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Create") {
                    createDocket()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number.isEmpty || jobName.isEmpty)
            }
        }
        .padding()
    }
    
    private func createDocket() {
        // Validate inputs
        guard !number.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Docket number cannot be empty"
            showValidationError = true
            return
        }

        guard !jobName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationMessage = "Job name cannot be empty"
            showValidationError = true
            return
        }

        let docketName = "\(number)_\(jobName)"

        // Check if docket already exists
        if manager.dockets.contains(docketName) {
            validationMessage = "A docket with this name already exists"
            showValidationError = true
            return
        }

        // Create the docket folder on disk
        let config = AppConfig(settings: settingsManager.currentSettings)
        let paths = config.getPaths()
        let docketFolder = paths.workPic.appendingPathComponent(docketName)

        do {
            try FileManager.default.createDirectory(at: docketFolder, withIntermediateDirectories: true)
            selectedDocket = docketName
            manager.refreshDockets() // Refresh to show the new docket
            isPresented = false
        } catch {
            validationMessage = "Failed to create docket folder: \(error.localizedDescription)"
            showValidationError = true
        }
    }
}

// MARK: - Custom TextField with Selection Control

class NoSelectNSTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        // Move cursor to end without selecting text
        if let editor = currentEditor() {
            editor.selectedRange = NSRange(location: stringValue.count, length: 0)
        }
        return result
    }
}

struct NoSelectTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onTextChange: () -> Void

    func makeNSView(context: Context) -> NoSelectNSTextField {
        let textField = NoSelectNSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.font = .systemFont(ofSize: 20)
        textField.isBordered = false
        textField.focusRingType = .none
        textField.backgroundColor = .clear
        return textField
    }

    func updateNSView(_ nsView: NoSelectNSTextField, context: Context) {
        nsView.placeholderString = placeholder
        nsView.isEnabled = isEnabled

        // Only update text if it's actually different
        if nsView.stringValue != text {
            nsView.stringValue = text

            // Only adjust cursor position when text changes and editor is active
            if let editor = nsView.currentEditor(), text.count > 0 {
                let expectedRange = NSRange(location: text.count, length: 0)
                if editor.selectedRange != expectedRange {
                    editor.selectedRange = expectedRange
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NoSelectTextField

        init(_ parent: NoSelectTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                parent.text = textField.stringValue
                parent.onTextChange()
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - Docket Selection Search View (New)

struct DocketSearchView: View {
    @ObservedObject var manager: MediaManager
    @Binding var isPresented: Bool
    @Binding var selectedDocket: String
    var onConfirm: () -> Void
    
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var filteredDockets: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header / Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search projects...", text: $searchText)
                   .textFieldStyle(.plain)
                   .font(.system(size: 18))
                   .focused($isSearchFocused)
                   .onChange(of: searchText) { oldValue, newValue in updateSearch() }
                   .onSubmit {
                       if let first = filteredDockets.first {
                           selectDocket(first)
                       }
                   }
                
                if !searchText.isEmpty {
                     Button(action: { searchText = "" }) {
                         Image(systemName: "xmark.circle.fill")
                             .foregroundColor(.secondary)
                     }
                     .buttonStyle(.plain)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // List
            List {
                if filteredDockets.isEmpty {
                    Text("No projects found")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ForEach(filteredDockets, id: \.self) { docket in
                        Button(action: {
                            selectDocket(docket)
                        }) {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.blue)
                                Text(docket)
                                    .font(.system(size: 14))
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 400, height: 500)
        .onAppear {
            filteredDockets = manager.dockets
            isSearchFocused = true
        }
    }
    
    func updateSearch() {
        if searchText.isEmpty {
            filteredDockets = manager.dockets
        } else {
            filteredDockets = manager.dockets.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    func selectDocket(_ docket: String) {
        selectedDocket = docket
        isPresented = false
        // Delay slightly to ensure sheet closes before job runs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onConfirm()
        }
    }
}

// MARK: - Search View

struct SearchView: View {
    @ObservedObject var manager: MediaManager
    @Binding var isPresented: Bool
    let initialText: String
    @State private var searchText: String
    @State private var exactResults: [String] = []
    @State private var fuzzyResults: [String] = []
    @State private var selectedPath: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isListFocused: Bool

    // Custom initializer to set searchText immediately
    init(manager: MediaManager, isPresented: Binding<Bool>, initialText: String) {
        self.manager = manager
        self._isPresented = isPresented
        self.initialText = initialText
        // Initialize searchText with initialText so it's set before the view appears
        self._searchText = State(initialValue: initialText)
    }

    // MARK: Grouping Helper
    struct YearSection: Identifiable {
        let id = UUID()
        let year: String
        let paths: [String]
    }

    func groupByYear(_ paths: [String]) -> [YearSection] {
        var sections: [YearSection] = []
        var currentYear = ""
        var currentPaths: [String] = []

        for path in paths {
            let year = extractYear(from: path)

            if year != currentYear {
                if !currentPaths.isEmpty {
                    sections.append(YearSection(year: currentYear, paths: currentPaths))
                }
                currentYear = year
                currentPaths = []
            }
            currentPaths.append(path)
        }

        if !currentPaths.isEmpty {
            sections.append(YearSection(year: currentYear, paths: currentPaths))
        }

        return sections
    }

    var groupedExactResults: [YearSection] {
        groupByYear(exactResults)
    }

    var groupedFuzzyResults: [YearSection] {
        groupByYear(fuzzyResults)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: Search Bar
            HStack {
                Image(systemName: manager.isIndexing ? "hourglass" : "magnifyingglass")
                    .foregroundColor(manager.isIndexing ? .orange : .primary)

                NoSelectTextField(
                    text: $searchText,
                    placeholder: manager.isIndexing ? "Building search index..." : "Search sessions...",
                    isEnabled: !manager.isIndexing,
                    onSubmit: {
                        openInFinder()
                    },
                    onTextChange: {
                        performSearch()
                    }
                )
                .padding(10)

                if manager.isIndexing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // MARK: Results List
            ZStack {
                ScrollViewReader { proxy in
                    List(selection: $selectedPath) {
                        // Exact matches section
                        if !exactResults.isEmpty {
                            // Exact results header
                            HStack {
                                VStack {
                                    Divider()
                                }
                                Text("Exact Matches")
                                    .font(.headline)
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 8)
                                VStack {
                                    Divider()
                                }
                            }
                            .padding(.vertical, 12)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                            ForEach(groupedExactResults) { section in
                                ForEach(section.paths, id: \.self) { path in
                                    Button(action: {
                                        // Single click selects
                                        if selectedPath == path {
                                            // Double click (clicking already selected item) opens folder in Finder
                                            let url = URL(fileURLWithPath: path)
                                            NSWorkspace.shared.open(url)
                                            isPresented = false
                                        } else {
                                            selectedPath = path
                                        }
                                    }) {
                                        SearchResultRow(path: path, year: section.year)
                                    }
                                    .buttonStyle(.plain)
                                    .tag(path)
                                }
                            }
                        }

                        // Fuzzy matches section (if any)
                        if !fuzzyResults.isEmpty {
                            // Section divider
                            HStack {
                                VStack {
                                    Divider()
                                }
                                Text("Similar Results")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 8)
                                VStack {
                                    Divider()
                                }
                            }
                            .padding(.vertical, 12)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                            ForEach(groupedFuzzyResults) { section in
                                ForEach(section.paths, id: \.self) { path in
                                    Button(action: {
                                        if selectedPath == path {
                                            // Double click opens folder in Finder
                                            let url = URL(fileURLWithPath: path)
                                            NSWorkspace.shared.open(url)
                                            isPresented = false
                                        } else {
                                            selectedPath = path
                                        }
                                    }) {
                                        HStack {
                                            Image(systemName: "sparkles")
                                                .font(.caption)
                                                .foregroundColor(.orange)
                                            SearchResultRow(path: path, year: section.year)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .tag(path)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .focused($isListFocused)
                    .onChange(of: selectedPath) { oldValue, newValue in
                        if let path = newValue {
                            withAnimation(.easeInOut(duration: 0.08)) {
                                proxy.scrollTo(path, anchor: .center)
                            }
                        }
                    }
                }
                
                // Loading/Empty States
                if isSearching {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Searching...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(8)
                } else if manager.isIndexing && exactResults.isEmpty && fuzzyResults.isEmpty {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Building search index...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(8)
                } else if exactResults.isEmpty && fuzzyResults.isEmpty && !searchText.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("No sessions found")
                            .foregroundColor(.gray)
                        Text("Try adjusting your search terms")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }
            }
            
            // MARK: Action Bar
            HStack {
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Open Folder") {
                    openInFinder()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPath == nil)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 650, height: 500)
        .onChange(of: manager.isIndexing) { oldValue, newValue in
            // Auto-focus search field when indexing completes
            if oldValue && !newValue {
                isSearchFieldFocused = true
                isListFocused = false
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
        // Native Keyboard Navigation
        .onKeyPress(.upArrow) {
            if !exactResults.isEmpty || !fuzzyResults.isEmpty {
                isSearchFieldFocused = false
                isListFocused = true
                moveSelection(-1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if !exactResults.isEmpty || !fuzzyResults.isEmpty {
                isSearchFieldFocused = false
                isListFocused = true
                moveSelection(1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.tab) {
            // Pressing Tab refocuses the search field
            isSearchFieldFocused = true
            isListFocused = false
            return .handled
        }
        .onKeyPress(.escape) {
            // Pressing Escape closes the search sheet
            isPresented = false
            return .handled
        }
        .onKeyPress(.return) {
            // Enter key opens selected item in Finder
            if isListFocused && selectedPath != nil {
                openInFinder()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.delete) {
            // Backspace refocuses search field
            if isListFocused {
                isSearchFieldFocused = true
                isListFocused = false
                return .handled
            }
            return .ignored
        }
        .onKeyPress { press in
            // Any letter/character refocuses search field
            if isListFocused && press.characters.count == 1 {
                let char = press.characters.first!
                if char.isLetter || char.isNumber || char.isWhitespace || char.isPunctuation {
                    isSearchFieldFocused = true
                    isListFocused = false
                    return .handled
                }
            }
            return .ignored
        }
    }
    
    // MARK: - Helper Methods
    
    private func performSearch() {
        // Cancel previous search
        searchTask?.cancel()

        selectedPath = nil

        // Debounce search
        searchTask = Task {
            // Shorter debounce for faster response
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            guard !Task.isCancelled else { return }

            // Set searching state after debounce (reduces UI updates)
            await MainActor.run {
                isSearching = true
            }

            let searchResults = await manager.searchSessions(term: searchText)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                exactResults = searchResults.exactMatches
                fuzzyResults = searchResults.fuzzyMatches
                isSearching = false

                // Auto-select first result (prefer exact matches)
                if let firstResult = searchResults.exactMatches.first ?? searchResults.fuzzyMatches.first {
                    selectedPath = firstResult
                }
            }
        }
    }
    
    private func extractYear(from path: String) -> String {
        let components = (path as NSString).deletingLastPathComponent
            .components(separatedBy: "/")
        
        guard let lastComponent = components.last else {
            return "Unknown"
        }
        
        return lastComponent.components(separatedBy: "_").first ?? "Unknown"
    }
    
    private func openInFinder() {
        guard let path = selectedPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
        isPresented = false
    }
    
    private func moveSelection(_ direction: Int) {
        let allResults = exactResults + fuzzyResults
        guard !allResults.isEmpty else { return }

        if let currentPath = selectedPath,
           let currentIndex = allResults.firstIndex(of: currentPath) {
            let newIndex = min(max(currentIndex + direction, 0), allResults.count - 1)
            selectedPath = allResults[newIndex]
        } else {
            selectedPath = allResults.first
        }
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let path: String
    let year: String
    
    var fileName: String {
        (path as NSString).lastPathComponent
    }
    
    var parentFolder: String {
        (path as NSString).deletingLastPathComponent
            .components(separatedBy: "/").last ?? ""
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .lineLimit(1)
                
                Text(parentFolder)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
