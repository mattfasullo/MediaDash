import Foundation

/// Protocol for providing app settings
protocol SettingsProviding {
    var currentSettings: AppSettings { get }
    func updateConfig(settings: AppSettings)
}

