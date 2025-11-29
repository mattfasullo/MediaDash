import SwiftUI
import AppKit

struct GatekeeperView: View {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var onboardingSettingsManager = SettingsManager()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    
    // Get appearance from current settings (will be updated when settings change)
    private var appearance: AppearanceMode {
        if case .loggedIn(let profile) = sessionManager.authenticationState {
            return profile.settings.appearance
        }
        return onboardingSettingsManager.currentSettings.appearance
    }

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                // Show onboarding for first-time users
                OnboardingView(
                    hasCompletedOnboarding: $hasCompletedOnboarding,
                    settingsManager: onboardingSettingsManager
                )
                .preferredColorScheme(appearance.colorScheme)
            } else {
                // Normal app flow
            switch sessionManager.authenticationState {
            case .loggedOut:
                LoginView(sessionManager: sessionManager)
                    .preferredColorScheme(appearance.colorScheme)

            case .loggedIn(let profile):
                AuthenticatedRootView(
                    sessionManager: sessionManager,
                    profile: profile
                )
                .preferredColorScheme(profile.settings.appearance.colorScheme)
                }
            }
        }
        .onAppear {
            // Ensure window is configured when view appears
            DispatchQueue.main.async {
                if let window = NSApplication.shared.windows.first {
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.styleMask.insert(.fullSizeContentView)
                    window.toolbar = nil
                    window.invalidateShadow()
                }
            }
        }
    }
}

// MARK: - Authenticated Root View

struct AuthenticatedRootView: View {
    @ObservedObject var sessionManager: SessionManager
    let profile: WorkspaceProfile

    @StateObject private var settingsManager: SettingsManager
    @StateObject private var metadataManager: DocketMetadataManager
    @StateObject private var manager: MediaManager
    @StateObject private var emailScanningService: EmailScanningService
    @StateObject private var notificationCenter = NotificationCenter()
    @StateObject private var asanaCacheManager = AsanaCacheManager()
    @StateObject private var grabbedIndicatorService = GrabbedIndicatorService()
    
    @State private var showSplashScreen = true
    @State private var initializationComplete = false
    @State private var initializationProgress: Double = 0.0
    @State private var initializationStatus: String = "Initializing..."

    init(sessionManager: SessionManager, profile: WorkspaceProfile) {
        self.sessionManager = sessionManager
        self.profile = profile

        // Initialize with the profile's settings
        let settings = SettingsManager(settings: profile.settings)
        let metadata = DocketMetadataManager(settings: profile.settings)
        let mediaManager = MediaManager(settingsManager: settings, metadataManager: metadata)

        _settingsManager = StateObject(wrappedValue: settings)
        _metadataManager = StateObject(wrappedValue: metadata)
        _manager = StateObject(wrappedValue: mediaManager)
        
        // Initialize notification center
        let notificationCenter = NotificationCenter()
        _notificationCenter = StateObject(wrappedValue: notificationCenter)
        
        // Initialize email scanning service
        let gmailService = GmailService()
        let parser = EmailDocketParser()
        let emailService = EmailScanningService(gmailService: gmailService, parser: parser)
        emailService.mediaManager = mediaManager
        emailService.settingsManager = settings
        
        // Initialize grabbed indicator service
        let grabbedService = GrabbedIndicatorService()
        grabbedService.gmailService = gmailService
        grabbedService.notificationCenter = notificationCenter
        grabbedService.settingsManager = settings
        emailService.notificationCenter = notificationCenter
        emailService.metadataManager = metadata
        
        // Create AsanaCacheManager and configure it
        let asanaCache = AsanaCacheManager()
        if let sharedCacheURL = profile.settings.sharedCacheURL, !sharedCacheURL.isEmpty {
            asanaCache.updateCacheSettings(
                sharedCacheURL: sharedCacheURL,
                useSharedCache: true,
                serverBasePath: profile.settings.serverBasePath,
                serverConnectionURL: profile.settings.serverConnectionURL
            )
        }
        emailService.asanaCacheManager = asanaCache
        
        _emailScanningService = StateObject(wrappedValue: emailService)
        _asanaCacheManager = StateObject(wrappedValue: asanaCache)
        _grabbedIndicatorService = StateObject(wrappedValue: grabbedService)
        
        // Company name cache and other preloading will happen during splash screen
    }

    var body: some View {
        ZStack {
            // Always create ContentView so initialization can happen
            ContentView()
                .environmentObject(settingsManager)
                .environmentObject(metadataManager)
                .environmentObject(manager)
                .environmentObject(sessionManager)
                .environmentObject(emailScanningService)
                .environmentObject(notificationCenter)
                .opacity(showSplashScreen ? 0 : 1)
            
            // Show splash screen on top during initialization
            if showSplashScreen {
                SplashScreenView(progress: initializationProgress, statusMessage: initializationStatus)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
                // Sync settings manager with profile settings
                settingsManager.currentSettings = profile.settings
                
                // Update email scanning service references
                emailScanningService.mediaManager = manager
                emailScanningService.settingsManager = settingsManager
                emailScanningService.asanaCacheManager = asanaCacheManager
                
                // Update grabbed indicator service references
                grabbedIndicatorService.gmailService = emailScanningService.gmailService
                grabbedIndicatorService.notificationCenter = notificationCenter
                grabbedIndicatorService.settingsManager = settingsManager
                
                // Link the notification center to the grabbed service (for immediate checks)
                notificationCenter.grabbedIndicatorService = grabbedIndicatorService
                
                // Start grabbed indicator monitoring (non-blocking)
                grabbedIndicatorService.startMonitoring()
                
                // Initial grabbed check will happen during splash screen preloading
                
                // Update Asana cache settings
                if let sharedCacheURL = profile.settings.sharedCacheURL, !sharedCacheURL.isEmpty {
                    asanaCacheManager.updateCacheSettings(
                        sharedCacheURL: sharedCacheURL,
                        useSharedCache: true,
                        serverBasePath: profile.settings.serverBasePath,
                        serverConnectionURL: profile.settings.serverConnectionURL
                    )
                }
                
                // Update Asana sync settings for periodic background sync
                if profile.settings.docketSource == .asana {
                    asanaCacheManager.updateSyncSettings(
                        workspaceID: profile.settings.asanaWorkspaceID,
                        projectID: profile.settings.asanaProjectID,
                        docketField: profile.settings.asanaDocketField,
                        jobNameField: profile.settings.asanaJobNameField
                    )
                }
                
                // Start email scanning if enabled and authenticated
                if settingsManager.currentSettings.gmailEnabled {
                    // Restore tokens from Keychain
                    if let accessToken = SharedKeychainService.getGmailAccessToken(), !accessToken.isEmpty {
                        // Restore refresh token if available
                        let refreshToken = SharedKeychainService.getGmailRefreshToken()
                        print("GmailService: Restoring tokens on app launch")
                        print("  - Access token: \(accessToken.prefix(20))...")
                        print("  - Refresh token: \(refreshToken != nil ? "\(refreshToken!.prefix(20))..." : "nil")")
                        emailScanningService.gmailService.setAccessToken(accessToken, refreshToken: refreshToken)
                        
                        // Start scanning - token will auto-refresh if expired
                        emailScanningService.startScanning()
                    } else {
                        print("GmailService: No access token found in Keychain")
                    }
                }
                
                // Initialize progress tracking
                updateInitializationProgress()
                
                // Wait for initialization to complete before hiding splash screen
                Task {
                    await waitForInitialization()
                }
            }
            .onChange(of: manager.isScanningDockets) { _, isScanning in
                updateInitializationProgress()
                if !isScanning {
                    checkInitializationComplete()
                }
            }
            .onChange(of: manager.isIndexing) { _, isIndexing in
                updateInitializationProgress()
                if !isIndexing {
                    checkInitializationComplete()
                }
            }
            .onChange(of: settingsManager.currentSettings) { _, newSettings in
                // Update the profile when settings change
                sessionManager.updateProfile(settings: newSettings)
                
                // Update email scanning service settings
                emailScanningService.settingsManager = settingsManager
                
                // Start/stop scanning based on settings
                if newSettings.gmailEnabled {
                    if let accessToken = SharedKeychainService.getGmailAccessToken(), !accessToken.isEmpty {
                        // Restore refresh token if available
                        let refreshToken = SharedKeychainService.getGmailRefreshToken()
                        emailScanningService.gmailService.setAccessToken(accessToken, refreshToken: refreshToken)
                        if !emailScanningService.isEnabled {
                            emailScanningService.startScanning()
                        }
                    }
                } else {
                    emailScanningService.stopScanning()
                }
            }
    }
    
    /// Humorous loading messages
    private let loadingMessages = [
        "Convincing the CPU to care…",
        "Negotiating with the cloud…",
        "Shaking hands with reality…",
        "Syncing the unsyncable…",
        "Spinning up the tiny hamsters…",
        "Politely asking the bits to hurry…",
        "Tuning the quantum vibes…",
        "Buffering enthusiasm…",
        "Stretching before the big moment…",
        "Cranking the imaginary lever…",
        "Tightening the digital bolts…",
        "Brewing the startup potion…",
        "Stirring the data soup…",
        "Oil-ing the virtual gears…",
        "Pressurizing the pipes…",
        "Inflating the progress balloon…",
        "Almost doing something important…",
        "Pretending to boot faster than we are…",
        "Calculating how long this will take (forever)…",
        "Smoothing out the rough edges…",
        "Removing evidence of previous crashes…",
        "Calibrating the vibe parameters…",
        "Doing app things you definitely wouldn't understand…",
        "Deciding which bugs to keep…",
        "Loading… because you asked nicely",
        "Herding the digital cats…",
        "Untangling the spaghetti code…",
        "Asking the server for a favour…",
        "Rewiring the imaginary neurons…",
        "Consulting the prophecy…",
        "Summoning the progress spirits…",
        "Teaching the app what a \"loading bar\" means…",
        "Kindling the bonfire…",
        "Retrieving lost data (don't die)…",
        "Preparing to roll through everything…",
        "Adjusting hollow status…",
        "Two-handing the progress bar…",
        "\"YOU DIED\"… reloading anyway…",
        "Summoning a phantom process…",
        "Touching grace, hold on…",
        "Plumbing the data pipes…",
        "Loading… bwa-ha-ha (Bowser laugh intensifies)…",
        "Checking for missing stars…",
        "Polishing the kart tires…",
        "Heating up the fire flower…",
        "Grabbing a mushroom for extra RAM…",
        "Reforging the Master Progress Bar…",
        "Cutting grass for rupees (and bandwidth)…",
        "Attuning to the Sheikah Slate…",
        "Opening yet another chest… da-da-da-DAAA…",
        "Calibrating the Hero of Time…",
        "Rehydrating Ganon… stand by…",
        "Powering the Varia Suit…",
        "Downloading Chozo firmware…",
        "Rolling into morph ball mode…",
        "Scanning the environment for bugs…",
        "Waking the Spartan from cryo…",
        "Rebooting Cortana (a safe amount)…",
        "Prepping the Warthog for physics chaos…",
        "Charging the plasma progress rifle…",
        "Taking an arrow to the load time…",
        "Reading yet another lore book…",
        "Shouting at the server: FUS RO—loading…",
        "Sneaking… even though no one's watching…",
        "Inverting the dream…",
        "Acquiring insight into the progress bar…",
        "Allowing the moon to do moon things…",
        "Bloodtinge rising… hold tight…",
        "Calibrating… always calibrating…",
        "Prepping the Normandy's loading relays…",
        "Checking Paragon/Renegade alignment of the progress bar…"
    ]
    
    /// Update initialization progress based on current state
    private func updateInitializationProgress() {
        let isScanningDockets = manager.isScanningDockets
        let isIndexing = manager.isIndexing
        
        // Calculate progress: 0.0 to 1.0
        var progress: Double = 0.0
        var status: String
        
        if isScanningDockets && isIndexing {
            // Both running - show intermediate progress
            progress = 0.3
        } else if isScanningDockets {
            // Only scanning dockets
            progress = 0.5
        } else if isIndexing {
            // Only scanning folders
            progress = 0.8
        } else {
            // Both complete
            progress = 1.0
            status = "Ready!"
            initializationProgress = progress
            initializationStatus = status
            return
        }
        
        // Select a random humorous message
        status = loadingMessages.randomElement() ?? "Loading..."
        
        // Defer state updates to avoid modifying during view updates
        Task { @MainActor in
            let transaction = Transaction(animation: .spring(response: 0.3, dampingFraction: 0.8))
            withTransaction(transaction) {
                initializationProgress = progress
                initializationStatus = status
            }
        }
    }
    
    /// Preload additional data in the background to improve startup efficiency
    private func preloadBackgroundData() async {
        // Preload company name cache (improves email scanning and matching)
        // This is already async internally, so it won't block
        await MainActor.run {
            emailScanningService.populateCompanyNameCache()
        }
        
        // Preload metadata (improves docket display speed)
        // This loads from disk, which is fast and non-blocking
        await MainActor.run {
            metadataManager.reloadMetadata()
        }
        
        // Preload Asana cache if using Asana (improves search speed)
        if settingsManager.currentSettings.docketSource == .asana {
            await MainActor.run {
                _ = asanaCacheManager.loadCachedDockets() // Preload cache
            }
        }
        
        // Build additional folder indexes (improves search speed for other folders)
        // These are already async and run in background tasks
        await MainActor.run {
            // Build workPicture and mediaPostings indexes in background
            manager.buildSessionIndex(folder: .workPicture)
            manager.buildSessionIndex(folder: .mediaPostings)
        }
        
        // Initial grabbed indicator check (non-blocking)
        await grabbedIndicatorService.checkForGrabbedReplies()
    }
    
    /// Wait for initialization processes to complete
    private func waitForInitialization() async {
        // Update initial progress - defer to next run loop cycle
        Task { @MainActor in
            updateInitializationProgress()
        }
        
        // Start background preloading immediately (non-blocking)
        let preloadTask = Task {
            await preloadBackgroundData()
        }
        
        // Minimum splash screen time to show messages (2 seconds)
        let minSplashTime: UInt64 = 2_000_000_000 // 2 seconds
        
        // First, check immediately in case initialization is already complete
        let isAlreadyComplete = await MainActor.run {
            !manager.isScanningDockets && !manager.isIndexing
        }
        
        if isAlreadyComplete {
            // Still show splash for minimum time to see messages
            await MainActor.run {
                initializationProgress = 0.9
                updateInitializationProgress() // Get a random message
            }
            
            // Wait minimum time while preloading happens
            try? await Task.sleep(nanoseconds: minSplashTime)
            
            // Wait for preloading to complete
            await preloadTask.value
            
            await MainActor.run {
                initializationProgress = 1.0
                initializationStatus = "Ready!"
            }
            await MainActor.run {
                checkInitializationComplete()
            }
            return
        }
        
        // Wait for MediaManager to finish scanning dockets AND scanning folders
        // Both are essential for smooth UX
        var attempts = 0
        let maxAttempts = 120 // 12 seconds max wait (120 * 0.1s)
        let startTime = DispatchTime.now()
        
        while attempts < maxAttempts {
            // Check if both operations are complete
            let isComplete = await MainActor.run {
                !manager.isScanningDockets && !manager.isIndexing
            }
            
            if isComplete {
                // Calculate elapsed time
                let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                let elapsedSeconds = Double(elapsed) / 1_000_000_000
                
                // Update progress to show we're finishing up
                await MainActor.run {
                    initializationProgress = 0.9
                    updateInitializationProgress() // Get a random message
                }
                
                // Wait for preloading to complete (or minimum time, whichever is longer)
                let remainingTime = max(0.0, 2.0 - elapsedSeconds)
                if remainingTime > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remainingTime * 1_000_000_000))
                }
                
                // Wait for preloading task
                await preloadTask.value
                
                await MainActor.run {
                    initializationProgress = 1.0
                    initializationStatus = "Ready!"
                }
                await MainActor.run {
                    checkInitializationComplete()
                }
                return
            }
            
            // Update progress and change message periodically (throttled to reduce choppiness)
            if attempts % 15 == 0 { // Every 1.5 seconds (less frequent = smoother)
                await MainActor.run {
                    updateInitializationProgress()
                }
            }
            
            // Wait a bit before checking again
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            attempts += 1
        }
        
        // If we've waited too long, wait for preloading and hide splash screen anyway
        await preloadTask.value
        await MainActor.run {
            initializationProgress = 1.0
            initializationStatus = "Ready!"
            checkInitializationComplete()
        }
    }
    
    /// Check if initialization is complete and hide splash screen
    private func checkInitializationComplete() {
        guard !initializationComplete else { return }
        
        // Wait for both docket scanning AND folder scanning to complete
        // This ensures smooth UX when the app first opens
        if !manager.isScanningDockets && !manager.isIndexing {
            initializationComplete = true
            
            // Small delay to show "Ready!" status
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                // Hide splash screen with animation
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showSplashScreen = false
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    GatekeeperView()
}
