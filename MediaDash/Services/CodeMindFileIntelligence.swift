import Foundation
import Combine

// MARK: - File Intelligence Models

/// Represents a tracked file with intelligence
struct TrackedFile: Identifiable, Equatable {
    let id: String
    let path: String
    let name: String
    let fileType: FileType
    var docketNumber: String?
    var relationships: [FileRelationship]
    var validationStatus: ValidationStatus
    var lastAnalyzed: Date
    var metadata: FileMetadata?
    
    enum FileType: String, Codable, CaseIterable {
        case proToolsSession = "ProTools Session"
        case audio = "Audio"
        case video = "Video"
        case omfAaf = "OMF/AAF"
        case document = "Document"
        case archive = "Archive"
        case other = "Other"
        
        static func from(extension ext: String) -> FileType {
            let lower = ext.lowercased()
            switch lower {
            case "ptx", "ptf", "pts":
                return .proToolsSession
            case "wav", "aif", "aiff", "mp3", "m4a", "flac":
                return .audio
            case "mov", "mp4", "avi", "mxf", "prores":
                return .video
            case "omf", "aaf":
                return .omfAaf
            case "pdf", "doc", "docx", "txt", "rtf":
                return .document
            case "zip", "rar", "7z", "tar", "gz":
                return .archive
            default:
                return .other
            }
        }
    }
    
    enum ValidationStatus: String, Codable {
        case valid = "Valid"
        case incomplete = "Incomplete"
        case missingDependencies = "Missing Dependencies"
        case corrupted = "Corrupted"
        case unknown = "Unknown"
    }
    
    struct FileMetadata: Codable, Equatable {
        var size: Int64?
        var createdAt: Date?
        var modifiedAt: Date?
        var duration: Double? // For audio/video
        var sampleRate: Int? // For audio
        var channels: Int? // For audio
        var resolution: String? // For video
    }
    
    static func == (lhs: TrackedFile, rhs: TrackedFile) -> Bool {
        lhs.id == rhs.id
    }
}

/// Represents a relationship between files
struct FileRelationship: Identifiable, Codable, Equatable {
    let id: UUID
    let relatedFileId: String
    let relatedFileName: String
    let relationshipType: RelationshipType
    var status: RelationshipStatus
    
    enum RelationshipType: String, Codable {
        case sessionContains = "Session Contains" // Session -> Audio files
        case linkedMedia = "Linked Media" // OMF/AAF -> Audio files
        case deliveryBundle = "Delivery Bundle" // Files delivered together
        case stemGroup = "Stem Group" // Related stems
        case versionOf = "Version Of" // Different versions of same file
    }
    
    enum RelationshipStatus: String, Codable {
        case resolved = "Resolved" // Related file exists
        case missing = "Missing" // Related file not found
        case broken = "Broken" // Link broken
    }
}

/// Represents a file delivery (group of files from an email)
struct FileDelivery: Identifiable, Equatable {
    let id: String
    let emailId: String?
    let emailSubject: String?
    let docketNumber: String?
    var files: [TrackedFile]
    var expectedFiles: [ExpectedFile]
    var completeness: Double // 0.0 to 1.0
    var receivedAt: Date
    var lastChecked: Date
    
    struct ExpectedFile: Codable, Equatable {
        let name: String
        let pattern: String? // Regex pattern to match
        let isRequired: Bool
        var isReceived: Bool
    }
    
    static func == (lhs: FileDelivery, rhs: FileDelivery) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - File Intelligence Engine

/// Background engine that analyzes files, tracks dependencies, and validates completeness
@MainActor
class CodeMindFileIntelligence: ObservableObject {
    static let shared = CodeMindFileIntelligence()
    
    // Published state for BrainView
    @Published private(set) var trackedFiles: [TrackedFile] = []
    @Published private(set) var fileDeliveries: [FileDelivery] = []
    @Published private(set) var missingFiles: [FileRelationship] = []
    @Published private(set) var incompleteDeliveries: [FileDelivery] = []
    @Published private(set) var isAnalyzing = false
    @Published private(set) var lastAnalysisDate: Date?
    
    // Internal tracking
    private var fileMap: [String: TrackedFile] = [:] // path -> file
    private var deliveryMap: [String: FileDelivery] = [:] // id -> delivery
    
    private init() {}
    
    // MARK: - File Tracking
    
    /// Track a file and analyze its properties
    func trackFile(
        path: String,
        docketNumber: String? = nil,
        fromDeliveryId: String? = nil
    ) async -> TrackedFile {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let ext = url.pathExtension
        let fileType = TrackedFile.FileType.from(extension: ext)
        
        // Generate ID from path hash
        let id = "\(path.hashValue)"
        
        // Get file metadata
        var metadata: TrackedFile.FileMetadata?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            metadata = TrackedFile.FileMetadata(
                size: attrs[.size] as? Int64,
                createdAt: attrs[.creationDate] as? Date,
                modifiedAt: attrs[.modificationDate] as? Date,
                duration: nil,
                sampleRate: nil,
                channels: nil,
                resolution: nil
            )
        }
        
        // Determine validation status
        let validationStatus = await validateFile(path: path, fileType: fileType)
        
        // Find relationships
        var relationships: [FileRelationship] = []
        if fileType == .proToolsSession || fileType == .omfAaf {
            relationships = await analyzeSessionDependencies(path: path, fileType: fileType)
        }
        
        let trackedFile = TrackedFile(
            id: id,
            path: path,
            name: name,
            fileType: fileType,
            docketNumber: docketNumber,
            relationships: relationships,
            validationStatus: validationStatus,
            lastAnalyzed: Date(),
            metadata: metadata
        )
        
        fileMap[path] = trackedFile
        updatePublishedState()
        
        // If part of a delivery, update that too
        if let deliveryId = fromDeliveryId, var delivery = deliveryMap[deliveryId] {
            if !delivery.files.contains(where: { $0.id == id }) {
                delivery.files.append(trackedFile)
                delivery.lastChecked = Date()
                deliveryMap[deliveryId] = delivery
            }
        }
        
        CodeMindLogger.shared.log(.debug, "Tracked file", category: .general, metadata: [
            "name": name,
            "type": fileType.rawValue,
            "status": validationStatus.rawValue
        ])
        
        return trackedFile
    }
    
    /// Track a file delivery from an email
    func trackDelivery(
        emailId: String?,
        emailSubject: String?,
        docketNumber: String?,
        files: [String], // File paths
        expectedPatterns: [String]? = nil
    ) async -> FileDelivery {
        let id = emailId ?? UUID().uuidString
        
        // Track each file
        var trackedFilesList: [TrackedFile] = []
        for filePath in files {
            let tracked = await trackFile(path: filePath, docketNumber: docketNumber, fromDeliveryId: id)
            trackedFilesList.append(tracked)
        }
        
        // Build expected files list
        var expectedFiles: [FileDelivery.ExpectedFile] = []
        if let patterns = expectedPatterns {
            for pattern in patterns {
                let isReceived = trackedFilesList.contains { file in
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                        let range = NSRange(file.name.startIndex..., in: file.name)
                        return regex.firstMatch(in: file.name, range: range) != nil
                    }
                    return file.name.contains(pattern)
                }
                expectedFiles.append(FileDelivery.ExpectedFile(
                    name: pattern,
                    pattern: pattern,
                    isRequired: true,
                    isReceived: isReceived
                ))
            }
        }
        
        // Calculate completeness
        let completeness: Double
        if expectedFiles.isEmpty {
            completeness = 1.0 // No expectations = complete
        } else {
            let received = expectedFiles.filter { $0.isReceived }.count
            completeness = Double(received) / Double(expectedFiles.count)
        }
        
        let delivery = FileDelivery(
            id: id,
            emailId: emailId,
            emailSubject: emailSubject,
            docketNumber: docketNumber,
            files: trackedFilesList,
            expectedFiles: expectedFiles,
            completeness: completeness,
            receivedAt: Date(),
            lastChecked: Date()
        )
        
        deliveryMap[id] = delivery
        updatePublishedState()
        
        CodeMindLogger.shared.log(.info, "Tracked file delivery", category: .general, metadata: [
            "id": id,
            "fileCount": "\(files.count)",
            "completeness": String(format: "%.0f%%", completeness * 100)
        ])
        
        return delivery
    }
    
    // MARK: - File Analysis
    
    /// Validate a file based on its type
    private func validateFile(path: String, fileType: TrackedFile.FileType) async -> TrackedFile.ValidationStatus {
        let fm = FileManager.default
        
        guard fm.fileExists(atPath: path) else {
            return .corrupted
        }
        
        // Check if file is readable and has content
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64,
              size > 0 else {
            return .corrupted
        }
        
        // Type-specific validation
        switch fileType {
        case .proToolsSession:
            // ProTools sessions should have reasonable size
            if size < 1000 {
                return .corrupted
            }
            return .valid
            
        case .omfAaf:
            // OMF/AAF files need proper header
            if size < 1000 {
                return .corrupted
            }
            // Could add more sophisticated validation here
            return .valid
            
        case .audio:
            // Audio files should have reasonable size
            if size < 100 {
                return .corrupted
            }
            return .valid
            
        case .video:
            // Video files should have reasonable size
            if size < 1000 {
                return .corrupted
            }
            return .valid
            
        default:
            return .valid
        }
    }
    
    /// Analyze session files for dependencies
    private func analyzeSessionDependencies(path: String, fileType: TrackedFile.FileType) async -> [FileRelationship] {
        var relationships: [FileRelationship] = []
        
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fm = FileManager.default
        
        // Look for audio files in same directory and subdirectories
        let audioExtensions = ["wav", "aif", "aiff", "mp3", "m4a"]
        
        if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
            while let fileURL = enumerator.nextObject() as? URL {
                let ext = fileURL.pathExtension.lowercased()
                if audioExtensions.contains(ext) {
                    let relatedId = "\(fileURL.path.hashValue)"
                    let exists = fm.fileExists(atPath: fileURL.path)
                    
                    let relationship = FileRelationship(
                        id: UUID(),
                        relatedFileId: relatedId,
                        relatedFileName: fileURL.lastPathComponent,
                        relationshipType: fileType == .proToolsSession ? .sessionContains : .linkedMedia,
                        status: exists ? .resolved : .missing
                    )
                    relationships.append(relationship)
                }
            }
        }
        
        return relationships
    }
    
    // MARK: - Dependency Checking
    
    /// Check for missing dependencies across all tracked files
    func checkAllDependencies() async {
        isAnalyzing = true
        
        var allMissing: [FileRelationship] = []
        
        for (path, var file) in fileMap {
            // Re-analyze dependencies for session files
            if file.fileType == .proToolsSession || file.fileType == .omfAaf {
                file.relationships = await analyzeSessionDependencies(path: path, fileType: file.fileType)
                file.lastAnalyzed = Date()
                fileMap[path] = file
            }
            
            // Collect missing relationships
            let missing = file.relationships.filter { $0.status == .missing }
            allMissing.append(contentsOf: missing)
        }
        
        missingFiles = allMissing
        updatePublishedState()
        
        lastAnalysisDate = Date()
        isAnalyzing = false
        
        CodeMindLogger.shared.log(.info, "Dependency check complete", category: .general, metadata: [
            "totalFiles": "\(fileMap.count)",
            "missingDependencies": "\(allMissing.count)"
        ])
    }
    
    /// Check completeness of all deliveries
    func checkDeliveryCompleteness() async {
        isAnalyzing = true
        
        var incomplete: [FileDelivery] = []
        
        for (id, var delivery) in deliveryMap {
            // Re-check expected files
            for i in delivery.expectedFiles.indices {
                let pattern = delivery.expectedFiles[i].pattern ?? delivery.expectedFiles[i].name
                let isReceived = delivery.files.contains { file in
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                        let range = NSRange(file.name.startIndex..., in: file.name)
                        return regex.firstMatch(in: file.name, range: range) != nil
                    }
                    return file.name.contains(pattern)
                }
                delivery.expectedFiles[i].isReceived = isReceived
            }
            
            // Recalculate completeness
            if !delivery.expectedFiles.isEmpty {
                let received = delivery.expectedFiles.filter { $0.isReceived }.count
                delivery.completeness = Double(received) / Double(delivery.expectedFiles.count)
            }
            
            delivery.lastChecked = Date()
            deliveryMap[id] = delivery
            
            if delivery.completeness < 1.0 {
                incomplete.append(delivery)
            }
        }
        
        incompleteDeliveries = incomplete
        updatePublishedState()
        
        isAnalyzing = false
        
        CodeMindLogger.shared.log(.info, "Delivery completeness check complete", category: .general, metadata: [
            "totalDeliveries": "\(deliveryMap.count)",
            "incompleteDeliveries": "\(incomplete.count)"
        ])
    }
    
    // MARK: - Queries
    
    /// Get files for a docket
    func getFiles(for docketNumber: String) -> [TrackedFile] {
        return trackedFiles.filter { $0.docketNumber == docketNumber }
    }
    
    /// Get deliveries for a docket
    func getDeliveries(for docketNumber: String) -> [FileDelivery] {
        return fileDeliveries.filter { $0.docketNumber == docketNumber }
    }
    
    /// Get file by path
    func getFile(path: String) -> TrackedFile? {
        return fileMap[path]
    }
    
    /// Get all files with missing dependencies
    func getFilesWithMissingDependencies() -> [TrackedFile] {
        return trackedFiles.filter { file in
            file.relationships.contains { $0.status == .missing }
        }
    }
    
    // MARK: - State Management
    
    private func updatePublishedState() {
        trackedFiles = Array(fileMap.values).sorted { $0.lastAnalyzed > $1.lastAnalyzed }
        fileDeliveries = Array(deliveryMap.values).sorted { $0.receivedAt > $1.receivedAt }
    }
    
    /// Clear all tracked data
    func clearAll() {
        fileMap.removeAll()
        deliveryMap.removeAll()
        missingFiles.removeAll()
        incompleteDeliveries.removeAll()
        updatePublishedState()
    }
}

