import Foundation

/// Helper functions for adding debug logging that the AI assistant can read
/// Use these when you need to debug issues - the AI will automatically read the logs
extension FileLogger {
    /// Log a debug message with automatic component detection
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let component = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        log("\(function):\(line) - \(message)", level: .debug, component: component)
    }
    
    /// Log an error with context
    func error(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        let component = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        var fullMessage = "\(function):\(line) - \(message)"
        if let error = error {
            fullMessage += " | Error: \(error.localizedDescription)"
        }
        log(fullMessage, level: .error, component: component)
    }
    
    /// Log a value for debugging
    func debugValue<T>(_ label: String, _ value: T, file: String = #file, function: String = #function, line: Int = #line) {
        let component = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        log("\(function):\(line) - \(label) = \(value)", level: .debug, component: component)
    }
}

/// Convenience functions for quick debugging
func debugLog(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    Task { @MainActor in
        FileLogger.shared.debug(message, file: file, function: function, line: line)
    }
}

func errorLog(_ message: String, error: Error? = nil, file: String = #file, function: String = #function, line: Int = #line) {
    Task { @MainActor in
        FileLogger.shared.error(message, error: error, file: file, function: function, line: line)
    }
}

func debugValue<T>(_ label: String, _ value: T, file: String = #file, function: String = #function, line: Int = #line) {
    Task { @MainActor in
        FileLogger.shared.debugValue(label, value, file: file, function: function, line: line)
    }
}

