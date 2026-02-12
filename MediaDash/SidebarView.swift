import SwiftUI
import AppKit
import Combine

struct SidebarView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.layoutMode) var layoutMode
    @Environment(\.windowSize) var windowSize
    
    /// Helper function to seed shared cache from local cache
    private func seedSharedCacheFromLocal(cacheManager: AsanaCacheManager, dockets: [DocketInfo]) async {
        // Get shared cache URL from settings
        let sharedURL = settingsManager.currentSettings.sharedCacheURL
        
        guard let sharedURL = sharedURL, !sharedURL.isEmpty else {
            // DEBUG: Commented out for performance
            // print("⚠️ [Cache] No shared cache URL configured in settings")
            return
        }
        
        do {
            try await cacheManager.saveToSharedCache(dockets: dockets, url: sharedURL)
            // DEBUG: Commented out for performance
            // print("🟢 [Cache] Successfully created shared cache from local cache")
        } catch {
            // DEBUG: Commented out for performance
            // print("⚠️ [Cache] Failed to create shared cache: \(error.localizedDescription)")
        }
    }
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var emailScanningService: EmailScanningService
    @EnvironmentObject var manager: MediaManager
    @ObservedObject private var keyboardFocus = MainWindowKeyboardFocus.shared
    var focusedButton: FocusState<ActionButtonFocus?>.Binding
    var mainViewFocused: FocusState<Bool>.Binding
    @Binding var isKeyboardMode: Bool
    @Binding var isCommandKeyHeld: Bool
    @Binding var hoverInfo: String
    @Binding var showSearchSheet: Bool
    @Binding var showQuickSearchSheet: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showVideoConverterSheet: Bool
    var notificationCenter: NotificationCenter?
    @Binding var showNotificationCenter: Bool
    
    let wpDate: Date
    let prepDate: Date
    let dateFormatter: DateFormatter
    let attempt: (JobType) -> Void
    let cacheManager: AsanaCacheManager?
    var onPrepElementsFromCalendar: ((DocketInfo) -> Void)?
    /// Right-click File → "File + Prep": file then open prep for matching session.
    var onFileThenPrep: (() -> Void)? = nil
    /// Open Prep window (sessions, today + 5 business days).
    var onOpenPrep: (() -> Void)? = nil
    /// Open full 2-week Asana calendar view.
    var onOpenFullCalendar: (() -> Void)? = nil
    /// Open Portal sheet (media layups hub).
    var onOpenPortal: (() -> Void)? = nil

    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
    }
    
    // Sidebar width - fixed for compact mode only
    private var sidebarWidth: CGFloat {
        return 300 // Fixed width for compact mode
    }
    
    private var logoImage: some View {
        let baseLogo = Image("HeaderLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 60)
        
        if colorScheme == .light {
            return AnyView(baseLogo.colorInvert())
        } else {
            return AnyView(baseLogo)
        }
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Background that extends to top
            currentTheme.sidebarBackground
                .ignoresSafeArea(.all, edges: .top)
            
            VStack(alignment: .leading, spacing: 12) {
                // App Logo
                logoImage
                    .rotationEffect(.degrees(0))
                    .shadow(color: .clear, radius: 5, x: 2, y: 2)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)

                // Info Hub: Notification Tab + Status Indicators
                if let notificationCenter = notificationCenter {
                    HStack(spacing: 8) {
                        NotificationTabButton(
                            notificationCenter: notificationCenter,
                            showNotificationCenter: $showNotificationCenter
                        )
                        
                        if let cacheManager = cacheManager {
                            ServerStatusIndicator(
                                cacheManager: cacheManager,
                                showSettings: $showSettingsSheet
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                // MARK: Action Buttons Grid
                ActionButtonsView(
                    focusedButton: focusedButton,
                    mainViewFocused: mainViewFocused,
                    isKeyboardMode: $isKeyboardMode,
                    isCommandKeyHeld: $isCommandKeyHeld,
                    hoverInfo: $hoverInfo,
                    showVideoConverterSheet: $showVideoConverterSheet,
                    wpDate: wpDate,
                    prepDate: prepDate,
                    dateFormatter: dateFormatter,
                    attempt: attempt,
                    cacheManager: cacheManager ?? AsanaCacheManager(),
                    onOpenPrep: {
                        if let cm = cacheManager {
                            AsanaCalendarWindowManager.shared.show(
                                cacheManager: cm,
                                settingsManager: settingsManager,
                                onPrepElements: onPrepElementsFromCalendar
                            )
                        }
                    },
                    onOpenFullCalendar: onOpenFullCalendar ?? {
                        if let cm = cacheManager {
                            AsanaFullCalendarWindowManager.shared.show(
                                cacheManager: cm,
                                settingsManager: settingsManager,
                                onPrepElements: onPrepElementsFromCalendar
                            )
                        }
                    },
                    onFileThenPrep: onFileThenPrep,
                    onOpenPortal: onOpenPortal ?? {}
                )
                .draggableLayout(id: "actionButtons")

                Spacer()

                Divider()

                // Bottom actions
                VStack(spacing: 8) {
                    FocusableNavButton(
                        icon: "magnifyingglass",
                        title: "Search",
                        shortcut: "⌘F",
                        isFocused: keyboardFocus.focusedButton == .search,
                        showShortcut: isCommandKeyHeld,
                        action: { showSearchSheet = true }
                    )
                    .focused(focusedButton, equals: .search)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton.wrappedValue = nil
                            mainViewFocused.wrappedValue = true
                            isKeyboardMode = false
                        }
                    }
                    .keyboardShortcut("f", modifiers: .command)

                    FocusableNavButton(
                        icon: "number.circle",
                        title: "Job Info",
                        shortcut: "⌘D",
                        isFocused: keyboardFocus.focusedButton == .jobInfo,
                        showShortcut: isCommandKeyHeld,
                        action: { showQuickSearchSheet = true }
                    )
                    .focused(focusedButton, equals: .jobInfo)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton.wrappedValue = nil
                            mainViewFocused.wrappedValue = true
                            isKeyboardMode = false
                        }
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    
                    FocusableNavButton(
                        icon: "archivebox",
                        title: "Archiver",
                        shortcut: "⌘⇧A",
                        isFocused: keyboardFocus.focusedButton == .archiver,
                        showShortcut: isCommandKeyHeld,
                        action: { SimianArchiverWindowManager.shared.show(settingsManager: settingsManager) }
                    )
                    .focused(focusedButton, equals: .archiver)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton.wrappedValue = nil
                            mainViewFocused.wrappedValue = true
                            isKeyboardMode = false
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Workspace Button (where log out button was)
                    if case .loggedIn(let profile) = sessionManager.authenticationState {
                        WorkspaceMenuButton(profile: profile, sessionManager: sessionManager)
                    }
                }
                .padding(.bottom, 12)
                .draggableLayout(id: "sidebarBottomActions")
            }
            .padding(16)
            .frame(width: 300)
            .background(currentTheme.sidebarBackground)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped() // Prevent overflow
            .animation(.easeInOut(duration: 0.2), value: layoutMode)

            // Staging area indicator (no toggle - always visible)
            HStack(spacing: 4) {
                // Blue dot indicator when staging area has items
                if !manager.selectedFiles.isEmpty {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
    }
}

// MARK: - Server Status Indicator

struct ServerStatusIndicator: View {
    @ObservedObject var cacheManager: AsanaCacheManager
    @Binding var showSettings: Bool
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var isHovered = false
    @State private var isProcessing = false
    @State private var pulsePhase: Double = 0.0
    @State private var showStatusPopover = false
    
    private var isServerConnected: Bool {
        switch cacheManager.cacheStatus {
        case .serverConnectedUsingShared, .serverConnectedNoCache:
            return true
        case .serverDisconnectedNoCache, .unknown:
            return false
        }
    }
    
    private var tooltipText: String {
        if isServerConnected {
            return "Server connected - Click for details"
        } else {
            return "Server disconnected - Click for details"
        }
    }
    
    var body: some View {
        Group {
            if isProcessing {
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 6, height: 6)
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
            } else {
                Image(systemName: isServerConnected ? "network" : "network.slash")
                    .font(.system(size: 11))
                    .foregroundColor(isServerConnected ? .green : .red)
            }
        }
        .frame(width: 28, height: 28) // Fixed square size to match notification button height
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(isHovered ? 0.15 : (isProcessing ? 0.2 : 0.08)))
        )
        .overlay(
            Group {
                if isProcessing {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.blue.opacity(0.4 + pulsePhase * 0.4), lineWidth: 1.5)
                }
            }
        )
        .onChange(of: isProcessing) { _, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulsePhase = 1.0
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    pulsePhase = 0.0
                }
            }
        }
        .help(isProcessing ? "Processing..." : tooltipText)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .popover(isPresented: $showStatusPopover, arrowEdge: .bottom) {
            ServerStatusPopover(
                cacheManager: cacheManager,
                showSettings: $showSettings,
                isProcessing: $isProcessing
            )
            .environmentObject(settingsManager)
            .frame(width: 350)
        }
        .onTapGesture {
            // Show status popover
            showStatusPopover = true
            // Refresh status when opening popover
            cacheManager.refreshCacheStatus()
        }
    }
}

// MARK: - Server Status Popover

struct ServerStatusPopover: View {
    @ObservedObject var cacheManager: AsanaCacheManager
    @Binding var showSettings: Bool
    @Binding var isProcessing: Bool
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var isConnecting = false
    @State private var showServerURLInput = false
    @State private var serverURLInput = ""
    @FocusState private var isServerURLFieldFocused: Bool
    @State private var isDialogOpen = false // Track if dialog is open to prevent parent updates from affecting it
    
    private var isServerConnected: Bool {
        switch cacheManager.cacheStatus {
        case .serverConnectedUsingShared, .serverConnectedNoCache:
            return true
        case .serverDisconnectedNoCache, .unknown:
            return false
        }
    }
    
    private var serverPath: String {
        // Show server connection URL if configured, otherwise show base path
        if let connectionURL = settingsManager.currentSettings.serverConnectionURL, !connectionURL.isEmpty {
            return connectionURL
        }
        return settingsManager.currentSettings.serverBasePath.isEmpty ? 
            "Not configured" : settingsManager.currentSettings.serverBasePath
    }
    
    private var cacheStateDescription: String {
        switch cacheManager.cacheStatus {
        case .serverConnectedUsingShared:
            return "Using shared cache"
        case .serverConnectedNoCache:
            return "No cache available"
        case .serverDisconnectedNoCache:
            return "Server disconnected, no cache"
        case .unknown:
            return "Status unknown"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: isServerConnected ? "network" : "network.slash")
                    .font(.system(size: 16))
                    .foregroundColor(isServerConnected ? .green : .red)
                
                Text("Server Status")
                    .font(.system(size: 14, weight: .semibold))
                
                Spacer()
                
                Circle()
                    .fill(isServerConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
            }
            
            Divider()
            
            // Connection Status
            VStack(alignment: .leading, spacing: 8) {
                Text("Connection")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                HStack {
                    Text(isServerConnected ? "Connected" : "Disconnected")
                        .font(.system(size: 12))
                        .foregroundColor(isServerConnected ? .green : .red)
                    Spacer()
                }
                
                Text(cacheStateDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            // Server Path
            VStack(alignment: .leading, spacing: 4) {
                Text("Server Path")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text(serverPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            // Test Result
            if let result = testResult {
                HStack(spacing: 6) {
                    Image(systemName: result.contains("✅") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(result.contains("✅") ? .green : .red)
                    Text(result)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
            }
            
            Divider()
            
            // Actions
            if !isServerConnected {
                let serverName = getServerDisplayName()
                Button(action: {
                    if let savedServer = settingsManager.currentSettings.serverConnectionURL, !savedServer.isEmpty {
                        // Use saved server URL
                        connectToServerURL(savedServer)
                    } else {
                        // No saved server, prompt for URL
                        connectToServer()
                    }
                }) {
                    HStack(spacing: 4) {
                        if isConnecting {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "link")
                                .font(.system(size: 10))
                        }
                        Text("Connect to \(serverName)")
                            .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isConnecting)
            }
            
            HStack(spacing: 8) {
                Button(action: {
                    testConnection()
                }) {
                    HStack(spacing: 4) {
                        if isTesting {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                        }
                        Text("Test Connection")
                            .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting || isConnecting)
                
                Button(action: {
                    // Allow changing server URL
                    if let savedServer = settingsManager.currentSettings.serverConnectionURL, !savedServer.isEmpty {
                        serverURLInput = savedServer
                    }
                    showServerURLInput = true
                }) {
                    Text(settingsManager.currentSettings.serverConnectionURL != nil ? "Change Server" : "Set Server")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button(action: {
                    showSettings = true
                }) {
                    Text("Settings")
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .sheet(isPresented: Binding(
            get: { showServerURLInput },
            set: { 
                showServerURLInput = $0
                isDialogOpen = $0
            }
        )) {
            ServerConnectionDialogView(
                serverURLInput: $serverURLInput,
                onConnect: {
                    connectToServerURL(serverURLInput)
                },
                onCancel: {
                    showServerURLInput = false
                    isDialogOpen = false
                    serverURLInput = ""
                }
            )
            .interactiveDismissDisabled() // Prevent accidental dismissal
        }
        .onChange(of: showServerURLInput) { oldValue, newValue in
            isDialogOpen = newValue
        }
    }
    
    private func connectToServer() {
        // Pre-fill with saved server URL if available
        if let savedServer = settingsManager.currentSettings.serverConnectionURL, !savedServer.isEmpty {
            serverURLInput = savedServer
        }
        showServerURLInput = true
    }
    
    private func getServerDisplayName() -> String {
        if let connectionURL = settingsManager.currentSettings.serverConnectionURL, !connectionURL.isEmpty {
            // Extract hostname/IP from URL for display
            var displayName = connectionURL
            if let url = URL(string: connectionURL) {
                displayName = url.host ?? connectionURL
            } else if connectionURL.hasPrefix("smb://") || connectionURL.hasPrefix("afp://") {
                displayName = String(connectionURL.dropFirst(6))
                if let slashIndex = displayName.firstIndex(of: "/") {
                    displayName = String(displayName[..<slashIndex])
                }
            }
            return displayName
        }
        return "Server"
    }
    
    private func connectToServerURL(_ urlString: String) {
        guard !urlString.isEmpty else {
            testResult = "❌ Server URL cannot be empty"
            showServerURLInput = false
            return
        }
        
        // Normalize the URL - add smb:// if no protocol specified
        var normalizedURL = urlString.trimmingCharacters(in: .whitespaces)
        if !normalizedURL.hasPrefix("smb://") && !normalizedURL.hasPrefix("afp://") && !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            // Assume SMB if no protocol
            normalizedURL = "smb://\(normalizedURL)"
        }
        
        guard let url = URL(string: normalizedURL) else {
            testResult = "❌ Invalid server URL format"
            showServerURLInput = false
            return
        }
        
        // Save the server URL to settings
        settingsManager.currentSettings.serverConnectionURL = normalizedURL
        settingsManager.saveCurrentProfile()
        
        // Update cache manager with new server connection URL
        cacheManager.updateCacheSettings(
            sharedCacheURL: settingsManager.currentSettings.sharedCacheURL,
            useSharedCache: settingsManager.currentSettings.useSharedCache,
            serverBasePath: settingsManager.currentSettings.serverBasePath,
            serverConnectionURL: normalizedURL
        )
        
        isConnecting = true
        testResult = nil
        showServerURLInput = false
        
        Task {
            // Open the server URL using NSWorkspace
            // This will trigger macOS's native connection dialog
            let success = NSWorkspace.shared.open(url)
            
            await MainActor.run {
                if success {
                    testResult = "✅ Connection dialog opened. Please authenticate to connect."
                    
                    // Wait a bit, then check if connection succeeded
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                        await MainActor.run {
                            cacheManager.refreshCacheStatus()
                            testConnection()
                            isConnecting = false
                        }
                    }
                } else {
                    testResult = "❌ Failed to open connection dialog"
                    isConnecting = false
                }
            }
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            // Test server connection
            let serverPath = settingsManager.currentSettings.serverBasePath
            let serverExists = !serverPath.isEmpty && FileManager.default.fileExists(atPath: serverPath)
            
            // Test shared cache if enabled
            var sharedCacheExists = false
            if settingsManager.currentSettings.useSharedCache {
                if let sharedURL = settingsManager.currentSettings.sharedCacheURL, !sharedURL.isEmpty {
                    // Convert string path to URL
                    let path = sharedURL.trimmingCharacters(in: .whitespaces)
                    var fileURL: URL
                    if path.hasPrefix("file://") {
                        fileURL = URL(string: path) ?? URL(fileURLWithPath: path)
                    } else {
                        fileURL = URL(fileURLWithPath: path)
                    }
                    
                    // If path doesn't end with .json, assume it's a directory and append cache filename
                    if !fileURL.lastPathComponent.hasSuffix(".json") {
                        fileURL = fileURL.appendingPathComponent("mediadash_docket_cache.json")
                    }
                    
                    sharedCacheExists = FileManager.default.fileExists(atPath: fileURL.path)
                }
            }
            
            // Test local cache
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let appFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
            let localCachePath = appFolder.appendingPathComponent("mediadash_docket_cache.json").path
            let localCacheExists = FileManager.default.fileExists(atPath: localCachePath)
            
            // Refresh status
            await MainActor.run {
                cacheManager.refreshCacheStatus()
            }
            
            // Build result message
            var results: [String] = []
            if serverExists {
                results.append("✅ Server accessible")
            } else {
                results.append("❌ Server not accessible")
            }
            
            if settingsManager.currentSettings.useSharedCache {
                if sharedCacheExists {
                    results.append("✅ Shared cache found")
                } else {
                    results.append("❌ Shared cache not found")
                }
            }
            
            if localCacheExists {
                results.append("✅ Local cache found")
            } else {
                results.append("❌ Local cache not found")
            }
            
            await MainActor.run {
                testResult = results.joined(separator: "\n")
                isTesting = false
            }
        }
    }
}

// MARK: - Server Connection Dialog

struct ServerConnectionDialogView: View {
    @Binding var serverURLInput: String
    let onConnect: () -> Void
    let onCancel: () -> Void
    @FocusState private var isServerURLFieldFocused: Bool
    @State private var focusRestoreTask: DispatchWorkItem?
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Connect to Server")
                .font(.headline)
            
            Text("Enter server URL (e.g., 192.168.200.200 or smb://192.168.200.200). This will be saved for future connections.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            TextField("192.168.200.200 or smb://server/share", text: $serverURLInput)
                .textFieldStyle(.roundedBorder)
                .focused($isServerURLFieldFocused)
                .onSubmit {
                    if !serverURLInput.isEmpty {
                        onConnect()
                    }
                }
            
            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                
                Button("Connect", action: onConnect)
                    .buttonStyle(.borderedProminent)
                    .disabled(serverURLInput.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400, height: 180)
        .onAppear {
            // Focus the text field when sheet appears - use longer delay to ensure sheet is fully presented
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isServerURLFieldFocused = true
            }
        }
        .onChange(of: isServerURLFieldFocused) { oldValue, newValue in
            // If focus is lost while dialog is still visible, restore it
            if !newValue && oldValue {
                // Cancel any pending restore task
                focusRestoreTask?.cancel()
                
                // Create new restore task
                let task = DispatchWorkItem {
                    isServerURLFieldFocused = true
                }
                focusRestoreTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
            }
        }
        .onDisappear {
            focusRestoreTask?.cancel()
            isServerURLFieldFocused = false
        }
    }
}

// MARK: - Removed components

// MARK: - Right-Clickable Button Helper

struct RightClickableButton<Content: View>: NSViewRepresentable {
    let action: () -> Void
    let rightClickAction: () -> Void
    let content: Content
    
    init(action: @escaping () -> Void, rightClickAction: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.rightClickAction = rightClickAction
        self.content = content()
    }
    
    func makeNSView(context: Context) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        
        // Add click gesture recognizer for left-click
        let clickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        clickGesture.buttonMask = 0x1 // Left button
        hostingView.addGestureRecognizer(clickGesture)
        
        // Add right-click gesture recognizer
        let rightClickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRightClick(_:)))
        rightClickGesture.buttonMask = 0x2 // Right button
        hostingView.addGestureRecognizer(rightClickGesture)
        
        return hostingView
    }
    
    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.rootView = content
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator {
        let parent: RightClickableButton
        
        init(_ parent: RightClickableButton) {
            self.parent = parent
        }
        
        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            parent.action()
        }
        
        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            parent.rightClickAction()
        }
    }
}
