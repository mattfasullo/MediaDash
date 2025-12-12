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
    @State private var selectedTab: NotificationTab = .newDockets // Tab selection
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
    
    // Notifications that need review (low confidence)
    private var notificationsForReview: [Notification] {
        let threshold = settingsManager.currentSettings.codeMindReviewThreshold
        return allActiveNotifications.filter { notification in
            guard let codeMindMeta = notification.codeMindClassification,
                  codeMindMeta.wasUsed else {
                return false // Only show CodeMind-classified notifications
            }
            return codeMindMeta.confidence < threshold
        }
    }
    
    // Regular notifications (above confidence threshold)
    private var regularNotifications: [Notification] {
        let threshold = settingsManager.currentSettings.codeMindReviewThreshold
        return allActiveNotifications.filter { notification in
            // For CodeMind-classified notifications, check confidence
            if let codeMindMeta = notification.codeMindClassification,
               codeMindMeta.wasUsed {
                return codeMindMeta.confidence >= threshold
            }
            // For non-CodeMind notifications, include them in regular list
            return true
        }
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
        VStack(spacing: 0) {
            // Header (double-click to toggle lock)
            HStack {
                Text("Notifications")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                if notificationCenter.unreadCount > 0 {
                    Text("\(notificationCenter.unreadCount) new")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                // Email refresh button
                EmailRefreshButton(
                    notificationCenter: notificationCenter,
                    grabbedIndicatorService: notificationCenter.grabbedIndicatorService
                )
                    .environmentObject(emailScanningService)
                
                // Lock/Unlock toggle
                Button(action: {
                    let manager = NotificationWindowManager.shared
                    manager.setLocked(!manager.isLocked)
                    // Update settings
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
                // Double-click to toggle lock/unlock
                let manager = NotificationWindowManager.shared
                manager.setLocked(!manager.isLocked)
                // Update settings
                var updatedSettings = settingsManager.currentSettings
                updatedSettings.notificationWindowLocked = manager.isLocked
                settingsManager.currentSettings = updatedSettings
                settingsManager.saveCurrentProfile()
            }
            
            Divider()
            
            // Check Gmail connection status
            let isGmailConnected = emailScanningService.gmailService.isAuthenticated
            let gmailEnabled = settingsManager.currentSettings.gmailEnabled
            
            // Gmail disabled banner (if Gmail is disabled)
            if !gmailEnabled {
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
            // Gmail connection warning banner (if Gmail is enabled but not connected)
            else if gmailEnabled && !isGmailConnected {
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
            
            // Show Gmail connection status if Gmail is enabled but not connected (empty state)
            if gmailEnabled && !isGmailConnected {
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
                        // Close notification window when opening settings
                        NotificationWindowManager.shared.hideNotificationWindow()
                        isExpanded = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if !gmailEnabled && notificationsForReview.isEmpty && mediaFileNotifications.isEmpty && activeNotifications.isEmpty {
                // Show message when Gmail is disabled
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
                        // Close notification window when opening settings
                        NotificationWindowManager.shared.hideNotificationWindow()
                        isExpanded = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if notificationsForReview.isEmpty && mediaFileNotifications.isEmpty && activeNotifications.isEmpty {
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
            } else {
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
                            } else if selectedTab == .fileDeliveries && !regularFileDeliveryNotifications.isEmpty {
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
                            } else if selectedTab == .requests && !regularRequestNotifications.isEmpty {
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
                }
            }
            
            // Footer
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
            
            // Debug info panel
            if showDebugInfo {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
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
            
            // Cache info panel
            if showCacheInfo {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
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
        }
        .frame(width: 400, height: 500)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12)) // Ensure content is clipped to rounded corners
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        .onChange(of: activeNotifications.count) { oldCount, newCount in
            // Auto-select tab if current selection is empty
            if selectedTab == .newDockets && newCount == 0 && !mediaFileNotifications.isEmpty {
                selectedTab = .fileDeliveries
            } else if selectedTab == .fileDeliveries && mediaFileNotifications.isEmpty && newCount > 0 {
                selectedTab = .newDockets
            }
        }
        .onChange(of: mediaFileNotifications.count) { oldCount, newCount in
            // Auto-select tab if current selection is empty
            if selectedTab == .fileDeliveries && newCount == 0 && !activeNotifications.isEmpty {
                selectedTab = .newDockets
            } else if selectedTab == .newDockets && activeNotifications.isEmpty && newCount > 0 {
                selectedTab = .fileDeliveries
            }
        }
        .onAppear {
            // Clean up old archived notifications
            notificationCenter.cleanupOldArchivedNotifications()
            // Clean up old completed requests (older than 24 hours)
            notificationCenter.cleanupOldCompletedRequests()
            // Sync completion status from shared cache
            Task {
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
    @State private var showCustomClassificationDialog = false
    @State private var customClassificationText = ""
    @State private var showClassificationDetails = false
    
    // Get current notification from center (always up-to-date)
    private var notification: Notification? {
        notificationCenter.notifications.first(where: { $0.id == notificationId })
    }
    
    // Update SimianService webhook URL when settings change
    private func updateSimianServiceWebhook() {
        if let webhookURL = settingsManager.currentSettings.simianWebhookURL {
            simianService.setWebhookURL(webhookURL)
        } else {
            simianService.clearWebhookURL()
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
            updateSimianServiceWebhook()
            // Always refresh hasSubmittedFeedback from persistent storage when view appears
            // This ensures we check the source of truth even after view recreation
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }),
               let emailId = currentNotification.emailId {
                hasSubmittedFeedback = EmailFeedbackTracker.shared.hasFeedback(for: emailId)
            } else {
                hasSubmittedFeedback = false
            }
        }
        .onChange(of: settingsManager.currentSettings.simianWebhookURL) { _, _ in
            updateSimianServiceWebhook()
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
            CodeMindFeedbackDialog(
                isPresented: $showFeedbackDialog,
                correction: $feedbackCorrection,
                comment: $feedbackComment,
                onSubmit: {
                    Task {
                        await submitFeedback(
                            notificationId: notificationId,
                            wasCorrect: false,
                            rating: 1,
                            correction: feedbackCorrection.isEmpty ? nil : feedbackCorrection,
                            comment: feedbackComment.isEmpty ? nil : feedbackComment
                        )
                    }
                }
            )
        }
        .sheet(isPresented: $showCustomClassificationDialog) {
            CustomClassificationDialog(
                isPresented: $showCustomClassificationDialog,
                classificationText: $customClassificationText,
                onConfirm: {
                    guard let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }),
                          !customClassificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    Task {
                        await notificationCenter.reclassify(
                            currentNotification,
                            toCustomType: customClassificationText,
                            autoArchive: false,
                            emailScanningService: emailScanningService
                        )
                    }
                    customClassificationText = ""
                }
            )
        }
        .onChange(of: showClassificationDetails) { _, isPresented in
            if isPresented, let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                ClassificationDetailsWindowManager.shared.showWindow(notification: currentNotification) {
                    showClassificationDetails = false
                }
            } else if !isPresented {
                ClassificationDetailsWindowManager.shared.hideWindow()
            }
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
        
        await emailScanningService.provideCodeMindFeedback(
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
            
            if wasCorrect {
                // Thumbs up: Boost confidence above threshold to move it from "For Review" to regular section
                if let codeMindMeta = updatedNotification.codeMindClassification,
                   codeMindMeta.wasUsed {
                    let threshold = settingsManager.currentSettings.codeMindReviewThreshold
                    // If it's currently below threshold (in "For Review"), boost it above
                    if codeMindMeta.confidence < threshold {
                        // Create new metadata with boosted confidence
                        let boostedConfidence = min(1.0, threshold + 0.01) // Boost to just above threshold
                        let newMetadata = CodeMindClassificationMetadata(
                            wasUsed: codeMindMeta.wasUsed,
                            confidence: boostedConfidence,
                            reasoning: codeMindMeta.reasoning,
                            classificationType: codeMindMeta.classificationType,
                            extractedData: codeMindMeta.extractedData
                        )
                        // Update the notification's CodeMind metadata
                        notificationCenter.updateCodeMindMetadata(updatedNotification, metadata: newMetadata)
                        print("📋 NotificationCenterView: ✅ Boosted confidence from \(Int(codeMindMeta.confidence * 100))% to \(Int(boostedConfidence * 100))% - moved from 'For Review' to regular section")
                    }
                }
            } else {
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
        let docketAlreadyExists = checkIfDocketExists(notification: notification)
        
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Create Work Picture Folder", isOn: workPictureBinding())
                .font(.system(size: 11))
                .disabled(docketAlreadyExists)
                .opacity(docketAlreadyExists ? 0.5 : 1.0)
            
            Toggle("Create Simian Job", isOn: simianJobBinding())
                .font(.system(size: 11))
                .disabled(true)
                .opacity(0.5)
            
            if notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateSimianJob == true {
                projectManagerFieldView(notification: notification)
            }
            
            approveArchiveButtons(notification: notification)
        }
        .padding(.top, 4)
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
            
            TextField("Project Manager", text: projectManagerBinding(notification: notification))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            
            Text("Defaults to email sender. Edit if needed.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
    
    private func projectManagerBinding(notification: Notification) -> Binding<String> {
        Binding(
            get: { notificationCenter.notifications.first(where: { $0.id == notificationId })?.projectManager ?? notification.sourceEmail ?? "" },
            set: { newValue in
                if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                    notificationCenter.updateProjectManager(currentNotification, to: newValue.isEmpty ? nil : newValue)
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

            // Show feedback UI if CodeMind metadata exists (whether used or skipped)
            // This allows users to provide feedback even when CodeMind was skipped
            if let codeMindMeta = notification.codeMindClassification {
                codeMindFeedbackUI(notification: notification, codeMindMeta: codeMindMeta)
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
            codeMindConfidenceView(notification: notification)
            emailPreviewSection(notification: notification)
            
            // Show feedback UI if CodeMind was used OR if CodeMind is available but was skipped
            if let codeMindMeta = notification.codeMindClassification {
                if codeMindMeta.wasUsed {
                    codeMindFeedbackUI(notification: notification, codeMindMeta: codeMindMeta)
                } else {
                    // CodeMind metadata exists but wasn't used (e.g., was skipped)
                    codeMindFeedbackUI(notification: notification, codeMindMeta: codeMindMeta)
                }
            }
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
            codeMindConfidenceView(notification: notification)
            emailPreviewSection(notification: notification)
            
            // Show feedback UI if CodeMind was used OR if CodeMind is available but was skipped
            // This allows users to provide feedback even when CodeMind was skipped
            if let codeMindMeta = notification.codeMindClassification {
                if codeMindMeta.wasUsed {
                    codeMindFeedbackUI(notification: notification, codeMindMeta: codeMindMeta)
                } else {
                    // CodeMind metadata exists but wasn't used (e.g., was skipped)
                    // Still show feedback UI so users can provide feedback about the classification
                    codeMindFeedbackUI(notification: notification, codeMindMeta: codeMindMeta)
                }
            } else {
                // Debug: Log when CodeMind metadata is missing
                #if DEBUG
                let _ = print("NotificationCenterView: ⚠️ CodeMind metadata is nil for notification \(notification.id) - feedback UI will not show")
                let _ = print("  - Notification type: \(notification.type)")
                let _ = print("  - Has emailId: \(notification.emailId != nil)")
                let _ = print("  - Has codeMindClassification: \(notification.codeMindClassification != nil)")
                #endif
                EmptyView()
            }
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
    
    /// Helper view for CodeMind confidence indicator
    @ViewBuilder
    private func codeMindConfidenceView(notification: Notification) -> some View {
        if let codeMindMeta = notification.codeMindClassification, codeMindMeta.wasUsed {
            let confidence = codeMindMeta.confidence
            let threshold = settingsManager.currentSettings.codeMindReviewThreshold
            let isLowConfidence = confidence < threshold
            let reasoning = codeMindMeta.reasoning
            
            HStack(spacing: 4) {
                Image(systemName: isLowConfidence ? "exclamationmark.triangle.fill" : "brain.head.profile")
                    .font(.system(size: 9))
                    .foregroundColor(isLowConfidence ? .orange : .blue.opacity(0.7))
                Text("Confidence: \(Int(confidence * 100))%")
                    .font(.system(size: 10, weight: isLowConfidence ? .semibold : .regular))
                    .foregroundColor(isLowConfidence ? .orange : .secondary.opacity(0.8))
                if isLowConfidence {
                    Text("(Needs Review)")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
            .padding(.top, 2)
            .help(reasoning ?? "No reasoning provided")
            .onTapGesture {
                showClassificationDetails = true
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
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
    
    /// Helper view for CodeMind feedback UI to reduce view complexity
    @ViewBuilder
    private func codeMindFeedbackUI(notification: Notification, codeMindMeta: CodeMindClassificationMetadata) -> some View {
        // Always check persistent storage - this is the source of truth
        // Get current notification from center to ensure we have the latest emailId
        let currentNotification = notificationCenter.notifications.first(where: { $0.id == notification.id }) ?? notification
        let emailId = currentNotification.emailId ?? notification.emailId
        // Only check for existing feedback if we have an emailId - if emailId is nil, show feedback options
        let hasExistingFeedback = emailId != nil && (EmailFeedbackTracker.shared.hasFeedback(for: emailId!) || hasSubmittedFeedback)
        
        Divider()
            .padding(.vertical, 4)
        
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 10))
                .foregroundColor(.purple)
            Text("CodeMind Classification")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            
            // Only show confidence if CodeMind was actually used
            // When wasUsed is false, CodeMind was skipped and confidence is meaningless (set to 0.0)
            if codeMindMeta.wasUsed {
            Text("(\(Int(codeMindMeta.confidence * 100))% confidence)")
                .font(.system(size: 8))
                .foregroundColor(.secondary.opacity(0.7))
            } else {
                Text("(skipped)")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            
            Spacer()
            
            if !hasExistingFeedback {
                HStack(spacing: 4) {
                    Button(action: {
                        Task {
                            await submitFeedback(notificationId: notification.id, wasCorrect: true, rating: 5)
                        }
                    }) {
                        Image(systemName: "hand.thumbsup.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .help("Classification was correct")
                    .disabled(isSubmittingFeedback)
                    
                    Button(action: {
                        showFeedbackDialog = true
                    }) {
                        Image(systemName: "hand.thumbsdown.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Classification was incorrect")
                    .disabled(isSubmittingFeedback)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text("Feedback submitted")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.top, 4)
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
        
        // Check if docket already exists
        if docketExists(docketNumber: docketNumber, jobName: jobName) {
            // Show error notification
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
        
        // Check if docket already exists before creating
        if docketExists(docketNumber: finalDocketNumber, jobName: jobName) {
            processingNotification = nil
            // Show error notification
            let errorNotification = Notification(
                type: .error,
                title: "Docket Already Exists",
                message: "Docket \(finalDocketNumber): \(jobName) already exists in Work Picture"
            )
            notificationCenter.add(errorNotification)
            return
        }
        
        // Update notification with docket number
        notificationCenter.updateDocketNumber(currentNotification, to: finalDocketNumber)
        
        // Get updated notification
        guard let updatedNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) else {
            return
        }
        
        processingNotification = notificationId
        
        Task {
            do {
                // Create Work Picture folder if requested
                if updatedNotification.shouldCreateWorkPicture {
                    try await emailScanningService.createDocketFromNotification(updatedNotification)
                }
                
                // Create Simian job via Zapier webhook if enabled and requested
                if updatedNotification.shouldCreateSimianJob {
                    // Update webhook URL from settings before calling
                    updateSimianServiceWebhook()
                    
                    do {
                        // Get project manager from notification (fallback to sourceEmail)
                        let projectManager = updatedNotification.projectManager ?? updatedNotification.sourceEmail
                        
                        try await simianService.createJob(
                            docketNumber: finalDocketNumber,
                            jobName: jobName,
                            projectManager: projectManager,
                            projectTemplate: settingsManager.currentSettings.simianProjectTemplate
                        )
                        // DEBUG: Commented out for performance
                        // print("✅ Simian job creation requested for \(finalDocketNumber): \(jobName)")
                    } catch {
                        // Log error but don't fail the whole approval process
                        // DEBUG: Commented out for performance
                        // print("⚠️ Failed to create Simian job: \(error.localizedDescription)")
                        // Optionally show a warning notification
                        await MainActor.run {
                            let warningNotification = Notification(
                                type: .info,
                                title: "Simian Job Creation Failed",
                                message: "Work Picture folder created, but Simian job creation failed: \(error.localizedDescription)"
                            )
                            notificationCenter.add(warningNotification)
                        }
                    }
                }
                
                await MainActor.run {
                    processingNotification = nil
                    // Mark email as read when approving notification (creating work pic/simian)
                    markEmailAsReadIfNeeded(updatedNotification)
                    
                    // Track approval interaction by email ID
                    if let emailId = updatedNotification.emailId {
                        var details: [String: String] = [:]
                        if updatedNotification.shouldCreateWorkPicture {
                            details["createdWorkPicture"] = "true"
                        }
                        if updatedNotification.shouldCreateSimianJob {
                            details["createdSimianJob"] = "true"
                        }
                        if let docketNumber = updatedNotification.docketNumber {
                            details["docketNumber"] = docketNumber
                        }
                        EmailFeedbackTracker.shared.recordInteraction(
                            emailId: emailId,
                            type: .approved,
                            details: details.isEmpty ? nil : details
                        )
                    }
                    
                    // Check if docket already exists before marking as completed
                    // If it exists, just remove the notification instead
                    if let docketNumber = updatedNotification.docketNumber,
                       let jobName = updatedNotification.jobName {
                        let docketName = "\(docketNumber)_\(jobName)"
                        if mediaManager.dockets.contains(docketName) {
                            // Docket already exists, remove notification instead of marking as completed
                            notificationCenter.remove(updatedNotification, emailScanningService: emailScanningService)
                            return
                        }
                    }
                    // Update notification status to completed
                    notificationCenter.updateStatus(updatedNotification, to: .completed, emailScanningService: emailScanningService)
                }
            } catch {
                await MainActor.run {
                    processingNotification = nil
                    // Show error notification
                    let errorNotification = Notification(
                        type: .error,
                        title: "Failed to Create Docket",
                        message: error.localizedDescription
                    )
                    notificationCenter.add(errorNotification)
                }
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
        case .custom:
            return "tag.fill"
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
        case .custom:
            return .purple
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
        
        // CodeMind MindMap options
        if notification.codeMindClassification?.wasUsed == true {
            Button(action: {
                showClassificationDetails = true
            }) {
                Label("View Classification Details", systemImage: "info.circle")
            }
            
            Button(action: {
                // Navigate to this classification in the brain view
                CodeMindBrainNavigator.shared.navigateToClassification(subject: notification.emailSubject ?? notification.title)
            }) {
                Label("View in MindMap", systemImage: "brain")
            }
            
            Button(action: {
                // Create a rule based on this email
                CodeMindBrainNavigator.shared.createRuleForEmail(
                    subject: notification.emailSubject ?? notification.title,
                    from: notification.sourceEmail,
                    classificationType: notification.type == .newDocket ? "newDocket" : (notification.type == .request ? "request" : "fileDelivery")
                )
            }) {
                Label("Create Classification Rule", systemImage: "plus.circle")
            }
            
            Divider()
        }
        
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
        
        // Re-classify submenu
        Menu {
            Button(action: {
                Task {
                    await notificationCenter.reclassify(
                        notification,
                        to: .newDocket,
                        autoArchive: false,
                        emailScanningService: emailScanningService
                    )
                }
            }) {
                Label("New Docket", systemImage: "doc.badge.plus")
            }
            .disabled(notification.type == .newDocket)
            
            Button(action: {
                Task {
                    await notificationCenter.reclassify(
                        notification,
                        to: .mediaFiles,
                        autoArchive: false,
                        emailScanningService: emailScanningService
                    )
                }
            }) {
                Label("File Delivery", systemImage: "arrow.down.doc")
            }
            .disabled(notification.type == .mediaFiles)
            
            Button(action: {
                Task {
                    await notificationCenter.reclassify(
                        notification,
                        to: .request,
                        autoArchive: false,
                        emailScanningService: emailScanningService
                    )
                }
            }) {
                Label("Request", systemImage: "hand.raised")
            }
            .disabled(notification.type == .request)
            
            Divider()
            
            Button(action: {
                Task {
                    await notificationCenter.markAsJunk(notification, emailScanningService: emailScanningService)
                }
            }) {
                Label("Junk (Ads/Promos)", systemImage: "trash")
            }
            
            Button(action: {
                Task {
                    await notificationCenter.skip(notification, emailScanningService: emailScanningService)
                }
            }) {
                Label("Skip (Remove)", systemImage: "forward")
            }
            
            Divider()
            
            // Recent custom classifications
            let recentCustomTypes = RecentCustomClassificationsManager.shared.getRecent()
            if !recentCustomTypes.isEmpty {
                ForEach(recentCustomTypes, id: \.self) { customType in
                    Button(action: {
                        Task {
                            await notificationCenter.reclassify(
                                notification,
                                toCustomType: customType,
                                autoArchive: false,
                                emailScanningService: emailScanningService
                            )
                        }
                    }) {
                        Label(customType, systemImage: "tag")
                    }
                    .disabled(notification.type == .custom && notification.customTypeName == customType)
                }
                
                Divider()
            }
            
            // Other option
            Button(action: {
                customClassificationText = ""
                showCustomClassificationDialog = true
            }) {
                Label("Other...", systemImage: "plus.circle")
            }
        } label: {
            Label("Re-classify", systemImage: "arrow.triangle.2.circlepath")
        }
        
        Divider()
        
        // Archive option
        if notification.status == .pending && notification.archivedAt == nil {
            Button(action: {
                notificationCenter.archive(notification, emailScanningService: emailScanningService)
            }) {
                Label("Archive", systemImage: "archivebox")
            }
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

/// Dialog for entering custom classification type
struct CustomClassificationDialog: View {
    @Binding var isPresented: Bool
    @Binding var classificationText: String
    let onConfirm: () -> Void
    
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Custom Classification")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter a custom classification name:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                TextField("Classification name", text: $classificationText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        if !classificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onConfirm()
                            isPresented = false
                        }
                    }
            }
            
            HStack {
                Button("Cancel") {
                    classificationText = ""
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("OK") {
                    onConfirm()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(classificationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400, height: 200)
        .onAppear {
            isTextFieldFocused = true
        }
    }
}

/// View showing detailed CodeMind classification information
struct ClassificationDetailsView: View {
    let notification: Notification
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                Text("CodeMind Classification Details")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            if let codeMindMeta = notification.codeMindClassification, codeMindMeta.wasUsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Classification Type
                        InfoRow(label: "Classification Type", value: codeMindMeta.classificationType.capitalized)
                        
                        // Confidence
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Confidence")
                                    .font(.headline)
                                Spacer()
                                Text("\(Int(codeMindMeta.confidence * 100))%")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(confidenceColor(codeMindMeta.confidence))
                            }
                            ProgressView(value: codeMindMeta.confidence)
                                .tint(confidenceColor(codeMindMeta.confidence))
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                        
                        // Reasoning
                        if let reasoning = codeMindMeta.reasoning, !reasoning.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Reasoning")
                                    .font(.headline)
                                Text(reasoning)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.05))
                                    .cornerRadius(8)
                            }
                        }
                        
                        // Extracted Data
                        if let extractedData = codeMindMeta.extractedData, !extractedData.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Extracted Information")
                                    .font(.headline)
                                ForEach(Array(extractedData.keys.sorted()), id: \.self) { key in
                                    InfoRow(
                                        label: key.capitalized.replacingOccurrences(of: "_", with: " "),
                                        value: extractedData[key] ?? "N/A"
                                    )
                                }
                            }
                            .padding()
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(8)
                        }
                        
                        // Email Information
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Email Information")
                                .font(.headline)
                            if let subject = notification.emailSubject {
                                InfoRow(label: "Subject", value: subject)
                            }
                            if let from = notification.sourceEmail {
                                InfoRow(label: "From", value: from)
                            }
                            if let emailId = notification.emailId {
                                InfoRow(label: "Email ID", value: String(emailId.prefix(20)) + "...")
                            }
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No CodeMind Classification")
                        .font(.headline)
                    Text("This notification was not classified using CodeMind.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
            
            Spacer()
            
            // Close button
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 500)
    }
    
    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.8 {
            return .green
        } else if confidence >= 0.6 {
            return .orange
        } else {
            return .red
        }
    }
}

/// Helper view for displaying key-value pairs
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Window manager for classification details window
@MainActor
class ClassificationDetailsWindowManager {
    static let shared = ClassificationDetailsWindowManager()
    
    private var window: NSWindow?
    private var onClose: (() -> Void)?
    
    private init() {}
    
    func showWindow(notification: Notification, onClose: @escaping () -> Void) {
        // Close existing window if open
        hideWindow()
        
        self.onClose = onClose
        
        let contentView = ClassificationDetailsView(notification: notification)
            .environment(\.dismiss, DismissAction(action: { [weak self] in
                self?.hideWindow()
            }))
        
        let hostingController = NSHostingController(rootView: contentView)
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        guard let window = window else { return }
        
        window.contentViewController = hostingController
        window.title = "CodeMind Classification Details"
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.level = .floating // Ensure it appears above other windows
        window.isReleasedWhenClosed = false
        
        // Handle window close
        let weakSelf = self
        Foundation.NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: OperationQueue.main
        ) { (_: Foundation.Notification) in
            Task { @MainActor [weak weakSelf] in
                weakSelf?.hideWindow()
            }
        }
    }
    
    func hideWindow() {
        window?.close()
        window = nil
        onClose?()
        onClose = nil
    }
}

/// Custom DismissAction for window-based dismissal
struct DismissAction {
    let action: () -> Void
    
    func callAsFunction() {
        action()
    }
}

extension EnvironmentValues {
    var dismiss: DismissAction {
        get { self[DismissKey.self] }
        set { self[DismissKey.self] = newValue }
    }
    
    private struct DismissKey: EnvironmentKey {
        static let defaultValue = DismissAction(action: {})
    }
}

