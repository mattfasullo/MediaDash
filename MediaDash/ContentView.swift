import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var metadataManager: DocketMetadataManager
    @EnvironmentObject var manager: MediaManager
    @EnvironmentObject var sessionManager: SessionManager
    @StateObject private var cacheManager = AsanaCacheManager()
    @State private var selectedDocket: String = ""
    @State private var showNewDocketSheet = false
    @State private var showSearchSheet = false
    @State private var showQuickSearchSheet = false
    @State private var showSettingsSheet = false
    @State private var showVideoConverterSheet = false
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
        case file, prep, both, convert, jobInfo, search, settings
    }
    @FocusState private var focusedButton: ActionButtonFocus?

    // Easter egg: Windows 95 theme
    @State private var logoClickCount = 0

    // Keyboard mode tracking
    @State private var isKeyboardMode = false
    @State private var isCommandKeyHeld = false

    // Staging area hover state
    @State private var isStagingHovered = false
    @State private var isStagingPressed = false

    // Computed property for current theme
    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }

    // Theme-specific text
    private var themeTitleText: String {
        switch currentTheme {
        case .modern: return "MediaDash"
        case .retroDesktop: return "MEDIADASH.EXE"
        }
    }

    private var themeSubtitleText: String {
        switch currentTheme {
        case .modern: return "Professional Media Manager"
        case .retroDesktop: return "C:\\TOOLS\\MEDIA>"
        }
    }

    private var themeTitleFont: Font {
        switch currentTheme {
        case .modern:
            return .system(size: 28, weight: .semibold, design: .rounded)
        case .retroDesktop:
            return .system(size: 20, weight: .bold, design: .monospaced)
        }
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
            sidebarView

            if isStagingAreaVisible {
                Divider()
                stagingAreaView
            }
        }
        .frame(width: isStagingAreaVisible ? 650 : 300, height: 550)
        .focusable()
        .focused($mainViewFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            isKeyboardMode = true
            moveGridFocus(direction: .left)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            isKeyboardMode = true
            moveGridFocus(direction: .right)
            return .handled
        }
        .onKeyPress(.upArrow) {
            isKeyboardMode = true
            moveGridFocus(direction: .up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            isKeyboardMode = true
            moveGridFocus(direction: .down)
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
        .alert("Directory Not Connected", isPresented: $manager.showConnectionWarning) {
            Button("OK", role: .cancel) {}
            Button("Open Settings") {
                showSettingsSheet = true
            }
        } message: {
            if let warning = manager.connectionWarning {
                Text(warning)
            }
        }
        .alert("Convert Videos to ProRes Proxy?", isPresented: $manager.showConvertVideosPrompt) {
            Button("Convert", role: .destructive) {
                Task {
                    await manager.convertPrepVideos()
                }
            }
            Button("Skip", role: .cancel) {
                manager.skipPrepVideoConversion()
            }
        } message: {
            if let pending = manager.pendingPrepConversion {
                Text("Found \(pending.videoFiles.count) video file(s). Convert to ProRes Proxy 16:9 1920x1080?\n\nOriginals will be saved in PICTURE/z_unconverted folder.")
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
            SearchView(manager: manager, settingsManager: settingsManager, isPresented: $showSearchSheet, initialText: initialSearchText)
        }
        .sheet(isPresented: $showDocketSelectionSheet) {
            DocketSearchView(
                manager: manager,
                settingsManager: settingsManager,
                isPresented: $showDocketSelectionSheet,
                selectedDocket: $selectedDocket,
                jobType: pendingJobType ?? .workPicture,
                onConfirm: {
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
                initialSearchText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    mainViewFocused = true
                }
            }
        }
        .onChange(of: showSettingsSheet) { oldValue, newValue in
            if !newValue {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    mainViewFocused = true
                }
            }
        }
        .onChange(of: manager.selectedFiles.count) { oldValue, newValue in
            if newValue > 0 && focusedButton == nil {
                focusedButton = .file
            }
        }
        .onKeyPress { press in
            if press.key == .tab {
                isKeyboardMode = true
            }

            guard !showSearchSheet && !showQuickSearchSheet && !showSettingsSheet && !showVideoConverterSheet && !showNewDocketSheet && !showDocketSelectionSheet else {
                return .ignored
            }

            if press.characters.count == 1 {
                let char = press.characters.first!
                if char.isLetter || char.isNumber {
                    initialSearchText = String(char)
                    // Open configured default search
                    if settingsManager.currentSettings.defaultQuickSearch == .search {
                        showSearchSheet = true
                    } else {
                        showQuickSearchSheet = true
                    }
                    isKeyboardMode = true
                    return .handled
                }
            }
            return .ignored
        }
        .onChange(of: focusedButton) { oldValue, newValue in
            if newValue != nil {
                isKeyboardMode = true
            }
        }
        .sheet(isPresented: $showQuickSearchSheet) {
            QuickDocketSearchView(isPresented: $showQuickSearchSheet, initialText: initialSearchText, settingsManager: settingsManager, cacheManager: cacheManager)
        }
        .onChange(of: showQuickSearchSheet) { oldValue, newValue in
            if !newValue {
                initialSearchText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    focusedButton = .file
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(settingsManager: settingsManager, isPresented: $showSettingsSheet)
        }
        .sheet(isPresented: $manager.showPrepSummary) {
            PrepSummaryView(summary: manager.prepSummary, isPresented: $manager.showPrepSummary)
        }
        .sheet(isPresented: $showVideoConverterSheet) {
            VideoConverterView(manager: manager)
        }
        .sheet(isPresented: $manager.showOMFAAFValidator) {
            if let fileURL = manager.omfAafFileToValidate,
               let validator = manager.omfAafValidator {
                OMFAAFValidatorView(validator: validator, fileURL: fileURL)
            }
        }
        .onChange(of: settingsManager.currentSettings) { oldValue, newValue in
            manager.updateConfig(settings: newValue)
            metadataManager.updateSettings(newValue)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                mainViewFocused = true
                focusedButton = .file
            }

            // Build search indexes immediately at app startup
            manager.buildAllFolderIndexes()

            // Monitor Command key state for showing shortcuts
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                isCommandKeyHeld = event.modifierFlags.contains(.command)
                return event
            }
        }
    }

    // MARK: - Sidebar View

    private var sidebarView: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 12) {
                    // App Logo (clickable Easter egg)
                    Image("HeaderLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 60)
                        .rotationEffect(.degrees(0))
                        .shadow(color: .clear, radius: 5, x: 2, y: 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Easter egg: 10 clicks cycles through themes
                            logoClickCount += 1
                            if logoClickCount >= 2 {
                                cycleTheme()
                                logoClickCount = 0
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 4)

                // Workspace Name Display
                if case .loggedIn(let profile) = sessionManager.authenticationState {
                    HStack(spacing: 6) {
                        Image(systemName: profile.name == "Grayson Music" ? "cloud.fill" : "desktopcomputer")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)

                        Text(profile.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.1))
                    )
                }

                // MARK: Action Buttons Grid
                VStack(spacing: 8) {
                    // Row 1: File and Prep
                    HStack(spacing: 8) {
                        ActionButtonWithShortcut(
                            title: "File",
                            subtitle: "Work Picture",
                            shortcut: "⌘1",
                            color: currentTheme.buttonColors.file,
                            isPrimary: false,
                            isFocused: focusedButton == .file,
                            showShortcut: isCommandKeyHeld,
                            theme: currentTheme,
                            iconName: "folder"
                        ) {
                            attempt(type: .workPicture)
                        }
                        .focused($focusedButton, equals: .file)
                        .focusEffectDisabled()
                        .onHover { hovering in
                            if hovering {
                                focusedButton = nil
                                mainViewFocused = true
                                isKeyboardMode = false
                            }
                            hoverInfo = hovering ?
                                "Files to Work Picture (\(dateFormatter.string(from: wpDate)))" :
                                "Ready."
                        }
                        .keyboardShortcut("1", modifiers: .command)

                        ActionButtonWithShortcut(
                            title: "Prep",
                            subtitle: "Session Prep",
                            shortcut: "⌘2",
                            color: currentTheme.buttonColors.prep,
                            isPrimary: false,
                            isFocused: focusedButton == .prep,
                            showShortcut: isCommandKeyHeld,
                            theme: currentTheme,
                            iconName: "list.clipboard"
                        ) {
                            attempt(type: .prep)
                        }
                        .focused($focusedButton, equals: .prep)
                        .focusEffectDisabled()
                        .onHover { hovering in
                            if hovering {
                                focusedButton = nil
                                mainViewFocused = true
                                isKeyboardMode = false
                            }
                            hoverInfo = hovering ?
                                "Files to Session Prep (\(dateFormatter.string(from: prepDate)))" :
                                "Ready."
                        }
                        .keyboardShortcut("2", modifiers: .command)
                    }

                    // Row 2: Both and Convert
                    HStack(spacing: 8) {
                        ActionButtonWithShortcut(
                            title: "File + Prep",
                            subtitle: "Both",
                            shortcut: "⌘3",
                            color: currentTheme.buttonColors.both,
                            isPrimary: false,
                            isFocused: focusedButton == .both,
                            showShortcut: isCommandKeyHeld,
                            theme: currentTheme,
                            iconName: "doc.on.doc"
                        ) {
                            attempt(type: .both)
                        }
                        .focused($focusedButton, equals: .both)
                        .focusEffectDisabled()
                        .onHover { hovering in
                            if hovering {
                                focusedButton = nil
                                mainViewFocused = true
                                isKeyboardMode = false
                            }
                            hoverInfo = hovering ?
                                "Processes both Work Picture and Prep" :
                                "Ready."
                        }
                        .keyboardShortcut("3", modifiers: .command)

                        ActionButtonWithShortcut(
                            title: "Convert Video",
                            subtitle: "ProRes Proxy",
                            shortcut: "⌘4",
                            color: Color(red: 0.50, green: 0.25, blue: 0.25),  // Subtle dark red
                            isPrimary: false,
                            isFocused: focusedButton == .convert,
                            showShortcut: isCommandKeyHeld,
                            theme: currentTheme,
                            iconName: "film"
                        ) {
                            showVideoConverterSheet = true
                        }
                        .focused($focusedButton, equals: .convert)
                        .focusEffectDisabled()
                        .onHover { hovering in
                            if hovering {
                                focusedButton = nil
                                mainViewFocused = true
                                isKeyboardMode = false
                            }
                            hoverInfo = hovering ?
                                "Convert videos" :
                                "Ready."
                        }
                        .keyboardShortcut("4", modifiers: .command)
                    }
                }

                Spacer()

                Divider()

                // Bottom actions
                VStack(spacing: 8) {
                    FocusableNavButton(
                        icon: "magnifyingglass",
                        title: "Search",
                        shortcut: "⌘F",
                        isFocused: focusedButton == .search,
                        showShortcut: isCommandKeyHeld,
                        action: { showSearchSheet = true }
                    )
                    .focused($focusedButton, equals: .search)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton = nil
                            mainViewFocused = true
                            isKeyboardMode = false
                        }
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    FocusableNavButton(
                        icon: "number.circle",
                        title: "Job Info",
                        shortcut: "⌘D",
                        isFocused: focusedButton == .jobInfo,
                        showShortcut: isCommandKeyHeld,
                        action: { showQuickSearchSheet = true }
                    )
                    .focused($focusedButton, equals: .jobInfo)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton = nil
                            mainViewFocused = true
                            isKeyboardMode = false
                        }
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    
                    FocusableNavButton(
                        icon: "gearshape",
                        title: "Settings",
                        shortcut: "⌘,",
                        isFocused: focusedButton == .settings,
                        showShortcut: isCommandKeyHeld,
                        action: { showSettingsSheet = true }
                    )
                    .focused($focusedButton, equals: .settings)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton = nil
                            mainViewFocused = true
                            isKeyboardMode = false
                        }
                    }
                    .keyboardShortcut(",", modifiers: .command)

                    Divider()
                        .padding(.vertical, 4)

                    // Log Out Button
                    Button(action: {
                        sessionManager.logout()
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 14))
                                .foregroundColor(.red)
                                .frame(width: 18)

                            Text("Log Out")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.red)

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.1))
                    )
                }
                .padding(.bottom, 12)
            }
            .padding(16)
            .frame(width: 300)
            .background(currentTheme.sidebarBackground)

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
    }

    // MARK: - Staging Area View

    private var stagingAreaView: some View {
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

                    // Always show Add Files button
                    HoverableButton(action: { manager.pickFiles() }) { isHovered in
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11))
                            Text("Add Files")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(isHovered ? .blue.opacity(0.8) : .blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isHovered ? Color.blue.opacity(0.1) : Color.clear)
                        .cornerRadius(6)
                    }
                    .keyboardShortcut("o", modifiers: .command)

                    if !manager.selectedFiles.isEmpty {
                        HoverableButton(action: { manager.clearFiles() }) { isHovered in
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                Text("Clear")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(isHovered ? .red.opacity(0.8) : .red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isHovered ? Color.red.opacity(0.1) : Color.clear)
                            .cornerRadius(6)
                        }
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
                                    .fill(isStagingPressed ? Color.blue.opacity(0.2) : (isStagingHovered ? Color.gray.opacity(0.15) : Color.gray.opacity(0.1)))
                                    .frame(width: 100, height: 100)
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 40))
                                    .foregroundColor(isStagingPressed ? .blue : .secondary)
                            }
                            .scaleEffect(isStagingPressed ? 0.95 : (isStagingHovered ? 1.05 : 1.0))
                            .animation(.easeInOut(duration: 0.15), value: isStagingPressed)
                            .animation(.easeInOut(duration: 0.15), value: isStagingHovered)

                            VStack(spacing: 6) {
                                Text("No files staged")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("Click to add files or drop them here")
                                    .font(.system(size: 13))
                                    .foregroundColor(isStagingPressed ? .blue : .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // File List
                        List(manager.selectedFiles) { f in
                            ZStack(alignment: .leading) {
                                // Progress bar background
                                if let progress = manager.fileProgress[f.id], progress > 0 {
                                    GeometryReader { geometry in
                                        Rectangle()
                                            .fill(Color.blue.opacity(0.2))
                                            .frame(width: geometry.size.width * progress)
                                    }
                                } else if let convProgress = manager.conversionProgress[f.id], convProgress > 0 {
                                    GeometryReader { geometry in
                                        Rectangle()
                                            .fill(Color.purple.opacity(0.2))
                                            .frame(width: geometry.size.width * convProgress)
                                    }
                                }

                                // File info
                                HStack {
                                    Image(nsImage: getIcon(f.url))
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                    Text(f.name)
                                    Spacer()

                                    // Show checkmark, progress, or file info
                                    if let completionState = manager.fileCompletionState[f.id] {
                                        switch completionState {
                                        case .complete:
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.system(size: 16))
                                        case .workPicDone, .prepDone:
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.yellow)
                                                .font(.system(size: 16))
                                        case .none:
                                            EmptyView()
                                        }
                                    } else if let convProgress = manager.conversionProgress[f.id], convProgress > 0, convProgress < 1.0 {
                                        HStack(spacing: 4) {
                                            Image(systemName: "film")
                                                .font(.system(size: 10))
                                            Text("\(Int(convProgress * 100))%")
                                                .font(.caption)
                                                .monospacedDigit()
                                        }
                                        .foregroundColor(.purple)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.purple.opacity(0.1))
                                        .cornerRadius(4)
                                    } else if let progress = manager.fileProgress[f.id], progress > 0, progress < 1.0 {
                                        Text("\(Int(progress * 100))%")
                                            .font(.caption)
                                            .monospacedDigit()
                                            .foregroundColor(.blue)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.1))
                                            .cornerRadius(4)
                                    } else {
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
                                    
                                    // Remove button
                                    HoverableButton(action: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            manager.removeFile(withId: f.id)
                                        }
                                    }) { isHovered in
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(isHovered ? .red : (currentTheme == .retroDesktop ? Color(red: 0.502, green: 0.502, blue: 0.502) : .secondary))
                                            .font(.system(size: 14))
                                            .scaleEffect(isHovered ? 1.15 : 1.0)
                                    }
                                    .help("Remove from staging")
                                }
                            }
                            .contextMenu {
                                // Remove option
                                Button("Remove from Staging") {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        manager.removeFile(withId: f.id)
                                    }
                                }
                                
                                // Show context menu for OMF/AAF files
                                if !f.isDirectory {
                                    let ext = f.url.pathExtension.lowercased()
                                    if ext == "omf" {
                                        Divider()
                                        Button("Validate OMF") {
                                            manager.omfAafFileToValidate = f.url
                                            manager.showOMFAAFValidator = true
                                        }
                                    } else if ext == "aaf" {
                                        Divider()
                                        Button("Validate AAF") {
                                            manager.omfAafFileToValidate = f.url
                                            manager.showOMFAAFValidator = true
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                        .animation(.easeInOut(duration: 0.3), value: manager.selectedFiles)
                        .animation(.easeInOut(duration: 0.2), value: manager.fileProgress)
                        .animation(.easeInOut(duration: 0.2), value: manager.conversionProgress)
                        .animation(.easeInOut(duration: 0.3), value: manager.fileCompletionState)
                    }
                }
                .contentShape(Rectangle())
                .background(
                    Group {
                        if isStagingPressed {
                            Color.blue.opacity(0.15)
                        } else if isStagingHovered {
                            Color.gray.opacity(0.05)
                        } else {
                            Color.clear
                        }
                    }
                )
                .scaleEffect(isStagingPressed ? 0.998 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isStagingPressed)
                .onHover { hovering in
                    isStagingHovered = hovering
                    if hovering {
                        isKeyboardMode = false
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isStagingPressed {
                                isStagingPressed = true
                            }
                        }
                        .onEnded { _ in
                            isStagingPressed = false
                            manager.pickFiles()
                        }
                )
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                    return true
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

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

    enum GridDirection {
        case up, down, left, right
    }

    private func moveGridFocus(direction: GridDirection) {
        // Grid layout: [file, prep]
        //              [both, convert]
        // Then linear: [search, jobInfo, settings]

        // If no button is focused, auto-focus the first one
        if focusedButton == nil {
            focusedButton = .file
            return
        }

        guard let current = focusedButton else { return }

        switch direction {
        case .up:
            switch current {
            case .file, .prep:
                focusedButton = .settings  // Wrap to bottom
            case .both:
                focusedButton = .file
            case .convert:
                focusedButton = .prep
            case .search:
                focusedButton = .both  // Return to grid from below
            case .jobInfo:
                focusedButton = .search
            case .settings:
                focusedButton = .jobInfo
            }

        case .down:
            switch current {
            case .file:
                focusedButton = .both
            case .prep:
                focusedButton = .convert
            case .both, .convert:
                focusedButton = .search
            case .search:
                focusedButton = .jobInfo
            case .jobInfo:
                focusedButton = .settings
            case .settings:
                focusedButton = .file  // Wrap to top
            }

        case .left:
            switch current {
            case .prep:
                focusedButton = .file
            case .convert:
                focusedButton = .both
            default:
                break  // No left movement from left column or linear items
            }

        case .right:
            switch current {
            case .file:
                focusedButton = .prep
            case .both:
                focusedButton = .convert
            default:
                break  // No right movement from right column or linear items
            }
        }
    }

    private func moveFocus(direction: Int) {
        // Linear navigation fallback
        let mainButtons: [ActionButtonFocus] = [.file, .prep, .both, .convert, .search, .jobInfo, .settings]

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
        case .convert:
            showVideoConverterSheet = true
        case .jobInfo:
            showQuickSearchSheet = true
        case .search:
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
    let showShortcut: Bool
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

                if showShortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                }
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
    let showShortcut: Bool
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

                if showShortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.6))
                }
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

// MARK: - Color Extension for Brightening

extension Color {
    func brightened(by amount: Double = 0.2) -> Color {
        let uiColor = NSColor(self)
        guard let components = uiColor.cgColor.components else { return self }

        let r = min(1.0, (components[0] + amount))
        let g = min(1.0, (components[1] + amount))
        let b = min(1.0, (components[2] + amount))
        let a = components.count > 3 ? components[3] : 1.0

        return Color(red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Hoverable Button

struct HoverableButton<Content: View>: View {
    let action: () -> Void
    let content: (Bool) -> Content
    @State private var isHovered = false
    
    init(action: @escaping () -> Void, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.action = action
        self.content = content
    }
    
    var body: some View {
        Button(action: action) {
            content(isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Hoverable List Button (for List items)

struct HoverableListButton<Content: View>: View {
    let action: () -> Void
    let content: (Bool) -> Content
    @State private var isHovered = false
    
    init(action: @escaping () -> Void, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.action = action
        self.content = content
    }
    
    var body: some View {
        Button(action: action) {
            content(isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
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
    let showShortcut: Bool
    let theme: AppTheme
    let iconName: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Translucent background icon
                if let iconName = iconName {
                    Image(systemName: iconName)
                        .font(.system(size: 50, weight: .thin))
                        .foregroundColor(theme.textColor.opacity(0.08))
                        .rotationEffect(.degrees(0))
                }

                VStack(spacing: 0) {
                    Spacer()

                    // Main content - centered
                    Text(title)
                        .font(buttonTitleFont)
                        .foregroundColor(theme.textColor)
                        .shadow(color: theme.textShadowColor ?? .clear, radius: 2, x: 1, y: 1)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .rotationEffect(.degrees(0))

                    Spacer()
                    Spacer()

                    // Shortcut - positioned in lower third
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textColor.opacity(showShortcut ? 0.6 : 0.0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(showShortcut ? 0.2 : 0.0))
                        .cornerRadius(4)
                        .opacity(showShortcut ? 1 : 0)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                (isHovered || isFocused ? color.brightened(by: 0.15) : color)
            )
            .cornerRadius(theme.buttonCornerRadius)
            .overlay(
                Group {
                    if theme == .retroDesktop {
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
                    } else {
                        RoundedRectangle(cornerRadius: theme.buttonCornerRadius)
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: isFocused ? 2 : 0)
                    }
                }
            )
            .shadow(
                color: theme == .retroDesktop ? .clear : Color.black.opacity(0.15),
                radius: 3,
                y: 1
            )
            .scaleEffect((isHovered || isFocused) ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
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
        case .retroDesktop:
            return .system(size: isPrimary ? 14 : 12, weight: .bold, design: .monospaced)
        }
    }

    private var buttonSubtitleFont: Font {
        switch theme {
        case .retroDesktop:
            return .system(size: 9, weight: .bold, design: .monospaced)
        case .modern:
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
        
        // Verify parent directory exists before creating docket folder
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.workPic.path) else {
            validationMessage = "Work Picture folder path does not exist:\n\(paths.workPic.path)\n\nPlease check your settings and make sure the server is connected."
            showValidationError = true
            return
        }
        
        let docketFolder = paths.workPic.appendingPathComponent(docketName)

        // Only create the docket folder, not parent directories
        // Parent directory (paths.workPic) must already exist
        do {
            try FileManager.default.createDirectory(at: docketFolder, withIntermediateDirectories: false)
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
            validationMessage = "Failed to create docket folder: \(error.localizedDescription)\n\nPath: \(docketFolder.path)"
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
            // Handle Enter key
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }

            // Let arrow keys pass through to SwiftUI handlers
            // This allows navigation and folder cycling to work
            if commandSelector == #selector(NSResponder.moveUp(_:)) ||
               commandSelector == #selector(NSResponder.moveDown(_:)) ||
               commandSelector == #selector(NSResponder.moveLeft(_:)) ||
               commandSelector == #selector(NSResponder.moveRight(_:)) {
                return false  // Don't consume, let it bubble up
            }

            // Let delete/backspace pass through
            if commandSelector == #selector(NSResponder.deleteBackward(_:)) ||
               commandSelector == #selector(NSResponder.deleteForward(_:)) {
                return false  // Don't consume, let it bubble up
            }

            return false  // Don't consume other commands
        }
    }
}

// MARK: - Docket Selection Search View (New)

struct DocketSearchView: View {
    @ObservedObject var manager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var isPresented: Bool
    @Binding var selectedDocket: String
    var jobType: JobType = .workPicture
    var onConfirm: () -> Void

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isListFocused: Bool
    @State private var filteredDockets: [String] = []
    @State private var selectedPath: String?
    @State private var showNewDocketSheet = false
    @State private var allDockets: [String] = []
    @State private var showExistingPrepAlert = false
    @State private var existingPrepFolders: [String] = []

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
            // Scan dockets based on job type
            Task {
                let currentConfig = manager.config
                let dockets = await Task.detached {
                    MediaLogic.scanDockets(config: currentConfig, jobType: jobType)
                }.value
                await MainActor.run {
                    allDockets = dockets
                    filteredDockets = dockets
                    // Auto-select first docket
                    if let first = dockets.first {
                        selectedPath = first
                    }
                    isSearchFieldFocused = true
                }
            }
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
        .alert("Existing Prep Folder Found", isPresented: $showExistingPrepAlert) {
            Button("Use Existing", action: useExistingPrepFolder)
            Button("Create New", action: createNewPrepFolder)
            Button("Cancel", role: .cancel) {
                showExistingPrepAlert = false
            }
        } message: {
            if existingPrepFolders.count == 1 {
                Text("A prep folder already exists for this docket:\n\(existingPrepFolders[0])\n\nDo you want to add files to the existing folder or create a new one?")
            } else {
                Text("\(existingPrepFolders.count) prep folders exist for this docket. Do you want to add to the most recent one or create a new folder?")
            }
        }
    }

    // MARK: - Helper Methods

    private func performSearch() {
        selectedPath = nil

        if searchText.isEmpty {
            filteredDockets = allDockets
        } else {
            filteredDockets = allDockets.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }

        // Auto-select first result
        if let first = filteredDockets.first {
            selectedPath = first
        }
    }

    private func selectDocket(_ docket: String) {
        selectedDocket = docket

        // For "Both" mode, check if prep folders already exist
        if jobType == .both {
            checkForExistingPrepFolders(docket: docket)
        } else {
            isPresented = false
            // Delay slightly to ensure sheet closes before job runs
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                onConfirm()
            }
        }
    }

    private func checkForExistingPrepFolders(docket: String) {
        Task {
            let prepPath = manager.config.getPaths().prep
            let fm = FileManager.default

            var existingFolders: [String] = []

            if let items = try? fm.contentsOfDirectory(at: prepPath, includingPropertiesForKeys: nil) {
                for item in items {
                    // Check if folder matches prep folder format for this docket
                    // Prep folders typically start with "{docket}_PREP_" or use the configured format
                    let prepPrefix = "\(docket)_PREP_"
                    if item.hasDirectoryPath && item.lastPathComponent.hasPrefix(prepPrefix) {
                        existingFolders.append(item.lastPathComponent)
                    }
                }
            }

            await MainActor.run {
                if !existingFolders.isEmpty {
                    existingPrepFolders = existingFolders
                    showExistingPrepAlert = true
                } else {
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        onConfirm()
                    }
                }
            }
        }
    }

    private func useExistingPrepFolder() {
        // For now, just proceed - the runJob will create a new folder anyway
        // In the future, we could modify runJob to use an existing folder
        showExistingPrepAlert = false
        isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onConfirm()
        }
    }

    private func createNewPrepFolder() {
        showExistingPrepAlert = false
        isPresented = false
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
    @ObservedObject var settingsManager: SettingsManager
    @Binding var isPresented: Bool
    let initialText: String
    @State private var searchText: String
    @State private var exactResults: [String] = []
    @State private var fuzzyResults: [String] = []
    @State private var selectedPath: String?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedFolder: SearchFolder
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isListFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    // Cache search results for all folders
    @State private var cachedResults: [SearchFolder: (exact: [String], fuzzy: [String])] = [:]

    // Custom initializer to set searchText immediately
    init(manager: MediaManager, settingsManager: SettingsManager, isPresented: Binding<Bool>, initialText: String) {
        self.manager = manager
        self.settingsManager = settingsManager
        self._isPresented = isPresented
        self.initialText = initialText
        // Initialize searchText with initialText so it's set before the view appears
        self._searchText = State(initialValue: initialText)

        // Initialize selected folder based on settings
        let settings = settingsManager.currentSettings
        if settings.searchFolderPreference == .rememberLast, let lastUsed = settings.lastUsedSearchFolder {
            self._selectedFolder = State(initialValue: lastUsed)
        } else {
            self._selectedFolder = State(initialValue: settings.defaultSearchFolder)
        }
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

    private func folderButton(_ folder: SearchFolder) -> some View {
        let isSelected = selectedFolder == folder
        return Button(action: {
            selectedFolder = folder
            if settingsManager.currentSettings.searchFolderPreference == .rememberLast {
                settingsManager.currentSettings.lastUsedSearchFolder = folder
                settingsManager.saveCurrentProfile()
            }
            // Switch to cached results (instant) and maintain focus
            updateDisplayedResults()
            isSearchFieldFocused = true
            isListFocused = false

            // Aggressively restore focus with delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                isSearchFieldFocused = true
                isListFocused = false
            }
        }) {
            Text(folder.displayName)
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.clear)
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    var folderSelectorView: some View {
        HStack(spacing: 4) {
            ForEach(SearchFolder.allCases, id: \.self) { folder in
                folderButton(folder)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Search Bar
            HStack {
                Image(systemName: manager.isIndexing ? "hourglass" : "magnifyingglass")
                    .foregroundColor(manager.isIndexing ? .orange : .primary)

                NoSelectTextField(
                    text: $searchText,
                    placeholder: manager.isIndexing ? "Type to search (indexing in progress)..." : "Search sessions...",
                    isEnabled: true,
                    onSubmit: {
                        openInFinder()
                    },
                    onTextChange: {
                        // Always allow typing, but defer search until index is ready
                        Task { @MainActor in
                            performSearch()
                        }
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

            // MARK: Folder Selector
            folderSelectorView

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
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Searching...")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .frame(width: 180)
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(8)
                } else if manager.isIndexing && exactResults.isEmpty && fuzzyResults.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Building search index...")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .frame(width: 180)
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(8)
                } else if exactResults.isEmpty && fuzzyResults.isEmpty && !searchText.isEmpty && !manager.isIndexing {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Populating list...")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .frame(width: 180)
                    .padding()
                    .background(.regularMaterial)
                    .cornerRadius(8)
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
        .onAppear {
            // Set initial focus when view appears
            isSearchFieldFocused = true
            isListFocused = false

            // Perform initial search if there's text (index was pre-built at app startup)
            if !searchText.isEmpty && !manager.isIndexing {
                performSearch()
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Restore focus when window becomes active
            if newPhase == .active {
                isSearchFieldFocused = true
                isListFocused = false
            }
        }
        .onChange(of: manager.isIndexing) { oldValue, newValue in
            // When indexing completes, re-run search if there's text
            if oldValue && !newValue {
                isSearchFieldFocused = true
                isListFocused = false

                // Re-search with existing text if any
                if !searchText.isEmpty {
                    performSearch(immediate: true)
                }
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
        // Folder Cycling with Cmd+Arrow - MUST BE FIRST to capture before other handlers
        .onKeyPress { press in
            if press.modifiers.contains(.command) {
                if press.key == .leftArrow {
                    cycleFolder(direction: -1)
                    return .handled
                } else if press.key == .rightArrow {
                    cycleFolder(direction: 1)
                    return .handled
                }
            }
            return .ignored
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
            // Any letter/character refocuses search field and adds the character
            if isListFocused && press.characters.count == 1 {
                let char = press.characters.first!
                if char.isLetter || char.isNumber || char.isWhitespace || char.isPunctuation {
                    // Defer state updates to avoid publishing during view updates
                    Task { @MainActor in
                        // Append the character to search text
                        searchText += String(char)
                        // Refocus search field
                        isSearchFieldFocused = true
                        isListFocused = false
                        // Trigger search with new text
                        performSearch()
                    }
                    return .handled
                }
            }
            return .ignored
        }
    }

    // MARK: - Helper Methods

    private func performSearch(immediate: Bool = false) {
        // Don't search if index is still building
        guard !manager.isIndexing else {
            return
        }

        // Cancel previous search
        searchTask?.cancel()

        selectedPath = nil

        // If search text is empty, clear results immediately
        if searchText.isEmpty {
            cachedResults.removeAll()
            exactResults = []
            fuzzyResults = []
            isSearching = false
            return
        }

        // Set searching state immediately
        isSearching = true

        searchTask = Task {
            do {
                // Debounce search only when typing (not when changing folders)
                if !immediate {
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    guard !Task.isCancelled else {
                        await MainActor.run { isSearching = false }
                        return
                    }
                }

                // Search all folders simultaneously with error handling
                let currentSearchText = searchText

                // Wrap searches in error handling
                let workPictureResults = await manager.searchSessions(term: currentSearchText, folder: .workPicture)
                guard !Task.isCancelled else {
                    await MainActor.run { isSearching = false }
                    return
                }

                let mediaPostingsResults = await manager.searchSessions(term: currentSearchText, folder: .mediaPostings)
                guard !Task.isCancelled else {
                    await MainActor.run { isSearching = false }
                    return
                }

                let sessionsResults = await manager.searchSessions(term: currentSearchText, folder: .sessions)
                guard !Task.isCancelled else {
                    await MainActor.run { isSearching = false }
                    return
                }

                await MainActor.run {
                    // Cache all results - always update cache even if empty
                    cachedResults[.workPicture] = (workPictureResults.exactMatches, workPictureResults.fuzzyMatches)
                    cachedResults[.mediaPostings] = (mediaPostingsResults.exactMatches, mediaPostingsResults.fuzzyMatches)
                    cachedResults[.sessions] = (sessionsResults.exactMatches, sessionsResults.fuzzyMatches)

                    // Display results for currently selected folder
                    // isSearching will be set to false inside updateDisplayedResults after results are displayed
                    updateDisplayedResults()
                }
            } catch {
                // If there's any error, ensure we reset the state
                await MainActor.run {
                    isSearching = false
                    // Ignore cancellation errors (expected when typing quickly)
                    if !(error is CancellationError) {
                        print("Search error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func updateDisplayedResults() {
        // Validate that indexes are built for this folder
        if manager.folderCaches[selectedFolder] == nil && !manager.isIndexing {
            print("Warning: No index for \(selectedFolder.displayName), triggering rebuild")
            manager.buildSessionIndex(folder: selectedFolder)
        }

        // Defer state updates to avoid publishing during view updates
        Task { @MainActor in
            if let cached = cachedResults[selectedFolder] {
                exactResults = cached.exact
                fuzzyResults = cached.fuzzy

                // Auto-select first result (prefer exact matches)
                if let firstResult = cached.exact.first ?? cached.fuzzy.first {
                    selectedPath = firstResult
                } else {
                    selectedPath = nil
                }

                // Set isSearching to false AFTER results are displayed
                isSearching = false
            } else {
                // No cached results for this folder yet
                exactResults = []
                fuzzyResults = []
                selectedPath = nil

                // If there's text to search and we're not already searching, trigger a search
                if !searchText.isEmpty && !isSearching && !manager.isIndexing {
                    print("No cached results for \(selectedFolder.displayName), triggering search")
                    performSearch(immediate: true)
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

    private func cycleFolder(direction: Int) {
        let allFolders = SearchFolder.allCases
        guard let currentIndex = allFolders.firstIndex(of: selectedFolder) else { return }

        let newIndex = (currentIndex + direction + allFolders.count) % allFolders.count

        // Defer state changes to next run loop to avoid SwiftUI warning
        DispatchQueue.main.async {
            self.selectedFolder = allFolders[newIndex]

            // Save to settings if remember last is enabled
            if self.settingsManager.currentSettings.searchFolderPreference == .rememberLast {
                self.settingsManager.currentSettings.lastUsedSearchFolder = self.selectedFolder
                self.settingsManager.saveCurrentProfile()
            }

            // Switch to cached results (instant)
            self.updateDisplayedResults()
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

struct DocketInfo: Identifiable, Hashable, Codable {
    let id: UUID
    let number: String
    let jobName: String
    let fullName: String
    
    nonisolated init(id: UUID = UUID(), number: String, jobName: String, fullName: String) {
        self.id = id
        self.number = number
        self.jobName = jobName
        self.fullName = fullName
    }

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
    @ObservedObject var cacheManager: AsanaCacheManager
    @StateObject private var metadataManager: DocketMetadataManager

    @State private var searchText: String
    @State private var allDockets: [DocketInfo] = []
    @State private var filteredDockets: [DocketInfo] = []
    @State private var isScanning = false
    @State private var selectedDocket: DocketInfo?
    @State private var asanaError: String?
    @FocusState private var isSearchFocused: Bool
    @State private var searchTask: Task<Void, Never>?

    init(isPresented: Binding<Bool>, initialText: String, settingsManager: SettingsManager, cacheManager: AsanaCacheManager) {
        self._isPresented = isPresented
        self.initialText = initialText
        self.settingsManager = settingsManager
        self.cacheManager = cacheManager
        self._searchText = State(initialValue: initialText)
        self._metadataManager = StateObject(wrappedValue: DocketMetadataManager(settings: settingsManager.currentSettings))
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
                    onSubmit: {
                        performSearch()
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

            // MARK: Sync Status Banner (non-blocking)
            if cacheManager.isSyncing {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Syncing with Asana...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if let lastSync = cacheManager.lastSyncDate {
                        Text("Last sync: \(lastSync, style: .relative)")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }

            // MARK: Results List
            ZStack {
                if isScanning {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        if settingsManager.currentSettings.docketSource == .asana {
                            Text("Searching cache...")
                                .font(.caption)
                                .foregroundColor(.gray)
                        } else {
                        Text("Scanning server for dockets...")
                            .font(.caption)
                            .foregroundColor(.gray)
                        }
                    }
                    .padding()
                } else if allDockets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.gray.opacity(0.5))
                        
                        if settingsManager.currentSettings.docketSource == .asana {
                            if searchText.isEmpty {
                                Text("Type to search Asana...")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                Text("Search by docket number or job name")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("No Results")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                Text("No dockets found matching '\(searchText)'")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                        Text("No Docket Data")
                            .font(.title3)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        }
                        
                        if let error = asanaError {
                            VStack(spacing: 8) {
                                Text("Asana Error:")
                                    .font(.caption)
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
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
            
            let settings = settingsManager.currentSettings
            
            // Only load dockets on appear if NOT using Asana (Asana uses cache)
            if settings.docketSource != .asana {
            loadDockets()
            } else {
                // For Asana: Load existing cache immediately for instant search
                let cachedDockets = cacheManager.loadCachedDockets()
                if !cachedDockets.isEmpty {
                    allDockets = cachedDockets
                    filteredDockets = cachedDockets
                    print("📦 [CACHE] Loaded \(cachedDockets.count) dockets from cache")
                } else {
                    print("📦 [CACHE] Cache is empty - waiting for sync...")
                }
                
                // Sync cache in background if needed (stale or missing)
                if cacheManager.shouldSync() {
                    print("🔵 [QuickSearch] Cache is stale or missing, syncing with Asana in background...")
                    Task {
                        do {
                            try await cacheManager.syncWithAsana(
                                workspaceID: settings.asanaWorkspaceID,
                                projectID: settings.asanaProjectID,
                                docketField: settings.asanaDocketField,
                                jobNameField: settings.asanaJobNameField
                            )
                            print("🟢 [QuickSearch] Cache sync complete")
                            
                            // Update results with fresh cache after sync
                            await MainActor.run {
                                let freshDockets = cacheManager.loadCachedDockets()
                                if !freshDockets.isEmpty {
                                    allDockets = freshDockets
                                    // Re-apply current search filter if there's search text
                                    if !searchText.isEmpty {
                                        filteredDockets = cacheManager.searchCachedDockets(query: searchText)
                                    } else {
                                        filteredDockets = freshDockets
                                    }
                                    print("🟢 [QuickSearch] Updated results with fresh cache (\(freshDockets.count) dockets)")
                                }
                            }
                        } catch {
                            print("🔴 [QuickSearch] Cache sync failed: \(error.localizedDescription)")
                            await MainActor.run {
                                asanaError = "Failed to sync with Asana: \(error.localizedDescription)"
                            }
                        }
                    }
                } else {
                    print("🟢 [QuickSearch] Cache is fresh, no sync needed")
                }
            }
        }
        .onDisappear {
            // Cancel any pending search
            searchTask?.cancel()
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
        print("🔵 [ContentView] loadDockets() called")
        var settings = settingsManager.currentSettings
        print("🔵 [ContentView] Docket source: \(settings.docketSource)")
        
        // TEMPORARILY DISABLED FOR ASANA DEBUGGING - Force Asana
        if settings.docketSource != .asana {
            print("⚠️ [ContentView] WARNING: Docket source is \(settings.docketSource), forcing to Asana for debugging")
            settings.docketSource = .asana
            settingsManager.currentSettings = settings
            settingsManager.saveCurrentProfile()
        }
        
        // TEMPORARILY DISABLED FOR ASANA DEBUGGING - Only Asana is used
        // Use the selected docket source (mutually exclusive)
        switch settings.docketSource {
        case .asana:
            print("🔵 [ContentView] Using Asana source (cache-based)")
            // Asana now uses cache - sync happens in onAppear of QuickDocketSearchView
            // Just load from cache if available
            let cachedDockets = cacheManager.loadCachedDockets()
            if !cachedDockets.isEmpty {
                allDockets = cachedDockets
                filteredDockets = cachedDockets
                print("🟢 [ContentView] Loaded \(cachedDockets.count) dockets from cache")
        } else {
                print("🔵 [ContentView] Cache is empty, will sync on search view appear")
            }
            isScanning = false
        case .csv:
            // TEMPORARILY DISABLED
            asanaError = "CSV integration temporarily disabled for Asana debugging"
            isScanning = false
            // loadDocketsFromCSV()
        case .server:
            // TEMPORARILY DISABLED
            asanaError = "Server integration temporarily disabled for Asana debugging"
            isScanning = false
            // scanDocketsFromServer()
        }
    }
    
    private func loadDocketsFromAsana() {
        // This function is no longer used - Asana now uses cache
        // Cache sync happens in onAppear of QuickDocketSearchView
        print("🔵 [Asana] loadDocketsFromAsana() called but Asana now uses cache")
        isScanning = false
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
            // Create DocketInfo - struct initialization doesn't require MainActor
            let docket = DocketInfo(
                number: docketNumber,
                jobName: cleanedJobName,
                fullName: folderName
            )
            dict[folderName] = docket
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
        let settings = settingsManager.currentSettings
        
        // Cancel previous search task
        searchTask?.cancel()
        
        if searchText.isEmpty {
            // Clear results when search is empty
            allDockets = []
            filteredDockets = []
            isScanning = false
            return
        }
        
        // If using Asana, search on-demand with debouncing
        if settings.docketSource == .asana {
            // Debounce: wait 500ms after user stops typing
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                
                // Check if task was cancelled or search text changed
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    searchAsana(query: searchText)
                }
            }
        } else {
            // For CSV/Server: filter existing results
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
    
    private func searchAsana(query: String) {
        // Cancel any previous search
        searchTask?.cancel()
        
        guard !query.isEmpty else {
            print("🔵 [QuickSearch] Query is empty, clearing results")
            allDockets = []
            filteredDockets = []
            isScanning = false
            return
        }
        
        // Require at least 3 characters
        guard query.count >= 3 else {
            print("🔵 [QuickSearch] Query too short (\(query.count) chars), clearing results")
            allDockets = []
            filteredDockets = []
            isScanning = false
            return
        }
        
        isScanning = false // No loading needed - cache is instant!
        asanaError = nil
        
        // Search local cache - instant results!
        let results = cacheManager.searchCachedDockets(query: query)
        
        allDockets = results
        filteredDockets = results
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

// MARK: - Prep Summary View

struct PrepSummaryView: View {
    let summary: String
    @Binding var isPresented: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Prep Summary")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Summary content
            ScrollView {
                Text(summary)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // Action buttons
            HStack {
                if copied {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Copied to clipboard!")
                            .foregroundColor(.green)
                    }
                    .font(.caption)
                }

                Spacer()

                Button("Copy to Clipboard") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(summary, forType: .string)
                    copied = true

                    // Reset copied state after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 600, height: 500)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
