import Foundation
import OSLog

/// Centralized file-based logger that captures all debug output
/// This logger writes to both console (for Xcode) and a file (for AI assistant access)
@MainActor
class FileLogger {
    static let shared = FileLogger()
    
    private let logFileURL: URL
    private let fileHandle: FileHandle?
    private let logger = Logger(subsystem: "com.mediadash", category: "FileLogger")
    private let dateFormatter: DateFormatter
    
    private init() {
        // Create log file in ~/Library/Logs/MediaDash/
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs")
            .appendingPathComponent("MediaDash")
        
        // Create directory if it doesn't exist
        if let logsDir = logsDirectory {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            logFileURL = logsDir.appendingPathComponent("mediadash-debug.log")
        } else {
            // Fallback to Documents if Library is unavailable
            let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            logFileURL = documentsDir.appendingPathComponent("mediadash-debug.log")
        }
        
        // Set up date formatter
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Open or create log file
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        // Open file handle for appending
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
        
        // Write init to file only (avoid duplicate console/OSLog output)
        let initMsg = "FileLogger initialized - logs will be written to: \(logFileURL.path)"
        if let data = "[\(dateFormatter.string(from: Date()))] INFO  [App] \(initMsg)\n".data(using: .utf8) {
            fileHandle?.write(data)
        }
    }
    
    deinit {
        fileHandle?.closeFile()
    }
    
    /// Log a message to both console and file
    func log(_ message: String, level: LogLevel = .debug, component: String = "App") {
        let timestamp = dateFormatter.string(from: Date())
        let levelPrefix = levelPrefix(for: level)
        let logLine = "[\(timestamp)] \(levelPrefix) [\(component)] \(message)\n"
        
        // Write to file (only fsync on errors to reduce I/O overhead)
        if let data = logLine.data(using: .utf8) {
            fileHandle?.write(data)
            if level == .error || level == .critical {
                fileHandle?.synchronizeFile()
            }
        }
        
        // Also log to OSLog
        switch level {
        case .debug:
            logger.debug("\(message)")
        case .info:
            logger.info("\(message)")
        case .warning:
            logger.warning("\(message)")
        case .error:
            logger.error("\(message)")
        case .critical:
            logger.critical("\(message)")
        }
        
        // Print to console (for Xcode) - use Swift.print to avoid recursion
        #if DEBUG
        Swift.print(logLine.trimmingCharacters(in: .whitespacesAndNewlines))
        #endif
    }
    
    private func levelPrefix(for level: LogLevel) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warning: return "WARN "
        case .error: return "ERROR"
        case .critical: return "CRIT "
        }
    }
    
    /// Get the path to the log file
    var logFilePath: String {
        logFileURL.path
    }
}

/// Global function to easily log messages
func log(_ message: String, level: LogLevel = .debug, component: String = "App") {
    Task { @MainActor in
        FileLogger.shared.log(message, level: level, component: component)
    }
}

