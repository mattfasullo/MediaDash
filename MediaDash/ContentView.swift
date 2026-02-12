import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// Focus management for all navigable buttons
enum ActionButtonFocus: Hashable {
    case file, prep, calendar, convert, search, jobInfo, archiver
}

/// Shared keyboard focus state so the NSEvent key handler can update focus and the view observes it.
/// @FocusState does not reliably update when set from the key-down monitor path.
final class MainWindowKeyboardFocus: ObservableObject {
    static let shared = MainWindowKeyboardFocus()
    @Published var focusedButton: ActionButtonFocus?
    private init() {}

    /// Same logic as ContentView.moveGridFocus; returns the next focus so the key handler can set focusedButton.
    static func nextFocus(from current: ActionButtonFocus?, direction: ContentView.GridDirection) -> ActionButtonFocus? {
        let cur = current ?? .file
        switch direction {
        case .up:
            switch cur {
            case .file, .prep: return .archiver
            case .calendar: return .file
            case .convert: return .prep
            case .search: return .calendar
            case .jobInfo: return .search
            case .archiver: return .jobInfo
            }
        case .down:
            switch cur {
            case .file: return .calendar
            case .prep: return .convert
            case .calendar, .convert: return .search
            case .search: return .jobInfo
            case .jobInfo: return .archiver
            case .archiver: return .file
            }
        case .left:
            switch cur {
            case .prep: return .file
            case .convert: return .calendar
            default: return cur
            }
        case .right:
            switch cur {
            case .file: return .prep
            case .calendar: return .convert
            default: return cur
            }
        }
    }
}

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
    @State private var showPortalSheet = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var hoverInfo: String = "Ready."
    @State private var initialSearchText = ""
    @State private var showNotificationCenter = false
    @State private var showManualPrepSheet = false
    @FocusState private var mainViewFocused: Bool
    @EnvironmentObject var notificationCenter: NotificationCenter
    @EnvironmentObject var emailScanningService: EmailScanningService

    // Task handle for hourly cache sync
    @State private var hourlySyncTask: Task<Void, Never>?

    // Logic for auto-docket selection
    @State private var showDocketSelectionSheet = false
    @State private var pendingJobType: JobType? = nil
    /// When true, next docket confirm will run file then open prep for a matching calendar session.
    @State private var pendingFileThenPrep = false
    /// After filing, open prep window for this session when isProcessing becomes false.
    @State private var pendingPrepSessionAfterFile: DocketInfo? = nil

    @FocusState private var focusedButton: ActionButtonFocus?
    @ObservedObject private var keyboardFocus = MainWindowKeyboardFocus.shared

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
    
    @StateObject private var layoutEditManager = LayoutEditManager.shared
    
    var body: some View {
        mainContentView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(layoutEditManager)
            .focusable()
            .focused($mainViewFocused)
            .onAppear {
                mainViewFocused = true
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                if notification.object as? NSWindow === WindowConfiguration.mainAppWindow {
                    mainViewFocused = true
                }
            }
            .onChange(of: keyboardFocus.focusedButton) { _, newValue in
                focusedButton = newValue
            }
            .onChange(of: focusedButton) { _, newValue in
                MainWindowKeyboardFocus.shared.focusedButton = newValue
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name("CreateTestDocketNotification"))) { _ in
                // Backup listener in ContentView - create test notification directly
                print("🔔 ContentView received CreateTestDocketNotification")
                createTestDocketNotificationFromMenu()
            }
            .onKeyPress { keyPress in
                // Handle arrow keys for layout editing
                if layoutEditManager.isEditMode, let selectedId = layoutEditManager.selectedViewId {
                    let step: CGFloat = 1.0 // 1 pixel per key press
                    var delta = CGSize.zero
                    
                    switch keyPress.key {
                    case .leftArrow:
                        delta = CGSize(width: -step, height: 0)
                    case .rightArrow:
                        delta = CGSize(width: step, height: 0)
                    case .upArrow:
                        delta = CGSize(width: 0, height: -step)
                    case .downArrow:
                        delta = CGSize(width: 0, height: step)
                    default:
                        return .ignored
                    }
                    
                    // moveOffset already defers internally, so we can call it directly
                    layoutEditManager.moveOffset(delta, for: selectedId)
                    return .handled
                }
                return .ignored
            }
            .modifier(KeyboardHandlersModifier(
                isKeyboardMode: $isKeyboardMode,
                focusedButton: $focusedButton,
                moveGridFocus: moveGridFocus,
                activateFocusedButton: activateFocusedButton,
                performActionForFocus: performAction(for:),
                settingsManager: settingsManager,
                showSearchSheet: $showSearchSheet,
                showQuickSearchSheet: $showQuickSearchSheet,
                showSettingsSheet: $showSettingsSheet,
                showVideoConverterSheet: $showVideoConverterSheet,
                showPortalSheet: $showPortalSheet,
                showNewDocketSheet: $showNewDocketSheet,
                showDocketSelectionSheet: $showDocketSelectionSheet,
                initialSearchText: $initialSearchText
            ))
            .modifier(AlertsModifier(
                showAlert: $showAlert,
                alertMessage: alertMessage,
                manager: manager,
                showSettingsSheet: $showSettingsSheet
            ))
            .onChange(of: manager.isProcessing) { oldValue, newValue in
                if oldValue == true && newValue == false, let session = pendingPrepSessionAfterFile {
                    pendingPrepSessionAfterFile = nil
                    CalendarPrepWindowManager.shared.show(
                        session: session,
                        asanaService: cacheManager.service,
                        manager: manager
                    )
                }
            }
            .onChange(of: manager.selectedFiles) { oldFiles, newFiles in
                // Auto-continue filing process when files are staged after clicking File button
                if pendingJobType != nil, !newFiles.isEmpty, oldFiles.isEmpty {
                    // Files were just added and we have a pending job type
                    // Automatically continue to docket selection (preserve pendingFileThenPrep state)
                    showDocketSelectionSheet = true
                }
            }
            .modifier(SheetsModifier(
                showNewDocketSheet: $showNewDocketSheet,
                selectedDocket: $selectedDocket,
                manager: manager,
                settingsManager: settingsManager,
                sessionManager: sessionManager,
                showSearchSheet: $showSearchSheet,
                initialSearchText: initialSearchText,
                showDocketSelectionSheet: $showDocketSelectionSheet,
                pendingJobType: $pendingJobType,
                showManualPrepSheet: $showManualPrepSheet,
                wpDate: wpDate,
                prepDate: prepDate,
                showQuickSearchSheet: $showQuickSearchSheet,
                cacheManager: cacheManager,
                showSettingsSheet: $showSettingsSheet,
                showVideoConverterSheet: $showVideoConverterSheet,
                showPortalSheet: $showPortalSheet,
                pendingFileThenPrep: $pendingFileThenPrep,
                onFileThenPrepConfirm: handleFileThenPrepConfirm
            ))
            .modifier(ContentViewLifecycleModifier(
                showSearchSheet: $showSearchSheet,
                showSettingsSheet: $showSettingsSheet,
                showQuickSearchSheet: $showQuickSearchSheet,
                initialSearchText: $initialSearchText,
                mainViewFocused: $mainViewFocused,
                focusedButton: $focusedButton,
                manager: manager,
                settingsManager: settingsManager,
                metadataManager: metadataManager,
                cacheManager: cacheManager,
                isCommandKeyHeld: $isCommandKeyHeld,
                autoSyncAsanaCache: autoSyncAsanaCache,
                hourlySyncTask: $hourlySyncTask
            ))
            // Notification popup is now handled by NotificationPopupWindowManager
            .onChange(of: showNotificationCenter) { oldValue, newValue in
                if newValue {
                    // Don't open notification centre in dashboard mode
                    if settingsManager.currentSettings.windowMode == .dashboard {
                        showNotificationCenter = false
                        return
                    }
                    
                    let content = AnyView(
                        NotificationCenterView(
                            notificationCenter: notificationCenter,
                            emailScanningService: emailScanningService,
                            mediaManager: manager,
                            settingsManager: settingsManager,
                            isExpanded: $showNotificationCenter,
                            showSettings: .constant(false)
                        )
                        .environmentObject(sessionManager)
                        .environmentObject(emailScanningService)
                    )
                    NotificationWindowManager.shared.showNotificationWindow(content: content, isLocked: false)
                } else {
                    // Hide window
                    NotificationWindowManager.shared.hideNotificationWindow()
                }
            }
            .background(
                Button(action: {
                    // Don't allow opening notification centre in dashboard mode
                    if settingsManager.currentSettings.windowMode != .dashboard {
                        if !showNotificationCenter {
                            showNotificationCenter = true
                        }
                    }
                }) {
                    EmptyView()
                }
                .keyboardShortcut("`", modifiers: .command)
                .disabled(showNotificationCenter)
                .hidden()
            )
            .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name("OpenSettings"))) { _ in
                // Open settings when requested (e.g., from menu bar status item)
                SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: NotificationWindowManager.notificationWindowDidCloseNotification)) { _ in
                showNotificationCenter = false
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name("windowModeChanged"))) { notification in
                // Reload settings when window mode changes (e.g., from fullscreen)
                settingsManager.reloadCurrentProfile()
                
                // Close notification centre if switching to dashboard mode
                if settingsManager.currentSettings.windowMode == .dashboard && showNotificationCenter {
                    showNotificationCenter = false
                }
                
                // Set minimum size for the mode; only resize if currently smaller
                DispatchQueue.main.async {
                    if let window = NSApplication.shared.windows.first {
                        let mode = settingsManager.currentSettings.windowMode
                        let minSize: NSSize
                        if mode == .dashboard {
                            minSize = NSSize(width: LayoutMode.dashboardMinWidth, height: LayoutMode.dashboardMinHeight)
                        } else {
                            minSize = NSSize(width: LayoutMode.minWidth, height: LayoutMode.minHeight)
                        }
                        window.minSize = minSize
                        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                        var frame = window.frame
                        if frame.size.width < minSize.width || frame.size.height < minSize.height {
                            frame.size.width = max(frame.size.width, minSize.width)
                            frame.size.height = max(frame.size.height, minSize.height)
                            window.setFrame(frame, display: true, animate: true)
                        }
                    }
                }
            }
            // Popup notifications disabled to prevent UI blocking
            // .onChange(of: notificationCenter.notifications) { oldValue, newValue in
            //     // Show popup when new notification arrives
            //     if let latestNotification = newValue.first,
            //        latestNotification.status == .pending,
            //        !oldValue.contains(where: { $0.id == latestNotification.id }) {
            //         // Show popup as separate window
            //         NotificationPopupWindowManager.shared.showPopup(notification: latestNotification)
            //     }
            // }
    }
    
    // Dashboard mode disabled for now; will be improved later. Always show compact.
    private static let dashboardModeEnabled = false

    private var mainContentView: some View {
        Group {
            if Self.dashboardModeEnabled && settingsManager.currentSettings.windowMode == .dashboard {
                // Dashboard Mode - Full desktop experience
                ZStack(alignment: .topLeading) {
                    DashboardView(
                        focusedButton: $focusedButton,
                        mainViewFocused: $mainViewFocused,
                        isKeyboardMode: $isKeyboardMode,
                        isCommandKeyHeld: $isCommandKeyHeld,
                        hoverInfo: $hoverInfo,
                        showSearchSheet: $showSearchSheet,
                        showQuickSearchSheet: $showQuickSearchSheet,
                        showSettingsSheet: $showSettingsSheet,
                        showVideoConverterSheet: $showVideoConverterSheet,
                        wpDate: wpDate,
                        prepDate: prepDate,
                        dateFormatter: dateFormatter,
                        attempt: attempt,
                        cacheManager: cacheManager
                    )
                    .frame(minWidth: LayoutMode.dashboardMinWidth, maxWidth: .infinity, minHeight: LayoutMode.dashboardMinHeight, maxHeight: .infinity)
                    .draggableLayout(id: "dashboardView")
                    .focusable()
                    .focused($mainViewFocused)
                    .focusEffectDisabled()
                    
                }
                .overlay(alignment: .topLeading) {
                    // Layout Edit Mode Indicator
                    if layoutEditManager.isEditMode {
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.draw")
                                    .foregroundColor(.blue)
                                Text("Layout Edit Mode")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.blue)
                                Text("(Cmd+Shift+E to exit)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            
                            Divider()
                                .frame(height: 20)
                            
                            // Undo/Redo buttons
                            Button(action: {
                                layoutEditManager.undo()
                            }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .disabled(!layoutEditManager.canUndo)
                            .foregroundColor(layoutEditManager.canUndo ? .blue : .gray)
                            .help("Undo (Cmd+Z)")
                            
                            Button(action: {
                                layoutEditManager.redo()
                            }) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .disabled(!layoutEditManager.canRedo)
                            .foregroundColor(layoutEditManager.canRedo ? .blue : .gray)
                            .help("Redo (Cmd+Shift+Z)")
                            
                            Divider()
                                .frame(height: 20)
                            
                            Button(action: {
                                layoutEditManager.resetAllOffsets()
                            }) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                            .help("Reset Layout")
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                        .padding(.top, 8)
                        .padding(.leading, 8)
                    }
                }
            } else {
                // Compact Mode - Phone-like compact interface
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        SidebarView(
                            focusedButton: $focusedButton,
                            mainViewFocused: $mainViewFocused,
                            isKeyboardMode: $isKeyboardMode,
                            isCommandKeyHeld: $isCommandKeyHeld,
                            hoverInfo: $hoverInfo,
                            showSearchSheet: $showSearchSheet,
                            showQuickSearchSheet: $showQuickSearchSheet,
                            showSettingsSheet: $showSettingsSheet,
                            showVideoConverterSheet: $showVideoConverterSheet,
                            notificationCenter: notificationCenter,
                            showNotificationCenter: $showNotificationCenter,
                            wpDate: wpDate,
                            prepDate: prepDate,
                            dateFormatter: dateFormatter,
                            attempt: attempt,
                            cacheManager: cacheManager,
                            onPrepElementsFromCalendar: { session in
                                CalendarPrepWindowManager.shared.show(
                                    session: session,
                                    asanaService: cacheManager.service,
                                    manager: manager
                                )
                            },
                            onFileThenPrep: attemptFileThenPrep,
                            onOpenPortal: { showPortalSheet = true }
                        )
                        .offset(x: 0, y: -4) // Layout edit: sidebar offset
                        .draggableLayout(id: "sidebar")
                        
                        StagingAreaView(
                            cacheManager: cacheManager,
                            isStagingHovered: $isStagingHovered,
                            isStagingPressed: $isStagingPressed,
                            showVideoConverterSheet: $showVideoConverterSheet
                        )
                        .environmentObject(manager)
                        .draggableLayout(id: "stagingArea")
                    }
                    .frame(minWidth: LayoutMode.minWidth, maxWidth: .infinity, minHeight: LayoutMode.minHeight, maxHeight: .infinity)
                    .focusable()
                    .focused($mainViewFocused)
                    .focusEffectDisabled()
                    
                }
                .overlay(alignment: .topTrailing) {
                    // Settings button in very top right - only in compact mode
                    Button(action: { 
                        SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
                    }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                    .offset(x: 2.7109375, y: -29.5390625) // Layout edit: dashboardButton offset
                    .draggableLayout(id: "dashboardButtonGroup")
                    .zIndex(1000) // Ensure it stays on top
                }
                .overlay(alignment: .topLeading) {
                    // Layout Edit Mode Indicator
                    if layoutEditManager.isEditMode {
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.draw")
                                    .foregroundColor(.blue)
                                Text("Layout Edit Mode")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.blue)
                                Text("(Cmd+Shift+E to exit)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            
                            Divider()
                                .frame(height: 20)
                            
                            // Undo/Redo buttons
                            Button(action: {
                                layoutEditManager.undo()
                            }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .disabled(!layoutEditManager.canUndo)
                            .foregroundColor(layoutEditManager.canUndo ? .blue : .gray)
                            .help("Undo (Cmd+Z)")
                            
                            Button(action: {
                                layoutEditManager.redo()
                            }) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .disabled(!layoutEditManager.canRedo)
                            .foregroundColor(layoutEditManager.canRedo ? .blue : .gray)
                            .help("Redo (Cmd+Shift+Z)")
                            
                            Divider()
                                .frame(height: 20)
                            
                            Button(action: {
                                layoutEditManager.resetAllOffsets()
                            }) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.blue)
                            .help("Reset Layout")
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(6)
                        .padding(.top, 8)
                        .padding(.leading, 8)
                    }
                }
            }
        }
    }
    
    // MARK: - Asana Auto-Sync
    
    /// Automatically sync Asana cache on app launch if configured
    private func autoSyncAsanaCache() {
        let settings = settingsManager.currentSettings
        
        // Only sync if Asana is the selected docket source
        guard settings.docketSource == .asana else {
            return
        }
        
        // Check if we have an access token
        guard SharedKeychainService.getAsanaAccessToken() != nil else {
            print("📦 [AutoSync] No Asana access token found, skipping sync")
            return
        }
        
        // Use shared cache if fresh; otherwise sync from Asana API so Job Info stays current
        print("📦 [AutoSync] Checking cache / syncing from Asana if needed...")
        
        // Only try to use shared cache if configured
        if settings.useSharedCache, let sharedURL = settings.sharedCacheURL, !sharedURL.isEmpty {
            // Try to load from shared cache (non-blocking)
            Task {
                do {
                    try await cacheManager.syncWithAsana(
                        workspaceID: settings.asanaWorkspaceID,
                        projectID: settings.asanaProjectID,
                        docketField: settings.asanaDocketField,
                        jobNameField: settings.asanaJobNameField,
                        sharedCacheURL: settings.sharedCacheURL,
                        useSharedCache: settings.useSharedCache
                    )
                    print("✅ [AutoSync] Loaded from shared cache successfully")
                } catch {
                    // Silently fail - shared cache might not be ready yet
                    print("⚠️ [AutoSync] Shared cache not available: \(error.localizedDescription)")
                }
            }
        } else {
            print("📦 [AutoSync] Shared cache not configured - external service will handle syncing")
        }
    }
    
    /// Perform the actual sync operation
    private func performSync() {
        let settings = settingsManager.currentSettings
        
        Task {
            do {
                try await cacheManager.syncWithAsana(
                    workspaceID: settings.asanaWorkspaceID,
                    projectID: settings.asanaProjectID,
                    docketField: settings.asanaDocketField,
                    jobNameField: settings.asanaJobNameField,
                    sharedCacheURL: settings.sharedCacheURL,
                    useSharedCache: settings.useSharedCache
                )
                print("✅ [AutoSync] Automatic sync completed successfully")
            } catch {
                print("⚠️ [AutoSync] Automatic sync failed: \(error.localizedDescription)")
                // Silently fail - don't show error to user
            }
        }
    }
    
    /// Set up a task to sync every hour
    /// NOTE: This is no longer used - external service handles all syncing
    private func setupHourlySyncTimer() {
        // MediaDash no longer performs hourly syncs - external service handles this
        // Cancel any existing task
        hourlySyncTask?.cancel()
        hourlySyncTask = nil
        print("📦 [AutoSync] Hourly sync disabled - external service handles syncing")
    }

    
    private func attempt(type: JobType) {
        // 1. If no files are staged, set pending job type and open file picker
        guard !manager.selectedFiles.isEmpty else {
            pendingJobType = type
            pendingFileThenPrep = false
            manager.pickFiles()
            return
        }

        // 2. Always show docket selection sheet
        pendingJobType = type
        pendingFileThenPrep = false
        showDocketSelectionSheet = true
    }

    /// Start "File + Prep" flow: show docket sheet; on confirm, file then open prep for a matching calendar session.
    private func attemptFileThenPrep() {
        guard !manager.selectedFiles.isEmpty else {
            pendingFileThenPrep = true
            pendingJobType = .workPicture
            manager.pickFiles()
            return
        }
        pendingFileThenPrep = true
        pendingJobType = .workPicture
        showDocketSelectionSheet = true
    }

    /// Called when user confirms docket in the sheet and we were in "File + Prep" mode. Run file, then set session to open prep when done.
    private func handleFileThenPrepConfirm(docket: String) {
        let sessions = cacheManager.matchingSessions(for: docket)
        pendingPrepSessionAfterFile = sessions.first
        manager.runJob(type: .workPicture, docket: docket, wpDate: wpDate, prepDate: prepDate)
        pendingJobType = nil
        pendingFileThenPrep = false
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
        //              [calendar, convert]
        // Then linear: [search, jobInfo, archiver]

        if focusedButton == nil {
            focusedButton = .file
            return
        }

        guard let current = focusedButton else { return }

        switch direction {
        case .up:
            switch current {
            case .file, .prep:
                focusedButton = .archiver
            case .calendar:
                focusedButton = .file
            case .convert:
                focusedButton = .prep
            case .search:
                focusedButton = .calendar
            case .jobInfo:
                focusedButton = .search
            case .archiver:
                focusedButton = .jobInfo
            }

        case .down:
            switch current {
            case .file:
                focusedButton = .calendar
            case .prep:
                focusedButton = .convert
            case .calendar, .convert:
                focusedButton = .search
            case .search:
                focusedButton = .jobInfo
            case .jobInfo:
                focusedButton = .archiver
            case .archiver:
                focusedButton = .file
            }

        case .left:
            switch current {
            case .prep:
                focusedButton = .file
            case .convert:
                focusedButton = .calendar
            default:
                break
            }

        case .right:
            switch current {
            case .file:
                focusedButton = .prep
            case .calendar:
                focusedButton = .convert
            default:
                break
            }
        }
        MainWindowKeyboardFocus.shared.focusedButton = focusedButton
    }

    private func moveFocus(direction: Int) {
        // Linear navigation fallback
        let mainButtons: [ActionButtonFocus] = [.file, .prep, .calendar, .convert, .search, .jobInfo, .archiver]

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
        let focused = MainWindowKeyboardFocus.shared.focusedButton ?? focusedButton
        guard let focused = focused else { return }
        performAction(for: focused)
    }

    /// Performs the action for a given focus target; used so the key handler can activate from shared state.
    private func performAction(for focus: ActionButtonFocus) {
        switch focus {
        case .file:
            attempt(type: .workPicture)
        case .prep:
            AsanaCalendarWindowManager.shared.show(
                cacheManager: cacheManager,
                settingsManager: settingsManager,
                onPrepElements: { session in
                    CalendarPrepWindowManager.shared.show(
                        session: session,
                        asanaService: cacheManager.service,
                        manager: manager
                    )
                }
            )
        case .calendar:
            AsanaFullCalendarWindowManager.shared.show(
                cacheManager: cacheManager,
                settingsManager: settingsManager,
                onPrepElements: { session in
                    CalendarPrepWindowManager.shared.show(
                        session: session,
                        asanaService: cacheManager.service,
                        manager: manager
                    )
                }
            )
        case .search:
            showSearchSheet = true
        case .convert:
            showPortalSheet = true
        case .jobInfo:
            showQuickSearchSheet = true
        case .archiver:
            SimianArchiverWindowManager.shared.show(settingsManager: settingsManager)
        }
    }
    
    // MARK: - Test Notification Creation
    
    /// Create a test docket notification from the menu
    private func createTestDocketNotificationFromMenu() {
        print("🔔 ContentView.createTestDocketNotificationFromMenu() called")
        
        // Count existing test notifications to continue numbering
        let testNotifications = notificationCenter.notifications.filter { notification in
            notification.type == .newDocket &&
            notification.jobName?.hasPrefix("TEST ") == true
        }
        
        var maxTestNumber = 0
        for notification in testNotifications {
            if let jobName = notification.jobName {
                let testNumString = jobName.replacingOccurrences(of: "TEST ", with: "")
                if let testNum = Int(testNumString) {
                    maxTestNumber = max(maxTestNumber, testNum)
                }
            }
        }
        
        let testNotificationCount = maxTestNumber + 1
        
        // Generate a random docket number that doesn't exist
        // Valid docket numbers: exactly 5 digits, starting with current year (YY) or next year
        var docketNumber: String
        var attempts = 0
        let maxAttempts = 100
        
        // Get valid year prefix (current year or next year)
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let currentYearLastTwo = currentYear % 100
        let nextYearLastTwo = (currentYearLastTwo + 1) % 100
        // Randomly choose current or next year
        let yearPrefix = Int.random(in: 0...1) == 0 ? currentYearLastTwo : nextYearLastTwo
        let yearPrefixString = String(format: "%02d", yearPrefix)
        
        func docketExists(docketNumber: String, jobName: String) -> Bool {
            let docketName = "\(docketNumber)_\(jobName)"
            if manager.dockets.contains(docketName) {
                return true
            }
            return notificationCenter.notifications.contains { notification in
                notification.docketNumber == docketNumber && notification.jobName == jobName
            }
        }
        
        repeat {
            // Generate 3 random digits (000-999) and combine with year prefix to make 5 digits
            let randomSuffix = Int.random(in: 0...999)
            let suffixString = String(format: "%03d", randomSuffix)
            docketNumber = "\(yearPrefixString)\(suffixString)"
            attempts += 1
        } while docketExists(docketNumber: docketNumber, jobName: "TEST \(testNotificationCount)") && attempts < maxAttempts
        
        if attempts >= maxAttempts {
            // Fallback: use timestamp-based docket number with valid year prefix
            let timestamp = Int(Date().timeIntervalSince1970) % 1000
            let suffixString = String(format: "%03d", timestamp)
            docketNumber = "\(yearPrefixString)\(suffixString)"
        }
        
        let jobName = "TEST \(testNotificationCount)"
        
        print("   Generated docket: \(docketNumber), job: \(jobName)")
        
        let testNotification = Notification(
            type: .newDocket,
            title: "Test New Docket",
            message: "Docket \(docketNumber): \(jobName)",
            docketNumber: docketNumber,
            jobName: jobName,
            sourceEmail: "test@graysonmusicgroup.com",
            emailSubject: "Test Docket Notification \(testNotificationCount)",
            emailBody: "This is a test notification created for debugging purposes."
        )
        
        print("   Created notification: \(testNotification.id)")
        notificationCenter.add(testNotification)
        print("   ✅ Notification added to notificationCenter")
        print("   Total notifications now: \(notificationCenter.notifications.count)")
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


// MARK: - Docket Selection Search View (New)

struct DocketSearchView: View {
    @ObservedObject var manager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var isPresented: Bool
    @Binding var selectedDocket: String
    var jobType: JobType = .workPicture
    var onConfirm: () -> Void
    var cacheManager: AsanaCacheManager?

    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isListFocused: Bool
    @State private var filteredDockets: [String] = []
    @State private var selectedPath: String?
    @State private var showNewDocketSheet = false
    @State private var showAsanaSearchSheet = false
    @State private var allDockets: [String] = []
    @State private var jobNameByDocket: [String: String] = [:]
    @State private var showExistingPrepAlert = false
    @State private var existingPrepFolders: [String] = []
    @State private var prefillDocketNumber: String? = nil
    @State private var prefillJobName: String? = nil

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
                    HoverableButton(action: { searchText = "" }) { isHovered in
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(isHovered ? .primary : .secondary)
                            .scaleEffect(isHovered ? 1.1 : 1.0)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // MARK: Results List
            ZStack {
                // Check if directories are connected
                if !manager.isServerDirectoryConnected() {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        
                        VStack(spacing: 8) {
                            Text("Search Unavailable")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            Text("Grayson server is not connected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Please connect to the Grayson server in Settings to use search")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        
                        Button("Open Settings") {
                            // Note: Parent view should handle opening settings
                            isPresented = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    ScrollViewReader { proxy in
                        List(selection: $selectedPath) {
                        // "Create New Folder" option at the top
                        HoverableButton(action: {
                            showNewDocketSheet = true
                        }) { isHovered in
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                                Text("Create New Folder")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(isHovered ? Color.green.opacity(0.15) : Color.clear)
                        }
                        .listRowBackground(Color.green.opacity(0.1))
                        
                        // "Search Asana" option below "Create New Folder"
                        if cacheManager != nil {
                            HoverableButton(action: {
                                showAsanaSearchSheet = true
                            }) { isHovered in
                                HStack {
                                    Image(systemName: "magnifyingglass.circle.fill")
                                        .foregroundColor(.blue)
                                    Text("Search Asana")
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .background(isHovered ? Color.blue.opacity(0.15) : Color.clear)
                            }
                            .listRowBackground(Color.blue.opacity(0.1))
                        }

                        if !filteredDockets.isEmpty {
                            Section {
                                ForEach(filteredDockets, id: \.self) { docket in
                                    HoverableListButton(action: {
                                        if selectedPath == docket {
                                            // Double click - select docket
                                            selectDocket(docket)
                                        } else {
                                            selectedPath = docket
                                        }
                                    }) { isHovered in
                                        HStack {
                                            Image(systemName: "folder.fill")
                                                .foregroundColor(.blue)
                                            Text(displayDocketName(docket))
                                                .font(.system(size: 14))
                                            Spacer()
                                        }
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                        .background(isHovered ? Color.blue.opacity(0.1) : Color.clear)
                                    }
                                    .tag(docket)
                                }
                            } header: {
                                HStack {
                                    VStack {
                                        Divider()
                                    }
                                    Text("Select a Docket")
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
                                Text("Try adjusting your search or create a new folder")
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 400, idealWidth: 600, maxWidth: 700, minHeight: 300, idealHeight: 500, maxHeight: 700)
        .onAppear {
            // Always show folders from Work Picture (never docket numbers from prep folder), sorted by most recently modified
            Task {
                let currentConfig = manager.config
                let scanType: JobType = .workPicture
                let dockets = await Task.detached {
                    MediaLogic.scanDockets(config: currentConfig, jobType: scanType)
                }.value
                await MainActor.run {
                    allDockets = dockets
                    filteredDockets = dockets
                    // Build dict without uniqueKeysWithValues to tolerate duplicate docket names (e.g. same folder scanned twice)
                    var jobByName: [String: String] = [:]
                    for docket in dockets {
                        jobByName[docket] = manager.getJobName(for: docket)
                    }
                    jobNameByDocket = jobByName
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
                    // Clear prefill values
                    prefillDocketNumber = nil
                    prefillJobName = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        onConfirm()
                    }
                },
                initialDocketNumber: prefillDocketNumber,
                initialJobName: prefillJobName
            )
            .sheetSizeStabilizer()
            .id("\(prefillDocketNumber ?? "nil")_\(prefillJobName ?? "nil")") // Force recreation when prefill values change
            .onDisappear {
                // Clear prefill values when sheet closes
                prefillDocketNumber = nil
                prefillJobName = nil
            }
        }
        .sheet(isPresented: $showAsanaSearchSheet) {
            if let cacheManager = cacheManager {
                QuickDocketSearchView(
                    isPresented: $showAsanaSearchSheet,
                    initialText: searchText,
                    settingsManager: settingsManager,
                    cacheManager: cacheManager,
                    onDocketSelectedForFolder: { docket in
                        // When a docket is selected from Asana, pre-fill the new folder form
                        // Close Asana search first
                        showAsanaSearchSheet = false
                        // Set values and open sheet - use Task to ensure state updates
                        Task { @MainActor in
                            prefillDocketNumber = docket.number
                            prefillJobName = docket.jobName
                            // Small delay to ensure state is updated
                            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
                            showNewDocketSheet = true
                        }
                    }
                )
                .sheetSizeStabilizer()
            }
        }
        .keyboardNavigationHandler(handleKey: { event in
            switch event.keyCode {
            case 125: // down
                if !filteredDockets.isEmpty {
                    isSearchFieldFocused = false
                    isListFocused = true
                    moveSelection(1)
                }
                return true
            case 126: // up
                if !filteredDockets.isEmpty {
                    isSearchFieldFocused = false
                    isListFocused = true
                    moveSelection(-1)
                }
                return true
            case 36: // return
                if isListFocused, let selected = selectedPath {
                    selectDocket(selected)
                }
                return true
            default: return false
            }
        })
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
            // Exclude newlines to let the .return handler process Enter key
            if isListFocused && press.characters.count == 1 {
                let char = press.characters.first!
                if char.isLetter || char.isNumber || (char.isWhitespace && !char.isNewline) || char.isPunctuation {
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
            let query = searchText.lowercased()
            filteredDockets = allDockets.filter { docket in
                if docket.lowercased().contains(query) {
                    return true
                }
                if jobType == .prep {
                    let jobName = jobNameForDocket(docket).lowercased()
                    return jobName.contains(query)
                }
                return false
            }
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

    private func jobNameForDocket(_ docket: String) -> String {
        if let cached = jobNameByDocket[docket] {
            return cached
        }
        let resolved = manager.getJobName(for: docket)
        jobNameByDocket[docket] = resolved
        return resolved
    }

    private func displayDocketName(_ docket: String) -> String {
        guard jobType == .prep else { return docket }
        let jobName = jobNameForDocket(docket)
        if jobName != docket {
            return "\(docket) - \(jobName)"
        }
        return docket
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
        return HoverableButton(action: {
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
        }) { isHovered in
            Text(folder.displayName)
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : (isHovered ? Color.gray.opacity(0.2) : Color.clear))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(4)
        }
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
                    placeholder: manager.isIndexing ? "Type to search (scanning folders)..." : "Search server...",
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
                    HoverableButton(action: { searchText = "" }) { isHovered in
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(isHovered ? .primary : .secondary)
                            .scaleEffect(isHovered ? 1.1 : 1.0)
                    }
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .frame(maxWidth: .infinity)

            // MARK: Folder Selector
            folderSelectorView
            .frame(maxWidth: .infinity)

            Divider()
            
            // MARK: Results List
            ZStack {
                // Check if directories are connected
                if !manager.isSessionsDirectoryConnected() {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        
                        VStack(spacing: 8) {
                            Text("Search Unavailable")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            Text("Server unavailable")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Please connect to the server in Settings to use search")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        
                        Button("Open Settings") {
                            // Note: Parent view should handle opening settings
                            isPresented = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                } else if manager.isIndexing && exactResults.isEmpty && fuzzyResults.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Building search index...")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                } else if exactResults.isEmpty && fuzzyResults.isEmpty && !searchText.isEmpty && !manager.isIndexing {
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Populating list...")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped() // Ensure content doesn't overflow
            
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
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 500, idealWidth: 650, maxWidth: 800, minHeight: 400, idealHeight: 600, maxHeight: 800)
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
        .keyboardNavigationHandler(handleKey: { event in
            switch event.keyCode {
            case 125: // down
                if !exactResults.isEmpty || !fuzzyResults.isEmpty {
                    isSearchFieldFocused = false
                    isListFocused = true
                    moveSelection(1)
                }
                return true
            case 126: // up
                if !exactResults.isEmpty || !fuzzyResults.isEmpty {
                    isSearchFieldFocused = false
                    isListFocused = true
                    moveSelection(-1)
                }
                return true
            case 36: // return
                if isListFocused && selectedPath != nil {
                    openInFinder()
                }
                return true
            default: return false
            }
        })
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
                // Exclude newlines - they should not be added to search text
                // (isWhitespace includes newlines, which would break exact matching)
                if char.isLetter || char.isNumber || (char.isWhitespace && !char.isNewline) || char.isPunctuation {
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

    private func performSearch(immediate: Bool = false, folderOnly: SearchFolder? = nil) {
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

                let currentSearchText = searchText
                
                // If folderOnly is specified (e.g., when switching tabs), only search that folder
                if let folder = folderOnly {
                    let results = await manager.searchSessions(term: currentSearchText, folder: folder)
                    guard !Task.isCancelled else {
                        await MainActor.run { isSearching = false }
                        return
                    }
                    
                    await MainActor.run {
                        // Cache result for this folder only
                        cachedResults[folder] = (results.exactMatches, results.fuzzyMatches)
                        
                        // Display results for currently selected folder
                        updateDisplayedResults()
                    }
                } else {
                    // Search all folders simultaneously (when user is typing)
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
                // Only search the selected folder when switching tabs (not all folders)
                if !searchText.isEmpty && !isSearching && !manager.isIndexing {
                    print("No cached results for \(selectedFolder.displayName), triggering search")
                    performSearch(immediate: true, folderOnly: selectedFolder)
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

// MARK: - Quick Docket Search (Reference Only)

struct QuickDocketSearchView: View {
    @Binding var isPresented: Bool
    let initialText: String
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var cacheManager: AsanaCacheManager
    @EnvironmentObject var manager: MediaManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var notificationCenter: NotificationCenter
    @StateObject private var metadataManager: DocketMetadataManager

    @State private var searchText: String
    @State private var allDockets: [DocketInfo] = []
    @State private var filteredDockets: [DocketInfo] = []
    @State private var isScanning = false
    @State private var selectedDocket: DocketInfo?
    @State private var asanaError: String?
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool
    @State private var searchTask: Task<Void, Never>?
    @State private var showSettingsSheet = false
    @State private var showMetadataEditor = false
    @State private var sortOrder: DocketSortOrder = .recentlyUpdated
    @State private var hasAutoSelectedInitial = false // Track if we've done initial auto-selection

    // Optional callback for when a docket is selected for creating a new folder (used when opened from DocketSearchView)
    var onDocketSelectedForFolder: ((DocketInfo) -> Void)? = nil
    
    init(isPresented: Binding<Bool>, initialText: String, settingsManager: SettingsManager, cacheManager: AsanaCacheManager, onDocketSelectedForFolder: ((DocketInfo) -> Void)? = nil) {
        self._isPresented = isPresented
        self.initialText = initialText
        self.settingsManager = settingsManager
        self.cacheManager = cacheManager
        self.onDocketSelectedForFolder = onDocketSelectedForFolder
        self._searchText = State(initialValue: initialText)
        self._metadataManager = StateObject(wrappedValue: DocketMetadataManager(settings: settingsManager.currentSettings))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBarSection
            Divider()
            sortOrderSection
            Divider()
            syncStatusSection
            resultsListSection
            infoBarSection
        }
        .frame(minWidth: 400, idealWidth: 600, maxWidth: 700, minHeight: 300, idealHeight: 500, maxHeight: 700)
        .onChange(of: showMetadataEditor) { oldValue, newValue in
            if newValue, let docket = selectedDocket {
                DocketHubWindowManager.shared.show(
                    docket: docket,
                    metadataManager: metadataManager,
                    cacheManager: cacheManager,
                    settingsManager: settingsManager
                )
                // Reset the flag since window manager handles its own state
                showMetadataEditor = false
            }
        }
        .onAppear {
            handleOnAppear()
        }
        .onReceive(cacheManager.$cachedDockets) { dockets in
            let settings = settingsManager.currentSettings
            guard settings.docketSource == .asana else { return }
            guard !dockets.isEmpty else { return }
            
            allDockets = dockets
            if !searchText.isEmpty {
                searchAsana(query: searchText)
            } else {
                filteredDockets = dockets
                applySorting()
            }
        }
        .onDisappear {
            // Cancel any pending search
            searchTask?.cancel()
        }
        .keyboardNavigationHandler(handleKey: { event in
            switch event.keyCode {
            case 125: // down
                if !filteredDockets.isEmpty {
                    isSearchFocused = false
                    isListFocused = true
                    moveSelection(1)
                }
                return true
            case 126: // up
                if !filteredDockets.isEmpty {
                    isSearchFocused = false
                    isListFocused = true
                    moveSelection(-1)
                }
                return true
            case 36: // return
                if isListFocused, let docket = selectedDocket {
                    if let callback = onDocketSelectedForFolder {
                        callback(docket)
                        isPresented = false
                    } else {
                        showMetadataEditor = true
                    }
                }
                return true
            default: return false
            }
        })
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !filteredDockets.isEmpty {
                isSearchFocused = false
                isListFocused = true
                moveSelection(-1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if !filteredDockets.isEmpty {
                isSearchFocused = false
                isListFocused = true
                moveSelection(1)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.tab) {
            // Pressing Tab refocuses the search field
            isSearchFocused = true
            isListFocused = false
            return .handled
        }
        .onKeyPress(.return) {
            // Enter key: if callback provided, use selected docket for new folder; otherwise open metadata editor
            if isListFocused, let docket = selectedDocket {
                if let callback = onDocketSelectedForFolder {
                    callback(docket)
                    isPresented = false
                    return .handled
                } else {
                    showMetadataEditor = true
                    return .handled
                }
            }
            return .ignored
        }
        .onKeyPress(.delete) {
            // Backspace refocuses search field
            if isListFocused {
                isSearchFocused = true
                isListFocused = false
                return .handled
            }
            return .ignored
        }
        .onKeyPress { press in
            // Any letter/character refocuses search field
            // Exclude newlines to let the .return handler process Enter key
            if isListFocused && press.characters.count == 1 {
                let char = press.characters.first!
                if char.isLetter || char.isNumber || (char.isWhitespace && !char.isNewline) || char.isPunctuation {
                    isSearchFocused = true
                    isListFocused = false
                    return .handled
                }
            }
            return .ignored
        }
    }
    
    // MARK: - View Sections
    
    private var searchBarSection: some View {
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
                HoverableButton(action: { searchText = "" }) { isHovered in
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(isHovered ? .primary : .secondary)
                        .scaleEffect(isHovered ? 1.1 : 1.0)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var sortOrderSection: some View {
        HStack {
            Text("Sort by:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Picker("", selection: $sortOrder) {
                ForEach(DocketSortOrder.allCases, id: \.self) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
            .onChange(of: sortOrder) {
                applySorting()
            }
            
            Spacer()
            
            if settingsManager.currentSettings.docketSource == .asana {
                Button {
                    refreshJobInfoFromAsana()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(cacheManager.isSyncing)
                .help("Refresh job list from Asana")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    
    @ViewBuilder
    private var syncStatusSection: some View {
        if cacheManager.isSyncing {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ProgressView(value: cacheManager.syncProgress > 0 ? cacheManager.syncProgress : nil)
                        .scaleEffect(0.7)
                    Text(cacheManager.syncPhase.isEmpty ? "Syncing from Asana..." : cacheManager.syncPhase)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if cacheManager.syncProgress > 0 {
                        Text("\(Int(cacheManager.syncProgress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
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
    }
    
    private var resultsListSection: some View {
        ZStack {
            // Check if directories are connected (for non-Asana sources)
            if settingsManager.currentSettings.docketSource != .asana && !manager.isServerDirectoryConnected() {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        
                        VStack(spacing: 8) {
                            Text("Search Unavailable")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            Text("Grayson server is not connected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Please connect to the Grayson server to use search")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        
                        Button("Open Settings") {
                            SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if isScanning {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if allDockets.isEmpty && !isScanning {
                            VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Populating list...")
                            .foregroundColor(.gray)
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    docketsListView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped() // Ensure content doesn't overflow
    }
    
    private var docketsListView: some View {
        ScrollViewReader { proxy in
            List {
                if !filteredDockets.isEmpty {
                    filteredDocketsSection
                } else if searchText.isEmpty && !allDockets.isEmpty {
                    allDocketsSection
                }
            }
            .listStyle(.inset)
            .focused($isListFocused)
            .onChange(of: selectedDocket) { oldValue, newValue in
                if let docket = newValue {
                    withAnimation(.easeInOut(duration: 0.08)) {
                        proxy.scrollTo(docket.id, anchor: .center)
                    }
                }
            }
            .onChange(of: filteredDockets) { oldValue, newValue in
                handleFilteredDocketsChange(oldValue: oldValue, newValue: newValue)
            }
        }
    }
    
    @ViewBuilder
    private var filteredDocketsSection: some View {
        Section {
            ForEach(filteredDockets) { docket in
                docketRow(docket: docket)
            }
        } header: {
            HStack {
                Text(searchText.isEmpty ? "All Dockets" : "Results")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(filteredDockets.count) docket\(filteredDockets.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
    
    @ViewBuilder
    private var allDocketsSection: some View {
        Section {
            ForEach(allDockets) { docket in
                simpleDocketRow(docket: docket)
            }
        } header: {
            HStack {
                Text("Recent Dockets")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(allDockets.count) docket\(allDockets.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
    
    private func docketRow(docket: DocketInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                selectedDocket = docket
                // If callback is provided (opened from DocketSearchView), use docket for new folder
                if let callback = onDocketSelectedForFolder {
                    callback(docket)
                    isPresented = false
                } else {
                    // Open docket hub
                    showMetadataEditor = true
                }
            }) {
                docketRowContent(docket: docket)
            }
            .buttonStyle(.plain)
            .tag(docket.id)
            .id(docket.id)
            .onTapGesture(count: 2) {
                // Double-click opens metadata editor (only if not using callback)
                if onDocketSelectedForFolder == nil {
                    selectedDocket = docket
                    showMetadataEditor = true
                }
            }
            
            if let subtasks = docket.subtasks, !subtasks.isEmpty {
                subtasksView(subtasks: subtasks)
            }
        }
    }
    
    private func docketRowContent(docket: DocketInfo) -> some View {
        HStack(spacing: 12) {
            // Number badge
            Text(docket.displayNumber)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue)
                .cornerRadius(6)

            // Job name and metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(docket.jobName)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)

                if let metadataType = docket.metadataType {
                    Text(metadataType)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if metadataManager.hasMetadata(for: docket.fullName) {
                    metadataInfoView(docket: docket)
                }
            }

            Spacer()

            // Info icon (visual indicator only, whole row is clickable)
            Image(systemName: "info.circle.fill")
                .foregroundColor(metadataManager.hasMetadata(for: docket.fullName) ? .blue : .secondary)
                .font(.caption)

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(docket.fullName, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy full name")
            .highPriorityGesture(TapGesture().onEnded {
                // Stop propagation - copy button should work independently
            })
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private func metadataInfoView(docket: DocketInfo) -> some View {
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
    
    private func subtasksView(subtasks: [DocketSubtask]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(subtasks) { subtask in
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 20)
                    
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subtask.name)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        if let metadataType = subtask.metadataType {
                            Text(metadataType)
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    
                    Spacer()
                }
                .padding(.vertical, 2)
                .padding(.leading, 8)
            }
        }
        .padding(.leading, 20)
        .padding(.bottom, 4)
    }
    
    private func simpleDocketRow(docket: DocketInfo) -> some View {
        Button(action: {
            selectedDocket = docket
            // If callback is provided (opened from DocketSearchView), use docket for new folder
            if let callback = onDocketSelectedForFolder {
                callback(docket)
                isPresented = false
            } else {
                showMetadataEditor = true
            }
        }) {
            HStack(spacing: 12) {
                Text(docket.number)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .cornerRadius(6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(docket.jobName)
                        .font(.system(size: 14))
                    
                    if let metadataType = docket.metadataType {
                        Text(metadataType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func handleFilteredDocketsChange(oldValue: [DocketInfo], newValue: [DocketInfo]) {
        // Only auto-select in these cases:
        // 1. Initial load: first time we get results (oldValue was empty, haven't auto-selected yet)
        // 2. Current selection was filtered out: if selected docket is no longer in the list
        if let currentSelected = selectedDocket {
            // If current selection is still in the new list, keep it
            if !newValue.contains(where: { $0.id == currentSelected.id }) {
                // Current selection is gone - only auto-select if list is not empty
                if !newValue.isEmpty {
                    selectedDocket = newValue.first
                } else {
                    selectedDocket = nil
                }
            }
        } else if !hasAutoSelectedInitial && oldValue.isEmpty && !newValue.isEmpty {
            // Initial load: only auto-select once when we first get results
            selectedDocket = newValue.first
            hasAutoSelectedInitial = true
        }
    }
    
    private var infoBarSection: some View {
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
    
    // MARK: - Lifecycle
    
    private func handleOnAppear() {
        isSearchFocused = true
        metadataManager.reloadMetadata()
        
        // Reset auto-selection flag when sheet opens
        hasAutoSelectedInitial = false
        selectedDocket = nil
        
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
                applySorting()
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
                            jobNameField: settings.asanaJobNameField,
                            sharedCacheURL: settings.sharedCacheURL,
                            useSharedCache: settings.useSharedCache
                        )
                        print("🟢 [QuickSearch] Cache sync complete")
                            
                            // Update results with fresh cache after sync
                            await MainActor.run {
                                let freshDockets = cacheManager.loadCachedDockets()
                                if !freshDockets.isEmpty {
                                    allDockets = freshDockets
                                    // Re-apply search filter if there's search text
                                    if !searchText.isEmpty {
                                        searchAsana(query: searchText)
                                    } else {
                                        filteredDockets = freshDockets
                                        applySorting()
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
    
    // MARK: - Helper Functions
    
    func loadDockets() {
        var settings = settingsManager.currentSettings

        // Ensure Asana is selected (currently the only supported source)
        if settings.docketSource != .asana {
            settings.docketSource = .asana
            settingsManager.currentSettings = settings
            settingsManager.saveCurrentProfile()
        }

        // Use Asana cache-based loading
        switch settings.docketSource {
        case .asana:
            // Asana uses cache - sync happens in onAppear of QuickDocketSearchView
            let cachedDockets = cacheManager.loadCachedDockets()
            if !cachedDockets.isEmpty {
                allDockets = cachedDockets
                filteredDockets = cachedDockets
                applySorting()
            }
            isScanning = false
        case .csv:
            // CSV source not currently supported
            asanaError = "CSV integration is currently unavailable. Please use Asana."
            isScanning = false
        case .server:
            // Server source not currently supported
            asanaError = "Server integration is currently unavailable. Please use Asana."
            isScanning = false
        }
    }
    
    private func refreshJobInfoFromAsana() {
        let settings = settingsManager.currentSettings
        guard settings.docketSource == .asana else { return }
        Task {
            do {
                try await cacheManager.forceFullSync(
                    workspaceID: settings.asanaWorkspaceID,
                    projectID: settings.asanaProjectID,
                    docketField: settings.asanaDocketField,
                    jobNameField: settings.asanaJobNameField
                )
                await MainActor.run {
                    let freshDockets = cacheManager.loadCachedDockets()
                    if !freshDockets.isEmpty {
                        allDockets = freshDockets
                        if !searchText.isEmpty {
                            searchAsana(query: searchText)
                        } else {
                            filteredDockets = freshDockets
                            applySorting()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    asanaError = "Failed to refresh from Asana: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func loadDocketsFromAsana() {
        // This function is no longer used - Asana now uses cache
        // Cache sync happens in onAppear of QuickDocketSearchView
        print("🔵 [Asana] loadDocketsFromAsana() called but Asana now uses cache")
        isScanning = false
    }

    func loadDocketsFromCSV() {
        // Force reload metadata from CSV
        metadataManager.reloadMetadata()

        // Load dockets from CSV metadata
        var dockets: [DocketInfo] = []

        print("Loading dockets from metadata. Total entries: \(metadataManager.metadata.count)")

        for (_, meta) in metadataManager.metadata {
            let metadataType = extractMetadataType(from: meta.jobName)
            dockets.append(DocketInfo(
                number: meta.docketNumber,
                jobName: meta.jobName,
                fullName: meta.id,
                metadataType: metadataType
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
        applySorting()
        performSearch()
    }

    func scanDocketsFromServer() {
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
                self.applySorting()
            }
        }
    }

    nonisolated func checkAndAddDocket(folderURL: URL, to dict: inout [String: DocketInfo]) {
        let folderName = folderURL.lastPathComponent

        // Parse format: "number_jobName"
        let components = folderName.split(separator: "_", maxSplits: 1)
        guard components.count >= 2 else { return }

        let firstPart = String(components[0])
        let docketNumber = extractDocketNumber(from: firstPart)
        guard !docketNumber.isEmpty else { return }

        // Clean up job name and extract metadata
        let rawJobName = String(components[1])
        let cleanedJobName = cleanJobName(rawJobName)
        let metadataType = extractMetadataType(from: rawJobName)

        // Use full name as unique key to avoid duplicates
        if dict[folderName] == nil {
            // Create DocketInfo - struct initialization doesn't require MainActor
            let docket = DocketInfo(
                number: docketNumber,
                jobName: cleanedJobName,
                fullName: folderName,
                metadataType: metadataType
            )
            dict[folderName] = docket
        }
    }

    nonisolated func extractDocketNumber(from text: String) -> String {
        // Match format: 12345 or 12345-US
        let pattern = #"^(\d+(-[A-Z]{2})?)$"#

        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return String(text[range])
        }

        return ""
    }

    nonisolated func cleanJobName(_ name: String) -> String {
        var cleaned = name

        // Replace underscores with spaces
        cleaned = cleaned.replacingOccurrences(of: "_", with: " ")
        
        // Remove metadata keywords FIRST (before other cleaning): "JOB INFO", "SESSION REPORT", "SESSION" (case-insensitive)
        // These should be treated as metadata, not part of the job name
        // Process in order: longest first to avoid partial matches
        let metadataKeywords = ["SESSION REPORT", "JOB INFO", "SESSION"]
        for keyword in metadataKeywords {
            let escapedKeyword = NSRegularExpression.escapedPattern(for: keyword)
            
            // Pattern 1: Keyword at start (with optional leading whitespace) followed by " - " or space
            // Handles: "SESSION - ", " SESSION - ", "SESSION ", etc.
            let pattern1 = #"^\s*"# + escapedKeyword + #"\s*-\s*"#
            if let regex = try? NSRegularExpression(pattern: pattern1, options: [.caseInsensitive]) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
            
            // Pattern 2: Keyword at start followed by space (no dash)
            let pattern2 = #"^\s*"# + escapedKeyword + #"\s+"#
            if let regex = try? NSRegularExpression(pattern: pattern2, options: [.caseInsensitive]) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                )
            }
            
            // Pattern 3: Keyword with dashes/spaces around it (anywhere in string)
            let pattern3 = #"\s*-\s*"# + escapedKeyword + #"(\s*-\s*|\s+|$)"#
            if let regex = try? NSRegularExpression(pattern: pattern3, options: [.caseInsensitive]) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: " "
                )
            }
            
            // Pattern 4: Standalone keyword with spaces (middle or end of string)
            let pattern4 = #"\s+"# + escapedKeyword + #"(\s+|$)"#
            if let regex = try? NSRegularExpression(pattern: pattern4, options: [.caseInsensitive]) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: " "
                )
            }
        }

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

    /// Extract metadata type (SESSION, PREP, POST, JOB INFO, SESSION REPORT) from text
    nonisolated func extractMetadataType(from text: String) -> String? {
        let metadataKeywords = ["SESSION REPORT", "JOB INFO", "SESSION", "PREP", "POST"]
        
        for keyword in metadataKeywords {
            let escapedKeyword = NSRegularExpression.escapedPattern(for: keyword)
            // Match keyword at start (with optional leading whitespace) followed by " - " or space
            let pattern = #"^\s*"# + escapedKeyword + #"(\s*-\s*|\s+|$)"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                return keyword.uppercased()
            }
        }
        
        return nil
    }

    func performSearch() {
        let settings = settingsManager.currentSettings
        
        // Cancel previous search task
        searchTask?.cancel()
        
        if searchText.isEmpty {
            // Show all dockets when search is empty
            filteredDockets = allDockets
            applySorting()
            return
        }
        
        // If using Asana, search on-demand with debouncing
        if settings.docketSource == .asana {
            // Debounce: wait 300ms after user stops typing
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                
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
            applySorting()
        }
    }
    
    /// Move selection up or down in the list
    func moveSelection(_ direction: Int) {
        guard !filteredDockets.isEmpty else { return }
        
        let currentIndex: Int
        if let selected = selectedDocket,
           let index = filteredDockets.firstIndex(where: { $0.id == selected.id }) {
            currentIndex = index
        } else {
            currentIndex = 0
        }
        
        let newIndex = max(0, min(filteredDockets.count - 1, currentIndex + direction))
        selectedDocket = filteredDockets[newIndex]
    }
    
    func applySorting() {
        let docketsToSort = searchText.isEmpty ? allDockets : filteredDockets
        let sorted = docketsToSort.sorted { d1, d2 in
            switch sortOrder {
            case .recentlyUpdated:
                // Most recently added first (use createdAt, fallback to updatedAt, nil dates go to end)
                let date1 = d1.createdAt ?? d1.updatedAt
                let date2 = d2.createdAt ?? d2.updatedAt
                if let date1 = date1, let date2 = date2 {
                    return date1 > date2
                } else if date1 != nil {
                    return true
                } else if date2 != nil {
                    return false
                }
                if let n1 = Int(d1.number.filter { $0.isNumber }),
                   let n2 = Int(d2.number.filter { $0.isNumber }) {
                    return n1 > n2
                }
                return d1.number > d2.number
                
            case .docketNumberDesc:
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
                
            case .docketNumberAsc:
                if let n1 = Int(d1.number.filter { $0.isNumber }),
                   let n2 = Int(d2.number.filter { $0.isNumber }) {
                    if n1 == n2 {
                        return d1.jobName < d2.jobName
                    }
                    return n1 < n2
                }
                if d1.number == d2.number {
                    return d1.jobName < d2.jobName
                }
                return d1.number < d2.number
                
            case .jobNameAsc:
                if d1.jobName == d2.jobName {
                    if let n1 = Int(d1.number.filter { $0.isNumber }),
                       let n2 = Int(d2.number.filter { $0.isNumber }) {
                        return n1 > n2
                    }
                    return d1.number > d2.number
                }
                return d1.jobName < d2.jobName
                
            case .jobNameDesc:
                if d1.jobName == d2.jobName {
                    if let n1 = Int(d1.number.filter { $0.isNumber }),
                       let n2 = Int(d2.number.filter { $0.isNumber }) {
                        return n1 > n2
                    }
                    return d1.number > d2.number
                }
                return d1.jobName > d2.jobName
            }
        }
        
        if searchText.isEmpty {
            allDockets = sorted
            filteredDockets = sorted
            // Auto-select first if none selected
            if selectedDocket == nil && !filteredDockets.isEmpty {
                selectedDocket = filteredDockets.first
            }
        } else {
            filteredDockets = sorted
            // Auto-select first if none selected
            if selectedDocket == nil && !filteredDockets.isEmpty {
                selectedDocket = filteredDockets.first
            }
        }
    }
    
    /// Check if a docket matches the search query
    func matchesSearch(docket: DocketInfo, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        
        let searchLower = query.lowercased()
        let isNumericQuery = query.allSatisfy { $0.isNumber }
        
        if isNumericQuery {
            let docketNumberLower = docket.number.lowercased()
            return docket.fullName.lowercased().contains(searchLower) ||
                   docketNumberLower.hasPrefix(searchLower) ||
                   docket.jobName.lowercased().contains(searchLower)
        } else {
            return docket.fullName.lowercased().contains(searchLower) ||
                   docket.number.lowercased().contains(searchLower) ||
                   docket.jobName.lowercased().contains(searchLower)
        }
    }
    
    func searchAsana(query: String) {
        // Cancel any previous search
        searchTask?.cancel()
        
        guard !query.isEmpty else {
            // If query is empty, show all dockets
            filteredDockets = allDockets
            applySorting()
            isScanning = false
            return
        }
        
            isScanning = false
        asanaError = nil
        
        // If we don't have dockets loaded yet, load from cache
        if allDockets.isEmpty {
            let cachedDockets = cacheManager.loadCachedDockets()
            if !cachedDockets.isEmpty {
                allDockets = cachedDockets
                applySorting()
            }
        }
        
        // Filter dockets based on search query
        let searchLower = query.lowercased()
        let isNumericQuery = query.allSatisfy { $0.isNumber }
        
        let matched = allDockets.filter { docket in
            if isNumericQuery {
                let docketNumberLower = docket.number.lowercased()
                return docket.fullName.lowercased().contains(searchLower) ||
                       docketNumberLower.hasPrefix(searchLower) ||
                       docket.jobName.lowercased().contains(searchLower)
            } else {
                return docket.fullName.lowercased().contains(searchLower) ||
                       docket.number.lowercased().contains(searchLower) ||
                       docket.jobName.lowercased().contains(searchLower)
            }
        }
        
        // Apply sorting to filtered results
        let sorted = matched.sorted { d1, d2 in
            switch sortOrder {
            case .recentlyUpdated:
                // Most recently added first (use createdAt, fallback to updatedAt, nil dates go to end)
                let date1 = d1.createdAt ?? d1.updatedAt
                let date2 = d2.createdAt ?? d2.updatedAt
                if let date1 = date1, let date2 = date2 {
                    return date1 > date2
                } else if date1 != nil {
                    return true
                } else if date2 != nil {
                    return false
                }
                if let n1 = Int(d1.number.filter { $0.isNumber }),
                   let n2 = Int(d2.number.filter { $0.isNumber }) {
                    return n1 > n2
                }
                return d1.number > d2.number
                
            case .docketNumberDesc:
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
                
            case .docketNumberAsc:
                if let n1 = Int(d1.number.filter { $0.isNumber }),
                   let n2 = Int(d2.number.filter { $0.isNumber }) {
                    if n1 == n2 {
                        return d1.jobName < d2.jobName
                    }
                    return n1 < n2
                }
                if d1.number == d2.number {
                    return d1.jobName < d2.jobName
                }
                return d1.number < d2.number
                
            case .jobNameAsc:
                if d1.jobName == d2.jobName {
                    if let n1 = Int(d1.number.filter { $0.isNumber }),
                       let n2 = Int(d2.number.filter { $0.isNumber }) {
                        return n1 > n2
                    }
                    return d1.number > d2.number
                }
                return d1.jobName < d2.jobName
                
            case .jobNameDesc:
                if d1.jobName == d2.jobName {
                    if let n1 = Int(d1.number.filter { $0.isNumber }),
                       let n2 = Int(d2.number.filter { $0.isNumber }) {
                        return n1 > n2
                    }
                    return d1.number > d2.number
                }
                return d1.jobName > d2.jobName
            }
        }
        
        filteredDockets = sorted
        
        // Auto-select first result if available
        if !filteredDockets.isEmpty {
            selectedDocket = filteredDockets.first
        } else {
            selectedDocket = nil
        }
    }
}

// MARK: - Main window focus driver (avoids stale closure capture in key handler)

/// Holds the current main-window keyboard navigation actions. Updated every time the modifier's body runs
/// so the key handler always calls into the live ContentView state.
final class MainWindowFocusDriver {
    static let shared = MainWindowFocusDriver()
    var moveGridFocus: ((ContentView.GridDirection) -> Void)?
    var activateFocusedButton: (() -> Void)?
    var isKeyboardModeBinding: Binding<Bool>?
    /// For debugging: returns current focus description from the view that last updated the driver.
    var getFocusDescription: (() -> String)?
    private init() {}
}

// MARK: - View Modifiers

struct KeyboardHandlersModifier: ViewModifier {
    @Binding var isKeyboardMode: Bool
    var focusedButton: FocusState<ActionButtonFocus?>.Binding
    let moveGridFocus: (ContentView.GridDirection) -> Void
    let activateFocusedButton: () -> Void
    let performActionForFocus: (ActionButtonFocus) -> Void
    @ObservedObject var settingsManager: SettingsManager
    @Binding var showSearchSheet: Bool
    @Binding var showQuickSearchSheet: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showVideoConverterSheet: Bool
    @Binding var showPortalSheet: Bool
    @Binding var showNewDocketSheet: Bool
    @Binding var showDocketSelectionSheet: Bool
    @Binding var initialSearchText: String

    func body(content: Content) -> some View {
        let driver = MainWindowFocusDriver.shared
        driver.moveGridFocus = moveGridFocus
        driver.activateFocusedButton = { [performActionForFocus] in
            guard let f = MainWindowKeyboardFocus.shared.focusedButton else { return }
            performActionForFocus(f)
        }
        driver.isKeyboardModeBinding = $isKeyboardMode
        driver.getFocusDescription = { String(describing: MainWindowKeyboardFocus.shared.focusedButton) }
        let mainWindowKeyHandler: (NSEvent) -> Bool = { event in
            if LayoutEditManager.shared.isEditMode { return true }
            driver.isKeyboardModeBinding?.wrappedValue = true
            let keyCode = event.keyCode
            switch keyCode {
            case 123:
                MainWindowKeyboardFocus.shared.focusedButton = MainWindowKeyboardFocus.nextFocus(from: MainWindowKeyboardFocus.shared.focusedButton, direction: .left)
            case 124:
                MainWindowKeyboardFocus.shared.focusedButton = MainWindowKeyboardFocus.nextFocus(from: MainWindowKeyboardFocus.shared.focusedButton, direction: .right)
            case 125:
                MainWindowKeyboardFocus.shared.focusedButton = MainWindowKeyboardFocus.nextFocus(from: MainWindowKeyboardFocus.shared.focusedButton, direction: .down)
            case 126:
                MainWindowKeyboardFocus.shared.focusedButton = MainWindowKeyboardFocus.nextFocus(from: MainWindowKeyboardFocus.shared.focusedButton, direction: .up)
            case 36:
                if MainWindowKeyboardFocus.shared.focusedButton == nil {
                    MainWindowKeyboardFocus.shared.focusedButton = .file
                }
                driver.activateFocusedButton?()
            default:
                return false
            }
            let focusAfter = driver.getFocusDescription?() ?? "nil"
            KeyboardNavigationCoordinator.logDebug(location: "ContentView.swift:mainWindowKeyHandler", message: "After move/activate", data: ["keyCode": Int(keyCode), "focusAfter": focusAfter], hypothesisId: "H11")
            return true
        }
        return content
            .keyboardNavigationHandler(handleKey: mainWindowKeyHandler)
            .onKeyPress(.leftArrow) {
                // #region agent log
                KeyboardNavigationCoordinator.logDebug(
                    location: "ContentView.swift:onKeyPress(.leftArrow)",
                    message: "onKeyPress received left arrow",
                    data: [:],
                    hypothesisId: "H9"
                )
                // #endregion
                // Don't handle arrow keys if in layout edit mode
                if LayoutEditManager.shared.isEditMode {
                    return .ignored
                }
                isKeyboardMode = true
                moveGridFocus(.left)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                // #region agent log
                KeyboardNavigationCoordinator.logDebug(
                    location: "ContentView.swift:onKeyPress(.rightArrow)",
                    message: "onKeyPress received right arrow",
                    data: [:],
                    hypothesisId: "H9"
                )
                // #endregion
                // Don't handle arrow keys if in layout edit mode
                if LayoutEditManager.shared.isEditMode {
                    return .ignored
                }
                isKeyboardMode = true
                moveGridFocus(.right)
                return .handled
            }
            .onKeyPress(.upArrow) {
                // #region agent log
                KeyboardNavigationCoordinator.logDebug(
                    location: "ContentView.swift:onKeyPress(.upArrow)",
                    message: "onKeyPress received up arrow",
                    data: [:],
                    hypothesisId: "H9"
                )
                // #endregion
                // Don't handle arrow keys if in layout edit mode
                if LayoutEditManager.shared.isEditMode {
                    return .ignored
                }
                isKeyboardMode = true
                moveGridFocus(.up)
                return .handled
            }
            .onKeyPress(.downArrow) {
                // #region agent log
                KeyboardNavigationCoordinator.logDebug(
                    location: "ContentView.swift:onKeyPress(.downArrow)",
                    message: "onKeyPress received down arrow",
                    data: [:],
                    hypothesisId: "H9"
                )
                // #endregion
                // Don't handle arrow keys if in layout edit mode
                if LayoutEditManager.shared.isEditMode {
                    return .ignored
                }
                isKeyboardMode = true
                moveGridFocus(.down)
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
            .onKeyPress { press in
                if press.key == .tab {
                    isKeyboardMode = true
                }

                guard !showSearchSheet && !showQuickSearchSheet && !SettingsWindowManager.shared.isVisible && !showVideoConverterSheet && !showPortalSheet && !showNewDocketSheet && !showDocketSelectionSheet else {
                    return .ignored
                }
                
                // Check if a text field is currently focused - if so, don't trigger autosearch
                if isTextFieldFocused() {
                    return .ignored
                }

                // Don't trigger quick search if CMD is held (for keyboard shortcuts)
                if press.modifiers.contains(.command) {
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
            .onChange(of: focusedButton.wrappedValue) { oldValue, newValue in
                if newValue != nil {
                    isKeyboardMode = true
                }
            }
    }
    
    /// Check if any text field is currently focused/active in any window
    private func isTextFieldFocused() -> Bool {
        // Check if the current first responder is a text field
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
            if let firstResponder = window.firstResponder {
                // Check if first responder is an NSTextView or NSTextField
                if firstResponder is NSTextView || firstResponder is NSTextField {
                    return true
                }
                // Also check if it's a text field's field editor
                if let textView = firstResponder as? NSTextView,
                   textView.isFieldEditor {
                    return true
                }
            }
        }
        
        // Also check all windows for any focused text fields
        for window in NSApplication.shared.windows {
            if let firstResponder = window.firstResponder {
                if firstResponder is NSTextView || firstResponder is NSTextField {
                    return true
                }
                if let textView = firstResponder as? NSTextView,
                   textView.isFieldEditor {
                    return true
                }
            }
        }
        
        return false
    }
}

struct AlertsModifier: ViewModifier {
    @Binding var showAlert: Bool
    let alertMessage: String
    @ObservedObject var manager: MediaManager
    @Binding var showSettingsSheet: Bool
    
    func body(content: Content) -> some View {
        content
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
            // Connection warnings now shown via status indicators in sidebar
            // Removed alert popup on launch
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
    }
}

struct SheetsModifier: ViewModifier {
    @Binding var showNewDocketSheet: Bool
    @Binding var selectedDocket: String
    @ObservedObject var manager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var sessionManager: SessionManager
    @Binding var showSearchSheet: Bool
    let initialSearchText: String
    @Binding var showDocketSelectionSheet: Bool
    @Binding var pendingJobType: JobType?
    @Binding var showManualPrepSheet: Bool
    let wpDate: Date
    let prepDate: Date
    @Binding var showQuickSearchSheet: Bool
    @ObservedObject var cacheManager: AsanaCacheManager
    @Binding var showSettingsSheet: Bool
    @Binding var showVideoConverterSheet: Bool
    @Binding var showPortalSheet: Bool
    @Binding var pendingFileThenPrep: Bool
    var onFileThenPrepConfirm: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showNewDocketSheet) {
                NewDocketView(
                    isPresented: $showNewDocketSheet,
                    selectedDocket: $selectedDocket,
                    manager: manager,
                    settingsManager: settingsManager
                )
                .sheetBorder()
            }
            .sheet(isPresented: $showSearchSheet) {
                SearchView(manager: manager, settingsManager: settingsManager, isPresented: $showSearchSheet, initialText: initialSearchText)
                    .sheetBorder()
            }
            .sheet(isPresented: $showDocketSelectionSheet) {
                DocketSearchView(
                    manager: manager,
                    settingsManager: settingsManager,
                    isPresented: $showDocketSelectionSheet,
                    selectedDocket: $selectedDocket,
                    jobType: pendingJobType ?? .workPicture,
                    onConfirm: {
                        if pendingFileThenPrep {
                            onFileThenPrepConfirm(selectedDocket)
                            showDocketSelectionSheet = false
                            return
                        }
                        if let type = pendingJobType {
                            if type == .prep {
                                showManualPrepSheet = true
                            } else {
                                manager.runJob(
                                    type: type,
                                    docket: selectedDocket,
                                    wpDate: wpDate,
                                    prepDate: prepDate
                                )
                            }
                            pendingJobType = nil
                        }
                    },
                    cacheManager: cacheManager
                )
                .sheetBorder()
            }
            .sheet(isPresented: $showManualPrepSheet) {
                ManualPrepSheet(
                    manager: manager,
                    isPresented: $showManualPrepSheet,
                    docket: selectedDocket,
                    wpDate: wpDate,
                    prepDate: prepDate
                )
                .sheetBorder()
            }
            .sheet(isPresented: $showQuickSearchSheet) {
                QuickDocketSearchView(isPresented: $showQuickSearchSheet, initialText: initialSearchText, settingsManager: settingsManager, cacheManager: cacheManager)
                    .sheetBorder()
            }
            .sheet(isPresented: $manager.showPrepSummary) {
                PrepSummaryView(summary: manager.prepSummary, isPresented: $manager.showPrepSummary)
                    .sheetBorder()
            }
            .sheet(isPresented: $showVideoConverterSheet) {
                VideoConverterView(manager: manager)
                    .sheetBorder()
            }
            .sheet(isPresented: $showPortalSheet) {
                PortalView(
                    isPresented: $showPortalSheet,
                    onOpenVideoConverter: {
                        showPortalSheet = false
                        showVideoConverterSheet = true
                    },
                    onOpenRestripe: {
                        showPortalSheet = false
                        RestripeWindowManager.shared.show()
                    },
                    onOpenSimian: {
                        showPortalSheet = false
                        SimianPostWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
                    }
                )
                .sheetBorder()
            }
            .sheet(isPresented: $manager.showOMFAAFValidator) {
                if let fileURL = manager.omfAafFileToValidate,
                   let validator = manager.omfAafValidator {
                    OMFAAFValidatorView(validator: validator, fileURL: fileURL)
                        .sheetBorder()
                }
            }
    }
}

struct ContentViewLifecycleModifier: ViewModifier {
    @Binding var showSearchSheet: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showQuickSearchSheet: Bool
    @Binding var initialSearchText: String
    var mainViewFocused: FocusState<Bool>.Binding
    var focusedButton: FocusState<ActionButtonFocus?>.Binding
    @ObservedObject var manager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var metadataManager: DocketMetadataManager
    @ObservedObject var cacheManager: AsanaCacheManager
    @Binding var isCommandKeyHeld: Bool
    let autoSyncAsanaCache: () -> Void
    @Binding var hourlySyncTask: Task<Void, Never>?
    
    func body(content: Content) -> some View {
        content
            .onChange(of: showSearchSheet) { oldValue, newValue in
                if !newValue {
                    initialSearchText = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        mainViewFocused.wrappedValue = true
                    }
                }
            }
            .onChange(of: manager.selectedFiles.count) { oldValue, newValue in
                if newValue > 0 && focusedButton.wrappedValue == nil {
                    focusedButton.wrappedValue = .file
                }
            }
            .onChange(of: showQuickSearchSheet) { oldValue, newValue in
                if !newValue {
                    initialSearchText = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        focusedButton.wrappedValue = .file
                    }
                }
            }
            .onChange(of: settingsManager.currentSettings) { oldValue, newValue in
                manager.updateConfig(settings: newValue)
                metadataManager.updateSettings(newValue)
                // Update cache manager with new shared cache settings
                cacheManager.updateCacheSettings(
                    sharedCacheURL: newValue.sharedCacheURL,
                    useSharedCache: newValue.useSharedCache,
                    serverBasePath: newValue.serverBasePath,
                    serverConnectionURL: newValue.serverConnectionURL
                )
                // Update sync settings for periodic background sync
                if newValue.docketSource == .asana {
                    cacheManager.updateSyncSettings(
                        workspaceID: newValue.asanaWorkspaceID,
                        projectID: newValue.asanaProjectID,
                        docketField: newValue.asanaDocketField,
                        jobNameField: newValue.asanaJobNameField
                )
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    mainViewFocused.wrappedValue = true
                    focusedButton.wrappedValue = .file
                }

                // Build search indexes immediately at app startup
                manager.buildAllFolderIndexes()

                // Monitor Command key state for showing shortcuts
                NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    isCommandKeyHeld = event.modifierFlags.contains(.command)
                    return event
                }
                
                // Update cache manager with shared cache settings
                let settings = settingsManager.currentSettings
                cacheManager.updateCacheSettings(
                    sharedCacheURL: settings.sharedCacheURL,
                        useSharedCache: settings.useSharedCache,
                        serverBasePath: settings.serverBasePath,
                        serverConnectionURL: settings.serverConnectionURL
                    )
                
                // Update sync settings for periodic background sync
                if settings.docketSource == .asana {
                    cacheManager.updateSyncSettings(
                        workspaceID: settings.asanaWorkspaceID,
                        projectID: settings.asanaProjectID,
                        docketField: settings.asanaDocketField,
                        jobNameField: settings.asanaJobNameField
                    )
                }
                
                // Auto-sync Asana cache on app launch if using Asana source
                autoSyncAsanaCache()
                
                // Start watching Downloads folder for "Use with MediaDash" popup
                Task { @MainActor in
                    DownloadPromptManager.shared.startWatching()
                }
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: DownloadPromptNotification.addToStaging)) { notification in
                guard let url = notification.userInfo?["url"] as? URL else { return }
                DispatchQueue.main.async {
                    guard url.isFileURL else { return }
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
                    let fileItem = FileItem(url: url)
                    let existing = Set(manager.selectedFiles.map { $0.url })
                    if !existing.contains(fileItem.url) {
                        manager.selectedFiles.append(fileItem)
                    }
                }
            }
            .onDisappear {
                // Clean up task when view disappears
                hourlySyncTask?.cancel()
                hourlySyncTask = nil
            }
    }
}

// MARK: - Notification Tab Button

struct NotificationTabButton: View {
    @ObservedObject var notificationCenter: NotificationCenter
    @Binding var showNotificationCenter: Bool
    @State private var isHovered = false
    
    var body: some View {
        Button(action: {
            showNotificationCenter.toggle()
        }) {
            HStack(spacing: 6) {
                Spacer()
                
                Image(systemName: "bell")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                Text("New Dockets")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                
                if notificationCenter.unreadCount > 0 {
                    Text("\(notificationCenter.unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .clipShape(Capsule())
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .help("New Dockets (\(notificationCenter.unreadCount))")
        .onHover { hovering in
            isHovered = hovering
        }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Email Refresh Button

struct EmailRefreshButton: View {
    @EnvironmentObject var emailScanningService: EmailScanningService
    var notificationCenter: NotificationCenter? = nil
    var grabbedIndicatorService: GrabbedIndicatorService? = nil
    @State private var isHovered = false
    @State private var isRefreshing = false
    @State private var statusMessage: String?
    @State private var statusTimer: Timer?
    
    var body: some View {
        HStack(spacing: 4) {
            Button(action: {
                guard !isRefreshing else { return }
                isRefreshing = true
                statusMessage = nil
                
                Task { @MainActor in
                    // Capture the service to avoid environment object wrapper issues
                    let service = emailScanningService
                    
                    // Get notification count before scan
                    let beforeCount = notificationCenter?.notifications.filter { $0.status == .pending }.count ?? 0
                    
                    // Use scanUnreadEmails with forceRescan to rescan even if notifications exist
                    await service.scanUnreadEmails(forceRescan: true)
                    
                    // After scanning, immediately check for grabbed replies
                    if let grabbedService = grabbedIndicatorService {
                        print("EmailRefreshButton: Triggering grabbed reply check after scan...")
                        await grabbedService.checkForGrabbedReplies()
                    }
                    
                    // Get notification count after scan
                    let afterCount = notificationCenter?.notifications.filter { $0.status == .pending }.count ?? 0
                    let newCount = afterCount - beforeCount
                    
                    await MainActor.run {
                        isRefreshing = false
                        
                        // Show status message
                        if newCount > 0 {
                            statusMessage = "✅ Found \(newCount) new notification\(newCount == 1 ? "" : "s")"
                        } else {
                            statusMessage = "✓ Up to date"
                        }
                        
                        // Clear status message after 3 seconds
                        statusTimer?.invalidate()
                        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                            statusMessage = nil
                        }
                    }
                }
            }) {
                ZStack {
                    Circle()
                        .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.accentColor.opacity(0.1))
                        .frame(width: 24, height: 24)
                    
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
            }
            .buttonStyle(.plain)
            .help(statusMessage ?? "Refresh emails")
            .disabled(isRefreshing || emailScanningService.isScanning)
            .onHover { hovering in
                isHovered = hovering
            }
            
            // Status message
            if let status = statusMessage {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                    .animation(.easeInOut, value: statusMessage)
            }
        }
        .onDisappear {
            statusTimer?.invalidate()
        }
    }
}

// MARK: - Workspace Menu Button

struct WorkspaceMenuButton: View {
    let profile: WorkspaceProfile
    @ObservedObject var sessionManager: SessionManager
    @State private var isHovered = false
    
    var body: some View {
        Button(role: .destructive) {
            sessionManager.logout()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(profile.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Text("Log Out")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.red.opacity(0.15) : Color.red.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            }
    }
}


// MARK: - Preview

#Preview {
    ContentView()
}

