import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.colorScheme) var colorScheme
    
    /// Helper function to seed shared cache from local cache
    private func seedSharedCacheFromLocal(cacheManager: AsanaCacheManager, dockets: [DocketInfo]) async {
        // Get shared cache URL from settings
        let sharedURL = settingsManager.currentSettings.sharedCacheURL
        
        guard let sharedURL = sharedURL, !sharedURL.isEmpty else {
            print("⚠️ [Cache] No shared cache URL configured in settings")
            return
        }
        
        do {
            try await cacheManager.saveToSharedCache(dockets: dockets, url: sharedURL)
            print("🟢 [Cache] Successfully created shared cache from local cache")
        } catch {
            print("⚠️ [Cache] Failed to create shared cache: \(error.localizedDescription)")
        }
    }
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var emailScanningService: EmailScanningService
    @EnvironmentObject var manager: MediaManager
    var focusedButton: FocusState<ActionButtonFocus?>.Binding
    var mainViewFocused: FocusState<Bool>.Binding
    @Binding var isKeyboardMode: Bool
    @Binding var isCommandKeyHeld: Bool
    @Binding var hoverInfo: String
    @Binding var showSearchSheet: Bool
    @Binding var showQuickSearchSheet: Bool
    @Binding var showSettingsSheet: Bool
    @Binding var showVideoConverterSheet: Bool
    @Binding var logoClickCount: Int
    var notificationCenter: NotificationCenter?
    @Binding var showNotificationCenter: Bool
    
    let wpDate: Date
    let prepDate: Date
    let dateFormatter: DateFormatter
    let attempt: (JobType) -> Void
    let cycleTheme: () -> Void
    let cacheManager: AsanaCacheManager?
    
    private var currentTheme: AppTheme {
        settingsManager.currentSettings.appTheme
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
            VStack(alignment: .leading, spacing: 12) {
                // App Logo (clickable Easter egg)
                logoImage
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

                // Info Hub: Notification Tab + Status Indicators
                if let notificationCenter = notificationCenter {
                    HStack(spacing: 8) {
                        NotificationTabButton(
                            notificationCenter: notificationCenter,
                            showNotificationCenter: $showNotificationCenter
                        )
                        
                        // Separate server and cache status indicators
                        if let cacheManager = cacheManager {
                            ServerStatusIndicator(
                                cacheManager: cacheManager,
                                showSettings: $showSettingsSheet
                            )
                            
                            CacheStatusIndicator(
                                cacheManager: cacheManager
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
                    attempt: attempt
                )

                Spacer()

                Divider()

                // Bottom actions
                VStack(spacing: 8) {
                    FocusableNavButton(
                        icon: "magnifyingglass",
                        title: "Search",
                        shortcut: "⌘F",
                        isFocused: focusedButton.wrappedValue == .search,
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
                        isFocused: focusedButton.wrappedValue == .jobInfo,
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
                        icon: "gearshape",
                        title: "Settings",
                        shortcut: "⌘,",
                        isFocused: focusedButton.wrappedValue == .settings,
                        showShortcut: isCommandKeyHeld,
                        action: { showSettingsSheet = true }
                    )
                    .focused(focusedButton, equals: .settings)
                    .focusEffectDisabled()
                    .onHover { hovering in
                        if hovering {
                            focusedButton.wrappedValue = nil
                            mainViewFocused.wrappedValue = true
                            isKeyboardMode = false
                        }
                    }
                    .keyboardShortcut(",", modifiers: .command)

                    Divider()
                        .padding(.vertical, 4)

                    // Workspace Button (where log out button was)
                    if case .loggedIn(let profile) = sessionManager.authenticationState {
                        WorkspaceMenuButton(profile: profile, sessionManager: sessionManager)
                    }
                }
                .padding(.bottom, 12)
            }
            .padding(16)
            .frame(width: 300)
            .background(currentTheme.sidebarBackground)

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
        case .serverConnectedUsingShared, .serverConnectedUsingLocal, .serverConnectedNoCache:
            return true
        case .serverDisconnectedUsingLocal, .serverDisconnectedNoCache, .unknown:
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
        case .serverConnectedUsingShared, .serverConnectedUsingLocal, .serverConnectedNoCache:
            return true
        case .serverDisconnectedUsingLocal, .serverDisconnectedNoCache, .unknown:
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
        case .serverConnectedUsingLocal:
            return "Using local cache (shared unavailable)"
        case .serverConnectedNoCache:
            return "No cache available"
        case .serverDisconnectedUsingLocal:
            return "Server disconnected, using local cache"
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
                        fileURL = fileURL.appendingPathComponent("mediadash_docket_search_cache.json")
                    }
                    
                    sharedCacheExists = FileManager.default.fileExists(atPath: fileURL.path)
                }
            }
            
            // Test local cache
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let appFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
            let localCachePath = appFolder.appendingPathComponent("mediadash_docket_search_cache.json").path
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
        .frame(width: 400)
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

// MARK: - Cache Status Indicator

struct CacheStatusIndicator: View {
    @ObservedObject var cacheManager: AsanaCacheManager
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var isHovered = false
    @State private var isProcessing = false
    @State private var lastActionTime: Date?
    @State private var pulsePhase: Double = 0.0
    @State private var showCachePopover = false
    
    private var cacheState: (available: Bool, isShared: Bool) {
        switch cacheManager.cacheStatus {
        case .serverConnectedUsingShared:
            return (true, true)
        case .serverConnectedUsingLocal:
            return (true, false)
        case .serverConnectedNoCache:
            return (false, false)
        case .serverDisconnectedUsingLocal:
            return (true, false)
        case .serverDisconnectedNoCache:
            return (false, false)
        case .unknown:
            return (false, false)
        }
    }
    
    private var tooltipText: String {
        let state = cacheState
        if state.available {
            if state.isShared {
                return "Cache: Using shared cache"
            } else {
                return "Cache: Using local cache\nClick to refresh or create shared cache"
            }
        } else {
            return "Cache: Not available\nClick to refresh"
        }
    }
    
    var body: some View {
        Group {
            if isProcessing {
                // Show spinning progress indicator when processing
                ProgressView()
                    .scaleEffect(0.4)
                    .frame(width: 6, height: 6)
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
            } else {
                // Show cache status icon when not processing
                let state = cacheState
                if state.available {
                    if state.isShared {
                        Image(systemName: "externaldrive.connected.to.line.below.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
                    } else {
                Image(systemName: "internaldrive")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    }
                } else {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 11))
                        .foregroundColor(.yellow)
                }
            }
        }
        .frame(width: 28, height: 28) // Fixed square size to match notification button height
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(isHovered ? 0.15 : (isProcessing ? 0.2 : 0.08)))
        )
        .overlay(
            // Pulsing border animation when processing
            Group {
                if isProcessing {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.blue.opacity(0.4 + pulsePhase * 0.4), lineWidth: 1.5)
                }
            }
        )
        .onChange(of: isProcessing) { _, newValue in
            if newValue {
                // Start pulsing animation
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulsePhase = 1.0
                }
            } else {
                // Stop pulsing animation
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
        .popover(isPresented: $showCachePopover, arrowEdge: .bottom) {
            CacheStatusPopover(
                cacheManager: cacheManager,
                isProcessing: $isProcessing
            )
            .environmentObject(settingsManager)
            .frame(width: 350)
        }
        .onTapGesture {
            // Show cache popover
            showCachePopover = true
            // Refresh status when opening popover
            cacheManager.refreshCacheStatus()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cache Status Popover

struct CacheStatusPopover: View {
    @ObservedObject var cacheManager: AsanaCacheManager
    @Binding var isProcessing: Bool
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var lastSyncDate: Date?
    
    private var cacheState: (available: Bool, isShared: Bool) {
        switch cacheManager.cacheStatus {
        case .serverConnectedUsingShared:
            return (true, true)
        case .serverConnectedUsingLocal:
            return (true, false)
        case .serverConnectedNoCache:
            return (false, false)
        case .serverDisconnectedUsingLocal:
            return (true, false)
        case .serverDisconnectedNoCache:
            return (false, false)
        case .unknown:
            return (false, false)
        }
    }
    
    private var cacheStateDescription: String {
        switch cacheManager.cacheStatus {
        case .serverConnectedUsingShared:
            return "Using shared cache"
        case .serverConnectedUsingLocal:
            return "Using local cache (shared unavailable)"
        case .serverConnectedNoCache:
            return "No cache available"
        case .serverDisconnectedUsingLocal:
            return "Server disconnected, using local cache"
        case .serverDisconnectedNoCache:
            return "Server disconnected, no cache"
        case .unknown:
            return "Status unknown"
        }
    }
    
    private var sharedCachePath: String {
        guard let urlString = settingsManager.currentSettings.sharedCacheURL, !urlString.isEmpty else {
            return "Not configured"
        }
        
        // Resolve to actual file path (appends cache filename if it's a directory)
        let fileURL = cacheManager.getFileURL(from: urlString)
        return fileURL.path
    }
    
    private var localCachePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appFolder = appSupport.appendingPathComponent("MediaDash", isDirectory: true)
        return appFolder.appendingPathComponent("mediadash_docket_search_cache.json").path
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                let state = cacheState
                if state.available {
                    if state.isShared {
                        Image(systemName: "externaldrive.connected.to.line.below.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 16))
                            .foregroundColor(.orange)
                    }
                } else {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 16))
                        .foregroundColor(.yellow)
                }
                
                Text("Cache Status")
                    .font(.system(size: 14, weight: .semibold))
                
                Spacer()
                
                Circle()
                    .fill(cacheState.available ? (cacheState.isShared ? Color.green : Color.orange) : Color.yellow)
                    .frame(width: 8, height: 8)
            }
            
            Divider()
            
            // Cache Status
            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                Text(cacheStateDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            }
            
            // Cache Paths
            VStack(alignment: .leading, spacing: 8) {
                Text("Cache Locations")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                
                if settingsManager.currentSettings.useSharedCache {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shared:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(sharedCachePath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Local:")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(localCachePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            
            // Last Sync Date
            if let lastSync = cacheManager.lastSyncDate {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Sync")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(lastSync, style: .relative)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Actions
            HStack(spacing: 8) {
                Button(action: {
                    refreshAndUpgradeCache()
                }) {
                    HStack(spacing: 4) {
                        if isProcessing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10))
                        }
                        Text(cacheManager.cacheStatus == .serverConnectedUsingLocal ? "Create Shared Cache" : "Refresh")
                            .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isProcessing)
                
                Button(action: {
                    syncNow()
                }) {
                    HStack(spacing: 4) {
                        if cacheManager.isSyncing {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 10, height: 10)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 10))
                        }
                        Text("Sync Now")
                            .font(.system(size: 11))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(cacheManager.isSyncing || isProcessing)
            }
        }
        .padding(12)
    }
    
    private func refreshAndUpgradeCache() {
        guard !isProcessing else { return }
        
        isProcessing = true
        
                Task { @MainActor in
            defer {
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
                    await MainActor.run {
                        isProcessing = false
                    }
                }
            }
            
                    // First refresh status
                    cacheManager.refreshCacheStatus()
                    
            // If server is connected but using local cache, try to create/switch to shared cache
            if cacheManager.cacheStatus == .serverConnectedUsingLocal {
                        // Try to seed shared cache from local cache
                        print("🔄 [Cache] Attempting to seed shared cache from local cache...")
                        
                        // Get local cache dockets
                        let localDockets = cacheManager.loadCachedDockets()
                        
                        if !localDockets.isEmpty {
                            // Get shared cache URL from settings
                    if let sharedURL = settingsManager.currentSettings.sharedCacheURL, !sharedURL.isEmpty {
                                do {
                                    try await cacheManager.saveToSharedCache(dockets: localDockets, url: sharedURL)
                                    print("🟢 [Cache] Successfully created shared cache from local cache")
                                } catch {
                                    print("⚠️ [Cache] Failed to create shared cache: \(error.localizedDescription)")
                                }
                            } else {
                                print("⚠️ [Cache] No shared cache URL configured in settings")
                            }
                        }
                        
                        // Refresh status after attempt
                        cacheManager.refreshCacheStatus()
                    } else {
                        // Just refresh status
                        cacheManager.refreshCacheStatus()
                    }
                }
            }
    
    private func syncNow() {
        guard !cacheManager.isSyncing else { return }
        
        Task { @MainActor in
            do {
                let settings = settingsManager.currentSettings
                try await cacheManager.syncWithAsana(
                    workspaceID: settings.asanaWorkspaceID,
                    projectID: settings.asanaProjectID,
                    docketField: settings.asanaDocketField,
                    jobNameField: settings.asanaJobNameField,
                    sharedCacheURL: settings.sharedCacheURL,
                    useSharedCache: settings.useSharedCache
                )
                print("🟢 [Cache] Manual sync complete")
                
                // Refresh status after sync
                cacheManager.refreshCacheStatus()
            } catch {
                print("⚠️ [Cache] Manual sync failed: \(error.localizedDescription)")
            }
        }
    }
}

