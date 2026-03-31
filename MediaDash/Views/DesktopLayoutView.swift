import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Desktop Layout View
/// A proper desktop-style layout with toolbar, narrow sidebar, main content, and details panel

struct DesktopLayoutView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var metadataManager: DocketMetadataManager
    @EnvironmentObject var manager: MediaManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var notificationCenter: NotificationCenter
    @EnvironmentObject var emailScanningService: EmailScanningService
    @Environment(\.colorScheme) var colorScheme
    
    // Bindings from ContentView
    var focusedButton: FocusState<ActionButtonFocus?>.Binding
    var mainViewFocused: FocusState<Bool>.Binding
    @Binding var isKeyboardMode: Bool
    @Binding var isCommandKeyHeld: Bool
    @Binding var hoverInfo: String
    @Binding var showSearchSheet: Bool
    @Binding var showQuickSearchSheet: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showVideoConverterSheet: Bool
    @Binding var showNotificationCenter: Bool
    
    let wpDate: Date
    let prepDate: Date
    let dateFormatter: DateFormatter
    let attempt: (JobType) -> Void
    let cacheManager: AsanaCacheManager?
    
    // State for details panel
    @State private var selectedFileIndex: Int? = nil
    @State private var showDetailsPanel: Bool = true
    
    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Toolbar
            DesktopToolbar(
                showSearchSheet: $showSearchSheet,
                showQuickSearchSheet: $showQuickSearchSheet,
                showSettingsSheet: $showSettingsSheet,
                showVideoConverterSheet: $showVideoConverterSheet,
                showNotificationCenter: $showNotificationCenter,
                showDetailsPanel: $showDetailsPanel,
                wpDate: wpDate,
                prepDate: prepDate,
                dateFormatter: dateFormatter,
                attempt: attempt,
                cacheManager: cacheManager
            )
            
            Divider()
            
            // Main Content Area
            HStack(spacing: 0) {
                // Narrow Icon Rail (left sidebar)
                DesktopIconRail(
                    showNotificationCenter: $showNotificationCenter,
                    showSettingsSheet: $showSettingsSheet
                )
                
                Divider()
                
                // Main Staging Area (center)
                DesktopStagingArea(
                    cacheManager: cacheManager,
                    prepDate: prepDate,
                    selectedFileIndex: $selectedFileIndex
                )
                
                // Details Panel (right) - only show when toggled and files exist
                if showDetailsPanel && !manager.selectedFiles.isEmpty {
                    Divider()
                    
                    DesktopDetailsPanel(
                        selectedFileIndex: $selectedFileIndex
                    )
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showDetailsPanel)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Desktop Toolbar

struct DesktopToolbar: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var manager: MediaManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var notificationCenter: NotificationCenter
    @Environment(\.colorScheme) var colorScheme
    
    @Binding var showSearchSheet: Bool
    @Binding var showQuickSearchSheet: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showVideoConverterSheet: Bool
    @Binding var showNotificationCenter: Bool
    @Binding var showDetailsPanel: Bool
    
    let wpDate: Date
    let prepDate: Date
    let dateFormatter: DateFormatter
    let attempt: (JobType) -> Void
    let cacheManager: AsanaCacheManager?
    
    @State private var testNotificationCount = 0
    
    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }
    
    private var logoImage: some View {
        let baseLogo = Image("HeaderLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 32)
        
        if colorScheme == .light {
            return AnyView(baseLogo.colorInvert())
        } else {
            return AnyView(baseLogo)
        }
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Logo
            logoImage
                .padding(.leading, 8)
            
            Divider()
                .frame(height: 28)
            
            // Main Actions as toolbar buttons
            HStack(spacing: 8) {
                ToolbarActionButton(
                    title: "File",
                    subtitle: "Work Picture",
                    icon: "folder.fill",
                    color: currentTheme.buttonColors.file,
                    shortcut: "⌘1",
                    disabled: manager.selectedFiles.isEmpty
                ) {
                    attempt(.workPicture)
                }
                
                ToolbarActionButton(
                    title: "Simian",
                    subtitle: "Upload",
                    icon: "arrow.up.circle.fill",
                    color: currentTheme.buttonColors.simian,
                    shortcut: "⌘2",
                    disabled: false
                ) {
                    SimianPostWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager, manager: manager)
                }
                
                ToolbarActionButton(
                    title: "Both",
                    subtitle: "File + Prep",
                    icon: "doc.on.doc.fill",
                    color: currentTheme.buttonColors.both,
                    shortcut: "⌘3",
                    disabled: manager.selectedFiles.isEmpty
                ) {
                    attempt(.both)
                }
                
                Divider()
                    .frame(height: 28)
                
                ToolbarActionButton(
                    title: "Portal",
                    subtitle: "",
                    icon: "film.fill",
                    color: Color(red: 0.50, green: 0.25, blue: 0.25),
                    shortcut: "⌘4",
                    disabled: false
                ) {
                    // Portal functionality to be implemented later
                }
            }
            
            Spacer()
            
            // Right-side toolbar items
            HStack(spacing: 12) {
                // Toggle details panel
                Button(action: { showDetailsPanel.toggle() }) {
                    Image(systemName: showDetailsPanel ? "sidebar.trailing" : "sidebar.trailing")
                        .font(.system(size: 14))
                        .foregroundColor(showDetailsPanel ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showDetailsPanel ? "Hide Details Panel" : "Show Details Panel")
                
                Divider()
                    .frame(height: 20)
                
                // Search
                Button(action: { showSearchSheet = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                        Text("Search")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Search (⌘F)")
                
                // Job Info
                Button(action: { showQuickSearchSheet = true }) {
                    Image(systemName: "number.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Job Info (⌘D)")
                
                // Settings
                Button(action: { 
                    SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                
                // View Menu (with debug options)
                if settingsManager.currentSettings.showDebugFeatures {
                    Divider()
                        .frame(height: 20)
                    
                    Menu {
                        Button("Create Test Docket Notification") {
                            createTestDocketNotification()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("View")
                                .font(.system(size: 12))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("View Menu")
                }
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onAppear {
            // Count existing test notifications to continue numbering
            updateTestNotificationCount()
        }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name("CreateTestDocketNotification"))) { _ in
            // Handle test notification creation from menu bar
            print("🔔 DesktopToolbar received CreateTestDocketNotification")
            createTestDocketNotification()
        }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name("DebugFeaturesToggled"))) { notification in
            // Refresh settings when debug features are toggled
            Task { @MainActor in
                // Small delay to ensure UserDefaults is fully written
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                settingsManager.reloadCurrentProfile()
                print("🔄 DebugFeatures: Reloaded settings, showDebugFeatures = \(settingsManager.currentSettings.showDebugFeatures)")
            }
        }
    }
    
    /// Create a test docket notification with a random docket number that doesn't exist
    private func createTestDocketNotification() {
        print("🔔 DesktopToolbar.createTestDocketNotification() called")
        print("   notificationCenter: \(notificationCenter)")
        print("   testNotificationCount: \(testNotificationCount)")
        
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
        
        repeat {
            // Generate 3 random digits (000-999) and combine with year prefix to make 5 digits
            let randomSuffix = Int.random(in: 0...999)
            let suffixString = String(format: "%03d", randomSuffix)
            docketNumber = "\(yearPrefixString)\(suffixString)"
            attempts += 1
        } while docketExists(docketNumber: docketNumber, jobName: "TEST \(testNotificationCount + 1)") && attempts < maxAttempts
        
        if attempts >= maxAttempts {
            // Fallback: use timestamp-based docket number with valid year prefix
            let timestamp = Int(Date().timeIntervalSince1970) % 1000
            let suffixString = String(format: "%03d", timestamp)
            docketNumber = "\(yearPrefixString)\(suffixString)"
        }
        
        // Increment test notification count
        testNotificationCount += 1
        let jobName = "TEST \(testNotificationCount)"
        
        print("   Generated docket: \(docketNumber), job: \(jobName)")
        
        // Create the test notification
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
    
    /// Check if a docket already exists (in Work Picture or existing notifications)
    private func docketExists(docketNumber: String, jobName: String) -> Bool {
        // Check Work Picture
        let docketName = "\(docketNumber)_\(jobName)"
        if manager.dockets.contains(docketName) {
            return true
        }
        
        // Check existing notifications
        return notificationCenter.notifications.contains { notification in
            notification.docketNumber == docketNumber && notification.jobName == jobName
        }
    }
    
    /// Update test notification count based on existing test notifications
    private func updateTestNotificationCount() {
        let testNotifications = notificationCenter.notifications.filter { notification in
            notification.type == .newDocket &&
            notification.jobName?.hasPrefix("TEST ") == true
        }
        
        // Extract the highest test number
        var maxTestNumber = 0
        for notification in testNotifications {
            if let jobName = notification.jobName {
                let testNumString = jobName.replacingOccurrences(of: "TEST ", with: "")
                if let testNum = Int(testNumString) {
                    maxTestNumber = max(maxTestNumber, testNum)
                }
            }
        }
        
        testNotificationCount = maxTestNumber
    }
}

// MARK: - Toolbar Action Button

struct ToolbarActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let shortcut: String
    let disabled: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(disabled ? Color.gray.opacity(0.5) : color)
                    .cornerRadius(6)
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(disabled ? .secondary : .primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isHovered && !disabled ? color.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            isHovered = hovering
            if hovering && !disabled {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("\(title) (\(shortcut))")
    }
}

// MARK: - Desktop Icon Rail

struct DesktopIconRail: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var notificationCenter: NotificationCenter
    @EnvironmentObject var emailScanningService: EmailScanningService
    @Environment(\.colorScheme) var colorScheme
    
    @Binding var showNotificationCenter: Bool
    @Binding var showSettingsSheet: Bool
    
    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // New Dockets
            IconRailButton(
                icon: "bell.fill",
                label: "New Dockets",
                badge: notificationCenter.unreadCount > 0 ? notificationCenter.unreadCount : nil,
                isActive: showNotificationCenter
            ) {
                showNotificationCenter.toggle()
            }
            
            Spacer()
            
            Divider()
                .padding(.horizontal, 12)
            
            // Profile/Workspace
            if case .loggedIn(let profile) = sessionManager.authenticationState {
                IconRailProfileButton(profile: profile, sessionManager: sessionManager)
            }
        }
        .padding(.vertical, 16)
        .frame(width: 64)
        .background(currentTheme.sidebarBackground)
    }
}

// MARK: - Icon Rail Button

struct IconRailButton: View {
    let icon: String
    let label: String
    let badge: Int?
    let isActive: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(isActive ? .accentColor : (isHovered ? .primary : .secondary))
                    
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundColor(isHovered ? .primary : .secondary)
                        .lineLimit(1)
                }
                .frame(width: 52, height: 48)
                .background(isActive ? Color.accentColor.opacity(0.15) : (isHovered ? Color.gray.opacity(0.1) : Color.clear))
                .cornerRadius(8)
                
                // Badge
                if let badge = badge, badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .cornerRadius(8)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(label)
    }
}

// MARK: - Icon Rail Profile Button

struct IconRailProfileButton: View {
    let profile: WorkspaceProfile
    let sessionManager: SessionManager
    
    @State private var isHovered = false
    @State private var showMenu = false
    @State private var showLogoutConfirmation = false
    
    // Compute initials from profile name
    private var initials: String {
        let components = profile.name.components(separatedBy: " ")
        if components.count >= 2 {
            let first = components[0].prefix(1)
            let last = components[1].prefix(1)
            return "\(first)\(last)".uppercased()
        }
        return String(profile.name.prefix(2)).uppercased()
    }
    
    // Display name - first name or full name
    private var displayName: String {
        profile.name.components(separatedBy: " ").first ?? profile.name
    }
    
    var body: some View {
        Button(action: { showMenu.toggle() }) {
            VStack(spacing: 4) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 32, height: 32)
                    
                    Text(initials)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
                
                Text(displayName)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 52, height: 52)
            .background(isHovered ? Color.gray.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(isPresented: $showMenu, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 40, height: 40)
                        
                        Text(initials)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.system(size: 13, weight: .semibold))
                        if let username = profile.username {
                            Text(username)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Divider()
                
                Button(action: {
                    showMenu = false
                    showLogoutConfirmation = true
                }) {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Log Out")
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(width: 250)
        }
        .confirmationDialog("Log Out", isPresented: $showLogoutConfirmation, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) {
                sessionManager.logout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can sign in again as this or another account (media or producer).")
        }
    }
}

// MARK: - Desktop Staging Area

struct DesktopStagingArea: View {
    @EnvironmentObject var manager: MediaManager
    @EnvironmentObject var settingsManager: SettingsManager
    let cacheManager: AsanaCacheManager?
    let prepDate: Date
    @Binding var selectedFileIndex: Int?
    
    @State private var isDragTargeted = false
    @State private var showBatchRenameSheet = false
    @State private var filesToRename: [FileItem] = []
    @State private var stagingContentMode: StagingCenterContentMode = .files
    
    private var totalFileCount: Int {
        manager.selectedFiles.reduce(0) { $0 + $1.fileCount }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header (match compact chrome: caption scale + controlBackground strip)
            HStack(spacing: 8) {
                if cacheManager != nil {
                    StagingHeaderModeToggleButton(selection: $stagingContentMode)
                } else {
                    Image(systemName: "tray.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Staging")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                if !manager.selectedFiles.isEmpty {
                    Text("\(totalFileCount) file\(totalFileCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Button(action: { manager.pickFiles() }) {
                    Color.clear.frame(width: 1, height: 1)
                }
                .keyboardShortcut("o", modifiers: .command)
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                if !manager.selectedFiles.isEmpty {
                    Button(action: { manager.clearFiles() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(stagingContentMode == .sessions)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            Group {
                switch stagingContentMode {
                case .files:
                    filesStagingBody
                case .sessions:
                    if let cache = cacheManager {
                        StagingSessionsPanel(cacheManager: cache, prepDate: prepDate)
                    } else {
                        Text("Connect Asana to use Sessions.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showBatchRenameSheet) {
            BatchRenameSheet(manager: manager, filesToRename: filesToRename)
                .sheetSizeStabilizer()
        }
    }
    
    private var filesStagingBody: some View {
        Group {
            if manager.selectedFiles.isEmpty {
                DesktopEmptyState(isDragTargeted: $isDragTargeted)
            } else {
                DesktopFileList(
                    selectedFileIndex: $selectedFileIndex,
                    showBatchRenameSheet: $showBatchRenameSheet,
                    filesToRename: $filesToRename
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            let fileItem = FileItem(url: url)
                            let currentIDs = Set(self.manager.selectedFiles.map { $0.url })
                            if !currentIDs.contains(fileItem.url) {
                                self.manager.selectedFiles.append(fileItem)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Desktop Empty State

struct DesktopEmptyState: View {
    @EnvironmentObject var manager: MediaManager
    @Binding var isDragTargeted: Bool
    
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(isDragTargeted ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2), lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                Image(systemName: isDragTargeted ? "arrow.down.doc" : "doc")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(isDragTargeted ? Color.accentColor : .secondary)
            }
            VStack(spacing: 4) {
                Text(isDragTargeted ? "Drop to add" : "No files staged")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("Click here, drag files in, or press ⌘O")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { manager.pickFiles() }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
                .padding(12)
        )
    }
}

// MARK: - Desktop File List

struct DesktopFileList: View {
    @EnvironmentObject var manager: MediaManager
    @Binding var selectedFileIndex: Int?
    @Binding var showBatchRenameSheet: Bool
    @Binding var filesToRename: [FileItem]
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(manager.selectedFiles.enumerated()), id: \.element.id) { index, file in
                    DesktopFileRow(
                        file: file,
                        isSelected: selectedFileIndex == index,
                        onSelect: { selectedFileIndex = index },
                        onRemove: { manager.removeFile(withId: file.id) }
                    )
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Desktop File Row

struct DesktopFileRow: View {
    let file: FileItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    
    @State private var isHovered = false
    
    private var fileIcon: String {
        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "mxf", "m4v":
            return "film"
        case "wav", "mp3", "aiff", "aif", "flac", "m4a":
            return "waveform"
        case "aaf", "omf":
            return "doc.text"
        default:
            return file.isDirectory ? "folder.fill" : "doc"
        }
    }
    
    private var fileIconColor: Color {
        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "mxf", "m4v":
            return .purple
        case "wav", "mp3", "aiff", "aif", "flac", "m4a":
            return .orange
        case "aaf", "omf":
            return .green
        default:
            return file.isDirectory ? .blue : .gray
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // File icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(fileIconColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: fileIcon)
                    .font(.system(size: 18))
                    .foregroundColor(fileIconColor)
            }
            
            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    if file.isDirectory {
                        Text("\(file.fileCount) items")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    
                    Text(file.url.pathExtension.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(fileIconColor.opacity(0.8))
                        .cornerRadius(4)
                    
                    if let size = file.formattedSize {
                        Text(size)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Remove button (visible on hover)
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from staging")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.gray.opacity(0.08) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Desktop Details Panel

struct DesktopDetailsPanel: View {
    @EnvironmentObject var manager: MediaManager
    @Binding var selectedFileIndex: Int?
    
    private var selectedFile: FileItem? {
        guard let index = selectedFileIndex,
              index >= 0,
              index < manager.selectedFiles.count else {
            return nil
        }
        return manager.selectedFiles[index]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Details")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            
            Divider()
            
            if let file = selectedFile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // File preview/icon
                        VStack(spacing: 12) {
                            FilePreviewView(file: file)
                                .frame(height: 140)
                                .frame(maxWidth: .infinity)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(8)
                            
                            Text(file.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        
                        Divider()
                        
                        // File details
                        VStack(alignment: .leading, spacing: 12) {
                            DetailRow(label: "Type", value: file.url.pathExtension.uppercased())
                            
                            if file.isDirectory {
                                DetailRow(label: "Items", value: "\(file.fileCount)")
                            }
                            
                            if let size = file.formattedSize {
                                DetailRow(label: "Size", value: size)
                            }
                            
                            DetailRow(label: "Location", value: file.url.deletingLastPathComponent().path)
                        }
                        
                        Divider()
                        
                        // Quick actions
                        VStack(spacing: 8) {
                            Button(action: {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }) {
                                HStack {
                                    Image(systemName: "folder")
                                    Text("Show in Finder")
                                    Spacer()
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            
                            Button(action: {
                                NSWorkspace.shared.open(file.url)
                            }) {
                                HStack {
                                    Image(systemName: "arrow.up.forward.square")
                                    Text("Open File")
                                    Spacer()
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(16)
                }
            } else {
                // No selection
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    
                    Text("Select a file to view details")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }
}

// MARK: - File Preview View

struct FilePreviewView: View {
    let file: FileItem
    
    private var fileIcon: String {
        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "mxf", "m4v":
            return "film.fill"
        case "wav", "mp3", "aiff", "aif", "flac", "m4a":
            return "waveform.circle.fill"
        case "aaf", "omf":
            return "doc.text.fill"
        default:
            return file.isDirectory ? "folder.fill" : "doc.fill"
        }
    }
    
    private var fileIconColor: Color {
        let ext = file.url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "mxf", "m4v":
            return .purple
        case "wav", "mp3", "aiff", "aif", "flac", "m4a":
            return .orange
        case "aaf", "omf":
            return .green
        default:
            return file.isDirectory ? .blue : .gray
        }
    }
    
    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [fileIconColor.opacity(0.3), fileIconColor.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Image(systemName: fileIcon)
                .font(.system(size: 48))
                .foregroundColor(fileIconColor)
        }
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Preview

#Preview {
    DesktopLayoutView(
        focusedButton: FocusState<ActionButtonFocus?>().projectedValue,
        mainViewFocused: FocusState<Bool>().projectedValue,
        isKeyboardMode: .constant(false),
        isCommandKeyHeld: .constant(false),
        hoverInfo: .constant("Ready"),
        showSearchSheet: .constant(false),
        showQuickSearchSheet: .constant(false),
        showSettingsSheet: .constant(false),
        showVideoConverterSheet: .constant(false),
        showNotificationCenter: .constant(false),
        wpDate: Date(),
        prepDate: Date(),
        dateFormatter: DateFormatter(),
        attempt: { _ in },
        cacheManager: nil
    )
    .frame(width: 1000, height: 700)
}

