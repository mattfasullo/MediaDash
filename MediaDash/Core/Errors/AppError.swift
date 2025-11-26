import Foundation

/// Unified error type for the application
enum AppError: LocalizedError {
    case fileSystem(FileSystemError)
    case network(NetworkError)
    case validation(ValidationError)
    case configuration(ConfigurationError)
    case asana(AsanaError)
    case oauth(OAuthError)
    
    var errorDescription: String? {
        switch self {
        case .fileSystem(let error):
            return "File System Error: \(error.localizedDescription)"
        case .network(let error):
            return "Network Error: \(error.localizedDescription)"
        case .validation(let error):
            return "Validation Error: \(error.localizedDescription)"
        case .configuration(let error):
            return "Configuration Error: \(error.localizedDescription)"
        case .asana(let error):
            return "Asana Error: \(error.localizedDescription)"
        case .oauth(let error):
            return "OAuth Error: \(error.localizedDescription)"
        }
    }
}

/// File system related errors
enum FileSystemError: LocalizedError {
    case fileNotFound(String)
    case directoryNotFound(String)
    case copyFailed(String, String)
    case createDirectoryFailed(String)
    case accessDenied(String)
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .copyFailed(let from, let to):
            return "Failed to copy from \(from) to \(to)"
        case .createDirectoryFailed(let path):
            return "Failed to create directory: \(path)"
        case .accessDenied(let path):
            return "Access denied: \(path)"
        }
    }
}

/// Network related errors
enum NetworkError: LocalizedError {
    case invalidURL(String)
    case requestFailed(Int, String)
    case noData
    case decodingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .requestFailed(let code, let message):
            return "Request failed with status \(code): \(message)"
        case .noData:
            return "No data received"
        case .decodingFailed(let message):
            return "Failed to decode response: \(message)"
        }
    }
}

/// Configuration related errors
enum ConfigurationError: LocalizedError {
    case missingSetting(String)
    case invalidSetting(String, String)
    case pathNotConfigured(String)
    
    var errorDescription: String? {
        switch self {
        case .missingSetting(let key):
            return "Missing required setting: \(key)"
        case .invalidSetting(let key, let value):
            return "Invalid setting \(key): \(value)"
        case .pathNotConfigured(let path):
            return "Path not configured: \(path)"
        }
    }
}

