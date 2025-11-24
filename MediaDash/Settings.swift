import Foundation
import SwiftUI
import Combine

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

    // Job Info Source
    var docketSource: DocketSource

    // App Theme
    var appTheme: AppTheme

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

    static var `default`: AppSettings {
        AppSettings(
            profileName: "Default",
            serverBasePath: "/Volumes/Grayson Assets/GM",
            sessionsBasePath: "/Volumes/Grayson Assets/SESSIONS",
            docketSource: .csv,
            appTheme: .modern,
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
            asanaJobNameField: nil
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
            saveProfile(settings: .default, name: "Default")
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
            // Defer state update to avoid SwiftUI warning
            DispatchQueue.main.async {
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

    private func loadAllProfiles() -> [String: AppSettings] {
        guard let profilesData = userDefaults.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([String: AppSettings].self, from: profilesData) else {
            return ["Default": .default]
        }
        return profiles
    }

    func resetToDefaults() {
        currentSettings = .default
        saveCurrentProfile()
    }
}
