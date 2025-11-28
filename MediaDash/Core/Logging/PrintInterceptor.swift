import Foundation

/// Optional: Intercepts print() statements and also writes them to the file logger
/// To use this, import it in files where you want automatic print() logging:
///   import MediaDash.PrintInterceptor
/// 
/// Note: This is optional. You can also use FileLogger.shared.log() directly
/// or the global log() function for explicit logging.

// Uncomment the following to enable automatic print() interception:
// This will capture all print() calls and also log them to file
/*
public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    // Build the message string
    let message = items.map { "\($0)" }.joined(separator: separator)
    
    // Call the standard print function (Swift.print to avoid recursion)
    Swift.print(message, terminator: terminator)
    
    // Also log to file (async to avoid blocking)
    Task { @MainActor in
        // Use Swift.print in FileLogger to avoid recursion
        FileLogger.shared.log(message, level: .debug, component: "Print")
    }
}
*/

