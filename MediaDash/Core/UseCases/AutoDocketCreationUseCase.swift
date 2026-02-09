import Foundation

/// Use case for automatically creating docket folders
struct AutoDocketCreationUseCase {
    nonisolated(unsafe) let fileSystem: FileSystem
    let config: AppConfig
    
    nonisolated init(fileSystem: FileSystem = DefaultFileSystem(), config: AppConfig) {
        self.fileSystem = fileSystem
        self.config = config
    }
    
    /// Create a docket folder automatically
    /// - Parameters:
    ///   - docketNumber: The docket number
    ///   - jobName: The job name
    ///   - existingDockets: Array of existing docket names to check for duplicates
    /// - Returns: Result indicating success or failure
    func createDocket(docketNumber: String, jobName: String, existingDockets: [String]) async throws -> DocketCreationResult {
        // Validate inputs
        let trimmedNumber = docketNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJobName = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedNumber.isEmpty else {
            throw DocketCreationError.invalidInput("Docket number cannot be empty")
        }
        
        guard !trimmedJobName.isEmpty else {
            throw DocketCreationError.invalidInput("Job name cannot be empty")
        }
        
        // Validate docket number format: at least 5 characters, optionally with "-US" suffix
        // Supports both numeric (25493) and alphanumeric (26XXX) formats for testing
        let baseNumber: String
        if trimmedNumber.uppercased().hasSuffix("-US") {
            baseNumber = String(trimmedNumber.dropLast(3))
        } else {
            baseNumber = trimmedNumber
        }
        
        guard baseNumber.count >= 5 else {
            throw DocketCreationError.invalidInput("Docket number must be at least 5 characters (e.g., 25493 or 25493-US)")
        }
        
        let docketName = "\(trimmedNumber)_\(trimmedJobName)"
        
        // Check if docket already exists
        if existingDockets.contains(docketName) {
            throw DocketCreationError.alreadyExists(docketName)
        }
        
        // Get paths
        let paths = config.getPaths()
        let fm = fileSystem
        
        // Verify parent directory exists
        guard fm.fileExists(atPath: paths.workPic.path) else {
            throw DocketCreationError.directoryNotFound(paths.workPic.path)
        }
        
        let docketFolder = paths.workPic.appendingPathComponent(docketName)
        
        // Check if folder already exists on disk
        if fm.fileExists(atPath: docketFolder.path) {
            throw DocketCreationError.alreadyExists(docketName)
        }
        
        // Create the docket folder
        do {
            try fm.createDirectory(at: docketFolder, withIntermediateDirectories: false, attributes: nil)
            return DocketCreationResult(
                success: true,
                docketName: docketName,
                path: docketFolder.path
            )
        } catch {
            throw DocketCreationError.creationFailed(error.localizedDescription)
        }
    }
}

/// Result of docket creation attempt
struct DocketCreationResult {
    let success: Bool
    let docketName: String
    let path: String
}

/// Errors that can occur during docket creation
enum DocketCreationError: LocalizedError {
    case invalidInput(String)
    case alreadyExists(String)
    case directoryNotFound(String)
    case creationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .alreadyExists(let docketName):
            return "Docket '\(docketName)' already exists"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .creationFailed(let message):
            return "Failed to create docket folder: \(message)"
        }
    }
}

