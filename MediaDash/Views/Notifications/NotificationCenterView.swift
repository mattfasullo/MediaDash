import SwiftUI

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
    @State private var cacheInfo: String?
    @State private var showCacheInfo = false
    @State private var isLoadingCache = false // Keep for fallback if file write fails
    
    enum NotificationTab {
        case newDockets
        case fileDeliveries
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
                        notificationCenter.remove(notification)
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
            
            // Gmail connection warning banner (if Gmail is enabled but not connected)
            if gmailEnabled && !isGmailConnected {
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
            } else if mediaFileNotifications.isEmpty && activeNotifications.isEmpty {
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
                    if !mediaFileNotifications.isEmpty || !activeNotifications.isEmpty {
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
                                    if !activeNotifications.isEmpty {
                                        Text("(\(activeNotifications.count))")
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
                                    if !mediaFileNotifications.isEmpty {
                                        Text("(\(mediaFileNotifications.count))")
                                            .font(.system(size: 11))
                                            .opacity(0.7)
                                    }
                                }
                                .foregroundColor(selectedTab == .fileDeliveries ? .orange : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    selectedTab == .fileDeliveries
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
                            if selectedTab == .newDockets && !activeNotifications.isEmpty {
                                ForEach(activeNotifications) { notification in
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
                            } else if selectedTab == .fileDeliveries && !mediaFileNotifications.isEmpty {
                                ForEach(mediaFileNotifications) { notification in
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
                            } else {
                                // Empty state for selected tab
                                VStack(spacing: 12) {
                                    Image(systemName: selectedTab == .newDockets ? "doc.text" : "link.circle")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                    Text("No \(selectedTab == .newDockets ? "new docket" : "file delivery") notifications")
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
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
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
        debugMessages.append("  Gmail Search Terms: \(settings.gmailSearchTerms.isEmpty ? "(none - using default)" : settings.gmailSearchTerms.joined(separator: ", "))")
        debugMessages.append("  Gmail Query: \(settings.gmailQuery.isEmpty ? "(none)" : settings.gmailQuery)")
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
        
        // Build query (same logic as EmailScanningService)
        let baseQuery: String
        if !settings.gmailSearchTerms.isEmpty {
            // Build OR query for each term
            let queryParts = settings.gmailSearchTerms.flatMap { term in
                [
                    "label:\"\(term)\"",
                    "subject:\"\(term)\"",
                    "\"\(term)\""
                ]
            }
            baseQuery = "(\(queryParts.joined(separator: " OR ")))"
        } else if !settings.gmailQuery.isEmpty {
            baseQuery = settings.gmailQuery
        } else {
            baseQuery = "\"new docket\" OR \"new docket -\" OR \"docket -\""
        }
        
        let query = "(\(baseQuery) OR \"new docket\" OR \"new docket -\" OR \"docket -\" OR \"New docket\") is:unread"
        
        debugMessages.append("🔍 Query Configuration:")
        debugMessages.append("  Search Terms: \(settings.gmailSearchTerms.isEmpty ? "(none)" : settings.gmailSearchTerms.joined(separator: ", "))")
        debugMessages.append("  Custom Query: \(settings.gmailQuery.isEmpty ? "(none)" : settings.gmailQuery)")
        debugMessages.append("  Base Query: \(baseQuery)")
        debugMessages.append("  Full Query: \(query)")
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
    @State private var feedbackCorrection = ""
    @State private var feedbackComment = ""
    @State private var isSubmittingFeedback = false
    @State private var feedbackSubmitted = false
    
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconForType(notification.type))
                    .foregroundColor(colorForType(notification.type))
                    .font(.system(size: 14))
                
                Text(notification.title)
                    .font(.system(size: 13, weight: .medium))
                
                Spacer()
                
                Text(timeAgo(notification.timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                // Grabbed and Priority Assist indicators
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
                            notificationCenter.archive(notification)
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
                
                if notification.status == .pending {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                }
            }
            
        // Show only docket number and job name for new docket notifications
        if notification.type == .newDocket {
            VStack(alignment: .leading, spacing: 4) {
                if let docketNumber = notification.docketNumber, docketNumber != "TBD" {
                    if let jobName = notification.jobName {
                        Text("Docket \(docketNumber): \(jobName)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        // Check if docket already exists
                        if docketExists(docketNumber: docketNumber, jobName: jobName) {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                Text("Docket already exists in Work Picture")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                            }
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
                
                // Show producer (sender) information
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
                
                // Email preview (expands on click)
                if notification.emailSubject != nil || notification.emailBody != nil {
                    // Visual indicator that notification is expandable
                    HStack(spacing: 4) {
                        Image(systemName: isEmailPreviewExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(isEmailPreviewExpanded ? "Hide email" : "Click to view email")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.top, 2)
                    
                    if isEmailPreviewExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            Divider()
                                .padding(.vertical, 4)
                            
                            Text("Email Content")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            
                            // Email subject
                            if let subject = notification.emailSubject, !subject.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Subject:")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    SelectableTextView(
                                        text: subject,
                                        font: .systemFont(ofSize: 11),
                                        selectedText: $selectedTextFromEmail
                                    )
                                    .frame(height: 40)
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                    )
                                    .contextMenu {
                                        notificationContextMenuContent(notification: notification)
                                    }
                                }
                            }
                            
                            // Email body
                            if let body = notification.emailBody, !body.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Body:")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary)
                                    SelectableTextView(
                                        text: body,
                                        font: .systemFont(ofSize: 11),
                                        selectedText: $selectedTextFromEmail
                                    )
                                    .frame(height: 400)
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                    )
                                    .contextMenu {
                                        notificationContextMenuContent(notification: notification)
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                
                // CodeMind feedback UI (if CodeMind was used)
                if let codeMindMeta = notification.codeMindClassification, codeMindMeta.wasUsed {
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 10))
                            .foregroundColor(.purple)
                        Text("AI Classification")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Text("(\(Int(codeMindMeta.confidence * 100))% confidence)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
                        
                        Spacer()
                        
                        if !feedbackSubmitted {
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
                                
                                Button(action: {
                                    showFeedbackDialog = true
                                }) {
                                    Image(systemName: "hand.thumbsdown.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Classification was incorrect")
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
            }
        } else if notification.type == .mediaFiles {
            // Media file notification content
            // Extract links from email body if not already stored (for older notifications)
            let extractedLinks: [String] = {
                if let existingLinks = notification.fileLinks, !existingLinks.isEmpty {
                    // DEBUG: Commented out for performance
                    // print("NotificationCenterView: Using stored fileLinks: \(existingLinks)")
                    return existingLinks
                }
                // Try to extract from email body if available
                if let emailBody = notification.emailBody {
                    // DEBUG: Commented out for performance
                    // print("NotificationCenterView: Extracting links from email body (length: \(emailBody.count))")
                    // print("NotificationCenterView: Email body preview: \(emailBody.prefix(500))")
                    let extracted = FileHostingLinkDetector.extractFileHostingLinks(emailBody)
                    // DEBUG: Commented out for performance
                    // print("NotificationCenterView: Extracted \(extracted.count) links: \(extracted)")
                    return extracted
                }
                // DEBUG: Commented out for performance
                // print("NotificationCenterView: No email body available for link extraction")
                return []
            }()
            
            VStack(alignment: .leading, spacing: 8) {
                Text(notification.message)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                // Show file hosting links if available
                if !extractedLinks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("File Links:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        ForEach(Array(extractedLinks.enumerated()), id: \.offset) { index, link in
                            // Check if link is valid
                            let isValidLink = URL(string: link) != nil
                            
                            if isValidLink {
                                // Valid link - show as clickable
                                Button(action: {
                                    // DEBUG: Commented out for performance
                                    // print("NotificationCenterView: Link button tapped: \(link)")
                                    openLinkInBrowser(link)
                                    // Show grabbed confirmation if email ID is available
                                    if let emailId = notification.emailId {
                                        pendingEmailIdForReply = emailId
                                        showGrabbedConfirmation = true
                                    }
                                }) {
                                    VStack(alignment: .leading, spacing: 4) {
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
                                        
                                        // Show sender name if there are multiple links
                                        if extractedLinks.count > 1, let sourceEmail = notification.sourceEmail {
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
                            } else {
                                // Invalid link - show error message with option to open email
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
                                            // Show grabbed confirmation
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
                        }
                    }
                    .padding(.top, 4)
                }
                
                // Show priority assist warning
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
                
                // CodeMind feedback UI (if CodeMind was used)
                if let codeMindMeta = notification.codeMindClassification, codeMindMeta.wasUsed {
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 10))
                            .foregroundColor(.purple)
                        Text("AI Classification")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Text("(\(Int(codeMindMeta.confidence * 100))% confidence)")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.7))
                        
                        Spacer()
                        
                        if !feedbackSubmitted {
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
                                
                                Button(action: {
                                    showFeedbackDialog = true
                                }) {
                                    Image(systemName: "hand.thumbsdown.fill")
                                        .font(.system(size: 11))
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Classification was incorrect")
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
            }
        } else {
            Text(notification.message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
            
            // Actions for new docket notifications (only show for active, non-archived notifications)
            if notification.type == .newDocket && notification.status == .pending && notification.archivedAt == nil {
                let docketAlreadyExists = {
                    if let docketNumber = notification.docketNumber, docketNumber != "TBD",
                       let jobName = notification.jobName {
                        return docketExists(docketNumber: docketNumber, jobName: jobName)
                    }
                    return false
                }()
                
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Create Work Picture Folder", isOn: Binding(
                        get: { 
                            notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateWorkPicture ?? true
                        },
                        set: { newValue in
                            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                                notificationCenter.updateActionFlags(currentNotification, workPicture: newValue)
                            }
                        }
                    ))
                    .font(.system(size: 11))
                    .disabled(docketAlreadyExists) // Disable if docket already exists
                    .opacity(docketAlreadyExists ? 0.5 : 1.0) // Grey out if disabled
                    
                    Toggle("Create Simian Job", isOn: Binding(
                        get: { 
                            notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateSimianJob ?? false
                        },
                        set: { newValue in
                            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                                notificationCenter.updateActionFlags(currentNotification, simianJob: newValue)
                            }
                        }
                    ))
                    .font(.system(size: 11))
                    .disabled(true) // Disabled until ready for release
                    .opacity(0.5) // Greyed out
                    
                    // Project Manager field (only show if Simian Job is enabled)
                    if notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateSimianJob == true {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Project Manager")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            
                            TextField("Project Manager", text: Binding(
                                get: {
                                    notificationCenter.notifications.first(where: { $0.id == notificationId })?.projectManager ?? notification.sourceEmail ?? ""
                                },
                                set: { newValue in
                                    if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                                        notificationCenter.updateProjectManager(currentNotification, to: newValue.isEmpty ? nil : newValue)
                                    }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            
                            Text("Defaults to email sender. Edit if needed.")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Button("Approve") {
                            // Check if docket number is missing
                            if notification.docketNumber == nil || notification.docketNumber == "TBD" {
                                isDocketInputForApproval = true // This is for approval
                                showDocketInputDialog = true
                            } else {
                            handleApprove()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(processingNotification == notificationId)
                        
                        Button("Archive") {
                            notificationCenter.archive(notification)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.top, 4)
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
        .padding(8)
        .background(
            ZStack {
                // Background color - different colors for different notification types
                Group {
                    if isHovered {
                        // Hover state - darker for visibility
                        if notification.type == .mediaFiles {
                            Color.orange.opacity(0.15)
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
                    } else {
                        Color.clear
                    }
                }
                
                // Tap area (only if email exists) - this captures taps on non-button areas
                // Note: For mediaFiles notifications, links are clickable and should take priority
                if (notification.emailSubject != nil || notification.emailBody != nil) && notification.type == .newDocket {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            debugEmailExpansion(notification, currentState: isEmailPreviewExpanded)
                            withAnimation {
                                isEmailPreviewExpanded.toggle()
                            }
                        }
                }
            }
        )
        .cornerRadius(8)
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
        }
        .onChange(of: settingsManager.currentSettings.simianWebhookURL) { _, _ in
            updateSimianServiceWebhook()
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
    }
    
    private func submitFeedback(
        notificationId: UUID,
        wasCorrect: Bool,
        rating: Int,
        correction: String? = nil,
        comment: String? = nil
    ) async {
        await emailScanningService.provideCodeMindFeedback(
            for: notificationId,
            rating: rating,
            wasCorrect: wasCorrect,
            correction: correction,
            comment: comment
        )
        
        await MainActor.run {
            feedbackSubmitted = true
            showFeedbackDialog = false
            feedbackCorrection = ""
            feedbackComment = ""
        }
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
                
                // Send reply with image if available, otherwise plain text
                _ = try await emailScanningService.gmailService.sendReply(
                    messageId: emailId,
                    body: "Grabbed",
                    to: ["media@graysonmusicgroup.com"],
                    imageURL: imageURL
                )
                
                // DEBUG: Commented out for performance
                // print("NotificationCenterView: ✅ Successfully sent 'Grabbed' reply\(imageURL != nil ? " with image" : "")")
                
                // Mark notification as grabbed (archive it)
                await MainActor.run {
                    if let notification = notification {
                        notificationCenter.archive(notification)
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
                    // Check if docket already exists before marking as completed
                    // If it exists, just remove the notification instead
                    if let docketNumber = updatedNotification.docketNumber,
                       let jobName = updatedNotification.jobName {
                        let docketName = "\(docketNumber)_\(jobName)"
                        if mediaManager.dockets.contains(docketName) {
                            // Docket already exists, remove notification instead of marking as completed
                            notificationCenter.remove(updatedNotification)
                            return
                        }
                    }
                    // Update notification status to completed
                    notificationCenter.updateStatus(updatedNotification, to: .completed)
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
        case .error:
            return "exclamationmark.triangle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
    
    private func colorForType(_ type: NotificationType) -> Color {
        switch type {
        case .newDocket:
            return .blue
        case .mediaFiles:
            return .orange // Different color for file deliveries
        case .error:
            return .red
        case .info:
            return .blue
        }
    }
    
    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    /// Check if a docket already exists in Work Picture
    private func docketExists(docketNumber: String, jobName: String) -> Bool {
        let docketName = "\(docketNumber)_\(jobName)"
        return mediaManager.dockets.contains(docketName)
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
        
        // Archive option
        if notification.status == .pending && notification.archivedAt == nil {
            Button(action: {
                notificationCenter.archive(notification)
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

