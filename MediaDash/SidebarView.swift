import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var emailScanningService: EmailScanningService
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
    var onRecentDocketSelected: ((String) -> Void)?
    
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

                // Notification Tab (where workspace label used to be)
                        if let notificationCenter = notificationCenter {
                    NotificationTabButton(
                        notificationCenter: notificationCenter,
                        showNotificationCenter: $showNotificationCenter
                    )
                    .frame(maxWidth: .infinity)
                }
                
                // Recent Dockets Section
                RecentDocketsSection(onDocketSelected: { docketName in
                    onRecentDocketSelected?(docketName)
                })

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
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
    }
}

