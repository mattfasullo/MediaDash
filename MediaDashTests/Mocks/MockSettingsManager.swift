import Foundation
@testable import MediaDash

/// Mock implementation of SettingsProviding for testing
class MockSettingsManager: SettingsProviding {
    var currentSettings: AppSettings
    
    init(settings: AppSettings = .default) {
        self.currentSettings = settings
    }
    
    func updateConfig(settings: AppSettings) {
        self.currentSettings = settings
    }
}

