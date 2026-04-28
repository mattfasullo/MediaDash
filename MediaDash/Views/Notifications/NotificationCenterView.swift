import SwiftUI
import AppKit
import Combine

// #region agent log
private func _debugLogWP(_ message: String, _ data: [String: Any], _ hypothesisId: String) {
    let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "NotificationCenterView", "message": message, "data": data, "sessionId": "debug-session", "hypothesisId": hypothesisId]
    guard let d = try? JSONSerialization.data(withJSONObject: payload), let line = String(data: d, encoding: .utf8) else { return }
    let path = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug.log"
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    guard let stream = OutputStream(url: url, append: true) else { return }
    stream.open()
    defer { stream.close() }
    let out = (line + "\n").data(using: .utf8)!
    _ = out.withUnsafeBytes { stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: out.count) }
}
// #endregion

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
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var airtableDocketScanningService: AirtableDocketScanningService
    @Binding var isExpanded: Bool
    @Binding var showSettings: Bool
    
    @State private var processingNotification: UUID?
    @State private var processingStatusById: [UUID: String] = [:]
    @State private var isScanningEmails = false
    @State private var lastScanStatus: String?
    @State private var debugInfo: String?
    @State private var showDebugInfo = false
    @State private var isArchivedExpanded = false
    @State private var isHistoryExpanded = false
    @State private var isFileDeliveriesExpanded = true // Default to expanded (keeping for archived section)
    @State private var cacheInfo: String?
    @State private var showCacheInfo = false
    @State private var isLoadingCache = false // Keep for fallback if file write fails
    
    // Computed properties for filtered notifications
    // Active notifications exclude completed ones (those go to history section)
    private var allActiveNotifications: [Notification] {
        notificationCenter.activeNotifications
    }
    
    private var activeNotifications: [Notification] {
        allActiveNotifications.filter { $0.type != .mediaFiles }
    }
    
    // All active notifications
    private var regularNotifications: [Notification] {
        return allActiveNotifications
    }
    
    /// New docket rows that still need user confirmation (no Gmail "New Docket" label).
    private var reviewNewDocketNotifications: [Notification] {
        regularNotifications.filter { $0.type == .newDocket && $0.status != .completed && $0.requiresDocketConfirmation == true }
    }

    /// Confirmed new docket notifications (excludes review queue and completed).
    private var confirmedNewDocketNotifications: [Notification] {
        let filtered = regularNotifications.filter { $0.type == .newDocket && $0.status != .completed && $0.requiresDocketConfirmation != true }
        if notificationCenter.unreadCount > 0 && filtered.isEmpty && reviewNewDocketNotifications.isEmpty {
            let allPending = notificationCenter.notifications.filter { $0.status == .pending }
            let allActive = notificationCenter.activeNotifications
            let allRegular = regularNotifications
            print("📋 [NotificationCenterView] DEBUG: unreadCount=\(notificationCenter.unreadCount), but confirmed/review new docket lists are empty")
            print("📋 [NotificationCenterView] DEBUG: Total notifications: \(notificationCenter.notifications.count)")
            print("📋 [NotificationCenterView] DEBUG: Pending notifications: \(allPending.count)")
            print("📋 [NotificationCenterView] DEBUG: Active notifications: \(allActive.count)")
            print("📋 [NotificationCenterView] DEBUG: Regular notifications: \(allRegular.count)")
            for (index, notif) in allPending.enumerated() {
                print("📋 [NotificationCenterView] DEBUG: Pending[\(index)]: id=\(notif.id), type=\(notif.type), status=\(notif.status), archivedAt=\(notif.archivedAt?.description ?? "nil"), docketNumber=\(notif.docketNumber ?? "nil")")
            }
        }
        return filtered
    }
    
    // Regular request notifications (including completed ones, which will be greyed out)
    private var regularRequestNotifications: [Notification] {
        allActiveNotifications.filter { $0.type == .request }
    }
    
    private var archivedNotifications: [Notification] {
        notificationCenter.archivedNotifications
    }
    
    // Completed docket notifications for history section (auto-clears after 48 hours)
    private var historyNotifications: [Notification] {
        notificationCenter.notifications.filter { 
            $0.type == .newDocket && $0.status == .completed 
        }.sorted { ($0.completedAt ?? $0.timestamp) > ($1.completedAt ?? $1.timestamp) }
    }
    
    var body: some View {
        mainContent
    }
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            headerSection
            
            Divider()
            
            if settingsManager.currentSettings.newDocketDetectionMode == .email {
                emailStatusBannerContent
            }
            
            emailModeContent
        }
        .frame(minWidth: 400, minHeight: 500)
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
        // Removed tab switching logic - only newDockets tab is available
        .onChange(of: settingsManager.currentSettings.simianAPIBaseURL) { _, _ in
            // Refresh when Simian API configuration changes
        }
        .onAppear {
            handleViewAppear()
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("New Dockets")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                if notificationCenter.unreadCount > 0 {
                    Text("\(notificationCenter.unreadCount)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                if settingsManager.currentSettings.newDocketDetectionMode == .email {
                    EmailRefreshButton(
                        notificationCenter: notificationCenter
                    )
                    .environmentObject(emailScanningService)
                    .environmentObject(settingsManager)
                } else {
                    AirtableDocketRefreshButton(
                        notificationCenter: notificationCenter
                    )
                    .environmentObject(airtableDocketScanningService)
                    .environmentObject(settingsManager)
                }
                
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
            
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
    }
    
    private var emailStatusBannerContent: some View {
        Group {
            let isGmailConnected = emailScanningService.gmailService.isAuthenticated
            let gmailEnabled = settingsManager.currentSettings.gmailEnabled
            
            if !gmailEnabled {
                gmailDisabledBanner
            } else if gmailEnabled && !isGmailConnected {
                gmailNotConnectedBanner
            } else if gmailEnabled && isGmailConnected, let retryAfter = emailScanningService.lastRateLimitRetryAfter, retryAfter > Date() {
                rateLimitBanner(retryAfter: retryAfter)
            }
        }
    }
    
    /// Banner shown when Gmail API rate limit is active, with live countdown
    private func rateLimitBanner(retryAfter: Date) -> some View {
        RateLimitCountdownView(retryAfter: retryAfter, emailScanningService: emailScanningService)
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
                    Text("Gmail is off or not connected. Enable Gmail in Settings when using Email detection for new dockets.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Settings") {
                    SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
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
                    SettingsWindowManager.shared.show(settingsManager: settingsManager, sessionManager: sessionManager)
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
    
    private var emailModeContent: some View {
        Group {
            // Any non-email mode (including nil → treated as Airtable after defaults) skips Gmail gatekeeping.
            if settingsManager.currentSettings.newDocketDetectionMode != .email {
                if activeNotifications.isEmpty {
                    noNotificationsEmptyState
                } else {
                    notificationListContent
                }
            } else {
                let isGmailConnected = emailScanningService.gmailService.isAuthenticated
                let gmailEnabled = settingsManager.currentSettings.gmailEnabled

                if gmailEnabled && !isGmailConnected {
                    gmailNotConnectedEmptyState
                } else if !gmailEnabled && activeNotifications.isEmpty {
                    gmailDisabledEmptyState
                } else if activeNotifications.isEmpty {
                    noNotificationsEmptyState
                } else {
                    notificationListContent
                }
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
                Text(settingsManager.currentSettings.newDocketDetectionMode == .email
                     ? "Scanning for unread emails..."
                     : "Checking Airtable for new dockets...")
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
                
                Button(action: triggerManualScan) {
                    Label("Scan for new dockets", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private var notificationListContent: some View {
        VStack(spacing: 0) {
            // Content - no tabs needed since we only show new dockets
            ScrollView {
                VStack(spacing: 0) {
                    if !reviewNewDocketNotifications.isEmpty {
                        HStack {
                            Text("Needs review")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.orange)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                        ForEach(reviewNewDocketNotifications) { notification in
                            NotificationRowView(
                                notificationId: notification.id,
                                notificationCenter: notificationCenter,
                                emailScanningService: emailScanningService,
                                mediaManager: mediaManager,
                                settingsManager: settingsManager,
                                processingNotification: $processingNotification,
                                processingStatusById: $processingStatusById,
                                debugInfo: $debugInfo,
                                showDebugInfo: $showDebugInfo
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                    if !confirmedNewDocketNotifications.isEmpty {
                        if !reviewNewDocketNotifications.isEmpty {
                            HStack {
                                Text("New dockets")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                        }
                        ForEach(confirmedNewDocketNotifications) { notification in
                            NotificationRowView(
                                notificationId: notification.id,
                                notificationCenter: notificationCenter,
                                emailScanningService: emailScanningService,
                                mediaManager: mediaManager,
                                settingsManager: settingsManager,
                                processingNotification: $processingNotification,
                                processingStatusById: $processingStatusById,
                                debugInfo: $debugInfo,
                                showDebugInfo: $showDebugInfo
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            
                            Divider()
                        }
                    }
                    if reviewNewDocketNotifications.isEmpty && confirmedNewDocketNotifications.isEmpty {
                        // Empty state - no new docket notifications
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("No new docket notifications")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Button(action: triggerManualScan) {
                                Label("Scan for new dockets", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .padding(.top, 4)
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
                                processingStatusById: $processingStatusById,
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
                
                // History section (completed dockets, auto-clears after 48 hours)
                if !historyNotifications.isEmpty {
                    Divider()
                    
                    Button(action: {
                        withAnimation {
                            isHistoryExpanded.toggle()
                        }
                    }) {
                        HStack {
                            Image(systemName: isHistoryExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                            Text("History (\(historyNotifications.count))")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Clears in 48h")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    
                    if isHistoryExpanded {
                        ForEach(historyNotifications) { notification in
                            historyRowView(notification)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                            
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
                        // Clearing notifications should allow a true re-scan from sources.
                        emailScanningService.clearProcessedEmails()
                        airtableDocketScanningService.clearSeenRecords()
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
    
    // History row for completed notifications
    @ViewBuilder
    private func historyRowView(_ notification: Notification) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title row
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                
                Text(notification.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Time since completion
                if let completedAt = notification.completedAt {
                    Text(timeAgo(completedAt))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            // What was created
            if let historyNote = notification.historyNote {
                HStack(spacing: 4) {
                    // Show icons based on what was created
                    if historyNote.contains("Work Picture") {
                        if historyNote.contains("Work Picture failed") {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        } else {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                        }
                    }
                    
                    if historyNote.contains("Simian") {
                        if historyNote.contains("Simian failed") {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        } else {
                            Image(systemName: "s.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Text(historyNote)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            // Docket info
            if let docketNumber = notification.docketNumber, let jobName = notification.jobName {
                Text("\(docketNumber)_\(jobName)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(.vertical, 4)
        .opacity(0.8)
    }
    
    // Helper to format time ago
    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
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
        // Move cleanup operations to async Task to avoid modifying @Published properties during view update
        Task { @MainActor in
            notificationCenter.cleanupOldArchivedNotifications()
            notificationCenter.cleanupOldCompletedRequests()
            await notificationCenter.syncCompletionStatus()
            await emailScanningService.refreshDuplicateIndicatorsForActiveNotifications()
        }
        
        autoFetchEmail()
    }
    
    private func autoFetchEmail() {
        if settingsManager.currentSettings.newDocketDetectionMode != .email {
            return
        }
        let timeSinceLastScan = emailScanningService.lastScanTime.map { Date().timeIntervalSince($0) } ?? Double.infinity
        let scanThreshold: TimeInterval = 30
        let shouldAutoScan = timeSinceLastScan > scanThreshold
        
        if shouldAutoScan {
            Task {
                isScanningEmails = true
                lastScanStatus = nil
                await emailScanningService.scanUnreadEmails(forceRescan: false)
                isScanningEmails = false
                
                if let retryAfter = emailScanningService.lastRateLimitRetryAfter, retryAfter > Date() {
                    lastScanStatus = emailScanningService.lastError ?? "Scan skipped (rate limited). Use the timer above."
                } else {
                    let activeCount = notificationCenter.activeNotifications.count
                    if activeCount == 0 {
                        lastScanStatus = "No unread docket emails found"
                    } else {
                        lastScanStatus = "Found \(activeCount) notification\(activeCount == 1 ? "" : "s")"
                    }
                }
            }
        } else {
            let timeAgo = Int(timeSinceLastScan)
            if timeAgo < 60 {
                lastScanStatus = "Last scan: \(timeAgo)s ago"
            } else {
                let minutesAgo = timeAgo / 60
                lastScanStatus = "Last scan: \(minutesAgo)m ago"
            }
        }
    }
    
    /// Manual refresh: Gmail inbox (email mode) or Airtable poll (Airtable mode).
    private func triggerManualScan() {
        guard !isScanningEmails else { return }
        if settingsManager.currentSettings.newDocketDetectionMode != .email {
            Task {
                isScanningEmails = true
                lastScanStatus = nil
                await airtableDocketScanningService.scanNow()
                isScanningEmails = false
                if let err = airtableDocketScanningService.lastError, !err.isEmpty {
                    lastScanStatus = err
                } else {
                    let n = notificationCenter.activeNotifications.count
                    lastScanStatus = n == 0
                        ? "No pending new dockets"
                        : "\(n) new docket\(n == 1 ? "" : "s") in the list"
                }
            }
            return
        }
        Task {
            isScanningEmails = true
            lastScanStatus = nil
            await emailScanningService.scanUnreadEmails(forceRescan: true)
            isScanningEmails = false
            if let retryAfter = emailScanningService.lastRateLimitRetryAfter, retryAfter > Date() {
                lastScanStatus = emailScanningService.lastError ?? "Scan skipped (rate limited)."
            } else {
                let activeCount = notificationCenter.activeNotifications.count
                if activeCount == 0 {
                    lastScanStatus = "No new docket emails found"
                } else {
                    lastScanStatus = "Found \(activeCount) notification\(activeCount == 1 ? "" : "s")"
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
        
        debugMessages.append("ℹ️ Gmail API is only used for new docket search.")
        debugMessages.append("   This debug panel does not fetch emails (no extra API calls).")
        debugMessages.append("   Use \"Scan for new dockets\" to run the real scan.")
        debugMessages.append("")
        debugMessages.append("🔔 Current notifications: \(notificationCenter.notifications.count)")
        
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
    @Binding var processingStatusById: [UUID: String]
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
        guard updatedNotification.requiresDocketConfirmation != true else {
            print("⚠️ createSimianProject blocked: notification still requires docket confirmation")
            await MainActor.run {
                processingNotification = nil
                processingStatusById[notificationId] = nil
            }
            return
        }
        
        // Update notification with the job name and docket number from dialog
        notificationCenter.updateJobName(updatedNotification, to: jobName)
        if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
            updatedNotification = currentNotification
        }
        
        notificationCenter.updateDocketNumber(updatedNotification, to: docketNumber)
        if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
            updatedNotification = currentNotification
        }
        
        let shouldCreateSimian = updatedNotification.shouldCreateSimianJob || 
            (settingsManager.currentSettings.simianEnabled && simianService.isConfigured)
        let shouldCreateWorkPicture = updatedNotification.shouldCreateWorkPicture
        
        // If docket was found in Asana, use Asana's name for WP and Simian so we don't create duplicates with different spelling
        let existenceInfo = checkDocketExistence(docketNumber: docketNumber, jobName: jobName)
        let (effectiveDocketNumber, effectiveJobName): (String, String) = {
            if existenceInfo.existsInAsana, let asana = existenceInfo.asanaDocketInfo {
                return (asana.number, asana.jobName)
            }
            return (docketNumber, jobName)
        }()
        
        print("🔔 createSimianProject: shouldCreateSimian = \(shouldCreateSimian), shouldCreateWorkPicture = \(shouldCreateWorkPicture)")
        print("🔔 createSimianProject: notification.shouldCreateWorkPicture = \(updatedNotification.shouldCreateWorkPicture)")
        print("🔔 createSimianProject: notification.shouldCreateSimianJob = \(updatedNotification.shouldCreateSimianJob)")
        if effectiveDocketNumber != docketNumber || effectiveJobName != jobName {
            print("🔔 createSimianProject: Using Asana name for creation: \(effectiveDocketNumber)_\(effectiveJobName)")
        }
        
        let playAddingSound = settingsManager.currentSettings.resolvedSoundDocketAddingEnabled
        let playAddedSound = settingsManager.currentSettings.resolvedSoundDocketAddedEnabled
        let addingVolume = settingsManager.currentSettings.resolvedSoundDocketAddingVolume
        let addedVolume = settingsManager.currentSettings.resolvedSoundDocketAddedVolume
        await MainActor.run {
            DocketAddSounds.startLoading(enabled: playAddingSound, volume: addingVolume)
        }
        
        var simianError: Error?
        var workPictureError: Error?
        
        // Create Work Picture folder if requested (use Asana name when found so folder matches Asana)
        if shouldCreateWorkPicture {
            do {
                updateProcessingStatus(notificationId, "Creating Work Picture folder...")
                print("🔔 Creating Work Picture folder with docket: \(effectiveDocketNumber), job: \(effectiveJobName)")
                try await emailScanningService.createDocketFromNotification(
                    updatedNotification,
                    effectiveDocketNumber: effectiveDocketNumber,
                    effectiveJobName: effectiveJobName
                )
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
        
        // Create Simian project if requested (use Asana name when found so project matches Asana)
        if shouldCreateSimian {
            updateSimianServiceConfiguration()
            
            do {
                // Check if project already exists in Simian before creating
                updateProcessingStatus(notificationId, "Checking for existing Simian project...")
                let projectAlreadyExists = try await simianService.projectExists(docketNumber: effectiveDocketNumber, jobName: effectiveJobName)
                
                if projectAlreadyExists {
                    print("⚠️ Simian project already exists: \(effectiveDocketNumber)_\(effectiveJobName)")
                    await MainActor.run {
                        let errorNotification = Notification(
                            type: .error,
                            title: "Simian Project Already Exists",
                            message: "Project \(effectiveDocketNumber)_\(effectiveJobName) already exists in Simian"
                        )
                        notificationCenter.add(errorNotification)
                        
                        // Mark as in Simian (pre-existing, not created by us)
                        if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                            notificationCenter.markAsInSimian(currentNotification, createdByUs: false)
                        }
                    }
                } else {
                    updateProcessingStatus(notificationId, "Creating Simian project...")
                    print("🔔 Creating Simian project with docket: \(effectiveDocketNumber), job: \(effectiveJobName)")
                    try await simianService.createJob(
                        docketNumber: effectiveDocketNumber,
                        jobName: effectiveJobName,
                        projectManager: projectManager,
                        projectTemplate: template ?? settingsManager.currentSettings.simianProjectTemplate
                    )
                    print("✅ Simian project created successfully")
                    
                    await MainActor.run {
                        if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                            notificationCenter.markAsInSimian(currentNotification, createdByUs: true)
                        }
                    }
                }
            } catch {
                print("❌ Simian project creation failed: \(error.localizedDescription)")
                simianError = error
            }
        }
        
        // Handle results and cleanup
        let wpCreationOK = !shouldCreateWorkPicture || workPictureError == nil
        let simCreationOK = !shouldCreateSimian || simianError == nil
        let attemptedCreation = shouldCreateWorkPicture || shouldCreateSimian
        await MainActor.run {
            DocketAddSounds.stopLoading()
            if attemptedCreation && wpCreationOK && simCreationOK {
                DocketAddSounds.playDocketAdded(enabled: playAddedSound, volume: addedVolume)
            }
            processingNotification = nil
            processingStatusById[notificationId] = nil
        }
        
        // Show error notifications if any failed
        if let wpError = workPictureError {
            await MainActor.run {
                let errorNotification = Notification(
                    type: .error,
                    title: "Work Picture Creation Failed",
                    message: wpError.localizedDescription
                )
                notificationCenter.add(errorNotification)
            }
        }
        
        if let simError = simianError {
            await MainActor.run {
                let errorNotification = Notification(
                    type: .error,
                    title: "Simian Project Creation Failed",
                    message: simError.localizedDescription
                )
                notificationCenter.add(errorNotification)
            }
        }
        
        // Mark email as read and track interaction
        if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
            // Mark email as read
            await markEmailAsReadIfNeeded(currentNotification)
            
            await MainActor.run {
                
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
                
                // Close dialog
                showSimianProjectDialog = false
                
                // Build history note based on what was created/failed
                var historyParts: [String] = []
                
                if shouldCreateWorkPicture {
                    if workPictureError == nil {
                        historyParts.append("Created in Work Picture")
                    } else {
                        historyParts.append("Work Picture failed")
                    }
                }
                
                if shouldCreateSimian {
                    if simianError == nil {
                        historyParts.append("Created in Simian")
                    } else {
                        historyParts.append("Simian failed")
                    }
                }
                
                let historyNote = historyParts.isEmpty ? "Approved" : historyParts.joined(separator: " • ")
                
                // Mark as completed instead of removing (moves to history)
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 second delay
                    if let finalNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                        notificationCenter.markAsCompleted(finalNotification, historyNote: historyNote)
                        print("✅ Marked notification as completed: \(historyNote)")
                    }
                }
            }
        }
    }
    
    var body: some View {
        // Guard to ensure notification exists
        guard let notification = notification else {
            // Log when notification is missing but count shows it exists
            print("📋 NotificationRowView: ⚠️ Notification \(notificationId) not found in list but count shows notifications exist")
            print("📋 NotificationRowView: Total notifications: \(notificationCenter.notifications.count), Unread count: \(notificationCenter.unreadCount)")
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
                        if notification.type == .request && notification.status == .completed {
                            Color.gray.opacity(0.1)
                        } else {
                            Color.blue.opacity(0.1)
                        }
                    } else if notification.status == .pending {
                        Color.blue.opacity(0.05)
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
        .sheet(isPresented: $showDocketInputDialog, onDismiss: {
            // When dialog is dismissed (cancelled), reset the approval flag
            // This ensures the notification remains visible and isn't removed
            print("📋 NotificationRowView: Dialog dismissed (cancelled) - preserving notification \(notificationId)")
            isDocketInputForApproval = false
            inputDocketNumber = ""
            
            // Ensure notification still exists and is visible
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                print("📋 NotificationRowView: ✅ Notification \(notificationId) still exists after cancel (status: \(currentNotification.status))")
            } else {
                print("📋 NotificationRowView: ❌ WARNING - Notification \(notificationId) was removed after cancel!")
            }
        }) {
            DocketNumberInputDialog(
                isPresented: $showDocketInputDialog,
                docketNumber: $inputDocketNumber,
                jobName: notification.jobName ?? "Unknown",
                onConfirm: {
                    // If this is from the Approve button, approve and create docket
                    // Otherwise, just update the docket number
                    if isDocketInputForApproval {
                        if let n = notificationCenter.notifications.first(where: { $0.id == notificationId }),
                           n.requiresDocketConfirmation == true {
                            return
                        }
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
            .sheetBorder()
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
                    isSimianEnabled: isSimianEnabled,
                    onConfirm: { docketNumber, jobName, _, template in
                        Task {
                            await createSimianProject(
                                notificationId: notificationId,
                                docketNumber: docketNumber,
                                jobName: jobName,
                                projectManager: nil,
                                template: template
                            )
                        }
                    }
                )
                .sheetBorder()
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
                                // Dialog was cancelled - DON'T remove notification, just clear pending state
                                // The notification should remain visible so the user can try again
                                print("🔔 Simian dialog was cancelled - preserving notification so user can try again")
                                pendingSimianNotificationId = nil
                                pendingSimianDocketNumber = ""
                                pendingSimianJobName = ""
                                processingNotification = nil
                                return
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
                .sheetBorder()
            }
        }
        .sheet(isPresented: $showFeedbackDialog) {
            EmptyView() // Feedback removed
        }
    }
    
    /// Mark email as read if notification has an emailId
    private func markEmailAsReadIfNeeded(_ notification: Notification) async {
        guard let emailId = notification.emailId else {
            print("📧 NotificationCenterView: ⚠️ Cannot mark email as read - notification has no emailId")
            return
        }
        
        do {
            try await emailScanningService.gmailService.markAsRead(messageId: emailId)
            print("📧 NotificationCenterView: ✅ Successfully marked email \(emailId) as read")
        } catch {
            print("📧 NotificationCenterView: ❌ Failed to mark email \(emailId) as read: \(error.localizedDescription)")
            print("📧 NotificationCenterView: Error details: \(error)")
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
                Task {
                    await markEmailAsReadIfNeeded(updatedNotification)
                    await notificationCenter.remove(updatedNotification, emailScanningService: emailScanningService)
                    print("📋 NotificationCenterView: Removed notification after downvote")
                }
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
    
    /// Check if server (Work Picture path) is connected/accessible
    private var isServerConnected: Bool {
        let path = settingsManager.currentSettings.serverBasePath
        guard !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
    
    /// Check if Simian is configured and ready
    private var isSimianConnected: Bool {
        settingsManager.currentSettings.simianEnabled && simianService.isConfigured
    }
    
    /// Helper view for new docket actions
    @ViewBuilder
    private func newDocketActionsView(notification: Notification) -> some View {
        // Update duplicate detection flags
        let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) ?? notification
        
        // Check if folders exist in filesystem
        let existsInWorkPicture = checkIfInWorkPicture(notification: currentNotification)
        let existsInSimian = currentNotification.isInSimian
        
        // Only show "Already exists" if folder was PRE-EXISTING (not created by us)
        // workPictureCreatedByUs = true means WE just created it, so it's not "already" there
        let wasPreExistingInWorkPicture = existsInWorkPicture && !currentNotification.workPictureCreatedByUs
        let wasPreExistingInSimian = existsInSimian && !currentNotification.simianCreatedByUs
        let wasAddedToWorkPicture = existsInWorkPicture && currentNotification.workPictureCreatedByUs
        let wasAddedToSimian = existsInSimian && currentNotification.simianCreatedByUs
        
        // For disabling toggles, use the full existence check (including ones we created)
        let isInWorkPicture = existsInWorkPicture
        let isInSimian = existsInSimian
        
        // Disable toggles when not connected to that service
        let workPictureToggleDisabled = isInWorkPicture || !isServerConnected
        let simianToggleDisabled = isInSimian || !isSimianConnected
        let neitherConnected = !isServerConnected && !isSimianConnected
        
        VStack(alignment: .leading, spacing: 8) {
            if currentNotification.requiresDocketConfirmation == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This message was not tagged “New Docket” in Gmail. Confirm if it’s a real new docket or dismiss.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Button("Confirm new docket") {
                            notificationCenter.confirmDocketCandidate(currentNotification)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Not a docket") {
                            Task {
                                await notificationCenter.skip(currentNotification, emailScanningService: emailScanningService)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(6)
            }
            // Warning when not connected to either server or Simian
            if neitherConnected {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text("Not connected to the server or Simian. Connect in Settings to create dockets.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(6)
            }
            // Visual indicators for both pre-existing and newly created destinations
            if wasPreExistingInWorkPicture || wasPreExistingInSimian || wasAddedToWorkPicture || wasAddedToSimian {
                HStack(spacing: 8) {
                    if wasAddedToWorkPicture {
                        Button(action: {
                            openWorkPictureFolderForNotification(currentNotification)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                                Text("Added to Work Picture")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open this docket’s folder in Finder")
                    }
                    if wasPreExistingInWorkPicture {
                        Button(action: {
                            openWorkPictureFolderForNotification(currentNotification)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                                Text("Already in Work Picture")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open this docket’s folder in Finder")
                    }
                    if wasPreExistingInSimian {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                            Text("Already in Simian")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    if wasAddedToSimian {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.blue)
                            Text("Added to Simian")
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
                .disabled(workPictureToggleDisabled)
                .opacity(workPictureToggleDisabled ? 0.5 : 1.0)
            
            Toggle("Create Simian Job", isOn: simianJobBinding())
                .font(.system(size: 11))
                .disabled(simianToggleDisabled)
                .opacity(simianToggleDisabled ? 0.5 : 1.0)
            
            if processingNotification == notificationId {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text(processingStatusById[notificationId] ?? "Processing approval...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
            
            approveArchiveButtons(
                notification: currentNotification,
                hideApprove: wasPreExistingInWorkPicture && wasPreExistingInSimian
            )
        }
        .padding(.top, 4)
        .onAppear {
            // #region agent log
            _debugLogWP("newDocketActionsView WP state", ["existsInWorkPicture_live": checkIfInWorkPicture(notification: currentNotification), "isInWorkPicture_stored": currentNotification.isInWorkPicture, "docketNumber": currentNotification.docketNumber ?? "", "jobName": currentNotification.jobName ?? ""], "H4")
            // #endregion
            // Update duplicate detection when view appears
            if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                notificationCenter.updateDuplicateDetection(currentNotification, mediaManager: mediaManager, settingsManager: settingsManager)
            }
            // Update Simian service configuration first, then pre-load users if Simian is enabled
            updateSimianServiceConfiguration()
        }
    }
    
    /// True only when the docket folder exists in Work Picture on disk (not Asana-only).
    private func checkIfInWorkPicture(notification: Notification) -> Bool {
        if let docketNumber = notification.docketNumber, docketNumber != "TBD",
           let jobName = notification.jobName {
            let info = checkDocketExistence(docketNumber: docketNumber, jobName: jobName)
            return info.existsInWorkPicture
        }
        return false
    }
    
    /// Open the Work Picture folder for this docket in Finder. If the exact docket folder is found (by year), open it; otherwise open the current year’s Work Picture root.
    private func openWorkPictureFolderForNotification(_ notification: Notification) {
        guard let docketNumber = notification.docketNumber, docketNumber != "TBD",
              let jobName = notification.jobName else { return }
        let docketName = "\(docketNumber)_\(jobName)"
        let config = AppConfig(settings: settingsManager.currentSettings)
        let url: URL
        if let year = config.findDocketYear(docket: docketName) {
            url = config.getWorkPicPath(for: year).appendingPathComponent(docketName)
        } else {
            url = config.getPaths().workPic
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
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
            get: {
                guard isServerConnected else { return false }
                return notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateWorkPicture ?? true
            },
            set: { newValue in
                guard isServerConnected else { return }
                if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                    notificationCenter.updateActionFlags(currentNotification, workPicture: newValue)
                }
            }
        )
    }
    
    private func simianJobBinding() -> Binding<Bool> {
        Binding(
            get: {
                guard isSimianConnected else { return false }
                return notificationCenter.notifications.first(where: { $0.id == notificationId })?.shouldCreateSimianJob ?? true
            },
            set: { newValue in
                guard isSimianConnected else { return }
                if let currentNotification = notificationCenter.notifications.first(where: { $0.id == notificationId }) {
                    notificationCenter.updateActionFlags(currentNotification, simianJob: newValue)
                }
            }
        )
    }
    
    /// Extract email address from sourceEmail string (handles "Name <email@example.com>" format)
    private func extractEmailAddress(from sourceEmail: String) -> String {
        // Check if it's in format "Name <email@example.com>"
        if let regex = try? NSRegularExpression(pattern: #"<([^>]+)>"#, options: []),
           let match = regex.firstMatch(in: sourceEmail, range: NSRange(sourceEmail.startIndex..., in: sourceEmail)),
           match.numberOfRanges >= 2 {
            let emailRange = Range(match.range(at: 1), in: sourceEmail)!
            return String(sourceEmail[emailRange]).trimmingCharacters(in: .whitespaces)
        }
        
        // If no angle brackets, check if it's just an email
        if let regex = try? NSRegularExpression(pattern: #"([^\s<>]+@[^\s<>]+)"#, options: []),
           let match = regex.firstMatch(in: sourceEmail, range: NSRange(sourceEmail.startIndex..., in: sourceEmail)),
           match.numberOfRanges >= 2 {
            let emailRange = Range(match.range(at: 1), in: sourceEmail)!
            return String(sourceEmail[emailRange]).trimmingCharacters(in: .whitespaces)
        }
        
        // Fallback: return as-is (might already be just an email)
        return sourceEmail.trimmingCharacters(in: .whitespaces)
    }
    
    
    @ViewBuilder
    private func approveArchiveButtons(notification: Notification, hideApprove: Bool) -> some View {
        let awaitingReviewConfirmation = notification.requiresDocketConfirmation == true
        HStack(spacing: 8) {
            if !hideApprove {
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
                .disabled(processingNotification == notificationId || awaitingReviewConfirmation)
                .help(awaitingReviewConfirmation ? "Confirm this is a new docket using the banner above before approving." : "Approve and create Work Picture / Simian as selected")
            }
            
            Group {
                if hideApprove {
                    Button("Remove") {
                        Task {
                            await notificationCenter.remove(notification, emailScanningService: emailScanningService)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Remove") {
                        Task {
                            await notificationCenter.remove(notification, emailScanningService: emailScanningService)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .disabled(processingNotification == notificationId)
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
            
            if notification.status == .pending {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
            }
        }
    }
    
    /// Helper view for notification content based on type
    @ViewBuilder
    private func notificationContentView(notification: Notification) -> some View {
        if notification.type == .newDocket {
            newDocketContentView(notification: notification)
        } else if notification.type == .request {
            requestContentView(notification: notification)
        } else {
            Text(notification.message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
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
                    
                    if existenceInfo.existsInAsana {
                        docketAsanaExistenceChip(existenceInfo: existenceInfo)
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
    
    /// Asana match chip only — Work Picture / Simian status is shown in the row below (Already in Work Picture / Simian).
    @ViewBuilder
    private func docketAsanaExistenceChip(existenceInfo: DocketExistenceInfo) -> some View {
        HStack(spacing: 6) {
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
        guard currentNotification.requiresDocketConfirmation != true else {
            return
        }
        
        // Check if docket number is missing
        if currentNotification.docketNumber == nil || currentNotification.docketNumber == "TBD" {
            isDocketInputForApproval = true
            showDocketInputDialog = true
            return
        }
        
        guard let docketNumber = currentNotification.docketNumber, docketNumber != "TBD" else {
            return
        }
        
        // Check if docket already exists in current year's Work Picture (only if creating Work Picture)
        // Allow creation in Simian even if it exists in Work Picture, and vice versa
        let docketName = "\(docketNumber)_\(jobName)"
        if currentNotification.shouldCreateWorkPicture && docketExistsInCurrentWorkPicture(docketName) {
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
        guard currentNotification.requiresDocketConfirmation != true else {
            await MainActor.run {
                processingNotification = nil
                processingStatusById[notificationId] = nil
            }
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
        
        // Check if docket already exists in current year's Work Picture before creating Work Picture folder
        // Note: We only check Work Picture here - Simian creation is independent
        let docketName = "\(finalDocketNumber)_\(jobName)"
        if docketExistsInCurrentWorkPicture(docketName) {
            // Only prevent if user wants to create Work Picture folder
            // Check the notification's shouldCreateWorkPicture flag
            if currentNotification.shouldCreateWorkPicture {
                await MainActor.run {
                    processingNotification = nil
                    processingStatusById[notificationId] = nil
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
        updateProcessingStatus(notificationId, "Preparing approval...")
        
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
                processingStatusById[notificationId] = nil
            }
            await markEmailAsReadIfNeeded(updatedNotification)
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

    @MainActor
    private func updateProcessingStatus(_ notificationId: UUID, _ status: String) {
        processingStatusById[notificationId] = status
    }

    private func docketExistsInCurrentWorkPicture(_ docketName: String) -> Bool {
        let config = AppConfig(settings: settingsManager.currentSettings)
        let workPicPath = config.getPaths().workPic.appendingPathComponent(docketName)
        return FileManager.default.fileExists(atPath: workPicPath.path)
    }
    
    /// Comprehensive check of where a docket exists across all known databases
    /// Note: This function is called from within view body, so it must NOT trigger any @Published updates
    /// Work Picture: we check the filesystem directly (same as "Open in Finder") so the badge and open action stay in sync.
    private func checkDocketExistence(docketNumber: String, jobName: String) -> DocketExistenceInfo {
        var info = DocketExistenceInfo()
        
        // Check Work Picture via filesystem (same logic as openWorkPictureFolderForNotification)
        let docketName = "\(docketNumber)_\(jobName)"
        let config = AppConfig(settings: settingsManager.currentSettings)
        let serverBase = settingsManager.currentSettings.serverBasePath
        let foundYear = config.findDocketYear(docket: docketName)
        let prefixMatchInLoadedDockets = DocketDuplicateDetection.workPictureContainsDocketNumber(
            docketNumber,
            dockets: mediaManager.dockets
        )
        if foundYear != nil || prefixMatchInLoadedDockets {
            info.existsInWorkPicture = true
        }
        // #region agent log
        _debugLogWP("checkDocketExistence", ["docketNumber": docketNumber, "jobName": jobName, "docketName": docketName, "foundYear": foundYear as Any, "existsInWorkPicture": info.existsInWorkPicture, "serverBasePath": serverBase], "H1")
        _debugLogWP("checkDocketExistence path", ["serverBasePath": serverBase, "workPictureFolderName": settingsManager.currentSettings.workPictureFolderName], "H2")
        // #endregion
        
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

// MARK: - Rate limit countdown (Timer-based to avoid TimelineView name collision)
private struct RateLimitCountdownView: View {
    let retryAfter: Date
    weak var emailScanningService: EmailScanningService?
    @State private var now = Date()
    
    private func rateLimitCountdownText(remaining: TimeInterval, retryAfter date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let timeStr = formatter.string(from: date)
        if remaining > 0 {
            let mins = Int(remaining) / 60
            let secs = Int(remaining) % 60
            if mins > 0 {
                return "Try again in \(mins)m \(secs)s (after \(timeStr))"
            } else {
                return "Try again in \(secs)s (after \(timeStr))"
            }
        } else {
            return "You can scan again now"
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gmail rate limit")
                        .font(.system(size: 12, weight: .medium))
                    Text(rateLimitCountdownText(remaining: max(0, retryAfter.timeIntervalSince(now)), retryAfter: retryAfter))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                now = Date()
                if max(0, retryAfter.timeIntervalSince(now)) <= 0 {
                    emailScanningService?.clearExpiredRateLimitIfNeeded()
                }
            }
            .onAppear {
                now = Date()
            }
            
            Divider()
        }
    }
}


