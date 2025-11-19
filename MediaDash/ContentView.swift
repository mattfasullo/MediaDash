import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject var settingsManager = SettingsManager()
    @StateObject var manager: MediaManager
    @State private var selectedDocket: String = ""
    @State private var showNewDocketSheet = false
    @State private var showSearchSheet = false
    @State private var showQuickSearchSheet = false
    @State private var showSettingsSheet = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var hoverInfo: String = "Ready."
    @State private var initialSearchText = ""
    @State private var isStagingAreaVisible = true
    @FocusState private var mainViewFocused: Bool

    // Logic for auto-docket selection
    @State private var showDocketSelectionSheet = false
    @State private var pendingJobType: JobType? = nil

    // Focus management for all navigable buttons
    enum ActionButtonFocus: Hashable {
        case file, prep, both, docketLookup, searchSessions, settings
    }
    @FocusState private var focusedButton: ActionButtonFocus?

    // Easter egg: Windows 95 theme
    @State private var logoClickCount = 0

    // Keyboard mode tracking
    @State private var isKeyboardMode = false

    // Staging area hover state
    @State private var isStagingHovered = false

    // Computed property for current theme
    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }

    // Legacy support for theme checks
    private var isWindows95Theme: Bool {
        currentTheme == .windows95
    }
    private var isWindowsXPTheme: Bool {
        currentTheme == .windowsXP
    }
    private var isMacOS1996Theme: Bool {
        currentTheme == .macos1996
    }
    private var isCursedTheme: Bool {
        currentTheme == .cursed
    }

    // Theme-specific text
    private var themeTitleText: String {
        switch currentTheme {
        case .modern: return "MediaDash"
        case .windows95: return "MediaDash 95"
        case .windowsXP: return "MediaDash XP"
        case .macos1996: return "MediaDash Classic"
        case .retro: return "MEDIADASH.EXE"
        case .cursed: return "M3D!@D@$H"
        }
    }

    private var themeSubtitleText: String {
        switch currentTheme {
        case .modern: return "Professional Media Manager"
        case .windows95: return "Enterprise Edition"
        case .windowsXP: return "Home Edition"
        case .macos1996: return "System 7.5.5"
        case .retro: return "C:\\TOOLS\\MEDIA>"
        case .cursed: return "💀 EXTREME EDITION 💀"
        }
    }

    private var themeTitleFont: Font {
        switch currentTheme {
        case .modern:
            return .system(size: 28, weight: .semibold, design: .rounded)
        case .windows95:
            return .system(size: 28, weight: .bold)
        case .windowsXP:
            return .system(size: 28, weight: .bold, design: .rounded)
        case .macos1996:
            return .system(size: 28, weight: .bold, design: .default)
        case .retro:
            return .system(size: 20, weight: .bold, design: .monospaced)
        case .cursed:
            return .system(size: 32, weight: .black, design: .monospaced)
        }
    }

    init() {
        let settings = SettingsManager()
        _settingsManager = StateObject(wrappedValue: settings)
        _manager = StateObject(wrappedValue: MediaManager(settingsManager: settings))
    }
    
    // Computed dates - File is always today, Prep is next business day
    private var wpDate: Date {
        Date()
    }

    private var prepDate: Date {
        BusinessDayCalculator.nextBusinessDay(
            from: Date(),
            skipWeekends: settingsManager.currentSettings.skipWeekends,
            skipHolidays: settingsManager.currentSettings.skipHolidays
        )
    }

    // Computed total file count (includes files in folders)
    private var totalFileCount: Int {
        manager.selectedFiles.reduce(0) { $0 + $1.fileCount }
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
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 20) {
                    // App Logo (clickable Easter egg)
                    Image("HeaderLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                        .rotationEffect(isCursedTheme ? .degrees(-3) : .degrees(0))
                        .shadow(color: isCursedTheme ? .cyan : .clear, radius: 5, x: 2, y: 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Easter egg: 10 clicks cycles through themes
                            logoClickCount += 1
                            if logoClickCount >= 10 {
                                cycleTheme()
                                logoClickCount = 0
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)
                
                // MARK: Action Buttons
                VStack(spacing: 10) {
                    ActionButtonWithShortcut(
                        title: "FILE",
                        subtitle: "Work Picture",
                        shortcut: "⌘1",
                        color: currentTheme.buttonColors.file,
                        isPrimary: false,
                        isFocused: focusedButton == .file,
                        theme: currentTheme
                    ) {
                        attempt(type: .workPicture)
                    }
                    .focused($focusedButton, equals: .file)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton = nil // Clear keyboard focus on mouse hover
                        }
                        hoverInfo = hovering ?
                            "Files to Work Picture (\(dateFormatter.string(from: wpDate)))" :
                            "Ready."
                    }
                    .keyboardShortcut("1", modifiers: .command)

                    ActionButtonWithShortcut(
                        title: "PREP",
                        subtitle: "Session Prep",
                        shortcut: "⌘2",
                        color: currentTheme.buttonColors.prep,
                        isPrimary: false,
                        isFocused: focusedButton == .prep,
                        theme: currentTheme
                    ) {
                        attempt(type: .prep)
                    }
                    .focused($focusedButton, equals: .prep)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton = nil // Clear keyboard focus on mouse hover
                        }
                        hoverInfo = hovering ?
                            "Files to Session Prep (\(dateFormatter.string(from: prepDate)))" :
                            "Ready."
                    }
                    .keyboardShortcut("2", modifiers: .command)

                    ActionButtonWithShortcut(
                        title: "FILE + PREP",
                        subtitle: "Both",
                        shortcut: "⌘3 or ↵",
                        color: currentTheme.buttonColors.both,
                        isPrimary: false,
                        isFocused: focusedButton == .both,
                        theme: currentTheme
                    ) {
                        attempt(type: .both)
                    }
                    .focused($focusedButton, equals: .both)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton = nil // Clear keyboard focus on mouse hover
                        }
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
                VStack(spacing: 8) {
                    FocusableNavButton(
                        icon: "number.circle",
                        title: "Docket Lookup",
                        shortcut: "⌘D",
                        isFocused: focusedButton == .docketLookup,
                        action: { showQuickSearchSheet = true }
                    )
                    .focused($focusedButton, equals: .docketLookup)
                    .focusEffectDisabled()
                    .keyboardShortcut("d", modifiers: .command)

                    FocusableNavButton(
                        icon: "magnifyingglass",
                        title: "Search Sessions",
                        shortcut: "⌘F",
                        isFocused: focusedButton == .searchSessions,
                        action: { showSearchSheet = true }
                    )
                    .focused($focusedButton, equals: .searchSessions)
                    .focusEffectDisabled()
                    .keyboardShortcut("f", modifiers: .command)

                    FocusableNavButton(
                        icon: "gearshape",
                        title: "Settings",
                        shortcut: "⌘,",
                        isFocused: focusedButton == .settings,
                        action: { showSettingsSheet = true }
                    )
                    .focused($focusedButton, equals: .settings)
                    .focusEffectDisabled()
                    .keyboardShortcut(",", modifiers: .command)
                }
                .padding(.bottom, 20)
            }
            .padding(20)
            .frame(width: 300)
            .background(
                Group {
                    if isCursedTheme {
                        LinearGradient(
                            colors: [.pink, .purple, .orange, .green],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .opacity(0.3)
                    } else {
                        currentTheme.sidebarBackground
                    }
                }
            )

            // Toggle staging button (top right)
            Button(action: {
                isStagingAreaVisible.toggle()
            }) {
                Image(systemName: isStagingAreaVisible ? "chevron.right" : "chevron.left")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(isStagingAreaVisible ? "Hide staging (⌘E)" : "Show staging (⌘E)")
            .keyboardShortcut("e", modifiers: .command)
            .padding(.top, 8)
            .padding(.trailing, 16)
        }

            if isStagingAreaVisible {
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
                            Text("\(totalFileCount)")
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
                                    .fill(Color.gray.opacity(0.1))
                                    .frame(width: 100, height: 100)
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                            }

                            VStack(spacing: 6) {
                                Text("No files staged")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("Click to add files or drop them here")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
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
                                // Show file count for folders, or file size for files
                                if f.isDirectory {
                                    Text("\(f.fileCount) file\(f.fileCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .cornerRadius(4)
                                } else if let size = getFileSize(f.url) {
                                    Text(size)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                    }
                }
                .contentShape(Rectangle())
                .background(isStagingHovered ? Color.gray.opacity(0.05) : Color.clear)
                .onHover { hovering in
                    isStagingHovered = hovering
                }
                .onTapGesture {
                    manager.pickFiles()
                }
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                    return true
                }
                .cursor(.pointingHand)

                // Status Bar
                HStack {
                    // Left side - Indexing indicator
                    if manager.isIndexing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                            Text("Indexing")
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
        }
        .frame(width: isStagingAreaVisible ? 650 : 300, height: 550)
        .focusable()
        .focused($mainViewFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            moveFocus(direction: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            moveFocus(direction: 1)
            return .handled
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
        .onKeyPress(.space) {
            activateFocusedButton()
            return .handled
        }
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
                settingsManager: settingsManager,
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
            // Auto-focus first button when files are added
            if newValue > 0 && focusedButton == nil {
                focusedButton = .file
            }
        }
        .onKeyPress { press in
            // Only handle typing when no sheets are open
            guard !showSearchSheet && !showQuickSearchSheet && !showSettingsSheet && !showNewDocketSheet && !showDocketSelectionSheet else {
                return .ignored
            }

            // Auto-search when typing in main view - opens quick docket search
            if press.characters.count == 1 {
                let char = press.characters.first!
                if char.isLetter || char.isNumber {
                    initialSearchText = String(char)
                    showQuickSearchSheet = true
                    return .handled
                }
            }
            return .ignored
        }
        .sheet(isPresented: $showQuickSearchSheet) {
            QuickDocketSearchView(isPresented: $showQuickSearchSheet, initialText: initialSearchText, settingsManager: settingsManager)
        }
        .onChange(of: showQuickSearchSheet) { oldValue, newValue in
            if !newValue {
                // Clear initial search text and refocus when quick search closes
                initialSearchText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedButton = .file
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(settingsManager: settingsManager, isPresented: $showSettingsSheet)
        }
        .onChange(of: settingsManager.currentSettings) { oldValue, newValue in
            // Update manager's config when settings change
            manager.updateConfig(settings: newValue)
        }
        .onAppear {
            // Auto-focus first action button for keyboard navigation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focusedButton = .file
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
        // 1. If no files are staged, open file picker
        guard !manager.selectedFiles.isEmpty else {
            manager.pickFiles()
            return
        }

        // 2. Always show docket selection sheet
        pendingJobType = type
        showDocketSelectionSheet = true
    }

    private func cycleTheme() {
        let allThemes = AppTheme.allCases
        guard let currentIndex = allThemes.firstIndex(of: currentTheme) else { return }
        let nextIndex = (currentIndex + 1) % allThemes.count
        settingsManager.currentSettings.appTheme = allThemes[nextIndex]
        settingsManager.saveCurrentProfile()
    }

    private func moveFocus(direction: Int) {
        // Only the three main action buttons
        let mainButtons: [ActionButtonFocus] = [.file, .prep, .both]

        // If no button is focused, auto-focus the first one when using arrow keys
        if focusedButton == nil {
            focusedButton = .file
            return
        }

        if let current = focusedButton,
           let currentIndex = mainButtons.firstIndex(of: current) {
            let newIndex = (currentIndex + direction + mainButtons.count) % mainButtons.count
            focusedButton = mainButtons[newIndex]
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
        case .docketLookup:
            showQuickSearchSheet = true
        case .searchSessions:
            showSearchSheet = true
        case .settings:
            showSettingsSheet = true
        }
    }
}

// MARK: - Focusable Nav Button

struct FocusableNavButton: View {
    let icon: String
    let title: String
    let shortcut: String
    let isFocused: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isFocused || isHovered ? .blue : .secondary)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isFocused || isHovered ? .primary : .secondary)

                Spacer()

                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isFocused ? Color.blue.opacity(0.1) : (isHovered ? Color.gray.opacity(0.1) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isFocused ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
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
    let theme: AppTheme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: isPrimary ? 6 : 4) {
                Text(title)
                    .font(buttonTitleFont)
                    .foregroundColor(theme.textColor)
                    .shadow(color: theme.textShadowColor ?? .clear, radius: 2, x: 1, y: 1)
                    .rotationEffect(theme == .cursed ? .degrees(Double.random(in: -5...5)) : .degrees(0))

                if isPrimary {
                    Text(subtitle)
                        .font(buttonSubtitleFont)
                        .foregroundColor(theme.textColor.opacity(0.8))
                        .shadow(color: theme.textShadowColor ?? .clear, radius: 1, x: 1, y: 1)
                }

                Text(shortcut)
                    .font(theme == .cursed ? .system(size: 9, weight: .heavy, design: .monospaced) : .system(size: isPrimary ? 11 : 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textColor.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, isPrimary ? 16 : 12)
            .background(
                Group {
                    if theme == .cursed {
                        LinearGradient(
                            colors: [color, color.opacity(0.5), .purple, .yellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else if theme == .windowsXP {
                        // Authentic Windows XP Luna glossy gradient
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.5), location: 0.0),
                                .init(color: color.opacity(0.9), location: 0.3),
                                .init(color: color, location: 0.5),
                                .init(color: color.opacity(0.8), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        (isHovered || isFocused ? color.opacity(0.9) : color.opacity(0.85))
                    }
                }
            )
            .cornerRadius(theme.buttonCornerRadius)
            .overlay(
                Group {
                    if theme == .windows95 || theme == .macos1996 || theme == .retro {
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(height: 2)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 2)
                                Spacer()
                                Rectangle()
                                    .fill(Color(white: 0.3))
                                    .frame(width: 2)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            HStack(spacing: 0) {
                                Spacer()
                                Rectangle()
                                    .fill(Color(white: 0.3))
                                    .frame(height: 2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else if theme == .windowsXP {
                        RoundedRectangle(cornerRadius: theme.buttonCornerRadius)
                            .strokeBorder(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.white.opacity(0.6), location: 0.0),
                                        .init(color: color.opacity(0.4), location: 0.5),
                                        .init(color: color.opacity(0.8), location: 1.0)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    } else if theme == .cursed {
                        RoundedRectangle(cornerRadius: theme.buttonCornerRadius)
                            .strokeBorder(
                                LinearGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple], startPoint: .leading, endPoint: .trailing),
                                lineWidth: 3
                            )
                    } else {
                        RoundedRectangle(cornerRadius: theme.buttonCornerRadius)
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: isFocused ? 2 : 0)
                    }
                }
            )
            .shadow(
                color: theme == .cursed ? color.opacity(0.8) : (theme == .windows95 || theme == .macos1996 ? .clear : Color.black.opacity(0.15)),
                radius: theme == .cursed ? 15 : 3,
                y: theme == .cursed ? 5 : 1
            )
            .scaleEffect((theme == .windows95 || theme == .macos1996) ? 1.0 : (isHovered || isFocused) ? 1.02 : 1.0)
            .animation(.easeInOut(duration: theme == .cursed ? 0.5 : 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var buttonTitleFont: Font {
        switch theme {
        case .modern:
            return .system(size: isPrimary ? 16 : 13, weight: .bold, design: .rounded)
        case .windows95:
            return .system(size: isPrimary ? 16 : 13, weight: .bold)
        case .windowsXP:
            return .system(size: isPrimary ? 17 : 14, weight: .bold, design: .rounded)
        case .macos1996:
            return .system(size: isPrimary ? 15 : 12, weight: .bold)
        case .retro:
            return .system(size: isPrimary ? 14 : 12, weight: .bold, design: .monospaced)
        case .cursed:
            return .system(size: isPrimary ? 18 : 14, weight: .black, design: .monospaced)
        }
    }

    private var buttonSubtitleFont: Font {
        switch theme {
        case .retro:
            return .system(size: 9, weight: .bold, design: .monospaced)
        case .cursed:
            return .system(size: 9, weight: .heavy)
        default:
            return .system(size: 11, weight: .medium)
        }
    }
}

// MARK: - New Docket View

struct NewDocketView: View {
    @Binding var isPresented: Bool
    @Binding var selectedDocket: String
    @ObservedObject var manager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    var onDocketCreated: (() -> Void)? = nil

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

            // Call the callback if provided
            if let callback = onDocketCreated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    callback()
                }
            }
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
    @ObservedObject var settingsManager: SettingsManager
    @Binding var isPresented: Bool
    @Binding var selectedDocket: String
    var onConfirm: () -> Void

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isListFocused: Bool
    @State private var filteredDockets: [String] = []
    @State private var selectedPath: String?
    @State private var showNewDocketSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.primary)

                NoSelectTextField(
                    text: $searchText,
                    placeholder: "Search dockets...",
                    isEnabled: true,
                    onSubmit: {
                        if let selected = selectedPath {
                            selectDocket(selected)
                        } else if let first = filteredDockets.first {
                            selectDocket(first)
                        }
                    },
                    onTextChange: {
                        performSearch()
                    }
                )
                .padding(10)

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
                        // "Create New Docket" option at the top
                        Button(action: {
                            showNewDocketSheet = true
                        }) {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                                Text("Create New Docket")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.green.opacity(0.1))

                        if !filteredDockets.isEmpty {
                            Section {
                                ForEach(filteredDockets, id: \.self) { docket in
                                    Button(action: {
                                        if selectedPath == docket {
                                            // Double click - select docket
                                            selectDocket(docket)
                                        } else {
                                            selectedPath = docket
                                        }
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
                                    .tag(docket)
                                }
                            } header: {
                                HStack {
                                    VStack {
                                        Divider()
                                    }
                                    Text("Recent Dockets")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 8)
                                    VStack {
                                        Divider()
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color.clear)
                            }
                        }

                        if filteredDockets.isEmpty && !searchText.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "folder.badge.questionmark")
                                    .font(.system(size: 32))
                                    .foregroundColor(.gray.opacity(0.5))
                                Text("No dockets found")
                                    .foregroundColor(.gray)
                                Text("Try adjusting your search or create a new docket")
                                    .font(.caption)
                                    .foregroundColor(.gray.opacity(0.7))
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .listRowBackground(Color.clear)
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
            }

            // MARK: Action Bar
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Select Docket") {
                    if let selected = selectedPath {
                        selectDocket(selected)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPath == nil)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 600, height: 500)
        .onAppear {
            filteredDockets = manager.dockets
            // Auto-select first docket
            if let first = manager.dockets.first {
                selectedPath = first
            }
            isSearchFieldFocused = true
        }
        .sheet(isPresented: $showNewDocketSheet) {
            NewDocketView(
                isPresented: $showNewDocketSheet,
                selectedDocket: $selectedDocket,
                manager: manager,
                settingsManager: settingsManager,
                onDocketCreated: {
                    // When a new docket is created, close both sheets and run the job
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        onConfirm()
                    }
                }
            )
        }
        // Native Keyboard Navigation
        .onKeyPress(.upArrow) {
            if !filteredDockets.isEmpty {
                isSearchFieldFocused = false
                isListFocused = true
                moveSelection(-1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if !filteredDockets.isEmpty {
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
            // Pressing Escape closes the sheet
            isPresented = false
            return .handled
        }
        .onKeyPress(.return) {
            // Enter key selects the docket
            if isListFocused && selectedPath != nil {
                if let selected = selectedPath {
                    selectDocket(selected)
                }
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
        selectedPath = nil

        if searchText.isEmpty {
            filteredDockets = manager.dockets
        } else {
            filteredDockets = manager.dockets.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }

        // Auto-select first result
        if let first = filteredDockets.first {
            selectedPath = first
        }
    }

    private func selectDocket(_ docket: String) {
        selectedDocket = docket
        isPresented = false
        // Delay slightly to ensure sheet closes before job runs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onConfirm()
        }
    }

    private func moveSelection(_ direction: Int) {
        guard !filteredDockets.isEmpty else { return }

        if let currentPath = selectedPath,
           let currentIndex = filteredDockets.firstIndex(of: currentPath) {
            let newIndex = min(max(currentIndex + direction, 0), filteredDockets.count - 1)
            selectedPath = filteredDockets[newIndex]
        } else {
            selectedPath = filteredDockets.first
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

// MARK: - Quick Docket Search (Reference Only)

struct DocketInfo: Identifiable, Hashable {
    let id = UUID()
    let number: String
    let jobName: String
    let fullName: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(fullName)
    }

    static func == (lhs: DocketInfo, rhs: DocketInfo) -> Bool {
        lhs.fullName == rhs.fullName
    }
}

struct QuickDocketSearchView: View {
    @Binding var isPresented: Bool
    let initialText: String
    @ObservedObject var settingsManager: SettingsManager
    @StateObject private var metadataManager = DocketMetadataManager()

    @State private var searchText: String
    @State private var allDockets: [DocketInfo] = []
    @State private var filteredDockets: [DocketInfo] = []
    @State private var isScanning = false
    @State private var selectedDocket: DocketInfo?
    @FocusState private var isSearchFocused: Bool

    init(isPresented: Binding<Bool>, initialText: String, settingsManager: SettingsManager) {
        self._isPresented = isPresented
        self.initialText = initialText
        self.settingsManager = settingsManager
        self._searchText = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Search Bar
            HStack {
                Image(systemName: "number.circle")
                    .foregroundColor(.primary)

                NoSelectTextField(
                    text: $searchText,
                    placeholder: "Search docket numbers or job names...",
                    isEnabled: true,
                    onSubmit: {},
                    onTextChange: {
                        performSearch()
                    }
                )
                .padding(10)

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
                if isScanning {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Scanning server for dockets...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding()
                } else if allDockets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("No Docket Data")
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        if settingsManager.currentSettings.docketSource == .csv {
                            VStack(spacing: 8) {
                                Text("Import a CSV file from Settings to populate docket lookup")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 40)

                                Text("CSV must include columns: docket_number, job_name")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 40)
                            }
                        } else {
                            Text("No dockets found on server. Check Sessions path in Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                    }
                    .padding()
                } else if filteredDockets.isEmpty && !searchText.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 32))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("No dockets found")
                            .foregroundColor(.gray)
                        Text("Try a different search term")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                } else {
                    List {
                        if !filteredDockets.isEmpty {
                            Section {
                                ForEach(filteredDockets) { docket in
                                    Button(action: {
                                        selectedDocket = docket
                                    }) {
                                        HStack(spacing: 12) {
                                            // Number badge
                                            Text(docket.number)
                                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.blue)
                                                .cornerRadius(6)

                                            // Job name and metadata indicator
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(docket.jobName)
                                                    .font(.system(size: 14))
                                                    .foregroundColor(.primary)

                                                if metadataManager.hasMetadata(for: docket.fullName) {
                                                    let meta = metadataManager.getMetadata(forId: docket.fullName)
                                                    HStack(spacing: 4) {
                                                        if !meta.client.isEmpty {
                                                            Text(meta.client)
                                                                .font(.caption)
                                                                .foregroundColor(.secondary)
                                                        }
                                                        if !meta.agency.isEmpty {
                                                            Text("•")
                                                                .font(.caption)
                                                                .foregroundColor(.secondary)
                                                            Text(meta.agency)
                                                                .font(.caption)
                                                                .foregroundColor(.secondary)
                                                        }
                                                    }
                                                }
                                            }

                                            Spacer()

                                            // Metadata indicator
                                            if metadataManager.hasMetadata(for: docket.fullName) {
                                                Image(systemName: "info.circle.fill")
                                                    .foregroundColor(.blue)
                                                    .font(.caption)
                                            }

                                            // Copy button
                                            Button(action: {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(docket.fullName, forType: .string)
                                            }) {
                                                Image(systemName: "doc.on.doc")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Copy full name")
                                        }
                                        .padding(.vertical, 4)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                HStack {
                                    Text("Results")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(filteredDockets.count) docket\(filteredDockets.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        } else if searchText.isEmpty && !allDockets.isEmpty {
                            Section {
                                ForEach(allDockets.prefix(20)) { docket in
                                    HStack(spacing: 12) {
                                        Text(docket.number)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.blue)
                                            .cornerRadius(6)

                                        Text(docket.jobName)
                                            .font(.system(size: 14))

                                        Spacer()

                                        Button(action: {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(docket.fullName, forType: .string)
                                        }) {
                                            Image(systemName: "doc.on.doc")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Copy full name")
                                    }
                                    .padding(.vertical, 4)
                                }
                            } header: {
                                HStack {
                                    Text("Recent Dockets")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("Showing 20 of \(allDockets.count)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }

            // MARK: Info Bar
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Reference only - type to search by number or job name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 600, height: 500)
        .onAppear {
            isSearchFocused = true
            metadataManager.reloadMetadata()
            loadDockets()
        }
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .sheet(item: $selectedDocket) { docket in
            DocketMetadataEditorView(
                docket: docket,
                isPresented: Binding(
                    get: { selectedDocket != nil },
                    set: { if !$0 { selectedDocket = nil } }
                ),
                metadataManager: metadataManager
            )
        }
    }

    private func loadDockets() {
        if settingsManager.currentSettings.docketSource == .csv {
            loadDocketsFromCSV()
        } else {
            scanDocketsFromServer()
        }
    }

    private func loadDocketsFromCSV() {
        // Force reload metadata from CSV
        metadataManager.reloadMetadata()

        // Load dockets from CSV metadata
        var dockets: [DocketInfo] = []

        print("Loading dockets from metadata. Total entries: \(metadataManager.metadata.count)")

        for (_, meta) in metadataManager.metadata {
            dockets.append(DocketInfo(
                number: meta.docketNumber,
                jobName: meta.jobName,
                fullName: meta.id
            ))
        }

        print("Loaded \(dockets.count) valid dockets for display")

        // Sort by number (descending)
        allDockets = dockets.sorted { d1, d2 in
            // Try to compare as numbers first
            if let n1 = Int(d1.number.filter { $0.isNumber }),
               let n2 = Int(d2.number.filter { $0.isNumber }) {
                if n1 == n2 {
                    return d1.jobName < d2.jobName
                }
                return n1 > n2
            }
            // Fallback to string comparison
            if d1.number == d2.number {
                return d1.jobName < d2.jobName
            }
            return d1.number > d2.number
        }

        filteredDockets = allDockets
        performSearch()
    }

    private func scanDocketsFromServer() {
        isScanning = true

        Task.detached(priority: .userInitiated) {
            let config = AppConfig(settings: await settingsManager.currentSettings)
            let sessionsPath = URL(fileURLWithPath: config.settings.sessionsBasePath)
            var docketsDict: [String: DocketInfo] = [:]

            // Scan only top-level directories (depth 2) for performance
            guard let topLevelItems = try? FileManager.default.contentsOfDirectory(
                at: sessionsPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                await MainActor.run {
                    self.isScanning = false
                }
                return
            }

            // Process each top-level directory
            for topItem in topLevelItems {
                guard topItem.hasDirectoryPath else { continue }

                // Check if top-level folder matches docket pattern
                checkAndAddDocket(folderURL: topItem, to: &docketsDict)

                // Also check immediate subdirectories (depth 2)
                if let subItems = try? FileManager.default.contentsOfDirectory(
                    at: topItem,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for subItem in subItems {
                        guard subItem.hasDirectoryPath else { continue }
                        checkAndAddDocket(folderURL: subItem, to: &docketsDict)
                    }
                }

                // Yield to prevent blocking
                await Task.yield()
            }

            // Convert to array and sort by number (descending)
            let dockets = Array(docketsDict.values).sorted { d1, d2 in
                if let n1 = Int(d1.number.filter { $0.isNumber }),
                   let n2 = Int(d2.number.filter { $0.isNumber }) {
                    if n1 == n2 {
                        return d1.jobName < d2.jobName
                    }
                    return n1 > n2
                }
                if d1.number == d2.number {
                    return d1.jobName < d2.jobName
                }
                return d1.number > d2.number
            }

            await MainActor.run {
                self.allDockets = dockets
                self.filteredDockets = dockets
                self.isScanning = false
                self.performSearch()
            }
        }
    }

    nonisolated private func checkAndAddDocket(folderURL: URL, to dict: inout [String: DocketInfo]) {
        let folderName = folderURL.lastPathComponent

        // Parse format: "number_jobName"
        let components = folderName.split(separator: "_", maxSplits: 1)
        guard components.count >= 2 else { return }

        let firstPart = String(components[0])
        let docketNumber = extractDocketNumber(from: firstPart)
        guard !docketNumber.isEmpty else { return }

        // Clean up job name
        let rawJobName = String(components[1])
        let cleanedJobName = cleanJobName(rawJobName)

        // Use full name as unique key to avoid duplicates
        if dict[folderName] == nil {
            dict[folderName] = DocketInfo(
                number: docketNumber,
                jobName: cleanedJobName,
                fullName: folderName
            )
        }
    }

    nonisolated private func extractDocketNumber(from text: String) -> String {
        // Match format: 12345 or 12345-US
        let pattern = #"^(\d+(-[A-Z]{2})?)$"#

        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return String(text[range])
        }

        return ""
    }

    nonisolated private func cleanJobName(_ name: String) -> String {
        var cleaned = name

        // Replace underscores with spaces
        cleaned = cleaned.replacingOccurrences(of: "_", with: " ")

        // Remove common date patterns (including MMMd.yy format like "Nov19.24")
        let datePatterns = [
            #"\s+[A-Z][a-z]{2}\d{1,2}\.\d{2}.*$"#, // " Nov19.24" and everything after
            #"\s+\d{4}.*$"#,           // " 2024" and everything after
            #"\s+\d{2}\.\d{2}.*$"#,    // " 01.24" and everything after
            #"\s+[A-Z][a-z]{2}\d{2}.*$"#, // " Jan24" and everything after
            #"\s+\d{1,2}-\d{1,2}-\d{2,4}.*$"#, // " 1-15-24" and everything after
            #"\s+\d{1,2}\.\d{1,2}\.\d{2,4}.*$"# // " 11.19.24" and everything after
        ]

        for pattern in datePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
        }

        // Remove common initials at the end (BB, VN, CM, etc.)
        let initialsPattern = #"\s+[A-Z]{2}$"#
        if let regex = try? NSRegularExpression(pattern: initialsPattern, options: []) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned),
                withTemplate: ""
            )
        }

        // Trim whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        return cleaned
    }

    private func performSearch() {
        if searchText.isEmpty {
            filteredDockets = allDockets
        } else {
            let search = searchText.lowercased()

            // Check if search starts with a digit (assume docket number search)
            if search.first?.isNumber == true {
                // Exact docket number prefix match
                filteredDockets = allDockets.filter {
                    $0.number.lowercased().hasPrefix(search)
                }
            } else {
                // Job name search - split into words and match all words
                let searchWords = search.split(separator: " ").map { String($0) }

                filteredDockets = allDockets.filter { docket in
                    let jobNameLower = docket.jobName.lowercased()
                    let fullNameLower = docket.fullName.lowercased()

                    // Check if ALL search words appear in either jobName or fullName
                    return searchWords.allSatisfy { word in
                        jobNameLower.contains(word) || fullNameLower.contains(word)
                    }
                }
            }
        }
    }
}

// MARK: - Docket Metadata Editor

struct DocketMetadataEditorView: View {
    let docket: DocketInfo
    @Binding var isPresented: Bool
    @ObservedObject var metadataManager: DocketMetadataManager

    @State private var metadata: DocketMetadata

    init(docket: DocketInfo, isPresented: Binding<Bool>, metadataManager: DocketMetadataManager) {
        self.docket = docket
        self._isPresented = isPresented
        self.metadataManager = metadataManager
        self._metadata = State(initialValue: metadataManager.getMetadata(forId: docket.fullName))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Docket Information")
                        .font(.title2)
                        .fontWeight(.bold)

                    HStack(spacing: 8) {
                        Text(docket.number)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.blue)
                            .cornerRadius(4)

                        Text(docket.jobName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button("Done") {
                    metadataManager.saveMetadata(metadata)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Job Details Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Job Details")
                            .font(.headline)

                        MetadataField(label: "Client", icon: "building.2", text: $metadata.client)
                        MetadataField(label: "Agency", icon: "briefcase", text: $metadata.agency)
                    }

                    Divider()

                    // Production Team Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Production Team")
                            .font(.headline)

                        MetadataField(label: "Producer", icon: "person", text: $metadata.producer)
                        MetadataField(label: "Agency Producer", icon: "person.badge.key", text: $metadata.agencyProducer)
                        MetadataField(label: "Director", icon: "video", text: $metadata.director)
                        MetadataField(label: "Engineer", icon: "waveform", text: $metadata.engineer)
                        MetadataField(label: "Sound Designer", icon: "music.note", text: $metadata.soundDesigner)
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

                    if metadata.lastUpdated > Date.distantPast {
                        HStack {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Last updated: \(metadata.lastUpdated, style: .relative)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Button("Clear All") {
                    metadata = DocketMetadata(docketNumber: docket.number, jobName: docket.jobName)
                }
                .foregroundColor(.red)

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
        .frame(width: 500, height: 650)
    }
}

struct MetadataField: View {
    let label: String
    let icon: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .frame(width: 16)
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

            TextField("Enter \(label.lowercased())", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
