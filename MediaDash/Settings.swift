import Foundation
import SwiftUI
import Combine

// MARK: - Layout Mode

enum LayoutMode: String, CaseIterable {
    case compact = "Compact"
    case desktop = "Desktop"
    
    var displayName: String {
        self.rawValue
    }
    
    // Threshold widths for layout changes
    static let compactMaxWidth: CGFloat = 750 // Below this = compact
    static let desktopMinWidth: CGFloat = 750 // Above this = desktop
    
    // Minimum window size (compact mode)
    static let minWidth: CGFloat = 650
    static let minHeight: CGFloat = 550
    
    // Determine layout mode from window size
    static func from(windowWidth: CGFloat) -> LayoutMode {
        return windowWidth >= desktopMinWidth ? .desktop : .compact
    }
}

// Environment key for layout mode
struct LayoutModeKey: EnvironmentKey {
    static let defaultValue: LayoutMode = .compact
}

// Environment key for window size
struct WindowSizeKey: EnvironmentKey {
    static let defaultValue: CGSize = CGSize(width: 650, height: 550)
}

extension EnvironmentValues {
    var layoutMode: LayoutMode {
        get { self[LayoutModeKey.self] }
        set { self[LayoutModeKey.self] = newValue }
    }
    
    var windowSize: CGSize {
        get { self[WindowSizeKey.self] }
        set { self[WindowSizeKey.self] = newValue }
    }
}

// MARK: - Business Day Calculator

struct BusinessDayCalculator {
    // Canadian Federal Holidays (fixed dates)
    static let fixedHolidays: [(month: Int, day: Int)] = [
        (1, 1),   // New Year's Day
        (7, 1),   // Canada Day
        (12, 25), // Christmas
        (12, 26)  // Boxing Day
    ]

    // Calculate next business day with Canadian holiday logic
    static func nextBusinessDay(from date: Date, skipWeekends: Bool = true, skipHolidays: Bool = true) -> Date {
        let calendar = Calendar.current
        var nextDay = calendar.date(byAdding: .day, value: 1, to: date)!

        // Check weekday of next day
        let weekday = calendar.component(.weekday, from: nextDay)

        // If next day is Saturday (7) or Sunday (1), skip to Monday (only if skipWeekends is enabled)
        if skipWeekends {
            if weekday == 7 { // Saturday
                nextDay = calendar.date(byAdding: .day, value: 2, to: nextDay)!
            } else if weekday == 1 { // Sunday
                nextDay = calendar.date(byAdding: .day, value: 1, to: nextDay)!
            }
        }

        // Check if next day is a Canadian holiday (only if skipHolidays is enabled)
        if skipHolidays && isCanadianHoliday(date: nextDay) {
            // If it's a holiday, check what day of week it is
            let holidayWeekday = calendar.component(.weekday, from: nextDay)

            // If holiday falls on Thursday, skip Thu, Fri, Sat, Sun, Mon -> choose Tuesday
            if holidayWeekday == 5 { // Thursday
                nextDay = calendar.date(byAdding: .day, value: 5, to: nextDay)!
            }
            // If holiday falls on Friday, skip Fri, Sat, Sun, Mon -> choose Tuesday
            else if holidayWeekday == 6 { // Friday
                nextDay = calendar.date(byAdding: .day, value: 4, to: nextDay)!
            }
            // For other weekdays (Mon-Wed), just skip to next business day
            else {
                nextDay = calendar.date(byAdding: .day, value: 1, to: nextDay)!
                // Recursively check again in case next day is also a holiday or weekend
                return nextBusinessDay(from: calendar.date(byAdding: .day, value: -1, to: nextDay)!, skipWeekends: skipWeekends, skipHolidays: skipHolidays)
            }
        }

        return nextDay
    }

    // Check if a date is a Canadian Federal Holiday
    static func isCanadianHoliday(date: Date) -> Bool {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let year = calendar.component(.year, from: date)
        let weekday = calendar.component(.weekday, from: date)

        // Check fixed holidays
        for holiday in fixedHolidays {
            if month == holiday.month && day == holiday.day {
                return true
            }
        }

        // Victoria Day (Monday before May 25)
        if month == 5 {
            let may25 = calendar.date(from: DateComponents(year: year, month: 5, day: 25))!
            let may25Weekday = calendar.component(.weekday, from: may25)
            let daysToMonday = (may25Weekday == 2) ? 0 : (may25Weekday - 2 + 7) % 7
            let victoriaDay = calendar.date(byAdding: .day, value: -daysToMonday, to: may25)!
            if calendar.isDate(date, inSameDayAs: victoriaDay) {
                return true
            }
        }

        // Labour Day (first Monday in September)
        if month == 9 && weekday == 2 {
            let firstOfMonth = calendar.date(from: DateComponents(year: year, month: 9, day: 1))!
            let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
            let daysToFirstMonday = (9 - firstWeekday) % 7
            let labourDay = calendar.date(byAdding: .day, value: daysToFirstMonday, to: firstOfMonth)!
            if calendar.isDate(date, inSameDayAs: labourDay) {
                return true
            }
        }

        // Thanksgiving (second Monday in October)
        if month == 10 && weekday == 2 {
            let firstOfMonth = calendar.date(from: DateComponents(year: year, month: 10, day: 1))!
            let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
            let daysToFirstMonday = (9 - firstWeekday) % 7
            let secondMonday = calendar.date(byAdding: .day, value: daysToFirstMonday + 7, to: firstOfMonth)!
            if calendar.isDate(date, inSameDayAs: secondMonday) {
                return true
            }
        }

        // Good Friday and Easter Monday (dynamic, would need more complex calculation)
        // For now, these would need to be added manually or use a more sophisticated calendar library

        return false
    }
}

// MARK: - Docket Source

enum DocketSource: String, Codable, CaseIterable {
    case asana = "Asana"
    case csv = "CSV File"
    case server = "Server Path"
    
    var displayName: String {
        self.rawValue
    }
}

// MARK: - Search Settings

enum SearchFolder: String, Codable, CaseIterable {
    case workPicture = "Work Picture"
    case mediaPostings = "Media Postings"
    case sessions = "Pro Tools Sessions"

    var displayName: String {
        self.rawValue
    }
}

enum SearchFolderPreference: String, Codable {
    case rememberLast = "Remember Last Used"
    case alwaysUseDefault = "Always Use Default"
}

enum DefaultQuickSearch: String, Codable {
    case search = "Search"
    case jobInfo = "Job Info"
}

enum DocketSortOrder: String, Codable, CaseIterable {
    case recentlyUpdated = "Recently Updated"
    case docketNumberDesc = "Docket Number (High to Low)"
    case docketNumberAsc = "Docket Number (Low to High)"
    case jobNameAsc = "Job Name (A to Z)"
    case jobNameDesc = "Job Name (Z to A)"
    
    var displayName: String {
        self.rawValue
    }
}

// MARK: - Update Channel

enum UpdateChannel: String, Codable, CaseIterable, Identifiable {
    case production = "Production"
    case development = "Development"

    var id: String { self.rawValue }

    var displayName: String {
        self.rawValue
    }

    var feedURL: String {
        switch self {
        case .production:
            return "https://raw.githubusercontent.com/mattfasullo/MediaDash/main/appcast.xml"
        case .development:
            return "https://raw.githubusercontent.com/mattfasullo/MediaDash/dev-builds/appcast-dev.xml"
        }
    }
}

// MARK: - Browser Preference

enum BrowserPreference: String, Codable, CaseIterable {
    case chrome = "Google Chrome"
    case safari = "Safari"
    case firefox = "Firefox"
    case edge = "Microsoft Edge"
    case defaultBrowser = "Default Browser"
    
    var displayName: String {
        self.rawValue
    }
    
    var bundleIdentifier: String? {
        switch self {
        case .chrome:
            return "com.google.Chrome"
        case .safari:
            return "com.apple.Safari"
        case .firefox:
            return "org.mozilla.firefox"
        case .edge:
            return "com.microsoft.edgemac"
        case .defaultBrowser:
            return nil // Use system default
        }
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, Codable, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    
    var displayName: String {
        self.rawValue
    }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil // Use system default
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

// MARK: - App Theme

enum AppTheme: String, Codable, CaseIterable {
    case modern = "Modern"
    case retroDesktop = "Retro Desktop (Beta)"

    var displayName: String {
        self.rawValue
    }

    // Theme-specific colors
    var sidebarBackground: Color {
        switch self {
        case .modern:
            return Color(nsColor: .controlBackgroundColor)
        case .retroDesktop:
            return Color(red: 0.173, green: 0.173, blue: 0.173) // Dark gray #2C2C2C
        }
    }

    var titleColor: Color {
        switch self {
        case .modern:
            return .primary
        case .retroDesktop:
            return .white
        }
    }

    var buttonCornerRadius: CGFloat {
        switch self {
        case .modern:
            return 8
        case .retroDesktop:
            return 6
        }
    }

    var buttonColors: (file: Color, prep: Color, both: Color) {
        switch self {
        case .modern:
            return (
                Color(red: 0.25, green: 0.35, blue: 0.50),  // Subtle slate blue
                Color(red: 0.50, green: 0.40, blue: 0.25),  // Subtle amber/brown
                Color(red: 0.25, green: 0.45, blue: 0.45)   // Subtle teal
            )
        case .retroDesktop:
            return (
                Color(red: 0.29, green: 0.565, blue: 0.886), // Blue #4A90E2
                Color(red: 1.0, green: 0.549, blue: 0.259),  // Orange #FF8C42
                Color(red: 0.29, green: 0.565, blue: 0.886)   // Blue #4A90E2
            )
        }
    }

    var textColor: Color {
        switch self {
        case .modern:
            return .white
        case .retroDesktop:
            return .white
        }
    }

    var textShadowColor: Color? {
        switch self {
        case .modern:
            return nil
        case .retroDesktop:
            return nil
        }
    }

    var useCustomFont: Bool {
        false
    }
    
    // Retro Desktop specific colors from design.json
    var retroBeige: Color {
        Color(red: 0.961, green: 0.961, blue: 0.863) // #F5F5DC
    }
    
    var retroBeigeDark: Color {
        Color(red: 0.910, green: 0.910, blue: 0.816) // #E8E8D0
    }
    
    var retroOrange: Color {
        Color(red: 1.0, green: 0.549, blue: 0.259) // #FF8C42
    }
    
    var retroBlue: Color {
        Color(red: 0.29, green: 0.565, blue: 0.886) // #4A90E2
    }
    
    var retroYellow: Color {
        Color(red: 1.0, green: 0.843, blue: 0.0) // #FFD700
    }
    
    var retroPink: Color {
        Color(red: 1.0, green: 0.714, blue: 0.757) // #FFB6C1
    }
    
    var retroPurple: Color {
        Color(red: 0.576, green: 0.439, blue: 0.859) // #9370DB
    }
    
    var retroRedOrange: Color {
        Color(red: 1.0, green: 0.388, blue: 0.278) // #FF6347
    }
    
    var retroDarkGray: Color {
        Color(red: 0.173, green: 0.173, blue: 0.173) // #2C2C2C
    }
    
    var retroGray: Color {
        Color(red: 0.502, green: 0.502, blue: 0.502) // #808080
    }
}

// MARK: - Settings Model

struct AppSettings: Codable, Equatable {
    var profileName: String

    // Path Settings
    var serverBasePath: String
    var sessionsBasePath: String
    var serverConnectionURL: String? // e.g., "smb://192.168.200.200" or "192.168.200.200"

    // Job Info Source
    var docketSource: DocketSource

    // App Theme
    var appTheme: AppTheme
    
    // Appearance (Color Scheme)
    var appearance: AppearanceMode

    // Update Channel
    var updateChannel: UpdateChannel

    // Folder Naming
    var workPictureFolderName: String
    var prepFolderName: String
    var yearPrefix: String // e.g., "GM_"

    // Date Format
    var dateFormat: String // e.g., "MMMd.yy"

    // File Categories
    var pictureExtensions: [String]
    var musicExtensions: [String]
    var aafOmfExtensions: [String]

    // Category Folder Names
    var pictureFolderName: String
    var musicFolderName: String
    var aafOmfFolderName: String
    var otherFolderName: String

    // Folder Format Settings
    var workPicNumberFormat: String // e.g., "%02d" for "01", "02", etc.
    var prepFolderFormat: String // e.g., "{docket}_PREP_{date}"

    // Search Settings
    var enableFuzzySearch: Bool
    var defaultSearchFolder: SearchFolder
    var searchFolderPreference: SearchFolderPreference
    var lastUsedSearchFolder: SearchFolder?
    var defaultQuickSearch: DefaultQuickSearch

    // Date/Business Day Settings
    var skipWeekends: Bool
    var skipHolidays: Bool

    // Canadian Holidays (for manual override/additions)
    var customHolidays: [String] // ISO date strings (yyyy-MM-dd)

    // Prep Workflow Settings
    var openPrepFolderWhenDone: Bool

    // CSV Column Names
    var csvDocketColumn: String
    var csvProjectTitleColumn: String
    var csvClientColumn: String
    var csvProducerColumn: String
    var csvStatusColumn: String
    var csvLicenseTotalColumn: String
    var csvCurrencyColumn: String
    var csvAgencyColumn: String
    var csvAgencyProducerColumn: String
    var csvMusicTypeColumn: String
    var csvTrackColumn: String
    var csvMediaColumn: String
    
    // Asana Integration (only used when docketSource == .asana)
    var asanaWorkspaceID: String?
    var asanaProjectID: String?
    var asanaClientID: String? // Stored in Keychain, not in settings
    var asanaClientSecret: String? // Stored in Keychain, not in settings
    var asanaDocketField: String? // Custom field name for docket number (if using custom fields)
    var asanaJobNameField: String? // Custom field name for job name (if using custom fields)
    
    // Shared Cache (optional - if set, will fetch from shared cache instead of syncing locally)
    var sharedCacheURL: String?
    var useSharedCache: Bool

    // Gmail Integration
    var gmailEnabled: Bool
    var gmailQuery: String // Gmail search query (e.g., "subject:New Docket") - deprecated, use gmailSearchTerms instead
    var gmailSearchTerms: [String] // Search terms/labels to look for (case-insensitive, e.g., ["New Docket", "DOCKET"])
    var gmailPollInterval: TimeInterval // Polling interval in seconds (default: 300 = 5 minutes)
    var docketParsingPatterns: [String] // Regex patterns for extracting docket info
    
    // CodeMind AI Integration
    var codeMindAPIKey: String? // Stored in Keychain, not in settings - API key for CodeMind AI email classification
    var codeMindProvider: String? // "gemini" or "grok" - determines which provider to use
    var codeMindOverlayEnabled: Bool // Show activity overlay on main window
    var codeMindOverlayDetailLevel: String // "minimal", "medium", or "detailed"
    var codeMindReviewThreshold: Double // Confidence threshold (0.0-1.0) - notifications below this go to "For Review" (default: 0.7)
    
    // Simian Integration (via Zapier webhook)
    var simianEnabled: Bool
    var simianWebhookURL: String? // Zapier webhook URL for creating Simian projects (get from Zapier Zap settings)
    var simianProjectTemplate: String? // Project template name/ID for Simian projects (always the same for all jobs)
    
    // Notification Window Settings
    var notificationWindowLocked: Bool // Whether notification window follows main window
    
    // Browser Preference
    var defaultBrowser: BrowserPreference // Default browser for opening email links

    // Advanced/Debug Settings
    var showDebugFeatures: Bool // Show debug/test features in notification center
    
    // Company Media Email Settings
    var companyMediaEmail: String // Email address to monitor for media file links (e.g., "media@graysonmusicgroup.com")
    
    // Media Team Grabbed Indicator Settings
    var mediaTeamEmails: [String] // List of media team email addresses
    var grabbedSubjectPatterns: [String] // Subject keywords that qualify as media-file-delivery (e.g., "FILE DELIVERY", "MEDIA FILE")
    var grabbedSubjectExclusions: [String] // Subject keywords that EXCLUDE from media-file-delivery (user-configurable, no defaults)
    var grabbedAttachmentTypes: [String] // File extensions that qualify as media files (e.g., "wav", "aiff", "zip", "mp4")
    var grabbedFileHostingWhitelist: [String] // Whitelist of file hosting domains for delivery (e.g., "drive.google.com", "wdrv.it")
    var grabbedSenderWhitelist: [String] // Approved sender email addresses
    var grabbedBodyExclusions: [String] // Body keywords that EXCLUDE from media-file-delivery (e.g., "check out", "review", "options posted")

    // Fun Feature: Cursed Image Replies
    var enableCursedImageReplies: Bool // Enable fun feature to send random images from Reddit instead of "Grabbed" text
    var cursedImageSubreddit: String // Subreddit name to fetch images from (e.g., "cursedimages")

    static var `default`: AppSettings {
        AppSettings(
            profileName: "Default",
            serverBasePath: "/Volumes/Grayson Assets/GM",
            sessionsBasePath: "/Volumes/Grayson Assets/SESSIONS",
            serverConnectionURL: "192.168.200.200",
            docketSource: .csv,
            appTheme: .modern,
            appearance: .system, // Default to system appearance
            updateChannel: .production,
            workPictureFolderName: "WORK PICTURE",
            prepFolderName: "SESSION PREP",
            yearPrefix: "GM_",
            dateFormat: "MMMd.yy",
            pictureExtensions: ["mp4", "mov", "avi", "mxf", "prores", "m4v"],
            musicExtensions: ["wav", "mp3", "aiff", "aif", "flac", "m4a", "aac"],
            aafOmfExtensions: ["aaf", "omf"],
            pictureFolderName: "PICTURE",
            musicFolderName: "MUSIC",
            aafOmfFolderName: "AAF-OMF",
            otherFolderName: "OTHER",
            workPicNumberFormat: "%02d",
            prepFolderFormat: "{docket}_PREP_{date}",
            enableFuzzySearch: true,
            defaultSearchFolder: .sessions,
            searchFolderPreference: .rememberLast,
            lastUsedSearchFolder: nil,
            defaultQuickSearch: .search,
            skipWeekends: true,
            skipHolidays: true,
            customHolidays: [],
            openPrepFolderWhenDone: true,
            csvDocketColumn: "Docket",
            csvProjectTitleColumn: "Licensor/Project Title",
            csvClientColumn: "Client",
            csvProducerColumn: "Grayson Producer",
            csvStatusColumn: "STATUS",
            csvLicenseTotalColumn: "Music License Totals",
            csvCurrencyColumn: "Currency",
            csvAgencyColumn: "Agency",
            csvAgencyProducerColumn: "Agency Producer / Supervisor",
            csvMusicTypeColumn: "Music Type",
            csvTrackColumn: "Track",
            csvMediaColumn: "Media",
            asanaWorkspaceID: nil,
            asanaProjectID: nil,
            asanaClientID: nil,
            asanaClientSecret: nil,
            asanaDocketField: nil,
            asanaJobNameField: nil,
            sharedCacheURL: "/Volumes/Grayson Assets/MEDIA/Media Dept Misc. Folders/Misc./MediaDash_Cache",
            useSharedCache: true,
            gmailEnabled: false,
            gmailQuery: "label:\"New Docket\"",
            gmailSearchTerms: ["New Docket", "DOCKET"], // Default search terms
            gmailPollInterval: 300, // 5 minutes
            docketParsingPatterns: [],
            codeMindAPIKey: nil, // Stored in Keychain
            codeMindProvider: nil, // Defaults to Claude if API key is set
            codeMindOverlayEnabled: false, // Activity overlay disabled by default
            codeMindOverlayDetailLevel: "medium", // Default detail level
            codeMindReviewThreshold: 0.7, // Default: notifications below 70% confidence go to review
            simianEnabled: false,
            simianWebhookURL: nil,
            simianProjectTemplate: nil,
            notificationWindowLocked: true, // Default to locked (follows main window)
            defaultBrowser: .chrome, // Default to Chrome
            showDebugFeatures: false, // Debug features hidden by default
            companyMediaEmail: "media@graysonmusicgroup.com", // Default company media email
            mediaTeamEmails: ["kevin@graysonmusicgroup.com", "mattfasullo@graysonmusicgroup.com", "jeremy@graysonmusicgroup.com"], // Default media team
            grabbedSubjectPatterns: [
                "audio",           // Most common - appears in many subjects
                "sfx",             // Sound effects
                "mix",             // Mix or mix prep
                "omf",             // OMF files
                "aaf",             // AAF files
                "prep",            // Audio prep, mix prep, prep files
                "elements",        // Audio elements
                "avtc",            // Audio/video timecode
                "dc",              // Director's cut
                "offline"          // Offline audio elements
            ], // Default subject patterns (case-insensitive matching)
            grabbedSubjectExclusions: [], // Subject exclusions (user-configurable, no defaults)
            grabbedAttachmentTypes: ["wav", "aiff", "aif", "zip", "mp4", "mov", "mxf", "prores", "m4v", "mp3", "flac", "m4a", "aac", "omf", "aaf"], // Default attachment types
            grabbedFileHostingWhitelist: [
                "drive.google.com",      // Google Drive
                "docs.google.com",      // Google Docs/Drive
                "wdrv.it",              // WeTransfer
                "wetransfer.com",       // WeTransfer
                "wpp.box.com",          // Box (WPP)
                "box.com",              // Box
                "boxusercontent.com",   // Box
                "psi.schoolediting.com", // School Editing custom hosting
                "f.io"                  // Frame.io (delivery links, not review)
            ], // Default file hosting whitelist (based on real examples)
            grabbedSenderWhitelist: [], // Default sender whitelist (empty, user can add)
            grabbedBodyExclusions: [], // Body exclusions (user-configurable, no defaults)
            enableCursedImageReplies: false, // Fun feature disabled by default
            cursedImageSubreddit: "cursedimages" // Default subreddit
        )
    }
}

// MARK: - Settings Manager

@MainActor
class SettingsManager: ObservableObject {
    @Published var currentSettings: AppSettings
    @Published var availableProfiles: [String] = []

    private let userDefaults = UserDefaults.standard
    private let currentProfileKey = "currentProfile"
    private let profilesKey = "savedProfiles"

    init() {
        // Initialize stored properties first (required before calling instance methods)
        // Load current profile name
        let profileName = userDefaults.string(forKey: currentProfileKey) ?? "Default"

        // Load available profiles
        if let profilesData = userDefaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData) {
            self.availableProfiles = Array(profiles.keys).sorted()
            self.currentSettings = profiles[profileName] ?? .default
        } else {
            // First launch - create default profile
            self.currentSettings = .default
            self.availableProfiles = ["Default"]
        }
        
        // Now that all stored properties are initialized, we can call instance methods
        // Reset path-related settings to defaults on app update
        // This ensures paths work consistently across different machines
        resetPathsOnUpdateIfNeeded()
        
        // After reset, reload profiles in case they were modified
        if let profilesData = userDefaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData) {
            self.availableProfiles = Array(profiles.keys).sorted()
            let updatedProfileName = userDefaults.string(forKey: currentProfileKey) ?? profileName
            self.currentSettings = profiles[updatedProfileName] ?? profiles[profileName] ?? .default
        }
        
        // If this was first launch, save the default profile after reset
        if availableProfiles.count == 1 && availableProfiles.first == "Default" {
            saveProfile(settings: .default, name: "Default")
        }
    }
    
    /// Resets path-related settings to defaults when app version changes
    /// This ensures paths work consistently across different machines
    private func resetPathsOnUpdateIfNeeded() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let lastResetVersion = userDefaults.string(forKey: "lastPathResetVersion") ?? "0.0.0"
        
        // If version changed, reset path-related settings to defaults
        if currentVersion != lastResetVersion {
            print("🔄 App version changed from \(lastResetVersion) to \(currentVersion)")
            print("   Resetting path-related settings to defaults...")
            
            // Load all profiles
            var profiles = loadAllProfiles()
            
            // Reset path-related settings for each profile
            for (profileName, var profile) in profiles {
                profile.serverBasePath = AppSettings.default.serverBasePath
                profile.sessionsBasePath = AppSettings.default.sessionsBasePath
                profile.workPictureFolderName = AppSettings.default.workPictureFolderName
                profile.yearPrefix = AppSettings.default.yearPrefix
                profiles[profileName] = profile
                print("   ✓ Reset paths for profile: \(profileName)")
            }
            
            // Save updated profiles
            if let encoded = try? JSONEncoder().encode(profiles) {
                userDefaults.set(encoded, forKey: profilesKey)
            }
            
            // Store current version so we don't reset again until next update
            userDefaults.set(currentVersion, forKey: "lastPathResetVersion")
            print("   ✅ Paths reset to defaults")
        }
    }

    // Custom init for workspace profiles
    init(settings: AppSettings) {
        self.currentSettings = settings
        self.availableProfiles = []
    }

    func saveCurrentProfile() {
        saveProfile(settings: currentSettings, name: currentSettings.profileName)
    }

    func saveProfile(settings: AppSettings, name: String) {
        var profiles = loadAllProfiles()
        profiles[name] = settings

        if let encoded = try? JSONEncoder().encode(profiles) {
            userDefaults.set(encoded, forKey: profilesKey)
            let profileKeys = Array(profiles.keys).sorted()
            // Defer state update to avoid SwiftUI warning - use Task to ensure it happens after view update
            Task { @MainActor in
                self.availableProfiles = profileKeys
            }
        }
    }

    func loadProfile(name: String) {
        let profiles = loadAllProfiles()
        if let profile = profiles[name] {
            currentSettings = profile
            userDefaults.set(name, forKey: currentProfileKey)
        }
    }

    func deleteProfile(name: String) {
        guard name != "Default" else { return } // Can't delete default

        var profiles = loadAllProfiles()
        profiles.removeValue(forKey: name)

        if let encoded = try? JSONEncoder().encode(profiles) {
            userDefaults.set(encoded, forKey: profilesKey)
            availableProfiles = Array(profiles.keys).sorted()

            // If we deleted the current profile, switch to default
            if currentSettings.profileName == name {
                loadProfile(name: "Default")
            }
        }
    }

    func duplicateProfile(name: String, newName: String) {
        let profiles = loadAllProfiles()
        if var profile = profiles[name] {
            profile.profileName = newName
            saveProfile(settings: profile, name: newName)
        }
    }

    func resetToDefaults() {
        currentSettings = .default
        saveCurrentProfile()
    }
    
    private func loadAllProfiles() -> [String: AppSettings] {
        guard let profilesData = userDefaults.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData) else {
            return ["Default": .default]
        }
        return profiles
    }
}
