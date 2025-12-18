//
//  DashboardView.swift
//  MediaDash
//
//  Dashboard Mode - Full desktop experience with modular panels
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Dashboard Layout Configuration

/// Stores user's panel layout preferences
struct DashboardLayoutConfig: Codable {
    var leftPanelWidth: CGFloat
    var rightPanelWidth: CGFloat
    var leftPanelCollapsed: Bool
    var rightPanelCollapsed: Bool
    
    static var `default`: DashboardLayoutConfig {
        DashboardLayoutConfig(
            leftPanelWidth: 320,
            rightPanelWidth: 380,
            leftPanelCollapsed: false,
            rightPanelCollapsed: false
        )
    }
}

// MARK: - Dashboard View

struct DashboardView: View {
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
    
    let wpDate: Date
    let prepDate: Date
    let dateFormatter: DateFormatter
    let attempt: (JobType) -> Void
    let cacheManager: AsanaCacheManager?
    
    // Panel state
    @State private var leftPanelWidth: CGFloat = 320
    @State private var rightPanelWidth: CGFloat = 380
    @State private var leftPanelCollapsed: Bool = false
    @State private var rightPanelCollapsed: Bool = false
    @State private var isDraggingLeftDivider: Bool = false
    @State private var isDraggingRightDivider: Bool = false
    @State private var selectedFileIndex: Int? = nil
    
    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            DashboardTopBar(
                showSearchSheet: $showSearchSheet,
                showQuickSearchSheet: $showQuickSearchSheet,
                showSettingsSheet: $showSettingsSheet,
                showVideoConverterSheet: $showVideoConverterSheet,
                leftPanelCollapsed: $leftPanelCollapsed,
                rightPanelCollapsed: $rightPanelCollapsed,
                wpDate: wpDate,
                prepDate: prepDate,
                dateFormatter: dateFormatter,
                attempt: attempt,
                cacheManager: cacheManager
            )
            .draggableLayout(id: "dashboardTopBar")
            
            // Main Content with Panels
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    // Left Panel - Calendar & Dockets
                    if !leftPanelCollapsed {
                        DashboardLeftPanel(
                            cacheManager: cacheManager,
                            showSettings: $showSettingsSheet
                        )
                        .frame(width: leftPanelWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .draggableLayout(id: "dashboardLeftPanel")
                        
                        // Left Divider
                        ResizableDivider(
                            isDragging: $isDraggingLeftDivider,
                            panelWidth: $leftPanelWidth,
                            minWidth: 280,
                            maxWidth: 450,
                            edge: .leading
                        )
                    }
                    
                    // Center - Staging Area
                    DashboardStagingArea(
                        cacheManager: cacheManager,
                        selectedFileIndex: $selectedFileIndex
                    )
                    .frame(minWidth: 400)
                    .draggableLayout(id: "dashboardStagingArea")
                    
                    // Right Panel - Notifications
                    if !rightPanelCollapsed {
                        // Right Divider
                        ResizableDivider(
                            isDragging: $isDraggingRightDivider,
                            panelWidth: $rightPanelWidth,
                            minWidth: 320,
                            maxWidth: 500,
                            edge: .trailing
                        )
                        
                        DashboardNotificationsPanel(
                            isVisible: .constant(true),
                            showSettings: $showSettingsSheet
                        )
                        .frame(width: rightPanelWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .draggableLayout(id: "dashboardRightPanel")
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: leftPanelCollapsed)
            .animation(.easeInOut(duration: 0.2), value: rightPanelCollapsed)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Resizable Divider

struct ResizableDivider: View {
    @Binding var isDragging: Bool
    @Binding var panelWidth: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let edge: Edge
    
    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: isDragging ? 3 : 1)
            .contentShape(Rectangle().inset(by: -5))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        let delta = edge == .leading ? value.translation.width : -value.translation.width
                        let newWidth = panelWidth + delta
                        panelWidth = min(max(newWidth, minWidth), maxWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

// MARK: - Dashboard Top Bar

struct DashboardTopBar: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var manager: MediaManager
    @EnvironmentObject var notificationCenter: NotificationCenter
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var emailScanningService: EmailScanningService
    @Environment(\.colorScheme) var colorScheme
    
    @Binding var showSearchSheet: Bool
    @Binding var showQuickSearchSheet: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showVideoConverterSheet: Bool
    @Binding var leftPanelCollapsed: Bool
    @Binding var rightPanelCollapsed: Bool
    
    let wpDate: Date
    let prepDate: Date
    let dateFormatter: DateFormatter
    let attempt: (JobType) -> Void
    let cacheManager: AsanaCacheManager?
    
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
        HStack(spacing: 0) {
            // Left: Panel toggle + Logo
            HStack(spacing: 12) {
                // Traffic light padding
                Color.clear.frame(width: 70)
                
                // Left panel toggle
                Button(action: { 
                    withAnimation { leftPanelCollapsed.toggle() }
                }) {
                    Image(systemName: leftPanelCollapsed ? "sidebar.left" : "sidebar.leading")
                        .font(.system(size: 14))
                        .foregroundColor(leftPanelCollapsed ? .secondary : .accentColor)
                }
                .buttonStyle(.plain)
                .help(leftPanelCollapsed ? "Show Calendar Panel" : "Hide Calendar Panel")
                
                logoImage
            }
            .frame(width: 200, alignment: .leading)
            
            Divider()
                .frame(height: 28)
                .padding(.horizontal, 12)
            
            // Compact Mode Button
            Button(action: {
                switchToCompactMode()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.portrait")
                        .font(.system(size: 12))
                    Text("Compact")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Switch to Compact Mode")
            
            Divider()
                .frame(height: 28)
                .padding(.horizontal, 12)
            
            // Center: Quick Actions
            HStack(spacing: 8) {
                DashboardQuickAction(
                    title: "File",
                    icon: "folder.fill",
                    color: currentTheme.buttonColors.file,
                    shortcut: "⌘1",
                    disabled: manager.selectedFiles.isEmpty
                ) {
                    attempt(.workPicture)
                }
                
                DashboardQuickAction(
                    title: "Prep",
                    icon: "list.clipboard.fill",
                    color: currentTheme.buttonColors.prep,
                    shortcut: "⌘2",
                    disabled: manager.selectedFiles.isEmpty
                ) {
                    attempt(.prep)
                }
                
                DashboardQuickAction(
                    title: "Both",
                    icon: "doc.on.doc.fill",
                    color: currentTheme.buttonColors.both,
                    shortcut: "⌘3",
                    disabled: manager.selectedFiles.isEmpty
                ) {
                    attempt(.both)
                }
                
                DashboardQuickAction(
                    title: "Convert",
                    icon: "film.fill",
                    color: Color(red: 0.50, green: 0.25, blue: 0.35),
                    shortcut: "⌘4",
                    disabled: false
                ) {
                    showVideoConverterSheet = true
                }
            }
            
            Spacer()
            
            // Right: Search and tools
            HStack(spacing: 10) {
                // Search
                Button(action: { showSearchSheet = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                        Text("Search")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
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
                
                // Status indicators
                if let cache = cacheManager {
                    ServerStatusIndicator(
                        cacheManager: cache,
                        showSettings: $showSettingsSheet
                    )
                    
                    CacheStatusIndicator(
                        cacheManager: cache
                    )
                }
                
                Divider()
                    .frame(height: 20)
                
                // Notification panel toggle
                Button(action: { 
                    withAnimation { rightPanelCollapsed.toggle() }
                }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: rightPanelCollapsed ? "bell" : "bell.fill")
                            .font(.system(size: 16))
                            .foregroundColor(rightPanelCollapsed ? .secondary : .accentColor)
                        
                        if notificationCenter.unreadCount > 0 && rightPanelCollapsed {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(rightPanelCollapsed ? "Show Notifications" : "Hide Notifications")
                
                // Settings
                Button(action: { showSettingsSheet = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                
                // User profile
                if case .loggedIn(let profile) = sessionManager.authenticationState {
                    DashboardProfileButton(profile: profile, sessionManager: sessionManager)
                }
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.6)
        )
    }
}

// MARK: - Dashboard Quick Action (Compact)

struct DashboardQuickAction: View {
    let title: String
    let icon: String
    let color: Color
    let shortcut: String
    let disabled: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(disabled ? Color.gray.opacity(0.5) : color)
                    .cornerRadius(6)
                
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(disabled ? .secondary : .primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered && !disabled ? color.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .help("\(title) (\(shortcut))")
    }
}

// MARK: - Dashboard Profile Button

struct DashboardProfileButton: View {
    let profile: WorkspaceProfile
    let sessionManager: SessionManager
    
    @State private var isHovered = false
    @State private var showMenu = false
    
    private var initials: String {
        let components = profile.name.components(separatedBy: " ")
        if components.count >= 2 {
            return "\(components[0].prefix(1))\(components[1].prefix(1))".uppercased()
        }
        return String(profile.name.prefix(2)).uppercased()
    }
    
    var body: some View {
        Button(action: { showMenu.toggle() }) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 30, height: 30)
                
                Text(initials)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 36, height: 36)
                        
                        Text(initials)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                            .font(.system(size: 13, weight: .medium))
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
                    sessionManager.logout()
                }) {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Log Out")
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .frame(width: 220)
        }
    }
}

// MARK: - Dashboard Left Panel (Calendar & Dockets)

struct DashboardLeftPanel: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var emailScanningService: EmailScanningService
    let cacheManager: AsanaCacheManager?
    @Binding var showSettings: Bool
    
    @State private var selectedTab: LeftPanelTab = .recent

    enum LeftPanelTab: String, CaseIterable {
        case recent = "Recent"
        case status = "Status"

        var icon: String {
            switch self {
            case .recent: return "clock.arrow.circlepath"
            case .status: return "chart.bar.fill"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab Selector
            HStack(spacing: 0) {
                ForEach(LeftPanelTab.allCases, id: \.self) { tab in
                    Button(action: { selectedTab = tab }) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedTab == tab ?
                            Color.accentColor.opacity(0.15) :
                            Color.clear
                        )
                        .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
            
            Divider()
            
            // Tab Content
            switch selectedTab {
            case .recent:
                RecentDocketsView(cacheManager: cacheManager)
            case .status:
                StatusPanelView(
                    cacheManager: cacheManager,
                    showSettings: $showSettings
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Asana-Style Task Row

struct AsanaTaskRow: View {
    let docket: DocketInfo
    @State private var isHovered = false
    @State private var isExpanded = false
    
    private var projectColor: Color {
        if let colorName = docket.projectMetadata?.color {
            return asanaColorToSwiftUI(colorName)
        }
        return .blue
    }
    
    private func asanaColorToSwiftUI(_ colorName: String) -> Color {
        switch colorName.lowercased() {
        case "dark-pink", "hot-pink": return .pink
        case "dark-red", "red": return .red
        case "dark-orange", "orange": return .orange
        case "dark-warm-gray", "warm-gray": return Color(red: 0.6, green: 0.5, blue: 0.4)
        case "yellow", "light-yellow": return .yellow
        case "dark-green", "green": return .green
        case "light-green", "lime": return Color(red: 0.5, green: 0.8, blue: 0.3)
        case "dark-teal", "teal": return .teal
        case "aqua", "light-teal": return .cyan
        case "dark-blue", "blue": return .blue
        case "light-blue": return Color(red: 0.4, green: 0.7, blue: 1.0)
        case "dark-purple", "purple": return .purple
        case "light-purple": return Color(red: 0.7, green: 0.5, blue: 0.9)
        case "cool-gray", "light-gray": return .gray
        default: return .blue
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main task row
            HStack(spacing: 10) {
                // Checkbox placeholder (visual only)
                Circle()
                    .strokeBorder(projectColor, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                
                // Project color indicator bar
                RoundedRectangle(cornerRadius: 2)
                    .fill(projectColor)
                    .frame(width: 3, height: 28)
                
                // Task content
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // Docket number badge
                        Text(docket.number)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(projectColor)
                            .cornerRadius(3)
                        
                        // Job name
                        Text(docket.jobName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    
                    // Metadata row
                    HStack(spacing: 8) {
                        if let metadataType = docket.metadataType {
                            HStack(spacing: 3) {
                                Image(systemName: iconForMetadataType(metadataType))
                                    .font(.system(size: 8))
                                Text(metadataType)
                                    .font(.system(size: 9))
                            }
                            .foregroundColor(.secondary)
                        }
                        
                        if let projectName = docket.projectMetadata?.projectName {
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                    .font(.system(size: 8))
                                Text(projectName)
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                            }
                            .foregroundColor(.secondary)
                        }
                        
                        if let subtasks = docket.subtasks, !subtasks.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 8))
                                Text("\(subtasks.count)")
                                    .font(.system(size: 9))
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Expand button for subtasks
                if let subtasks = docket.subtasks, !subtasks.isEmpty {
                    Button(action: { 
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            
            // Subtasks (when expanded)
            if isExpanded, let subtasks = docket.subtasks, !subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subtasks) { subtask in
                        SubtaskRow(subtask: subtask, projectColor: projectColor)
                    }
                }
                .padding(.leading, 36)
                .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.gray.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isHovered ? Color.gray.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in isHovered = hovering }
    }
    
    private func iconForMetadataType(_ type: String) -> String {
        switch type.uppercased() {
        case "SESSION", "SESSIONS": return "waveform.circle"
        case "PREP": return "list.clipboard"
        case "POST": return "film"
        case "MIX": return "slider.horizontal.3"
        case "MASTER", "MASTERING": return "dial.high"
        case "RECORD", "RECORDING": return "mic"
        default: return "tag"
        }
    }
}

// MARK: - Subtask Row

struct SubtaskRow: View {
    let subtask: DocketSubtask
    let projectColor: Color
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            // Checkbox placeholder
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: 12, height: 12)
            
            // Subtask name
            Text(subtask.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .foregroundColor(.primary)
            
            Spacer()
            
            // Metadata type badge
            if let metadataType = subtask.metadataType {
                Text(metadataType)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(projectColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(projectColor.opacity(0.1))
                    .cornerRadius(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.gray.opacity(0.05) : Color.clear)
        )
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Legacy Calendar Components (kept for compatibility)

struct CalendarDayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let hasDockets: Bool
    let docketCount: Int
    let action: () -> Void
    
    private var calendar: Calendar { Calendar.current }
    
    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        isSelected ? Color.accentColor :
                        isToday ? Color.accentColor.opacity(0.15) :
                        Color.clear
                    )
                
                VStack(spacing: 2) {
                    Text("\(calendar.component(.day, from: date))")
                        .font(.system(size: 12, weight: isSelected || isToday ? .semibold : .regular))
                        .foregroundColor(
                            isSelected ? .white :
                            isToday ? .accentColor :
                            .primary
                        )
                    
                    if hasDockets && !isSelected {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 4, height: 4)
                    } else if isSelected && hasDockets {
                        Text("\(docketCount)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .frame(height: 36)
        }
        .buttonStyle(.plain)
    }
}

struct CalendarDocketRow: View {
    let docket: DocketInfo
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 10) {
            Text(docket.number)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue)
                .cornerRadius(4)
            
            Text(docket.jobName)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(.primary)
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.gray.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Recent Dockets View

struct RecentDocketsView: View {
    let cacheManager: AsanaCacheManager?
    @EnvironmentObject var settingsManager: SettingsManager
    
    @State private var recentDockets: [DocketInfo] = []
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var lastSyncDate: Date?
    @State private var showForceSyncConfirmation = false
    @State private var forceSyncError: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recently Modified in Asana")
                        .font(.system(size: 12, weight: .semibold))
                    
                    if let lastSync = lastSyncDate {
                        Text("Last sync: \(lastSync, style: .relative) ago")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .help("When the app last synced with Asana. Docket timestamps show when they were modified in Asana.")
                    }
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    // Show sync progress if syncing
                    if let cache = cacheManager, cache.isSyncing {
                        if cache.syncProgress > 0 {
                            ProgressView(value: cache.syncProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 50)
                            Text("\(Int(cache.syncProgress * 100))%")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.blue)
                        } else {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                    } else if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                    
                    // Sync button - Option-click for force full sync
                    Button(action: {
                        if NSEvent.modifierFlags.contains(.option) {
                            showForceSyncConfirmation = true
                        } else {
                            Task { await syncWithAsana() }
                        }
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundColor(isSyncing ? .secondary : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSyncing || (cacheManager?.isSyncing ?? false))
                    .help("Sync with Asana (⌥-click for full sync)")
                    
                    Text("\(recentDockets.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            
            Divider()
            
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if recentDockets.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No dockets in cache")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    if cacheManager == nil {
                        Text("Cache manager not connected")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    } else {
                        Button("Sync with Asana") {
                            Task { await syncWithAsana() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(recentDockets.prefix(50)) { docket in
                            RecentDocketRow(docket: docket)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .task {
            await loadDockets()
        }
        .alert("Force Full Sync", isPresented: $showForceSyncConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Start Full Sync", role: .destructive) {
                Task { await forceFullSync() }
            }
        } message: {
            Text("This will clear the local cache and fetch ALL data directly from Asana.\n\nThis may take several minutes for large workspaces and bypasses the shared cache.")
        }
    }
    
    private func forceFullSync() async {
        guard let cacheManager = cacheManager else { return }
        
        isSyncing = true
        forceSyncError = nil
        
        let settings = settingsManager.currentSettings
        do {
            try await cacheManager.forceFullSync(
                workspaceID: settings.asanaWorkspaceID,
                projectID: settings.asanaProjectID,
                docketField: settings.asanaDocketField,
                jobNameField: settings.asanaJobNameField
            )
            
            // Reload after sync
            await loadDockets()
        } catch {
            print("⚠️ [Recent] Force sync failed: \(error.localizedDescription)")
            forceSyncError = error.localizedDescription
        }
        
        isSyncing = false
    }
    
    private func loadDockets() async {
        guard let cacheManager = cacheManager else {
            print("📋 [Recent] No cache manager available")
            isLoading = false
            return
        }
        
        // Small delay to let UI render first
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Load on main actor (required by AsanaCacheManager)
        let (allDockets, syncDate) = await MainActor.run {
            (cacheManager.loadCachedDockets(), cacheManager.lastSyncDate)
        }
        
        print("📋 [Recent] Loaded \(allDockets.count) dockets, last sync: \(String(describing: syncDate))")
        
        // Debug: Print top 5 most recent dates
        let docketsWithDates = allDockets.filter { $0.updatedAt != nil }
        let sortedByDate = docketsWithDates.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        
        print("📋 [Recent] Loaded \(allDockets.count) total dockets, \(docketsWithDates.count) have updatedAt dates")
        print("📋 [Recent] Top 5 most recent Asana modified_at dates:")
        for (index, docket) in sortedByDate.prefix(5).enumerated() {
            if let date = docket.updatedAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let daysAgo = Date().timeIntervalSince(date) / (24 * 60 * 60)
                print("   \(index + 1). \(docket.number) - \(formatter.string(from: date)) (\(String(format: "%.1f", daysAgo)) days ago)")
            }
        }
        
        // Check if we have any very recent dockets (within last 24 hours)
        let docketsModifiedRecently = sortedByDate.filter { docket in
            if let date = docket.updatedAt {
                return Date().timeIntervalSince(date) < 24 * 60 * 60
            }
            return false
        }
        if docketsModifiedRecently.isEmpty && !allDockets.isEmpty {
            print("⚠️ [Recent] WARNING: No dockets modified in the last 24 hours. Most recent is \(sortedByDate.first?.number ?? "unknown") from \(sortedByDate.first?.updatedAt != nil ? String(format: "%.1f", Date().timeIntervalSince(sortedByDate.first!.updatedAt!) / (24 * 60 * 60)) : "unknown") days ago")
            print("💡 [Recent] If you expect newer dockets, try doing a Force Full Sync from Settings")
        } else {
            print("✅ [Recent] Found \(docketsModifiedRecently.count) docket(s) modified in the last 24 hours")
        }
        
        await MainActor.run {
            recentDockets = sortedByDate
            lastSyncDate = syncDate
            isLoading = false
        }
    }
    
    private func syncWithAsana() async {
        guard let cacheManager = cacheManager else { return }
        
        isSyncing = true
        
        let settings = settingsManager.currentSettings
        do {
            try await cacheManager.syncWithAsana(
                workspaceID: settings.asanaWorkspaceID,
                projectID: settings.asanaProjectID,
                docketField: settings.asanaDocketField,
                jobNameField: settings.asanaJobNameField,
                sharedCacheURL: settings.sharedCacheURL,
                useSharedCache: settings.useSharedCache
            )
            
            // Reload after sync
            await loadDockets()
        } catch {
            print("⚠️ [Recent] Sync failed: \(error.localizedDescription)")
        }
        
        isSyncing = false
    }
}

struct RecentDocketRow: View {
    let docket: DocketInfo
    @State private var isHovered = false
    
    private var timeAgo: String {
        guard let date = docket.updatedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // Docket number
            Text(docket.number)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue)
                .cornerRadius(4)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(docket.jobName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                
                Text(timeAgo)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.gray.opacity(0.1) : Color.clear)
        )
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Status Panel View

struct StatusPanelView: View {
    let cacheManager: AsanaCacheManager?
    @Binding var showSettings: Bool
    @EnvironmentObject var emailScanningService: EmailScanningService
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Server Status
                if let cacheManager = cacheManager {
                    StatusCard(title: "Server Connection") {
                        ServerStatusIndicator(
                            cacheManager: cacheManager,
                            showSettings: $showSettings
                        )
                    }
                    
                    StatusCard(title: "Cache Status") {
                        CacheStatusIndicator(cacheManager: cacheManager)
                    }
                }
            }
            .padding(16)
        }
    }
}

struct StatusCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            
            HStack {
                content
                Spacer()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Dashboard Staging Area

struct DashboardStagingArea: View {
    @EnvironmentObject var manager: MediaManager
    @EnvironmentObject var settingsManager: SettingsManager
    let cacheManager: AsanaCacheManager?
    @Binding var selectedFileIndex: Int?
    
    @State private var isDragTargeted = false
    @State private var showBatchRenameSheet = false
    @State private var filesToRename: [FileItem] = []
    
    private var totalFileCount: Int {
        manager.selectedFiles.reduce(0) { $0 + $1.fileCount }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "tray.2.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                    
                    Text("Staging Area")
                        .font(.system(size: 15, weight: .semibold))
                    
                    if !manager.selectedFiles.isEmpty {
                        Text("\(totalFileCount)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue))
                    }
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: { manager.pickFiles() }) {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("o", modifiers: .command)
                    
                    if !manager.selectedFiles.isEmpty {
                        Button(action: { manager.clearFiles() }) {
                            Label("Clear", systemImage: "trash")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                        .keyboardShortcut("w", modifiers: .command)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            
            Divider()
            
            // Content
            if manager.selectedFiles.isEmpty {
                DashboardEmptyState(isDragTargeted: $isDragTargeted)
            } else {
                DashboardFileGrid(
                    selectedFileIndex: $selectedFileIndex,
                    showBatchRenameSheet: $showBatchRenameSheet,
                    filesToRename: $filesToRename
                )
            }
            
            // Status Bar
            dashboardStatusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .sheet(isPresented: $showBatchRenameSheet) {
            BatchRenameSheet(manager: manager, filesToRename: filesToRename)
        }
    }
    
    private var dashboardStatusBar: some View {
        HStack {
            // Left side - Scanning and Asana sync indicators
            HStack(spacing: 12) {
                if manager.isIndexing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text("Scanning")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }
                
                if let cache = cacheManager, cache.isSyncing {
                    HStack(spacing: 8) {
                        if cache.syncProgress > 0 {
                            // Show progress bar when we have progress info
                            ProgressView(value: cache.syncProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                            Text("\(Int(cache.syncProgress * 100))%")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.blue)
                        } else {
                            // Show spinner when starting
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        }
                        Text(cache.syncPhase.isEmpty ? "Syncing with Asana" : cache.syncPhase)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.blue)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)
                }
            }
            
            Spacer()
            
            // Center/Right - Processing or ready status
            if manager.isProcessing {
                HStack(spacing: 12) {
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
            } else {
                let isSyncing = cacheManager?.isSyncing ?? false
                if !isSyncing && !manager.isIndexing {
                    Text("Ready.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
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

// MARK: - Dashboard Empty State

struct DashboardEmptyState: View {
    @EnvironmentObject var manager: MediaManager
    @Binding var isDragTargeted: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(isDragTargeted ? Color.blue.opacity(0.4) : Color.gray.opacity(0.15), lineWidth: 2)
                    .frame(width: 100, height: 100)
                
                Circle()
                    .fill(isDragTargeted ? Color.blue.opacity(0.1) : Color.gray.opacity(0.05))
                    .frame(width: 80, height: 80)
                
                Image(systemName: isDragTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                    .font(.system(size: 32))
                    .foregroundColor(isDragTargeted ? .blue : .secondary.opacity(0.6))
            }
            
            VStack(spacing: 6) {
                Text(isDragTargeted ? "Drop files here" : "Drop files to stage")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isDragTargeted ? .blue : .primary)
                
                Text("or click Add to select files")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Button(action: { manager.pickFiles() }) {
                Label("Add Files", systemImage: "plus.circle.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDragTargeted ? Color.blue : Color.gray.opacity(0.15),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .padding(20)
        )
    }
}

// MARK: - Dashboard File Grid

struct DashboardFileGrid: View {
    @EnvironmentObject var manager: MediaManager
    @Binding var selectedFileIndex: Int?
    @Binding var showBatchRenameSheet: Bool
    @Binding var filesToRename: [FileItem]
    
    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 10)
    ]
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(manager.selectedFiles.enumerated()), id: \.element.id) { index, file in
                    DashboardFileCard(
                        file: file,
                        isSelected: selectedFileIndex == index,
                        onSelect: { selectedFileIndex = index },
                        onRemove: { manager.removeFile(withId: file.id) }
                    )
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Dashboard File Card

struct DashboardFileCard: View {
    let file: FileItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    
    @State private var isHovered = false
    
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
        VStack(spacing: 0) {
            // Preview
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [fileIconColor.opacity(0.2), fileIconColor.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Image(systemName: fileIcon)
                    .font(.system(size: 28))
                    .foregroundColor(fileIconColor)
                
                // Remove button
                if isHovered {
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: onRemove) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                                    .shadow(radius: 2)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }
            .frame(height: 70)
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                
                HStack(spacing: 4) {
                    Text(file.url.pathExtension.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(fileIconColor)
                        .cornerRadius(3)
                    
                    if file.isDirectory {
                        Text("\(file.fileCount)")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? Color.accentColor : (isHovered ? Color.gray.opacity(0.3) : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Dashboard Notifications Panel

struct DashboardNotificationsPanel: View {
    @EnvironmentObject var notificationCenter: NotificationCenter
    @EnvironmentObject var emailScanningService: EmailScanningService
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var manager: MediaManager
    @Binding var isVisible: Bool
    @Binding var showSettings: Bool
    
    @State private var selectedFilter: NotificationFilter = .all
    
    enum NotificationFilter: String, CaseIterable {
        case all = "All"
        case newDockets = "Dockets"
        case requests = "Requests"
        case fileDeliveries = "Files"
        case forReview = "Review"
        
        var icon: String {
            switch self {
            case .all: return "tray.full"
            case .newDockets: return "doc.badge.plus"
            case .fileDeliveries: return "arrow.down.doc"
            case .requests: return "hand.raised"
            case .forReview: return "eye"
            }
        }
    }
    
    private var filteredNotifications: [Notification] {
        let active = notificationCenter.activeNotifications
        switch selectedFilter {
        case .all:
            return active
        case .newDockets:
            return active.filter { $0.type == .newDocket }
        case .fileDeliveries:
            return active.filter { $0.type == .mediaFiles }
        case .requests:
            return active.filter { $0.type == .request }
        case .forReview:
            // For review filter (no longer available)
            return []
        }
    }
    
    private var reviewCount: Int {
        // Review count (no longer available)
        return 0
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
                
                Text("Notifications")
                    .font(.system(size: 13, weight: .semibold))
                
                Spacer()
                
                if notificationCenter.unreadCount > 0 {
                    Text("\(notificationCenter.unreadCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
                
                EmailRefreshButton(
                    notificationCenter: notificationCenter,
                    grabbedIndicatorService: notificationCenter.grabbedIndicatorService
                )
                .environmentObject(emailScanningService)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            // Filter Tabs
            HStack(spacing: 0) {
                ForEach(NotificationFilter.allCases, id: \.self) { filter in
                    Button(action: { selectedFilter = filter }) {
                        HStack(spacing: 4) {
                            Image(systemName: filter.icon)
                                .font(.system(size: 9))
                            Text(filter.rawValue)
                                .font(.system(size: 10, weight: .medium))
                            
                            if filter == .forReview && reviewCount > 0 {
                                Text("\(reviewCount)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            selectedFilter == filter ?
                            Color.accentColor.opacity(0.15) : Color.clear
                        )
                        .foregroundColor(selectedFilter == filter ? .accentColor : .secondary)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            
            Divider()
            
            // Notifications List
            if filteredNotifications.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No notifications")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredNotifications) { notification in
                            DashboardNotificationCard(
                                notification: notification,
                                showSettings: $showSettings
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Dashboard Notification Card

struct DashboardNotificationCard: View {
    let notification: Notification
    @Binding var showSettings: Bool
    @EnvironmentObject var notificationCenter: NotificationCenter
    @EnvironmentObject var emailScanningService: EmailScanningService
    @EnvironmentObject var settingsManager: SettingsManager
    
    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var showJobNameEditDialog = false
    @State private var editedJobName = ""
    @State private var showDocketInputDialog = false
    @State private var inputDocketNumber = ""
    
    private var typeIcon: String {
        switch notification.type {
        case .newDocket: return "doc.badge.plus"
        case .mediaFiles: return "arrow.down.doc.fill"
        case .request: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .junk, .skipped: return "xmark.circle.fill"
        }
    }
    
    private var typeColor: Color {
        switch notification.type {
        case .newDocket: return .blue
        case .mediaFiles: return .green
        case .request: return .orange
        case .error: return .red
        case .info: return .cyan
        case .junk, .skipped: return .gray
        }
    }
    
    private var displayTitle: String {
        notification.jobName ?? notification.emailSubject ?? notification.title
    }
    
    private var displaySubject: String {
        notification.emailSubject ?? notification.title
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            
            if isExpanded {
                expandedContent
            }
        }
        .padding(10)
        .background(cardBackground)
        .overlay(cardBorder)
        .onHover { hovering in isHovered = hovering }
        .contextMenu { contextMenuContent }
        .help("Right-click for more options")
        .sheet(isPresented: $showJobNameEditDialog) {
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notification.id }) {
                JobNameEditDialog(
                    isPresented: $showJobNameEditDialog,
                    jobName: $editedJobName,
                    docketNumber: currentNotification.docketNumber,
                    onConfirm: { newJobName in
                        notificationCenter.updateJobName(currentNotification, to: newJobName)
                        editedJobName = ""
                    }
                )
                .onAppear {
                    editedJobName = currentNotification.jobName ?? ""
                }
            }
        }
        .sheet(isPresented: $showDocketInputDialog) {
            DocketNumberInputDialog(
                isPresented: $showDocketInputDialog,
                docketNumber: $inputDocketNumber,
                jobName: notification.jobName ?? "Unknown",
                onConfirm: {
                    if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notification.id }) {
                        let finalDocketNumber = inputDocketNumber.isEmpty ? generateAutoDocketNumber() : inputDocketNumber
                        notificationCenter.updateDocketNumber(currentNotification, to: finalDocketNumber)
                        inputDocketNumber = ""
                    }
                }
            )
        }
    }
    
    private var cardHeader: some View {
        HStack(spacing: 8) {
            typeIconView
            titleSection
            Spacer()
            expandButton
        }
    }
    
    private var typeIconView: some View {
        ZStack {
            Circle()
                .fill(typeColor.opacity(0.15))
                .frame(width: 28, height: 28)
            
            Image(systemName: typeIcon)
                .font(.system(size: 12))
                .foregroundColor(typeColor)
        }
    }
    
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                docketBadge
                Text(displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            
            HStack(spacing: 6) {
                Text(notification.timestamp, style: .relative)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                
                confidenceIndicator
            }
        }
    }
    
    @ViewBuilder
    private var docketBadge: some View {
        if let docketNumber = notification.docketNumber, docketNumber != "TBD" {
            Text(docketNumber)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(typeColor)
                .cornerRadius(3)
        }
    }
    
    @ViewBuilder
    private var confidenceIndicator: some View {
        // Confidence indicator (no longer available)
        EmptyView()
    }
    
    private var expandButton: some View {
        Button(action: { isExpanded.toggle() }) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
    }
    
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            
            Text(displaySubject)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            
            if let body = notification.emailBody, !body.isEmpty {
                Text(body)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            
            actionButtons
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if notification.type == .newDocket, let emailId = notification.emailId {
                Button(action: { openEmail(emailId) }) {
                    Label("View Email", systemImage: "envelope")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            
            Button(action: { notificationCenter.archive(notification, emailScanningService: emailScanningService) }) {
                Label("Archive", systemImage: "archivebox")
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            
            Spacer()
        }
        .padding(.top, 4)
    }
    
    // MARK: - Context Menu
    
    @ViewBuilder
    private var contextMenuContent: some View {
        // Edit job name
        if notification.type == .newDocket {
            Button(action: { showJobNameEditDialog = true }) {
                Label("Edit Job Name", systemImage: "pencil")
            }
        }
        
        // Reset to defaults
        if notification.type == .newDocket {
            Button(action: {
                Task {
                    await notificationCenter.resetToDefaults(notification, emailScanningService: emailScanningService)
                }
            }) {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
        }
        
        Divider()
        
        // MindMap options removed
        
        // Open email in browser
        if let emailId = notification.emailId {
            Button(action: { openEmail(emailId) }) {
                Label("Open Email in Browser", systemImage: "safari")
            }
        }
        
        // Add docket number if missing
        if notification.type == .newDocket && (notification.docketNumber == nil || notification.docketNumber == "TBD") {
            Button(action: { showDocketInputDialog = true }) {
                Label("Add Docket Number", systemImage: "number")
            }
        }
        
        Divider()
        
        // Remove notification (marks email as read)
        Button(action: {
            Task {
                await notificationCenter.remove(notification, emailScanningService: emailScanningService)
            }
        }) {
            Label("Remove", systemImage: "trash")
        }
    }
    
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isHovered ? Color.gray.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(typeColor.opacity(notification.status == .pending ? 0.3 : 0), lineWidth: 1)
    }
    
    private func openEmail(_ messageId: String) {
        let urlString = "https://mail.google.com/mail/u/0/#inbox/\(messageId)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func generateAutoDocketNumber() -> String {
        let year = Calendar.current.component(.year, from: Date()) % 100
        let random = Int.random(in: 100...999)
        return "\(year)\(random)"
    }
}

// MARK: - Preview

#Preview {
    DashboardView(
        focusedButton: FocusState<ActionButtonFocus?>().projectedValue,
        mainViewFocused: FocusState<Bool>().projectedValue,
        isKeyboardMode: .constant(false),
        isCommandKeyHeld: .constant(false),
        hoverInfo: .constant("Ready"),
        showSearchSheet: .constant(false),
        showQuickSearchSheet: .constant(false),
        showSettingsSheet: .constant(false),
        showVideoConverterSheet: .constant(false),
        wpDate: Date(),
        prepDate: Date(),
        dateFormatter: DateFormatter(),
        attempt: { _ in },
        cacheManager: nil
    )
    .frame(width: 1400, height: 850)
}

