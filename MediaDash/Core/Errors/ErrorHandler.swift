import Foundation
import OSLog

/// Log levels for error reporting
enum LogLevel {
    case debug
    case info
    case warning
    case error
    case critical
}

/// Context for error reporting
struct ErrorContext {
    let component: String
    let operation: String
    let userInfo: [String: Any]?
    
    init(component: String, operation: String, userInfo: [String: Any]? = nil) {
        self.component = component
        self.operation = operation
        self.userInfo = userInfo
    }
}

/// Protocol for error handling
protocol ErrorHandling {
    func handle(_ error: Error, context: ErrorContext)
    func log(_ error: Error, level: LogLevel, context: ErrorContext)
}

/// Default error handler implementation
@MainActor
class ErrorHandler: ErrorHandling {
    static let shared = ErrorHandler()
    
    private let logger = Logger(subsystem: "com.mediadash", category: "ErrorHandler")
    
    private init() {}
    
    func handle(_ error: Error, context: ErrorContext) {
        // Log the error
        log(error, level: .error, context: context)
        
        // For now, just log. In the future, we can add:
        // - Error analytics
        // - User notification
        // - Error recovery strategies
    }
    
    func log(_ error: Error, level: LogLevel, context: ErrorContext) {
        let errorMessage = error.localizedDescription
        let logMessage = "[\(context.component)] \(context.operation): \(errorMessage)"
        
        switch level {
        case .debug:
            logger.debug("\(logMessage)")
        case .info:
            logger.info("\(logMessage)")
        case .warning:
            logger.warning("\(logMessage)")
        case .error:
            logger.error("\(logMessage)")
        case .critical:
            logger.critical("\(logMessage)")
        }
        
        // Also print to console for development
        #if DEBUG
        print("\(level): \(logMessage)")
        if let userInfo = context.userInfo {
            print("  Context: \(userInfo)")
        }
        #endif
    }
}

