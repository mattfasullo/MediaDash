import SwiftUI

/// Expandable notification center view
struct NotificationCenterView: View {
    @ObservedObject var notificationCenter: NotificationCenter
    @ObservedObject var emailScanningService: EmailScanningService
    @ObservedObject var mediaManager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var isExpanded: Bool
    
    @State private var processingNotification: UUID?
    @State private var isScanningEmails = false
    @State private var lastScanStatus: String?
    @State private var debugInfo: String?
    @State private var showDebugInfo = false
    @State private var isArchivedExpanded = false
    
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
                EmailRefreshButton()
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
            
            // Notifications list - filter out completed notifications if docket already exists
            let activeNotifications = notificationCenter.activeNotifications.filter { notification in
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
                        // Also remove the notification from the center since it's no longer needed
                        DispatchQueue.main.async {
                            notificationCenter.remove(notification)
                        }
                    }
                    return !exists
                }
                // Show all other notifications
                return true
            }
            let archivedNotifications = notificationCenter.archivedNotifications
            
            if activeNotifications.isEmpty && archivedNotifications.isEmpty {
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
                ScrollView {
                    VStack(spacing: 0) {
                        // Active notifications
                        ForEach(activeNotifications) { notification in
                            NotificationRowView(
                                notificationId: notification.id,
                                notificationCenter: notificationCenter,
                                emailScanningService: emailScanningService,
                                mediaManager: mediaManager,
                                settingsManager: settingsManager,
                                processingNotification: $processingNotification
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            
                            Divider()
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
                                        processingNotification: $processingNotification
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
        }
        .frame(width: 400, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .clipShape(RoundedRectangle(cornerRadius: 12)) // Ensure content is clipped to rounded corners
        .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
        .onAppear {
            // Clean up old archived notifications
            notificationCenter.cleanupOldArchivedNotifications()
            
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
        debugMessages.append("  Gmail Query: \(settings.gmailQuery.isEmpty ? "(default)" : settings.gmailQuery)")
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
        
        // Build query
        let baseQuery = settings.gmailQuery.isEmpty || settings.gmailQuery == "subject:\"New Docket\"" 
            ? "label:\"New Docket\"" 
            : settings.gmailQuery
        let query = "\(baseQuery) is:unread"
        
        debugMessages.append("🔍 Query:")
        debugMessages.append("  Base: \(baseQuery)")
        debugMessages.append("  Full: \(query)")
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
                    let bodyPreview = (message.plainTextBody ?? message.htmlBody ?? "").prefix(300)
                    if !bodyPreview.isEmpty {
                        debugMessages.append("     Body preview: \(bodyPreview)...")
                    } else {
                        debugMessages.append("     Body: (empty)")
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
            
            for message in unreadMessages {
                if existingEmailIds.contains(message.id) {
                    skippedCount += 1
                    debugMessages.append("  ⏭️  Email \(message.id): Already has notification")
                    continue
                }
                
                // Try to process the email
                let success = await emailScanningService.processEmailAndCreateNotification(message)
                if success {
                    createdCount += 1
                    debugMessages.append("  ✅ Email \(message.id): Created notification")
                    debugMessages.append("     Subject: \(message.subject ?? "(no subject)")")
                } else {
                    failedCount += 1
                    debugMessages.append("  ❌ Email \(message.id): Failed to create notification")
                    debugMessages.append("     Subject: \(message.subject ?? "(no subject)")")
                    debugMessages.append("     (May not be a valid docket email or docket already exists)")
                }
            }
            
            debugMessages.append("")
            debugMessages.append("📊 Summary:")
            debugMessages.append("  Created: \(createdCount)")
            debugMessages.append("  Skipped: \(skippedCount)")
            debugMessages.append("  Failed: \(failedCount)")
            
            let finalCount = notificationCenter.notifications.count
            debugMessages.append("  ✅ Final notification count: \(finalCount)")
            
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
}

/// Individual notification row
struct NotificationRowView: View {
    let notificationId: UUID
    @ObservedObject var notificationCenter: NotificationCenter
    @ObservedObject var emailScanningService: EmailScanningService
    @ObservedObject var mediaManager: MediaManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var processingNotification: UUID?
    
    @StateObject private var simianService = SimianService()
    @State private var showActions = false
    @State private var showDocketInputDialog = false
    @State private var inputDocketNumber = ""
    @State private var isHovered = false
    @State private var showContextMenu = false
    @State private var isDocketInputForApproval = false // Track if dialog is for approval or just updating
    
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
            Group {
                if isHovered {
                    Color.blue.opacity(0.1)
                } else if notification.status == .pending {
                    Color.blue.opacity(0.05)
                } else {
                    Color.clear
                }
            }
        )
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
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
        .onTapGesture {
            // On click: if email exists, open it; otherwise show docket input if needed
            if let emailId = notification.emailId {
                openEmailInBrowser(emailId: emailId)
            } else if notification.type == .newDocket && (notification.docketNumber == nil || notification.docketNumber == "TBD") {
                isDocketInputForApproval = false // Just updating, not approving
                showDocketInputDialog = true
            }
        }
        .help(notification.emailId != nil ? "Click to open email in Gmail, right-click for more options" : (notification.docketNumber == nil || notification.docketNumber == "TBD" ? "Click to add docket number, right-click for more options" : "Click or right-click for options"))
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
                        try await simianService.createJob(docketNumber: finalDocketNumber, jobName: jobName)
                        print("✅ Simian job creation requested for \(finalDocketNumber): \(jobName)")
                    } catch {
                        // Log error but don't fail the whole approval process
                        print("⚠️ Failed to create Simian job: \(error.localizedDescription)")
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
        case .error:
            return .red
        case .info:
            return .orange
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

