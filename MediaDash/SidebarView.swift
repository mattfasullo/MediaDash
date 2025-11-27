import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    
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
    @Binding var isStagingAreaVisible: Bool
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
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 12) {
                // App Logo (clickable Easter egg)
                Image("HeaderLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 60)
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
                        
                        // Cache status indicator
                        if let cacheManager = cacheManager {
                            CacheStatusIndicator(
                                cacheStatus: cacheManager.cacheStatus,
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

            // Toggle staging button (top right)
            HStack(spacing: 4) {
                // Blue dot indicator when staging area has items
                if !manager.selectedFiles.isEmpty {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }
                
            HoverableButton(action: {
                isStagingAreaVisible.toggle()
            }) { isHovered in
                Image(systemName: isStagingAreaVisible ? "chevron.right" : "chevron.left")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(isHovered ? .primary : .secondary.opacity(0.6))
                    .padding(4)
                    .background(isHovered ? Color.gray.opacity(0.1) : Color.clear)
                    .cornerRadius(4)
            }
            .help(isStagingAreaVisible ? "Hide staging (⌘E)" : "Show staging (⌘E)")
            .keyboardShortcut("e", modifiers: .command)
            }
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
    }
}

// MARK: - Cache Status Indicator

struct CacheStatusIndicator: View {
    let cacheStatus: AsanaCacheManager.CacheStatus
    let cacheManager: AsanaCacheManager?
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var isHovered = false
    
    private var tooltipText: String {
        let baseText: String
        switch cacheStatus {
        case .shared:
            baseText = "Using shared cache - Connected to server"
        case .local:
            baseText = "Using local cache - Click to switch to shared cache"
        case .unknown:
            baseText = "Cache status unknown - Click to refresh"
        }
        
        if cacheStatus != .shared {
            return "\(baseText) (Click to refresh)"
        }
        return baseText
    }
    
    var body: some View {
        Group {
            switch cacheStatus {
            case .shared:
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            case .local:
                Image(systemName: "internaldrive")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(isHovered ? 0.15 : 0.08))
        )
        .help(tooltipText)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            // Force refresh cache status and attempt to switch to shared cache
            if let cacheManager = cacheManager {
                Task { @MainActor in
                    // First refresh status
                    cacheManager.refreshCacheStatus()
                    
                    // If currently using local cache, try to create/switch to shared cache
                    if cacheStatus == .local {
                        // Try to seed shared cache from local cache
                        print("🔄 [Cache] Attempting to seed shared cache from local cache...")
                        
                        // Get local cache dockets
                        let localDockets = cacheManager.loadCachedDockets()
                        
                        if !localDockets.isEmpty {
                            // Get shared cache URL from settings
                            let sharedURL = settingsManager.currentSettings.sharedCacheURL
                            
                            if let sharedURL = sharedURL, !sharedURL.isEmpty {
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
        }
        .buttonStyle(.plain)
    }
}

