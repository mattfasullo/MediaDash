import SwiftUI
import AppKit

/// Information about where a docket already exists
struct DocketExistenceInfo {
    var existsInWorkPicture: Bool = false
    var existsInAsana: Bool = false
    var asanaDocketInfo: DocketInfo? = nil // The matching docket from Asana if found
    
    var existsAnywhere: Bool {
        existsInWorkPicture || existsInAsana
    }
    
    var existenceDescription: String {
        var locations: [String] = []
        if existsInWorkPicture { locations.append("Work Picture") }
        if existsInAsana { locations.append("Asana") }
        return locations.isEmpty ? "" : locations.joined(separator: " & ")
    }
}

/// Expandable notification center view
struct NotificationCenterView: View {
    // Feature flags - set to false to disable features
    // TODO: Re-enable these features in the future by setting to true
    private static let enableFileDeliveryFeature = false
    private static let enableRequestFeature = false
    
    @ObservedObject var notificationCenter: NotificationCenter
    @ObservedObject var emailScanningService: EmailScanningService
    @ObservedObject var mediaManager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var isExpanded: Bool
    @Binding var showSettings: Bool
    
    @State private var processingNotification: UUID?
    @State private var isScanningEmails = false
    @State private var lastScanStatus: String?
    @State private var debugInfo: String?
    @State private var showDebugInfo = false
    @State private var isArchivedExpanded = false
    @State private var isFileDeliveriesExpanded = true // Default to expanded (keeping for archived section)
    @State private var selectedTab: NotificationTab = .newDockets // Tab selection - will be reset if disabled tab is selected
    @State private var isForReviewExpanded = true // Default to expanded for visibility
    @State private var cacheInfo: String?
    @State private var showCacheInfo = false
    @State private var isLoadingCache = false // Keep for fallback if file write fails
    
    enum NotificationTab {
        case newDockets
        case fileDeliveries
        case requests
    }
    
    // Computed properties for filtered notifications (cached to avoid repeated filtering)
    private var allActiveNotifications: [Notification] {
        notificationCenter.activeNotifications.filter { notification in
            // If notification is completed, check if docket exists
            if notification.status == .completed,
               notification.type == .newDocket,
               let docketNumber = notification.docketNumber,
               docketNumber != "TBD",
               let jobName = notification.jobName {
                // Don't show completed notification if docket already exists
                let docketName = "\(docketNumber)_\(jobName)"
                let exists = mediaManager.dockets.contains(docketName)
                if exists {
                    // Remove the notification asynchronously to avoid blocking view updates
                    Task { @MainActor in
                        notificationCenter.remove(notification, emailScanningService: emailScanningService)
                    }
                }
                return !exists
            }
            // Show all other notifications (including media files)
            return true
        }
    }
    
    private var mediaFileNotifications: [Notification] {
        allActiveNotifications.filter { $0.type == .mediaFiles }
    }
    
    private var activeNotifications: [Notification] {
        allActiveNotifications.filter { $0.type != .mediaFiles }
    }
    
    // All active notifications (no longer separated by confidence)
    private var regularNotifications: [Notification] {
        return allActiveNotifications
    }
    
    // Empty array - no longer using "For Review" section
    private var notificationsForReview: [Notification] {
        return []
    }
    
    // Regular new docket notifications (excluding media files, requests, and low confidence)
    private var regularNewDocketNotifications: [Notification] {
        regularNotifications.filter { $0.type == .newDocket }
    }
    
    // Regular file delivery notifications
    private var regularFileDeliveryNotifications: [Notification] {
        regularNotifications.filter { $0.type == .mediaFiles }
    }
    
    // Regular request notifications (including completed ones, which will be greyed out)
    private var regularRequestNotifications: [Notification] {
        allActiveNotifications.filter { $0.type == .request }
    }
    
    private var archivedNotifications: [Notification] {
        notificationCenter.archivedNotifications
    }
    
    var body: some View {
        mainContent
    }
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            headerSection
            
            Divider()
            
            gmailStatusBanner
            
            mainNotificationContent
        }
        .frame(width: 400, height: 500)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.clear)
        )
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        .onChange(of: activeNotifications.count) { oldCount, newCount in
            if selectedTab == .newDockets && newCount == 0 && !mediaFileNotifications.isEmpty && Self.enableFileDeliveryFeature {
                selectedTab = .fileDeliveries
            } else if selectedTab == .fileDeliveries && mediaFileNotifications.isEmpty && newCount > 0 {
                selectedTab = .newDockets
            }
        }
        .onChange(of: mediaFileNotifications.count) { oldCount, newCount in
            if selectedTab == .fileDeliveries && newCount == 0 && !activeNotifications.isEmpty {
                selectedTab = .newDockets
            }
        }
        .onChange(of: settingsManager.currentSettings.simianAPIBaseURL) { _, _ in
            // Refresh when Simian API configuration changes
        }
        .onAppear {
            handleViewAppear()
        }
    }
    
    private var headerSection: some View {
        HStack {
            Text("Notifications")
                .font(.system(size: 16, weight: .semibold))
            
            Spacer()
            
            if notificationCenter.unreadCount > 0 {
                Text("\(notificationCenter.unreadCount) new")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            EmailRefreshButton(
                notificationCenter: notificationCenter,
                grabbedIndicatorService: notificationCenter.grabbedIndicatorService
            )
                .environmentObject(emailScanningService)
            
            Button(action: {
                let manager = NotificationWindowManager.shared
                manager.setLocked(!manager.isLocked)
                var updatedSettings = settingsManager.currentSettings
                updatedSettings.notificationWindowLocked = manager.isLocked
                settingsManager.currentSettings = updatedSettings
                settingsManager.saveCurrentProfile()
            }) {
                Image(systemName: NotificationWindowManager.shared.isLocked ? "lock.fill" : "lock.open.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(NotificationWindowManager.shared.isLocked ? "Unlock window (detach from main window)" : "Lock window (follow main window)")
            
            Button(action: {
                NotificationWindowManager.shared.hideNotificationWindow()
                isExpanded = false
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            let manager = NotificationWindowManager.shared
            manager.setLocked(!manager.isLocked)
            var updatedSettings = settingsManager.currentSettings
            updatedSettings.notificationWindowLocked = manager.isLocked
            settingsManager.currentSettings = updatedSettings
            settingsManager.saveCurrentProfile()
        }
    }
    
    private var gmailStatusBanner: some View {
        Group {
            let isGmailConnected = emailScanningService.gmailService.isAuthenticated
            let gmailEnabled = settingsManager.currentSettings.gmailEnabled
            
            if !gmailEnabled {
                gmailDisabledBanner
            } else if gmailEnabled && !isGmailConnected {
                gmailNotConnectedBanner
            }
        }
    }
    
    private var gmailDisabledBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.slash.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gmail Integration Disabled")
                        .font(.system(size: 12, weight: .medium))
                    Text("Email notifications are disabled. Enable in Settings to receive new docket and file delivery notifications")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Settings") {
                    showSettings = true
                    NotificationWindowManager.shared.hideNotificationWindow()
                    isExpanded = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1))
            
            Divider()
        }
    }
    
    private var gmailNotConnectedBanner: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gmail Not Connected")
                        .font(.system(size: 12, weight: .medium))
                    Text("Email notifications are disabled")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Settings") {
                    showSettings = true
                    NotificationWindowManager.shared.hideNotificationWindow()
                    isExpanded = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1))
            
            Divider()
        }
    }
    
    private var mainNotificationContent: some View {
        Group {
            let isGmailConnected = emailScanningService.gmailService.isAuthenticated
            let gmailEnabled = settingsManager.currentSettings.gmailEnabled
            
            if gmailEnabled && !isGmailConnected {
                gmailNotConnectedEmptyState
            } else if !gmailEnabled && notificationsForReview.isEmpty && mediaFileNotifications.isEmpty && activeNotifications.isEmpty {
                gmailDisabledEmptyState
            } else if notificationsForReview.isEmpty && mediaFileNotifications.isEmpty && activeNotifications.isEmpty {
                noNotificationsEmptyState
            } else {
                notificationListContent
            }
        }
    }
    
    private var gmailNotConnectedEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            
            VStack(spacing: 8) {
                Text("Gmail Not Connected")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("Connect to Gmail to receive email notifications for new dockets")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            
            Button("Open Settings") {
                showSettings = true
                NotificationWindowManager.shared.hideNotificationWindow()
                isExpanded = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var gmailDisabledEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.slash.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            
            VStack(spacing: 8) {
                Text("Gmail Integration Disabled")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("Enable Gmail integration in Settings to receive email notifications for new dockets and file deliveries")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            
            Button("Open Settings") {
                showSettings = true
                NotificationWindowManager.shared.hideNotificationWindow()
                isExpanded = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var noNotificationsEmptyState: some View {
        VStack(spacing: 12) {
            if isScanningEmails {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Scanning for unread emails...")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "bell.slash")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No notifications")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                if let status = lastScanStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var notificationListContent: some View {
        VStack(spacing: 0) {
            // Tabs for notification types
            if !mediaFileNotifications.isEmpty || !activeNotifications.isEmpty || !notificationsForReview.isEmpty {
                HStack(spacing: 0) {
                            // New Dockets tab
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedTab = .newDockets
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text.fill")
                                        .font(.system(size: 11))
                                    Text("New Dockets")
                                        .font(.system(size: 12, weight: .medium))
                                    if !regularNewDocketNotifications.isEmpty {
                                        Text("(\(regularNewDocketNotifications.count))")
                                            .font(.system(size: 11))
                                            .opacity(0.7)
                                    }
                                }
                                .foregroundColor(selectedTab == .newDockets ? .blue : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    selectedTab == .newDockets
                                        ? Color.blue.opacity(0.1)
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                            
                            // FEATURE FLAG: File delivery tab is hidden when disabled
                            if Self.enableFileDeliveryFeature {
                                Divider()
                                    .frame(height: 20)
                                
                                // File Deliveries tab
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedTab = .fileDeliveries
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "link.circle.fill")
                                            .font(.system(size: 11))
                                        Text("File Deliveries")
                                            .font(.system(size: 12, weight: .medium))
                                        if !regularFileDeliveryNotifications.isEmpty {
                                            Text("(\(regularFileDeliveryNotifications.count))")
                                                .font(.system(size: 11))
                                                .opacity(0.7)
                                        }
                                    }
                                    .foregroundColor(selectedTab == .fileDeliveries ? .green : .secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        selectedTab == .fileDeliveries
                                            ? Color.green.opacity(0.1)
                                            : Color.clear
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // FEATURE FLAG: Request tab is hidden when disabled
                            if Self.enableRequestFeature {
                                Divider()
                                    .frame(height: 20)
                                
                                // Requests tab
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedTab = .requests
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "hand.raised.fill")
                                            .font(.system(size: 11))
                                        Text("Requests")
                                            .font(.system(size: 12, weight: .medium))
                                        if !regularRequestNotifications.isEmpty {
                                            Text("(\(regularRequestNotifications.count))")
                                                .font(.system(size: 11))
                                                .opacity(0.7)
                                        }
                                    }
                                    .foregroundColor(selectedTab == .requests ? .orange : .secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        selectedTab == .requests
                                            ? Color.orange.opacity(0.1)
                                            : Color.clear
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                }
                .background(Color(nsColor: .separatorColor).opacity(0.3))
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color(nsColor: .separatorColor)),
                    alignment: .bottom
                )
                
                Divider()
            }
            
            // Content for selected tab
            ScrollView {
                VStack(spacing: 0) {
                    // "For Review" section (low confidence notifications)
                    if !notificationsForReview.isEmpty {
                        Button(action: {
                            withAnimation {
                                isForReviewExpanded.toggle()
                            }
                        }) {
                            HStack {
                                Image(systemName: isForReviewExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                Text("For Review")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.orange)
                                Text("(\(notificationsForReview.count))")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange.opacity(0.7))
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.1))
                        }
                        .buttonStyle(.plain)
                        
                        if isForReviewExpanded {
                            ForEach(notificationsForReview) { notification in
                                NotificationRowView(
                                        notificationId: notification.id,
                                        notificationCenter: notificationCenter,
                                        emailScanningService: emailScanningService,
                                        mediaManager: mediaManager,
                                        settingsManager: settingsManager,
                                        processingNotification: $processingNotification,
                                        debugInfo: $debugInfo,
                                        showDebugInfo: $showDebugInfo
                                )
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.05))
                                
                                Divider()
                            }
                        }
                        
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    if selectedTab == .newDockets && !regularNewDocketNotifications.isEmpty {
                        ForEach(regularNewDocketNotifications) { notification in
                            NotificationRowView(
                                notificationId: notification.id,
                                notificationCenter: notificationCenter,
                                emailScanningService: emailScanningService,
                                mediaManager: mediaManager,
                                settingsManager: settingsManager,
                                processingNotification: $processingNotification,
                                debugInfo: $debugInfo,
                                showDebugInfo: $showDebugInfo
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            
                            Divider()
                        }
                    } else if Self.enableFileDeliveryFeature && selectedTab == .fileDeliveries && !regularFileDeliveryNotifications.isEmpty {
                        ForEach(regularFileDeliveryNotifications) { notification in
                            NotificationRowView(
                                notificationId: notification.id,
                                notificationCenter: notificationCenter,
                                emailScanningService: emailScanningService,
                                mediaManager: mediaManager,
                                settingsManager: settingsManager,
                                processingNotification: $processingNotification,
                                debugInfo: $debugInfo,
                                showDebugInfo: $showDebugInfo
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            
                            Divider()
                        }
                    } else if Self.enableRequestFeature && selectedTab == .requests && !regularRequestNotifications.isEmpty {
                        ForEach(regularRequestNotifications) { notification in
                            NotificationRowView(
                                notificationId: notification.id,
                                notificationCenter: notificationCenter,
                                emailScanningService: emailScanningService,
                                mediaManager: mediaManager,
                                settingsManager: settingsManager,
                                processingNotification: $processingNotification,
                                debugInfo: $debugInfo,
                                showDebugInfo: $showDebugInfo
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            
                            Divider()
                        }
                    } else if notificationsForReview.isEmpty {
                        // Empty state for selected tab (only show if no review items)
                        // FEATURE FLAG: Only show empty state for enabled tabs
                        if (selectedTab == .newDockets) ||
                           (Self.enableFileDeliveryFeature && selectedTab == .fileDeliveries) ||
                           (Self.enableRequestFeature && selectedTab == .requests) {
                            VStack(spacing: 12) {
                                Image(systemName: {
                                    switch selectedTab {
                                    case .newDockets: return "doc.text"
                                    case .fileDeliveries: return "link.circle"
                                    case .requests: return "hand.raised"
                                    }
                                }())
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text({
                                    switch selectedTab {
                                    case .newDockets: return "No new docket notifications"
                                    case .fileDeliveries: return "No file delivery notifications"
                                    case .requests: return "No request notifications"
                                    }
                                }())
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                }
                
                // Archived notifications (collapsible)
                if !archivedNotifications.isEmpty {
                    Divider()
                    
                    Button(action: {
                        withAnimation {
                            isArchivedExpanded.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: isArchivedExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("Archived (\(archivedNotifications.count))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    
                    if isArchivedExpanded {
                        ForEach(archivedNotifications) { notification in
                            NotificationRowView(
                                notificationId: notification.id,
                                notificationCenter: notificationCenter,
                                emailScanningService: emailScanningService,
                                mediaManager: mediaManager,
                                settingsManager: settingsManager,
                                processingNotification: $processingNotification,
                                debugInfo: $debugInfo,
                                showDebugInfo: $showDebugInfo
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .opacity(0.6)
                            
                            Divider()
                        }
                    }
                }
            }
            
            footerSection
            
            if showDebugInfo {
                debugInfoPanel
            }
            
            if showCacheInfo {
                cacheInfoPanel
            }
        }
    }
    
    private var footerSection: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                // Last scan status indicator
                if let status = lastScanStatus {
                    HStack(spacing: 4) {
                        Image(systemName: status.contains("✅") ? "checkmark.circle.fill" : status.contains("⚠️") ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(status.contains("✅") ? .green : status.contains("⚠️") ? .orange : .blue)
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(4)
                }
                
                // Debug features (only shown if enabled in settings)
                if settingsManager.currentSettings.showDebugFeatures {
                Button("Test Notification") {
                    let testNotification = Notification(
                        type: .newDocket,
                        title: "Test New Docket",
                        message: "Docket 12345: Test Job Name",
                        docketNumber: "12345",
                        jobName: "Test Job Name"
                    )
                    notificationCenter.add(testNotification)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                
                Button("Debug Scan") {
                    Task {
                        await runDebugScan()
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundColor(.blue)
                    
                    Button("View Cache") {
                        showCacheView()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundColor(.green)
                }
                
                if !notificationCenter.notifications.isEmpty {
                    if !notificationCenter.archivedNotifications.isEmpty {
                        Button("Clear Archived") {
                        notificationCenter.clearDismissed()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    }
                    
                    Spacer()
                    
                    Button("Clear All") {
                        notificationCenter.clearAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                } else {
                    Spacer()
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
    
    private var debugInfoPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text("Debug Output")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let debugInfo = debugInfo {
                    Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(debugInfo, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy debug output")
                }
                Button("Close") {
                    showDebugInfo = false
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            
            if let debugInfo = debugInfo {
                ScrollView {
                    Text(debugInfo)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(height: 200)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            } else {
                Text("Running debug scan...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var cacheInfoPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack {
                Text("Company Name Cache")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let cacheInfo = cacheInfo {
                    Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(cacheInfo, forType: .string)
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy cache info")
                }
                Button("Close") {
                    showCacheInfo = false
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            
            if isLoadingCache {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading cache...")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if let cacheInfo = cacheInfo {
                ScrollView {
                    Text(cacheInfo)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(height: 300)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            } else {
                Text("Loading cache...")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private func handleViewAppear() {
        // Ensure selectedTab is valid (not a disabled tab) - reset to newDockets if disabled tab is selected
        // Do this synchronously as it's just local state
        if selectedTab == .fileDeliveries && !Self.enableFileDeliveryFeature {
            selectedTab = .newDockets
        }
        if selectedTab == .requests && !Self.enableRequestFeature {
            selectedTab = .newDockets
        }
        
        // Move cleanup operations to async Task to avoid modifying @Published properties during view update
        Task { @MainActor in
            // Clean up old archived notifications
            notificationCenter.cleanupOldArchivedNotifications()
            // Clean up old completed requests (older than 24 hours)
            notificationCenter.cleanupOldCompletedRequests()
            // Sync completion status from shared cache
            await notificationCenter.syncCompletionStatus()
        }
        
        // Auto-select tab if current selection is empty
        if selectedTab == .newDockets && activeNotifications.isEmpty && !mediaFileNotifications.isEmpty {
            selectedTab = .fileDeliveries
        } else if selectedTab == .fileDeliveries && mediaFileNotifications.isEmpty && !activeNotifications.isEmpty {
            selectedTab = .newDockets
        }
        
        // Only auto-scan if last scan was more than 30 seconds ago (debounce to avoid slowdown)
        let timeSinceLastScan = emailScanningService.lastScanTime.map { Date().timeIntervalSince($0) } ?? Double.infinity
        let scanThreshold: TimeInterval = 30 // 30 seconds
        let shouldAutoScan = timeSinceLastScan > scanThreshold
        
        if shouldAutoScan {
            // Auto-fetch unread emails when notification window opens (don't force rescan on appear)
            Task {
                isScanningEmails = true
                lastScanStatus = nil
                await emailScanningService.scanUnreadEmails(forceRescan: false)
                isScanningEmails = false
                
                // Update status message
                let activeCount = notificationCenter.activeNotifications.count
                if activeCount == 0 {
                    lastScanStatus = "No unread docket emails found"
                } else {
                    lastScanStatus = "Found \(activeCount) notification\(activeCount == 1 ? "" : "s")"
                }
            }
        } else {
            // Show cached results - scan was recent, no need to rescan
            let timeAgo = Int(timeSinceLastScan)
            if timeAgo < 60 {
                lastScanStatus = "Last scan: \(timeAgo)s ago"
            } else {
                let minutesAgo = timeAgo / 60
                lastScanStatus = "Last scan: \(minutesAgo)m ago"
            }
        }
    }
    
    private func runDebugScan() async {
        showDebugInfo = true
        isScanningEmails = true
        var debugMessages: [String] = []
        
        debugMessages.append("=== Email Scan Debug ===")
        debugMessages.append("")
        
        // Check settings
        let settings = settingsManager.currentSettings
        
        debugMessages.append("📋 Settings Check:")
        debugMessages.append("  Gmail Enabled: \(settings.gmailEnabled)")
        debugMessages.append("  Scanning: All unread emails (no filtering)")
        debugMessages.append("  Custom Parsing Patterns: \(settings.docketParsingPatterns.isEmpty ? "(none - using default)" : "\(settings.docketParsingPatterns.count) pattern(s)")")
        if !settings.docketParsingPatterns.isEmpty {
            for (index, pattern) in settings.docketParsingPatterns.enumerated() {
                debugMessages.append("    \(index + 1). \(pattern)")
            }
        }
        debugMessages.append("")
        
        guard settings.gmailEnabled else {
            debugMessages.append("❌ Gmail is not enabled in settings")
            debugInfo = debugMessages.joined(separator: "\n")
            isScanningEmails = false
            return
        }
        
        // Check authentication
        debugMessages.append("🔐 Authentication Check:")
        debugMessages.append("  Is Authenticated: \(emailScanningService.gmailService.isAuthenticated)")
        debugMessages.append("")
        
        guard emailScanningService.gmailService.isAuthenticated else {
            debugMessages.append("❌ Gmail is not authenticated")
            debugInfo = debugMessages.joined(separator: "\n")
            isScanningEmails = false
            return
        }
        
        // Always scan all unread emails - classifier determines relevance
        let query = "is:unread"
        
        debugMessages.append("🔍 Query Configuration:")
        debugMessages.append("  Query: \(query) (scanning all unread emails)")
        debugMessages.append("")
        
        // Try to fetch emails
        do {
            debugMessages.append("📧 Fetching emails...")
            let messageRefs = try await emailScanningService.gmailService.fetchEmails(
                query: query,
                maxResults: 50
            )
            debugMessages.append("  ✅ Found \(messageRefs.count) email reference(s)")
            debugMessages.append("")
            
            if messageRefs.isEmpty {
                // Try fallback query
                debugMessages.append("🔄 Trying fallback query (subject only)...")
                let fallbackQuery = "subject:\"New Docket\" is:unread"
                let fallbackRefs = try await emailScanningService.gmailService.fetchEmails(
                    query: fallbackQuery,
                    maxResults: 50
                )
                debugMessages.append("  ✅ Found \(fallbackRefs.count) email reference(s) with fallback")
                debugMessages.append("")
                
                if fallbackRefs.isEmpty {
                    debugMessages.append("⚠️  No unread emails found with either query")
                    debugInfo = debugMessages.joined(separator: "\n")
                    isScanningEmails = false
                    return
                }
            }
            
            // Get full messages
            debugMessages.append("📨 Fetching full email messages...")
            let messages = try await emailScanningService.gmailService.getEmails(
                messageReferences: messageRefs
            )
            debugMessages.append("  ✅ Fetched \(messages.count) full message(s)")
            debugMessages.append("")
            
            // Check unread status
            debugMessages.append("📬 Checking unread status:")
            let unreadMessages = messages.filter { message in
                guard let labelIds = message.labelIds else { return false }
                return labelIds.contains("UNREAD")
            }
            debugMessages.append("  Total messages: \(messages.count)")
            debugMessages.append("  Unread messages: \(unreadMessages.count)")
            debugMessages.append("")
            
            // Show sample email info
            if !unreadMessages.isEmpty {
                debugMessages.append("📋 Sample unread email(s):")
                for (index, message) in unreadMessages.prefix(3).enumerated() {
                    debugMessages.append("  \(index + 1). ID: \(message.id)")
                    debugMessages.append("     Subject: \(message.subject ?? "(no subject)")")
                    debugMessages.append("     From: \(message.from ?? "(unknown)")")
                    debugMessages.append("     Labels: \(message.labelIds?.joined(separator: ", ") ?? "none")")
                    
                    // Show body preview to check for docket numbers
                    let plainBody = message.plainTextBody ?? ""
                    let htmlBody = message.htmlBody ?? ""
                    let bodyPreview = !plainBody.isEmpty ? plainBody : htmlBody
                    
                    if !bodyPreview.isEmpty {
                        let preview = String(bodyPreview.prefix(500))
                        debugMessages.append("     Body preview (\(bodyPreview.count) chars):")
                        debugMessages.append("     \(preview)")
                        if bodyPreview.count > 500 {
                            debugMessages.append("     ... (truncated)")
                        }
                    } else {
                        debugMessages.append("     Body: (empty - may need format=full in API request)")
                        debugMessages.append("     Snippet: \(message.snippet ?? "(none)")")
                    }
                }
                debugMessages.append("")
            }
            
            // Check existing notifications
            let existingEmailIds = Set(notificationCenter.notifications.compactMap { $0.emailId })
            debugMessages.append("🔔 Notification Check:")
            debugMessages.append("  Existing notifications: \(notificationCenter.notifications.count)")
            debugMessages.append("  Existing email IDs: \(existingEmailIds.count)")
            debugMessages.append("")
            
            // Try to process emails
            debugMessages.append("⚙️  Processing emails...")
            var createdCount = 0
            var skippedCount = 0
            var failedCount = 0
            var parseFailures: [String] = []
            var docketExistsCount = 0
            
            for message in unreadMessages {
                if existingEmailIds.contains(message.id) {
                    skippedCount += 1
                    debugMessages.append("  ⏭️  Email \(message.id): Already has notification")
                    continue
                }
                
                // Try to parse the email first to see why it might fail
                let subject = message.subject ?? ""
                let body = message.plainTextBody ?? message.htmlBody ?? ""
                
                // Use parser with custom patterns if configured
                let settings = settingsManager.currentSettings
                let patterns = settings.docketParsingPatterns
                let parser = patterns.isEmpty ? EmailDocketParser() : EmailDocketParser(patterns: patterns)
                
                let parsed = parser.parseEmail(
                    subject: message.subject,
                    body: body,
                    from: message.from
                )
                
                if let parsedDocket = parsed {
                    // Check if docket already exists
                    if parsedDocket.docketNumber != "TBD",
                       mediaManager.dockets.contains("\(parsedDocket.docketNumber)_\(parsedDocket.jobName)") {
                        docketExistsCount += 1
                        debugMessages.append("  ⚠️  Email \(message.id): Docket already exists")
                        debugMessages.append("     Subject: \(subject)")
                        debugMessages.append("     Docket: \(parsedDocket.docketNumber)_\(parsedDocket.jobName)")
                        continue
                    }
                } else {
                    parseFailures.append(subject)
                    debugMessages.append("  ❌ Email \(message.id): Failed to parse")
                    debugMessages.append("     Subject: \(subject)")
                    debugMessages.append("     From: \(message.from ?? "(unknown)")")
                    debugMessages.append("     Body preview: \(body.prefix(100))...")
                    debugMessages.append("     (No docket pattern matched)")
                }
                
                // Try to process the email
                let success = await emailScanningService.processEmailAndCreateNotification(message)
                if success {
                    createdCount += 1
                    debugMessages.append("  ✅ Email \(message.id): Created notification")
                    debugMessages.append("     Subject: \(subject)")
                    if let parsed = parsed {
                        debugMessages.append("     Docket: \(parsed.docketNumber) - \(parsed.jobName)")
                    }
                } else {
                    failedCount += 1
                    if parsed == nil {
                        debugMessages.append("     (Parse failed - see above)")
                    } else {
                        debugMessages.append("     (Processing failed)")
                    }
                }
            }
            
            debugMessages.append("")
            debugMessages.append("📊 Summary:")
            debugMessages.append("  Created: \(createdCount)")
            debugMessages.append("  Skipped: \(skippedCount)")
            debugMessages.append("  Failed to parse: \(parseFailures.count)")
            debugMessages.append("  Docket already exists: \(docketExistsCount)")
            debugMessages.append("  Other failures: \(failedCount)")
            
            let finalCount = notificationCenter.notifications.count
            debugMessages.append("  ✅ Final notification count: \(finalCount)")
            
            // Update last scan status
            await MainActor.run {
                if createdCount > 0 {
                    lastScanStatus = "✅ Found \(createdCount) new notification\(createdCount == 1 ? "" : "s")"
                } else if unreadMessages.isEmpty {
                    lastScanStatus = "⚠️ No unread emails found"
                } else if parseFailures.count > 0 {
                    lastScanStatus = "⚠️ \(parseFailures.count) email\(parseFailures.count == 1 ? "" : "s") couldn't be parsed"
                } else if docketExistsCount > 0 {
                    lastScanStatus = "⚠️ \(docketExistsCount) docket\(docketExistsCount == 1 ? "" : "s") already exist"
                } else {
                    lastScanStatus = "ℹ️ Scan completed - no new notifications"
                }
            }
            
        } catch {
            debugMessages.append("")
            debugMessages.append("❌ ERROR:")
            debugMessages.append("  \(error.localizedDescription)")
            if let gmailError = error as? GmailError {
                debugMessages.append("  Type: \(gmailError)")
            }
        }
        
        debugInfo = debugMessages.joined(separator: "\n")
        isScanningEmails = false
    }
    
    private func showCacheView() {
        // Open cache in external text editor to avoid blocking UI
        Task {
            // Get cache text on background thread
            let cacheText = await Task.detached(priority: .userInitiated) {
                return await MainActor.run {
                    return CompanyNameCache.shared.getCacheAsText()
                }
            }.value
            
            // Get shared cache path info
            let sharedPath = await MainActor.run {
                return CompanyNameCache.shared.getSharedCachePath()
            }
            
            var finalCacheText = cacheText
            
            // Add shared cache status
            if let sharedPath = sharedPath {
                let fileExists = await Task.detached(priority: .userInitiated) {
                    return FileManager.default.fileExists(atPath: sharedPath)
                }.value
                
                if fileExists {
                    finalCacheText += "\n\n✅ Shared cache file exists at:\n\(sharedPath)\n"
                } else {
                    finalCacheText += "\n\n⚠️ Shared cache file not found at:\n\(sharedPath)\n"
                }
            } else {
                finalCacheText += "\n\nℹ️ Shared cache not configured (using local cache only)\n"
            }
            
            // Write to temporary file and open it
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("MediaDash_Cache_\(UUID().uuidString).txt")
            
            do {
                try finalCacheText.write(to: tempFile, atomically: true, encoding: .utf8)
                
                // Open in default text editor (non-blocking)
                await MainActor.run {
                    _ = NSWorkspace.shared.open(tempFile)
                }
                } catch {
                    // DEBUG: Commented out for performance
                    // print("Failed to write cache file: \(error.localizedDescription)")
                    await MainActor.run {
                    // Fallback: show in panel if file write fails
                    showCacheInfo = true
                    cacheInfo = finalCacheText
                    isLoadingCache = false
                }
            }
        }
    }
}

/// Individual notification row
struct NotificationRowView: View {
    let notificationId: UUID
    @ObservedObject var notificationCenter: NotificationCenter
    @ObservedObject var emailScanningService: EmailScanningService
    @ObservedObject var mediaManager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var processingNotification: UUID?
    @Binding var debugInfo: String?
    @Binding var showDebugInfo: Bool
    
    @StateObject private var simianService = SimianService()
    @State private var showActions = false
    @State private var showDocketInputDialog = false
    @State private var inputDocketNumber = ""
    @State private var isHovered = false
    @State private var showContextMenu = false
    @State private var isDocketInputForApproval = false // Track if dialog is for approval or just updating
    @State private var isEmailPreviewExpanded = false
    @State private var showJobNameEditDialog = false
    @State private var selectedTextFromEmail: String? = nil
    @State private var isGrabbedBadgeHovered = false
    @State private var showGrabbedConfirmation = false
    @State private var pendingEmailIdForReply: String?
    @State private var isSendingReply = false
    @State private var showFeedbackDialog = false
    @State private var isEmailPreviewButtonHovered = false
    @State private var feedbackCorrection = ""
    @State private var feedbackComment = ""
    @State private var isSubmittingFeedback = false
    @State private var hasSubmittedFeedback = false // Track locally to force UI refresh
    
    @State private var showSimianProjectDialog = false
    @State private var pendingSimianNotificationId: UUID?
    @State private var pendingSimianDocketNumber: String = ""
    @State private var pendingSimianJobName: String = ""
    @State private var pendingSimianSourceEmail: String?
    
    // Get current notification from center (always up-to-date)
    private var notification: Notification? {
        notificationCenter.notifications.first(where: { $0.id == notificationId })
    }
    
    // Update SimianService API configuration when settings change
    private func updateSimianServiceConfiguration() {
        let settings = settingsManager.currentSettings
        if let baseURL = settings.simianAPIBaseURL, !baseURL.isEmpty {
            // setBaseURL will normalize http:// to https:// automatically
            simianService.setBaseURL(baseURL)
            // Credentials are stored in keychain and retrieved automatically by SimianService
            if let username = SharedKeychainService.getSimianUsername(),
               let password = SharedKeychainService.getSimianPassword() {
                simianService.setCredentials(username: username, password: password)
            }
        } else {
            simianService.clearConfiguration()
        }
    }
    
    /// Create Simian project with user-provided parameters
    /// Create both Simian project and Work Picture folder using the values from the dialog
    private func createSimianProject(
        notificationId: UUID,
        docketNumber: String,
        jobName: String,
        projectManager: String?,
        template: String?
    ) async {
        print("🔔 NotificationCenterView.createSimianProject() called")
        print("   notificationId: \(notificationId)")
        print("   docketNumber: \(docketNumber)")
        print("   jobName: \(jobName)")
        print("   projectManager: \(projectManager ?? "nil")")
        print("   template: \(template ?? "nil")")
        
        // Get the latest notification state
        guard var updatedNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) else {
            print("⚠️ Could not find notification with id \(notificationId)")
            await MainActor.run {
                processingNotification = nil
            }
            return
        }
        
        // Update notification with the docket number and job name from dialog
        notificationCenter.updateDocketNumber(updatedNotification, to: docketNumber)
        if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
            updatedNotification = currentNotification
        }
        
        let shouldCreateSimian = updatedNotification.shouldCreateSimianJob || 
            (settingsManager.currentSettings.simianEnabled && simianService.isConfigured)
        let shouldCreateWorkPicture = updatedNotification.shouldCreateWorkPicture
        
        var simianError: Error?
        var workPictureError: Error?
        
        // Create Work Picture folder if requested
        if shouldCreateWorkPicture {
            do {
                print("🔔 Creating Work Picture folder with docket: \(docketNumber), job: \(jobName)")
                try await emailScanningService.createDocketFromNotification(updatedNotification)
                print("✅ Work Picture folder created successfully")
                
                await MainActor.run {
                    if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                        notificationCenter.updateDuplicateDetection(currentNotification, mediaManager: mediaManager, settingsManager: settingsManager)
                        // Mark as in Work Picture
                        notificationCenter.markAsInWorkPicture(currentNotification)
                    }
                }
            } catch {
                print("❌ Work Picture folder creation failed: \(error.localizedDescription)")
                workPictureError = error
            }
        }
        
        // Create Simian project if requested
        if shouldCreateSimian {
            updateSimianServiceConfiguration()
            
            do {
                print("🔔 Creating Simian project with docket: \(docketNumber), job: \(jobName)")
                try await simianService.createJob(
                    docketNumber: docketNumber,
                    jobName: jobName,
                    projectManager: projectManager,
                    projectTemplate: template ?? settingsManager.currentSettings.simianProjectTemplate
                )
                print("✅ Simian project created successfully")
                
                await MainActor.run {
                    if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                        notificationCenter.markAsInSimian(currentNotification)
                    }
                }
            } catch {
                print("❌ Simian project creation failed: \(error.localizedDescription)")
                simianError = error
            }
        }
        
        // Handle results and cleanup
        await MainActor.run {
            processingNotification = nil
            
            // Show error notifications if any failed
            if let wpError = workPictureError {
                let errorNotification = Notification(
                    type: .error,
                    title: "Work Picture Creation Failed",
                    message: wpError.localizedDescription
                )
                notificationCenter.add(errorNotification)
            }
            
            if let simError = simianError {
                let errorNotification = Notification(
                    type: .error,
                    title: "Simian Project Creation Failed",
                    message: simError.localizedDescription
                )
                notificationCenter.add(errorNotification)
            }
            
            // Mark email as read and track interaction
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                markEmailAsReadIfNeeded(currentNotification)
                
                if let emailId = currentNotification.emailId {
                    var details: [String: String] = [:]
                    if shouldCreateWorkPicture && workPictureError == nil {
                        details["createdWorkPicture"] = "true"
                    }
                    if shouldCreateSimian && simianError == nil {
                        details["createdSimianJob"] = "true"
                    }
                    details["docketNumber"] = docketNumber
                    EmailFeedbackTracker.shared.recordInteraction(
                        emailId: emailId,
                        type: .approved,
                        details: details.isEmpty ? nil : details
                    )
                }
                
                // Close dialog first, then remove notification after a small delay
                // This ensures the dialog doesn't get dismissed prematurely
                showSimianProjectDialog = false
                
                // Remove notification after both are created (or attempted)
                // Use a delay to ensure dialog has time to close first
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 second delay
                    if let finalNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                        await notificationCenter.remove(finalNotification, emailScanningService: emailScanningService)
                        print("✅ Removed notification after project creation")
                    }
                }
            }
        }
    }
    
    var body: some View {
        // Guard to ensure notification exists
        guard let notification = notification else {
            return AnyView(EmptyView())
        }
        
        return AnyView(notificationBody(notification))
    }
    
    private func notificationBody(_ notification: Notification) -> some View {
        notificationBodyContent(notification)
    }
    
    @ViewBuilder
    private func notificationBodyContent(_ notification: Notification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            notificationHeaderView(notification: notification)
            notificationContentView(notification: notification)
            notificationActionsView(notification: notification)
        }
        .padding(8)
        .background(
            ZStack {
                // Background color - different colors for different notification types
                Group {
                    if isHovered {
                        // Hover state - darker for visibility
                        if notification.type == .mediaFiles {
                            Color.orange.opacity(0.15)
                        } else if notification.type == .request && notification.status == .completed {
                            Color.gray.opacity(0.1)
                        } else {
                            Color.blue.opacity(0.1)
                        }
                    } else if notification.status == .pending {
                        // Pending state - subtle background
                        if notification.type == .mediaFiles {
                            Color.orange.opacity(0.08)
                        } else {
                            Color.blue.opacity(0.05)
                        }
                    } else if notification.type == .request && notification.status == .completed {
                        // Completed request - greyed out
                        Color.gray.opacity(0.05)
                    } else {
                        Color.clear
                    }
                }
                
                // Removed tap area - expansion is now handled by the chevron button
            }
        )
        .cornerRadius(8)
        .opacity(notification.type == .request && notification.status == .completed ? 0.6 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            notificationContextMenuContent(notification: notification)
        }
        .help("Right-click for options")
        .onAppear {
            updateSimianServiceConfiguration()
            // Always refresh hasSubmittedFeedback from persistent storage when view appears
            // This ensures we check the source of truth even after view recreation
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }),
               let emailId = currentNotification.emailId {
                hasSubmittedFeedback = EmailFeedbackTracker.shared.hasFeedback(for: emailId)
            } else {
                hasSubmittedFeedback = false
            }
        }
        .onChange(of: settingsManager.currentSettings.simianAPIBaseURL) { _, _ in
            updateSimianServiceConfiguration()
        }
        .onChange(of: self.notification?.emailId) { _, newEmailId in
            // Refresh feedback state when emailId changes
            if let emailId = newEmailId {
                hasSubmittedFeedback = EmailFeedbackTracker.shared.hasFeedback(for: emailId)
            } else {
                hasSubmittedFeedback = false
            }
        }
        .sheet(isPresented: $showDocketInputDialog) {
            DocketNumberInputDialog(
                isPresented: $showDocketInputDialog,
                docketNumber: $inputDocketNumber,
                jobName: notification.jobName ?? "Unknown",
                onConfirm: {
                    // If this is from the Approve button, approve and create docket
                    // Otherwise, just update the docket number
                    if isDocketInputForApproval {
                        handleApproveWithDocket(inputDocketNumber.isEmpty ? nil : inputDocketNumber)
                    } else {
                        // Just update the docket number without approving
                        if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                            let finalDocketNumber = inputDocketNumber.isEmpty ? generateAutoDocketNumber() : inputDocketNumber
                            notificationCenter.updateDocketNumber(currentNotification, to: finalDocketNumber)
                            // Clear input for next time
                            inputDocketNumber = ""
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $showSimianProjectDialog) {
            if let notificationId = pendingSimianNotificationId,
               let notification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                let isSimianEnabled = notification.shouldCreateSimianJob || 
                    (settingsManager.currentSettings.simianEnabled && simianService.isConfigured)
                
                SimianProjectCreationDialog(
                    isPresented: $showSimianProjectDialog,
                    simianService: simianService,
                    settingsManager: settingsManager,
                    initialDocketNumber: pendingSimianDocketNumber,
                    initialJobName: pendingSimianJobName,
                    sourceEmail: pendingSimianSourceEmail,
                    isSimianEnabled: isSimianEnabled,
                    onConfirm: { docketNumber, jobName, projectManager, template in
                        Task {
                            await createSimianProject(
                                notificationId: notificationId,
                                docketNumber: docketNumber,
                                jobName: jobName,
                                projectManager: projectManager,
                                template: template
                            )
                        }
                    }
                )
            }
        }
        .onChange(of: showSimianProjectDialog) { oldValue, newValue in
            // If dialog is dismissed (closed), clean up pending state
            // BUT don't remove notification here - let createSimianProject handle that
            // This prevents the notification from being removed prematurely
            if oldValue == true && newValue == false {
                // Wait a moment to check if this was a cancellation or successful completion
                // The createSimianProject function will close the dialog after completion
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 second delay
                    
                    await MainActor.run {
                        // Only clear pending state if notification was cancelled (not processed)
                        // Check if notification still exists and hasn't been processed
                        if let notificationId = pendingSimianNotificationId {
                            // Check if notification was actually processed (marked as in Simian or Work Picture)
                            let wasProcessed = notificationCenter.notifications.first(where: { $0.id == notificationId })?.isInSimian == true ||
                                notificationCenter.notifications.first(where: { $0.id == notificationId })?.isInWorkPicture == true
                            
                            if !wasProcessed {
                                // Dialog was cancelled before confirmation - remove notification
                                if let notification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                                    print("🔔 Simian dialog was cancelled - removing notification")
                                    Task {
                                        await notificationCenter.remove(notification, emailScanningService: emailScanningService)
                                        await MainActor.run {
                                            pendingSimianNotificationId = nil
                                            pendingSimianDocketNumber = ""
                                            pendingSimianJobName = ""
                                            processingNotification = nil
                                        }
                                    }
                                    return
                                }
                            }
                        }
                        
                        // Dialog was dismissed after processing - just clear pending state
                        pendingSimianNotificationId = nil
                        pendingSimianDocketNumber = ""
                        pendingSimianJobName = ""
                    }
                }
            }
        }
        .sheet(isPresented: $showJobNameEditDialog) {
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                // Use originalJobName if available (from email), otherwise fall back to current jobName
                let defaultJobName = currentNotification.originalJobName ?? currentNotification.jobName ?? ""
                JobNameEditDialog(
                    isPresented: $showJobNameEditDialog,
                    jobName: Binding(
                        get: { defaultJobName },
                        set: { _ in }
                    ),
                    docketNumber: currentNotification.docketNumber,
                    onConfirm: { newJobName in
                        notificationCenter.updateJobName(currentNotification, to: newJobName)
                        // Add to company name cache
                        CompanyNameCache.shared.addCompanyName(newJobName, source: "user")
                    }
                )
            }
        }
        .alert("Did you grab it?", isPresented: $showGrabbedConfirmation) {
            Button("No", role: .cancel) {
                pendingEmailIdForReply = nil
            }
            Button("Yes") {
                sendGrabbedReply()
            }
        } message: {
            Text("Did you successfully grab the file?")
        }
        .sheet(isPresented: $showFeedbackDialog) {
            EmptyView() // Feedback removed
        }
    }
    
    /// Mark email as read if notification has an emailId
    private func markEmailAsReadIfNeeded(_ notification: Notification) {
        guard let emailId = notification.emailId else {
            print("📧 NotificationCenterView: ⚠️ Cannot mark email as read - notification has no emailId")
            return
        }
        
        Task {
            do {
                try await emailScanningService.gmailService.markAsRead(messageId: emailId)
                print("📧 NotificationCenterView: ✅ Successfully marked email \(emailId) as read")
            } catch {
                print("📧 NotificationCenterView: ❌ Failed to mark email \(emailId) as read: \(error.localizedDescription)")
                print("📧 NotificationCenterView: Error details: \(error)")
            }
        }
    }
    
    private func submitFeedback(
        notificationId: UUID,
        wasCorrect: Bool,
        rating: Int,
        correction: String? = nil,
        comment: String? = nil
    ) async {
        // Prevent double-submission
        guard !isSubmittingFeedback else { return }
        
        await MainActor.run {
            isSubmittingFeedback = true
        }
        
        // Get notification before processing
        guard notificationCenter.notifications.first(where: { $0.id == notificationId }) != nil else {
            await MainActor.run {
                isSubmittingFeedback = false
                showFeedbackDialog = false
            }
            return
        }
        
        await emailScanningService.provideFeedback(
            for: notificationId,
            rating: rating,
            wasCorrect: wasCorrect,
            correction: correction,
            comment: comment
        )
        
        await MainActor.run {
            // Get the updated notification (in case it changed)
            guard let updatedNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) else {
                hasSubmittedFeedback = true
                isSubmittingFeedback = false
                showFeedbackDialog = false
                return
            }
            
            if !wasCorrect {
                // Thumbs down: Remove the notification and mark email as read
                markEmailAsReadIfNeeded(updatedNotification)
                notificationCenter.remove(updatedNotification, emailScanningService: emailScanningService)
                print("📋 NotificationCenterView: Removed notification after downvote")
            }
            
            hasSubmittedFeedback = true // Update local state to trigger UI refresh
            isSubmittingFeedback = false
            showFeedbackDialog = false
            feedbackCorrection = ""
            feedbackComment = ""
        }
    }
    
    /// Helper view for notification actions section
    @ViewBuilder
    private func notificationActionsView(notification: Notification) -> some View {
        if notification.type == .newDocket && notification.status == .pending && notification.archivedAt == nil {
            newDocketActionsView(notification: notification)
        } else if notification.type == .request {
            requestActionsView(notification: notification)
        } else if notification.status == .dismissed && notification.archivedAt != nil {
            HStack(spacing: 4) {
                Image(systemName: "archivebox.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 10))
                Text("Archived")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .italic()
            }
        } else if notification.status == .completed {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 12))
                Text("Completed")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
            }
        }
    }
    
    /// Helper view for request notification actions
    @ViewBuilder
    private func requestActionsView(notification: Notification) -> some View {
        if notification.status == .completed {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("Completed")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
                
                Button("Mark Incomplete") {
                    Task {
                        await notificationCenter.markRequestIncomplete(notification)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Button("Mark Complete") {
                Task {
                    await notificationCenter.markRequestComplete(notification)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(processingNotification == notificationId)
        }
    }
    
    /// Helper view for new docket actions
    @ViewBuilder
    private func newDocketActionsView(notification: Notification) -> some View {
        // Update duplicate detection flags
        let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) ?? notification
        let isInWorkPicture = checkIfInWorkPicture(notification: currentNotification)
        let isInSimian = currentNotification.isInSimian
        
        VStack(alignment: .leading, spacing: 8) {
            // Visual indicators for duplicates
            if isInWorkPicture || isInSimian {
                HStack(spacing: 8) {
                    if isInWorkPicture {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                            Text("Already in Work Picture")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    if isInSimian {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                            Text("Already in Simian")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
            }
            
            Toggle("Create Work Picture Folder", isOn: workPictureBinding())
                .font(.system(size: 11))
                .disabled(isInWorkPicture)
                .opacity(isInWorkPicture ? 0.5 : 1.0)
            
            Toggle("Create Simian Job", isOn: simianJobBinding())
                .font(.system(size: 11))
                .disabled(isInSimian)
                .opacity(isInSimian ? 0.5 : 1.0)
            
            if notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateSimianJob == true && !isInSimian {
                projectManagerFieldView(notification: notification)
            }
            
            approveArchiveButtons(notification: notification)
        }
        .padding(.top, 4)
        .onAppear {
            // Update duplicate detection when view appears
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                notificationCenter.updateDuplicateDetection(currentNotification, mediaManager: mediaManager, settingsManager: settingsManager)
            }
            // Update Simian service configuration first, then pre-load users if Simian is enabled
            updateSimianServiceConfiguration()
        }
    }
    
    private func checkIfInWorkPicture(notification: Notification) -> Bool {
        if let docketNumber = notification.docketNumber, docketNumber != "TBD",
           let jobName = notification.jobName {
            return docketExists(docketNumber: docketNumber, jobName: jobName)
        }
        return false
    }
    
    private func checkIfDocketExists(notification: Notification) -> Bool {
        if let docketNumber = notification.docketNumber, docketNumber != "TBD",
           let jobName = notification.jobName {
            return docketExists(docketNumber: docketNumber, jobName: jobName)
        }
        return false
    }
    
    private func workPictureBinding() -> Binding<Bool> {
        Binding(
            get: { notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateWorkPicture ?? true },
            set: { newValue in
                if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                    notificationCenter.updateActionFlags(currentNotification, workPicture: newValue)
                }
            }
        )
    }
    
    private func simianJobBinding() -> Binding<Bool> {
        Binding(
            get: { notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateSimianJob ?? false },
            set: { newValue in
                if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                    notificationCenter.updateActionFlags(currentNotification, simianJob: newValue)
                }
            }
        )
    }
    
    @ViewBuilder
    private func projectManagerFieldView(notification: Notification) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Project Manager")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            if settingsManager.currentSettings.simianProjectManagers.isEmpty {
                Text("No project managers configured. Add them in Settings > Simian Integration.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            } else {
                Picker("Project Manager", selection: projectManagerEmailBinding(notification: notification)) {
                    Text("None (use email sender)").tag(nil as String?)
                    ForEach(settingsManager.currentSettings.simianProjectManagers.filter { !$0.isEmpty }, id: \.self) { email in
                        Text(email)
                            .tag(email as String?)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 11))
            }
            
            Text("Defaults to email sender. Edit if needed.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
    
    private func projectManagerEmailBinding(notification: Notification) -> Binding<String?> {
        Binding(
            get: {
                notificationCenter.notifications.first(where: { $0.id == notificationId })?.projectManager
            },
            set: { selectedEmail in
                if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                    // Store the email address when selected (Simian will match it to a user)
                    notificationCenter.updateProjectManager(currentNotification, to: selectedEmail)
                }
            }
        )
    }
    
    
    @ViewBuilder
    private func approveArchiveButtons(notification: Notification) -> some View {
        HStack(spacing: 8) {
            Button("Approve") {
                if notification.docketNumber == nil || notification.docketNumber == "TBD" {
                    isDocketInputForApproval = true
                    showDocketInputDialog = true
                } else {
                    handleApprove()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(processingNotification == notificationId)
            
            Button("Archive") {
                notificationCenter.archive(notification, emailScanningService: emailScanningService)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    /// Helper view for notification header row
    @ViewBuilder
    private func notificationHeaderView(notification: Notification) -> some View {
        HStack {
            Image(systemName: iconForType(notification.type))
                .foregroundColor(notification.type == .request && notification.status == .completed ? .gray : colorForType(notification.type))
                .font(.system(size: 14))
            
            Text(notification.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(notification.type == .request && notification.status == .completed ? .secondary : .primary)
            
            Spacer()
            
            Text(timeAgo(notification.timestamp))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            
            mediaFilesStatusBadge(notification: notification)
            
            if notification.status == .pending {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
            }
        }
    }
    
    /// Helper view for media files status badge (grabbed/priority assist)
    @ViewBuilder
    private func mediaFilesStatusBadge(notification: Notification) -> some View {
        if notification.type == .mediaFiles {
            if notification.isPriorityAssist {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("Priority Assist")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.1))
                .cornerRadius(4)
            } else if notification.isGrabbed {
                Button(action: {
                    notificationCenter.archive(notification, emailScanningService: emailScanningService)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        if let grabbedBy = notification.grabbedBy {
                            Text("Grabbed by \(extractProducerName(from: grabbedBy))")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        } else {
                            Text("Grabbed")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isGrabbedBadgeHovered ? Color.green.opacity(0.2) : Color.green.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Click to archive notification")
                .onHover { hovering in
                    isGrabbedBadgeHovered = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
        }
    }
    
    /// Helper view for notification content based on type
    @ViewBuilder
    private func notificationContentView(notification: Notification) -> some View {
        if notification.type == .newDocket {
            newDocketContentView(notification: notification)
        } else if notification.type == .mediaFiles {
            mediaFilesContentView(notification: notification)
        } else if notification.type == .request {
            requestContentView(notification: notification)
        } else {
            Text(notification.message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
    
    /// Helper view for mediaFiles notification content to reduce view complexity
    @ViewBuilder
    private func mediaFilesContentView(notification: Notification) -> some View {
        let extractedLinks: [String] = {
            if let existingLinks = notification.fileLinks, !existingLinks.isEmpty {
                return existingLinks
            }
            if let emailBody = notification.emailBody {
                return FileHostingLinkDetector.extractFileHostingLinks(emailBody)
            }
            return []
        }()
        
        VStack(alignment: .leading, spacing: 8) {
            Text(notification.message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            
            if !extractedLinks.isEmpty {
                fileLinksListView(notification: notification, links: extractedLinks)
            }
            
            if notification.isPriorityAssist {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                    Text("Needs assistance - could not grab file")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.red)
                }
                .padding(.top, 2)
            }

        }
    }

    /// Helper view for request notification content
    @ViewBuilder
    private func requestContentView(notification: Notification) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notification.message)
                .font(.system(size: 12))
                .foregroundColor(notification.status == .completed ? .secondary.opacity(0.7) : .secondary)
            
            producerInfoView(notification: notification)
            emailPreviewSection(notification: notification)
        }
    }
    
    /// Helper view for file links list
    @ViewBuilder
    private func fileLinksListView(notification: Notification, links: [String]) -> some View {
        let descriptions = notification.fileLinkDescriptions ?? []

        VStack(alignment: .leading, spacing: 6) {
            Text("File Links:")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)

            ForEach(Array(links.enumerated()), id: \.offset) { index, link in
                let description = index < descriptions.count ? descriptions[index] : nil
                if URL(string: link) != nil {
                    validLinkButton(notification: notification, link: link, description: description, allLinks: links)
                } else {
                    invalidLinkView(notification: notification, link: link, description: description)
                }
            }
        }
        .padding(.top, 4)
    }
    
    /// Helper view for a valid link button
    @ViewBuilder
    private func validLinkButton(notification: Notification, link: String, description: String?, allLinks: [String]) -> some View {
        Button(action: {
            openLinkInBrowser(link)
            if let emailId = notification.emailId {
                pendingEmailIdForReply = emailId
                showGrabbedConfirmation = true
            }
        }) {
            VStack(alignment: .leading, spacing: 4) {
                // Show description if available
                if let desc = description, !desc.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.primary.opacity(0.7))
                        Text(desc)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "link.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text(link)
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                        .foregroundColor(.blue.opacity(0.7))
                }

                if allLinks.count > 1, let sourceEmail = notification.sourceEmail {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("From: \(extractProducerName(from: sourceEmail))")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Click to open link in browser")
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    /// Helper view for invalid link
    @ViewBuilder
    private func invalidLinkView(notification: Notification, link: String, description: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("Link Invalid")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                Spacer()
            }

            // Show description if available
            if let desc = description, !desc.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.primary.opacity(0.7))
                    Text(desc)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Unable to parse link from email. The link may be malformed or incomplete.")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Text("Extracted: \(link.prefix(100))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)
            
            if let emailId = notification.emailId {
                Button(action: {
                    openEmailInBrowser(emailId: emailId)
                    pendingEmailIdForReply = emailId
                    showGrabbedConfirmation = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 9))
                        Text("Open Email Thread")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Open the email in your browser to view the link")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    
    /// Helper view for newDocket notification content to reduce view complexity
    @ViewBuilder
    private func newDocketContentView(notification: Notification) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let docketNumber = notification.docketNumber, docketNumber != "TBD" {
                if let jobName = notification.jobName {
                    Text("Docket \(docketNumber): \(jobName)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    let existenceInfo = checkDocketExistence(docketNumber: docketNumber, jobName: jobName)
                    
                    if existenceInfo.existsAnywhere {
                        docketExistenceWarningView(existenceInfo: existenceInfo)
                    }
                } else {
                    Text("Docket \(docketNumber)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else if let jobName = notification.jobName {
                Text("\(jobName) (Docket number pending)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Text(notification.message)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            producerInfoView(notification: notification)
            emailPreviewSection(notification: notification)
        }
    }
    
    /// Helper view for docket existence warning
    @ViewBuilder
    private func docketExistenceWarningView(existenceInfo: DocketExistenceInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Text("Docket already exists in \(existenceInfo.existenceDescription)")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
            
            HStack(spacing: 6) {
                if existenceInfo.existsInWorkPicture {
                    HStack(spacing: 3) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 8))
                        Text("Work Picture")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.8))
                    .cornerRadius(4)
                }
                
                if existenceInfo.existsInAsana {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 8))
                        Text("Asana")
                            .font(.system(size: 9, weight: .medium))
                        if let asanaInfo = existenceInfo.asanaDocketInfo {
                            Text("(\(asanaInfo.jobName))")
                                .font(.system(size: 8))
                                .opacity(0.8)
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.8))
                    .cornerRadius(4)
                }
            }
        }
    }
    
    /// Helper view for producer info
    @ViewBuilder
    private func producerInfoView(notification: Notification) -> some View {
        if let sourceEmail = notification.sourceEmail, !sourceEmail.isEmpty {
            let producerName = extractProducerName(from: sourceEmail)
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                Text("Producer: \(producerName)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
    }
    
    /// Helper view for confidence indicator (removed - no longer used)
    @ViewBuilder
    private func confidenceView(notification: Notification) -> some View {
        EmptyView()
    }
    
    /// Helper view for email preview section
    @ViewBuilder
    private func emailPreviewSection(notification: Notification) -> some View {
        if notification.emailSubject != nil || notification.emailBody != nil {
            HStack(spacing: 6) {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isEmailPreviewExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isEmailPreviewExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 16, height: 16)
                        Text(isEmailPreviewExpanded ? "Hide email" : "View email")
                            .font(.system(size: 10))
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isEmailPreviewButtonHovered ? Color.primary.opacity(0.15) : Color.primary.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEmailPreviewButtonHovered = hovering
                    }
                }
                .help(isEmailPreviewExpanded ? "Click to hide email" : "Click to view email")
                
                Spacer()
            }
            .padding(.top, 4)
            
            if isEmailPreviewExpanded {
                expandedEmailPreviewView(notification: notification)
            }
        }
    }
    
    /// Helper view for expanded email preview
    @ViewBuilder
    private func expandedEmailPreviewView(notification: Notification) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.vertical, 6)
            
            Text("Email Content")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            
            if let subject = notification.emailSubject, !subject.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Subject:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(subject)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            notificationContextMenuContent(notification: notification)
                        }
                }
            }
            
            if let body = notification.emailBody, !body.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Body:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(body)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 400)
                    .contextMenu {
                        notificationContextMenuContent(notification: notification)
                    }
                }
            }
        }
        .padding(.top, 6)
    }
    
    
    private func sendGrabbedReply() {
        guard let emailId = pendingEmailIdForReply else { return }
        guard emailScanningService.gmailService.isAuthenticated else {
            // DEBUG: Commented out for performance
            // print("NotificationCenterView: Cannot send reply - Gmail not authenticated")
            return
        }
        
        isSendingReply = true
        
        Task {
            do {
                let settings = settingsManager.currentSettings
                var imageURL: URL? = nil
                
                // Check if cursed image feature is enabled
                if settings.enableCursedImageReplies && !settings.cursedImageSubreddit.isEmpty {
                    // DEBUG: Commented out for performance
                    // print("NotificationCenterView: Fetching random image from r/\(settings.cursedImageSubreddit)...")
                    
                    let redditService = RedditImageService()
                    do {
                        // Try to fetch image with retries
                        if let url = try await redditService.fetchRandomImageURLWithRetry(from: settings.cursedImageSubreddit) {
                            imageURL = url
                            // DEBUG: Commented out for performance
                            // print("NotificationCenterView: ✅ Found image: \(url.absoluteString)")
                        } else {
                            // DEBUG: Commented out for performance
                            // print("NotificationCenterView: ⚠️ No image found, falling back to text")
                        }
                    } catch {
                        // If image fetch fails, log but continue with plain text
                        // DEBUG: Commented out for performance
                        // print("NotificationCenterView: ⚠️ Failed to fetch image: \(error.localizedDescription), falling back to text")
                    }
                }
                
                // CRITICAL: Send reply ONLY to media email - NEVER to clients or other recipients
                // This removes all other recipients from the original email thread
                _ = try await emailScanningService.gmailService.sendReply(
                    messageId: emailId,
                    body: "Grabbed",
                    to: ["media@graysonmusicgroup.com"], // ONLY this recipient - all others removed
                    imageURL: imageURL
                )
                
                // DEBUG: Commented out for performance
                // print("NotificationCenterView: ✅ Successfully sent 'Grabbed' reply\(imageURL != nil ? " with image" : "")")
                
                // Mark notification as grabbed (remove it)
                await MainActor.run {
                    if let notification = notification {
                        // Mark email as read when grabbing file delivery
                        markEmailAsReadIfNeeded(notification)
                        
                        // Track grab interaction by email ID
                        if let emailId = notification.emailId {
                            EmailFeedbackTracker.shared.recordInteraction(
                                emailId: emailId,
                                type: .grabbed
                            )
                        }
                        
                        // Remove notification instead of archiving
                        notificationCenter.remove(notification, emailScanningService: emailScanningService)
                        print("📋 NotificationCenterView: Removed notification after grabbing file delivery")
                    }
                    pendingEmailIdForReply = nil
                    isSendingReply = false
                }
            } catch {
                // DEBUG: Commented out for performance
                // print("NotificationCenterView: ❌ Failed to send reply: \(error.localizedDescription)")
                
                await MainActor.run {
                    // Show error notification
                    let errorNotification = Notification(
                        type: .error,
                        title: "Failed to Send Reply",
                        message: "Could not send 'Grabbed' reply: \(error.localizedDescription)"
                    )
                    notificationCenter.add(errorNotification)
                    pendingEmailIdForReply = nil
                    isSendingReply = false
                }
            }
        }
    }
    
    /// Open a link in the default browser from settings
    private func openLinkInBrowser(_ link: String) {
        // DEBUG: Commented out for performance
        // print("NotificationCenterView: openLinkInBrowser called with link: \(link)")
        
        guard let url = URL(string: link) else {
            // DEBUG: Commented out for performance
            // print("NotificationCenterView: ❌ Invalid URL: \(link)")
            return
        }
        
        // DEBUG: Commented out for performance
        // print("NotificationCenterView: ✅ Valid URL created: \(url.absoluteString)")
        
        // Get browser preference from settings
        let browserPreference = settingsManager.currentSettings.defaultBrowser
        // DEBUG: Commented out for performance
        // print("NotificationCenterView: Browser preference: \(browserPreference)")
        
        // If a specific browser is selected, try to open with that browser
        if let bundleId = browserPreference.bundleIdentifier {
            // DEBUG: Commented out for performance
            // print("NotificationCenterView: Attempting to open with bundle ID: \(bundleId)")
            // Check if the browser is installed
            if let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                // DEBUG: Commented out for performance
                // print("NotificationCenterView: ✅ Browser found at: \(browserURL.path)")
                NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: { runningApp, error in
                    if error != nil {
                        // DEBUG: Commented out for performance
                        // print("NotificationCenterView: ❌ Error opening link in preferred browser: \(error.localizedDescription)")
                        // Fallback to default browser
                        // DEBUG: Commented out for performance
                        // print("NotificationCenterView: Falling back to default browser")
                        NSWorkspace.shared.open(url)
                    } else {
                        // DEBUG: Commented out for performance
                        // print("NotificationCenterView: ✅ Successfully opened link in preferred browser")
                    }
                })
                return
            } else {
                // DEBUG: Commented out for performance
                // print("NotificationCenterView: ⚠️ Browser with bundle ID \(bundleId) not found, falling back to default")
            }
        }
        
        // Fallback to default browser
        // DEBUG: Commented out for performance
        // print("NotificationCenterView: Opening with default browser")
        _ = NSWorkspace.shared.open(url)
        // DEBUG: Commented out for performance
        // print("NotificationCenterView: Default browser open result: \(success)")
    }
    
    /// Open email in Gmail browser
    private func openEmailInBrowser(emailId: String) {
        // Gmail URL format: https://mail.google.com/mail/u/0/#inbox/{messageId}
        let gmailURL = "https://mail.google.com/mail/u/0/#inbox/\(emailId)"
        guard let url = URL(string: gmailURL) else { return }
        
        // Get browser preference from settings
        let browserPreference = settingsManager.currentSettings.defaultBrowser
        
        // If a specific browser is selected, try to open with that browser
        if let bundleId = browserPreference.bundleIdentifier {
            // Check if the browser is installed
            if let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                return
            }
        }
        
        // Fallback to default browser
        NSWorkspace.shared.open(url)
    }
    
    private func handleApprove() {
        // Get the latest notification state from center
        guard let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }),
              currentNotification.type == .newDocket,
              let jobName = currentNotification.jobName else {
            return
        }
        
        // Check if docket number is missing
        if currentNotification.docketNumber == nil || currentNotification.docketNumber == "TBD" {
            showDocketInputDialog = true
            return
        }
        
        guard let docketNumber = currentNotification.docketNumber, docketNumber != "TBD" else {
            return
        }
        
        // Check if docket already exists in Work Picture (only if creating Work Picture)
        // Allow creation in Simian even if it exists in Work Picture, and vice versa
        let docketName = "\(docketNumber)_\(jobName)"
        if mediaManager.dockets.contains(docketName) && currentNotification.shouldCreateWorkPicture {
            // Show error notification only if trying to create Work Picture
            let errorNotification = Notification(
                type: .error,
                title: "Docket Already Exists",
                message: "Docket \(docketNumber): \(jobName) already exists in Work Picture"
            )
            notificationCenter.add(errorNotification)
            return
        }
        
        handleApproveWithDocket(docketNumber)
    }
    
    private func handleApproveWithDocket(_ providedDocketNumber: String?) {
        Task {
            await handleApproveWithDocketAsync(providedDocketNumber)
        }
    }
    
    private func handleApproveWithDocketAsync(_ providedDocketNumber: String?) async {
        // Get the latest notification state from center
        guard let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }),
              currentNotification.type == .newDocket,
              let jobName = currentNotification.jobName else {
            return
        }
        
        // Determine docket number: use provided, or generate YYXXX format
        let finalDocketNumber: String
        if let provided = providedDocketNumber, !provided.isEmpty {
            finalDocketNumber = provided
        } else {
            // Generate YYXXX format (YY = year suffix, XXX = literal "XXX")
            let year = Calendar.current.component(.year, from: Date())
            let yearSuffix = String(year).suffix(2) // Last 2 digits of year (25 for 2025, 26 for 2026)
            finalDocketNumber = "\(yearSuffix)XXX" // e.g., "25XXX", "26XXX"
        }
        
        // Check if docket already exists in Work Picture before creating Work Picture folder
        // Note: We only check Work Picture here - Simian creation is independent
        let docketName = "\(finalDocketNumber)_\(jobName)"
        if mediaManager.dockets.contains(docketName) {
            // Only prevent if user wants to create Work Picture folder
            // Check the notification's shouldCreateWorkPicture flag
            if currentNotification.shouldCreateWorkPicture {
                await MainActor.run {
                    processingNotification = nil
                    // Show error notification
                    let errorNotification = Notification(
                        type: .error,
                        title: "Docket Already Exists",
                        message: "Docket \(finalDocketNumber): \(jobName) already exists in Work Picture"
                    )
                    notificationCenter.add(errorNotification)
                }
                return
            }
            // If not creating Work Picture, allow Simian creation to proceed
        }
        
        // Update notification with docket number
        notificationCenter.updateDocketNumber(currentNotification, to: finalDocketNumber)
        
        // Get updated notification
        guard let updatedNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) else {
            return
        }
        
        processingNotification = notificationId
        
        // Check if we should show the dialog (if Simian is enabled OR if Work Picture is enabled)
        // The dialog allows setting docket number and job name that apply to both systems
        // IMPORTANT: Show dialog FIRST, do NOT create anything yet - wait for dialog confirmation
        await MainActor.run {
            updateSimianServiceConfiguration()
        }
        
        let shouldCreateSimian = updatedNotification.shouldCreateSimianJob || 
            (settingsManager.currentSettings.simianEnabled && simianService.isConfigured)
        let shouldCreateWorkPicture = updatedNotification.shouldCreateWorkPicture
        
        print("🔔 handleApproveWithDocket: shouldCreateSimian = \(shouldCreateSimian), shouldCreateWorkPicture = \(shouldCreateWorkPicture)")
        
        // Show dialog FIRST if either Simian or Work Picture is being created
        // This allows user to set docket number and job name that will be used for both
        // DO NOT create Work Picture or Simian here - wait for dialog confirmation
        if shouldCreateSimian || shouldCreateWorkPicture {
            print("🔔 Showing project creation dialog FIRST (before creating anything)")
            await MainActor.run {
                showSimianProjectDialog = true
                pendingSimianNotificationId = notificationId
                pendingSimianDocketNumber = finalDocketNumber
                pendingSimianJobName = jobName
                pendingSimianSourceEmail = currentNotification.sourceEmail
            }
            // Don't remove notification here - it will be removed after both are created
            // or if dialog is cancelled
        } else {
            // Neither is enabled - just remove notification
            print("⚠️ Neither Simian nor Work Picture enabled - removing notification")
            await MainActor.run {
                processingNotification = nil
                markEmailAsReadIfNeeded(updatedNotification)
            }
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                await notificationCenter.remove(currentNotification, emailScanningService: emailScanningService)
            }
        }
    }
    
    private func iconForType(_ type: NotificationType) -> String {
        switch type {
        case .newDocket:
            return "folder.badge.plus"
        case .mediaFiles:
            return "link.circle.fill"
        case .request:
            return "hand.raised.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        case .junk:
            return "trash.fill"
        case .skipped:
            return "forward.fill"
        }
    }
    
    private func colorForType(_ type: NotificationType) -> Color {
        switch type {
        case .newDocket:
            return .blue
        case .mediaFiles:
            return .green // Different color for file deliveries
        case .request:
            return .orange
        case .error:
            return .red
        case .info:
            return .blue
        case .junk:
            return .gray
        case .skipped:
            return .secondary
        }
    }
    
    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    /// Check if a docket already exists in Work Picture (simple check)
    private func docketExists(docketNumber: String, jobName: String) -> Bool {
        let info = checkDocketExistence(docketNumber: docketNumber, jobName: jobName)
        return info.existsAnywhere
    }
    
    /// Comprehensive check of where a docket exists across all known databases
    /// Note: This function is called from within view body, so it must NOT trigger any @Published updates
    private func checkDocketExistence(docketNumber: String, jobName: String) -> DocketExistenceInfo {
        var info = DocketExistenceInfo()
        
        // Check Work Picture
        let docketName = "\(docketNumber)_\(jobName)"
        if mediaManager.dockets.contains(docketName) {
            info.existsInWorkPicture = true
        }
        
        // Check Asana cache by directly loading the cache file (no @Published updates)
        let settings = settingsManager.currentSettings
        if settings.docketSource == .asana {
            // Load cache directly from file without going through AsanaCacheManager
            // This avoids triggering updateCacheStatus() which updates @Published properties
            let cachedDockets = loadAsanaCacheDirectly(
                sharedCacheURL: settings.sharedCacheURL,
                useSharedCache: settings.useSharedCache
            )
            
            // Check if docket number matches any cached docket
            if let matchingDocket = cachedDockets.first(where: { $0.number == docketNumber }) {
                info.existsInAsana = true
                info.asanaDocketInfo = matchingDocket
            }
        }
        
        return info
    }
    
    /// Load Asana cache directly from file without triggering any @Published updates
    /// This is safe to call from within view body
    private func loadAsanaCacheDirectly(sharedCacheURL: String?, useSharedCache: Bool) -> [DocketInfo] {
        // Try shared cache first if enabled
        if useSharedCache, let sharedURL = sharedCacheURL, !sharedURL.isEmpty {
            if let dockets = loadCacheFromPath(sharedURL) {
                return dockets
            }
        }
        
        // Fall back to local cache
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
        let localCacheURL = appFolder.appendingPathComponent("mediadash_docket_cache.json")
        
        if let dockets = loadCacheFromURL(localCacheURL) {
            return dockets
        }
        
        return []
    }
    
    /// Load cache from a path string
    private func loadCacheFromPath(_ path: String) -> [DocketInfo]? {
        var fileURL: URL
        if path.hasPrefix("file://") {
            fileURL = URL(string: path) ?? URL(fileURLWithPath: path)
        } else {
            fileURL = URL(fileURLWithPath: path)
        }
        
        // If path doesn't end with .json, assume it's a directory
        if !fileURL.lastPathComponent.hasSuffix(".json") {
            fileURL = fileURL.appendingPathComponent("mediadash_docket_cache.json")
        }
        
        return loadCacheFromURL(fileURL)
    }
    
    /// Load cache from a URL
    private func loadCacheFromURL(_ url: URL) -> [DocketInfo]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedDockets.self, from: data) else {
            return nil
        }
        return cached.dockets
    }
    
    /// Generate auto docket number in YYXXX format
    private func generateAutoDocketNumber() -> String {
        let year = Calendar.current.component(.year, from: Date())
        let yearSuffix = String(year).suffix(2) // Last 2 digits of year (25 for 2025, 26 for 2026)
        return "\(yearSuffix)XXX" // e.g., "25XXX", "26XXX"
    }
    
    /// Extract producer name from email source string
    /// Handles formats like "Name <email@example.com>" or just "email@example.com"
    /// Use selected text as job name
    private func useSelectedTextAsJobName(_ text: String) {
        guard let notification = notification else { return }
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return }
        
        // Update job name in notification
        notificationCenter.updateJobName(notification, to: cleanedText)
        
        // Add to company name cache
        CompanyNameCache.shared.addCompanyName(cleanedText, source: "user")
    }
    
    /// Reusable context menu content for notifications (used by both notification body and text fields)
    @ViewBuilder
    private func notificationContextMenuContent(notification: Notification) -> some View {
        // Replace job name with selected text (only show if text is selected)
        if let selectedText = selectedTextFromEmail, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(action: {
                useSelectedTextAsJobName(selectedText.trimmingCharacters(in: .whitespacesAndNewlines))
            }) {
                Label("Replace Job Name with '\(selectedText.prefix(30))'", systemImage: "text.cursor")
            }
        }
        
        // Edit job name
        if notification.type == .newDocket {
            Button(action: {
                showJobNameEditDialog = true
            }) {
                Label("Edit Job Name", systemImage: "pencil")
            }
        }
        
        // Reset to defaults
        if notification.type == .newDocket {
            Button(action: {
                Task {
                    await debugResetToDefaults(notification)
                }
            }) {
                Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
            }
        }
        
        Divider()
        
        
        // Open email in browser
        if let emailId = notification.emailId {
            Button(action: {
                openEmailInBrowser(emailId: emailId)
            }) {
                Label("Open Email in Browser", systemImage: "safari")
            }
        }
        
        // Add docket number if missing
        if notification.type == .newDocket && (notification.docketNumber == nil || notification.docketNumber == "TBD") {
            Button(action: {
                isDocketInputForApproval = false // Just updating, not approving
                showDocketInputDialog = true
            }) {
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
    
    /// Debug function for reset to defaults
    private func debugResetToDefaults(_ notification: Notification) async {
        var debugMessages: [String] = []
        debugMessages.append("=== Reset to Defaults Debug ===")
        debugMessages.append("")
        debugMessages.append("📋 Notification ID: \(notification.id)")
        debugMessages.append("")
        debugMessages.append("🔍 BEFORE Reset:")
        debugMessages.append("  Current docketNumber: \(notification.docketNumber ?? "nil")")
        debugMessages.append("  Current jobName: \(notification.jobName ?? "nil")")
        debugMessages.append("  Current projectManager: \(notification.projectManager ?? "nil")")
        debugMessages.append("  Current message: \(notification.message)")
        debugMessages.append("")
        debugMessages.append("📦 Original Values:")
        debugMessages.append("  originalDocketNumber: \(notification.originalDocketNumber ?? "nil")")
        debugMessages.append("  originalJobName: \(notification.originalJobName ?? "nil")")
        debugMessages.append("  originalProjectManager: \(notification.originalProjectManager ?? "nil")")
        debugMessages.append("  originalMessage: \(notification.originalMessage ?? "nil")")
        debugMessages.append("")
        debugMessages.append("📧 Email Content:")
        debugMessages.append("  emailSubject: \(notification.emailSubject?.prefix(50) ?? "nil")")
        debugMessages.append("  emailBody: \(notification.emailBody != nil ? "\(notification.emailBody!.count) chars" : "nil")")
        debugMessages.append("")
        
        // Perform the reset (re-fetches and re-parses email)
        await notificationCenter.resetToDefaults(notification, emailScanningService: emailScanningService)
        
        // Get updated notification
        if let updatedNotification = notificationCenter.notifications.first(where: { $0.id == notification.id }) {
            debugMessages.append("✅ AFTER Reset:")
            debugMessages.append("  Updated docketNumber: \(updatedNotification.docketNumber ?? "nil")")
            debugMessages.append("  Updated jobName: \(updatedNotification.jobName ?? "nil")")
            debugMessages.append("  Updated projectManager: \(updatedNotification.projectManager ?? "nil")")
            debugMessages.append("  Updated message: \(updatedNotification.message)")
            debugMessages.append("")
            debugMessages.append("🔍 Verification:")
            debugMessages.append("  docketNumber matches original: \(updatedNotification.docketNumber == notification.originalDocketNumber)")
            debugMessages.append("  jobName matches original: \(updatedNotification.jobName == notification.originalJobName)")
            debugMessages.append("  projectManager matches original: \(updatedNotification.projectManager == notification.originalProjectManager)")
        } else {
            debugMessages.append("❌ ERROR: Could not find notification after reset!")
        }
        
        // DEBUG: Commented out for performance
        // Print to console only (don't auto-open debug panel)
        // let debugOutput = debugMessages.joined(separator: "\n")
        // print(debugOutput)
    }
    
    /// Debug function for email expansion
    private func debugEmailExpansion(_ notification: Notification, currentState: Bool) {
        // DEBUG: Commented out for performance
        // var debugMessages: [String] = []
        // debugMessages.append("=== Email Expansion Debug ===")
        // debugMessages.append("")
        // debugMessages.append("📋 Notification ID: \(notification.id)")
        // debugMessages.append("")
        // debugMessages.append("🔍 Current State:")
        // debugMessages.append("  isEmailPreviewExpanded (before): \(currentState)")
        // debugMessages.append("  Will toggle to: \(!currentState)")
        // debugMessages.append("")
        // debugMessages.append("📧 Email Content Check:")
        // debugMessages.append("  emailSubject exists: \(notification.emailSubject != nil)")
        // debugMessages.append("  emailSubject value: \(notification.emailSubject?.prefix(50) ?? "nil")")
        // debugMessages.append("  emailBody exists: \(notification.emailBody != nil)")
        // debugMessages.append("  emailBody length: \(notification.emailBody?.count ?? 0) chars")
        // debugMessages.append("  Has email content: \(notification.emailSubject != nil || notification.emailBody != nil)")
        // debugMessages.append("")
        // debugMessages.append("🎯 Tap Gesture Conditions:")
        // debugMessages.append("  Tap area should be visible: \(notification.emailSubject != nil || notification.emailBody != nil)")
        // debugMessages.append("")
        //
        // Print to console only (don't auto-open debug panel)
        // let debugOutput = debugMessages.joined(separator: "\n")
        // print(debugOutput)
    }
    
    private func extractProducerName(from sourceEmail: String) -> String {
        // Check if it's in format "Name <email@example.com>"
        if let regex = try? NSRegularExpression(pattern: #"^(.+?)\s*<"#, options: []),
           let match = regex.firstMatch(in: sourceEmail, range: NSRange(sourceEmail.startIndex..., in: sourceEmail)),
           match.numberOfRanges >= 2 {
            let nameRange = Range(match.range(at: 1), in: sourceEmail)!
            let name = String(sourceEmail[nameRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "") // Remove quotes if present
            if !name.isEmpty {
                return name
            }
        }
        
        // If no name found, try to extract from email address (part before @)
        if let regex = try? NSRegularExpression(pattern: #"([^<\s@]+)@[^>\s]+"#, options: []),
           let match = regex.firstMatch(in: sourceEmail, range: NSRange(sourceEmail.startIndex..., in: sourceEmail)),
           match.numberOfRanges >= 2 {
            let emailRange = Range(match.range(at: 1), in: sourceEmail)!
            let username = String(sourceEmail[emailRange])
            // Capitalize first letter of username
            if !username.isEmpty {
                return username.prefix(1).uppercased() + username.dropFirst()
            }
        }
        
        // Fallback: return as-is if we can't parse it
        return sourceEmail
    }
}



