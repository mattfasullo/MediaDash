import SwiftUI
import CryptoKit

// MARK: - Cache Integrity

/// Cache format version constants
enum CacheFormat {
    /// Current cache format version - increment when making breaking changes to the cache structure
    nonisolated static let version: Int = 2
}

/// Result of cache integrity validation
enum CacheValidationResult: Sendable {
    case valid
    case corrupted(reason: String)
    case versionMismatch(found: Int, expected: Int)
    case checksumMismatch
    case countMismatch(found: Int, expected: Int)
    case missingIntegrity // Old cache without integrity data (not necessarily corrupt)
    
    nonisolated var isValid: Bool {
        if case .valid = self { return true }
        if case .missingIntegrity = self { return true } // Old caches without integrity are still usable
        return false
    }
    
    nonisolated var isCorrupted: Bool {
        switch self {
        case .corrupted, .checksumMismatch, .countMismatch:
            return true
        default:
            return false
        }
    }
    
    nonisolated var description: String {
        switch self {
        case .valid:
            return "Cache is valid"
        case .corrupted(let reason):
            return "Cache is corrupted: \(reason)"
        case .versionMismatch(let found, let expected):
            return "Cache version mismatch: found v\(found), expected v\(expected)"
        case .checksumMismatch:
            return "Cache checksum mismatch - data may be corrupted"
        case .countMismatch(let found, let expected):
            return "Cache count mismatch: found \(found), expected \(expected) - possible truncation"
        case .missingIntegrity:
            return "Cache missing integrity data (legacy format)"
        }
    }
}

/// Integrity metadata for cache validation
struct CacheIntegrity: Codable, Sendable {
    /// Cache format version
    let version: Int
    /// Expected docket count
    let docketCount: Int
    /// SHA256 checksum of docket data (computed from sorted docket fullNames)
    let checksum: String
    /// Timestamp when integrity was computed
    let computedAt: Date
    /// Historical peak docket count (optional, for detecting incomplete syncs)
    let peakDocketCount: Int?
    /// Timestamp of last full sync (optional, helps determine when to force full sync)
    let lastFullSyncDate: Date?
    /// Project GIDs that contain docket tasks (for smart sync optimization)
    let docketBearingProjectIDs: [String]?
    /// Timestamp of last full project discovery (when we scanned all projects)
    let lastDiscoveryDate: Date?
    
    nonisolated init(version: Int = CacheFormat.version, docketCount: Int, checksum: String, computedAt: Date = Date(), peakDocketCount: Int? = nil, lastFullSyncDate: Date? = nil, docketBearingProjectIDs: [String]? = nil, lastDiscoveryDate: Date? = nil) {
        self.version = version
        self.docketCount = docketCount
        self.checksum = checksum
        self.computedAt = computedAt
        self.peakDocketCount = peakDocketCount
        self.lastFullSyncDate = lastFullSyncDate
        self.docketBearingProjectIDs = docketBearingProjectIDs
        self.lastDiscoveryDate = lastDiscoveryDate
    }
    
    /// Compute checksum for a list of dockets
    nonisolated static func computeChecksum(for dockets: [DocketInfo]) -> String {
        // Create a deterministic string from sorted docket fullNames
        let sortedNames = dockets.map { $0.fullName }.sorted().joined(separator: "|")
        let data = Data(sortedNames.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    /// Create integrity metadata for a list of dockets
    /// - Parameters:
    ///   - dockets: The dockets to create integrity for
    ///   - previousPeakCount: Previous peak count for comparison
    ///   - isFullSync: Whether this was a full sync
    ///   - docketBearingProjectIDs: Project GIDs that contain dockets (for smart sync)
    ///   - isDiscovery: Whether this was a full discovery scan of all projects
    nonisolated static func create(for dockets: [DocketInfo], previousPeakCount: Int? = nil, isFullSync: Bool = false, docketBearingProjectIDs: [String]? = nil, isDiscovery: Bool = false) -> CacheIntegrity {
        let newPeak = max(dockets.count, previousPeakCount ?? 0)
        return CacheIntegrity(
            docketCount: dockets.count,
            checksum: computeChecksum(for: dockets),
            peakDocketCount: newPeak,
            lastFullSyncDate: isFullSync ? Date() : nil,
            docketBearingProjectIDs: docketBearingProjectIDs,
            lastDiscoveryDate: isDiscovery ? Date() : nil
        )
    }
    
    /// Check if a full project discovery is needed (scanned all projects to find docket-bearing ones)
    nonisolated func needsDiscovery(maxAgeDays: Int = 7) -> Bool {
        // Need discovery if we don't have the project list or it's stale
        guard let projectIDs = docketBearingProjectIDs, !projectIDs.isEmpty else { return true }
        guard let lastDiscovery = lastDiscoveryDate else { return true }
        let daysSinceDiscovery = Calendar.current.dateComponents([.day], from: lastDiscovery, to: Date()).day ?? Int.max
        return daysSinceDiscovery > maxAgeDays
    }
    
    /// Check if the current docket count suggests an incomplete cache
    /// Returns true if count dropped significantly below historical peak
    nonisolated func appearsIncomplete(currentCount: Int, threshold: Double = 0.8) -> Bool {
        guard let peak = peakDocketCount, peak > 100 else { return false }
        let ratio = Double(currentCount) / Double(peak)
        return ratio < threshold
    }
    
    /// Check if a full sync is needed based on age
    nonisolated func needsFullSync(maxAgeDays: Int = 7) -> Bool {
        guard let lastFull = lastFullSyncDate else { return true }
        let daysSinceFullSync = Calendar.current.dateComponents([.day], from: lastFull, to: Date()).day ?? Int.max
        return daysSinceFullSync > maxAgeDays
    }
}

// MARK: - Docket Info

struct DocketInfo: Identifiable, Hashable, Codable {
    let id: UUID
    let number: String
    let jobName: String
    let fullName: String
    let updatedAt: Date?
    let createdAt: Date?
    
    // Metadata keywords extracted from the original name (SESSION, PREP, POST, etc.)
    let metadataType: String?
    
    // Subtasks (tasks without docket numbers that are children of this docket)
    let subtasks: [DocketSubtask]?
    
    // Project metadata (from Asana project)
    let projectMetadata: ProjectMetadata?
    
    /// Task due date (date-only), e.g. "YYYY-MM-DD". From Asana task due_on; used for calendar view.
    let dueDate: String?
    
    /// Asana task GID (for fetching subtasks/assignees)
    let taskGid: String?
    
    /// Studio from Asana task tags (e.g. "A - Blue", "B - Green", "C - Red", "M4 - Fuchsia"). Shown on calendar.
    let studio: String?
    /// Asana tag color name for the studio tag (e.g. "dark-blue"). Used to faintly colour the studio badge.
    let studioColor: String?
    
    /// Whether the Asana task is completed. When true, calendar shows a check and greys out the row.
    let completed: Bool?
    
    /// Display number with country suffixes removed (e.g., "25464-US" -> "25464")
    var displayNumber: String {
        // Remove country suffixes like -US, -CA, -UK, etc. (1-3 uppercase letters after a dash)
        if let range = number.range(of: #"-\p{Lu}{1,3}$"#, options: .regularExpression) {
            return String(number[..<range.lowerBound])
        }
        return number
    }
    
    nonisolated init(id: UUID = UUID(), number: String, jobName: String, fullName: String, updatedAt: Date? = nil, createdAt: Date? = nil, metadataType: String? = nil, subtasks: [DocketSubtask]? = nil, projectMetadata: ProjectMetadata? = nil, dueDate: String? = nil, taskGid: String? = nil, studio: String? = nil, studioColor: String? = nil, completed: Bool? = nil) {
        self.id = id
        self.number = number
        self.jobName = jobName
        self.fullName = fullName
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.metadataType = metadataType
        self.subtasks = subtasks
        self.projectMetadata = projectMetadata
        self.dueDate = dueDate
        self.taskGid = taskGid
        self.studio = studio
        self.studioColor = studioColor
        self.completed = completed
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fullName)
    }

    static func == (lhs: DocketInfo, rhs: DocketInfo) -> Bool {
        lhs.fullName == rhs.fullName
    }
}

struct DocketSubtask: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let updatedAt: Date?
    let metadataType: String?
    
    nonisolated init(id: UUID = UUID(), name: String, updatedAt: Date? = nil, metadataType: String? = nil) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.metadataType = metadataType
    }
}

/// Cached dockets data structure
/// This struct is nonisolated and can be safely used from any actor context
struct CachedDockets: Codable, Sendable {
    let dockets: [DocketInfo]
    let lastSync: Date
    /// Integrity metadata for corruption detection (optional for backward compatibility)
    let integrity: CacheIntegrity?
    
    // Explicit nonisolated initializer to ensure it can be created from any context
    nonisolated init(dockets: [DocketInfo], lastSync: Date, includeIntegrity: Bool = true) {
        self.dockets = dockets
        self.lastSync = lastSync
        self.integrity = includeIntegrity ? CacheIntegrity.create(for: dockets) : nil
    }
    
    // Initializer with peak count tracking for cache health monitoring
    nonisolated init(dockets: [DocketInfo], lastSync: Date, previousPeakCount: Int?, isFullSync: Bool) {
        self.dockets = dockets
        self.lastSync = lastSync
        self.integrity = CacheIntegrity.create(for: dockets, previousPeakCount: previousPeakCount, isFullSync: isFullSync)
    }
    
    // Full initializer with smart sync optimization (docket-bearing project tracking)
    nonisolated init(dockets: [DocketInfo], lastSync: Date, previousPeakCount: Int?, isFullSync: Bool, docketBearingProjectIDs: [String]?, isDiscovery: Bool) {
        self.dockets = dockets
        self.lastSync = lastSync
        self.integrity = CacheIntegrity.create(for: dockets, previousPeakCount: previousPeakCount, isFullSync: isFullSync, docketBearingProjectIDs: docketBearingProjectIDs, isDiscovery: isDiscovery)
    }
    
    // Explicit nonisolated Codable implementation to avoid main actor isolation
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dockets = try container.decode([DocketInfo].self, forKey: .dockets)
        lastSync = try container.decode(Date.self, forKey: .lastSync)
        // Optional for backward compatibility with existing caches
        integrity = try container.decodeIfPresent(CacheIntegrity.self, forKey: .integrity)
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dockets, forKey: .dockets)
        try container.encode(lastSync, forKey: .lastSync)
        try container.encodeIfPresent(integrity, forKey: .integrity)
    }
    
    enum CodingKeys: String, CodingKey {
        case dockets
        case lastSync
        case integrity
    }
    
    /// Validate cache integrity
    /// Returns validation result indicating if cache is valid or the type of corruption detected
    nonisolated func validateIntegrity() -> CacheValidationResult {
        // Check if integrity data exists
        guard let integrity = integrity else {
            return .missingIntegrity
        }
        
        // Check version compatibility
        if integrity.version != CacheFormat.version {
            return .versionMismatch(found: integrity.version, expected: CacheFormat.version)
        }
        
        // Check docket count
        if integrity.docketCount != dockets.count {
            return .countMismatch(found: dockets.count, expected: integrity.docketCount)
        }
        
        // Verify checksum
        let computedChecksum = CacheIntegrity.computeChecksum(for: dockets)
        if computedChecksum != integrity.checksum {
            return .checksumMismatch
        }
        
        return .valid
    }
    
    /// Check if any dockets have invalid/missing required fields
    nonisolated func validateDocketData() -> [String] {
        var issues: [String] = []
        
        for (index, docket) in dockets.enumerated() {
            // Check for empty required fields
            if docket.number.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("Docket \(index): empty number field")
            }
            if docket.fullName.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("Docket \(index): empty fullName field")
            }
            
            // Check fullName consistency (should contain number)
            if !docket.fullName.contains(docket.number) && !docket.number.isEmpty {
                issues.append("Docket \(index) '\(docket.fullName)': fullName doesn't contain number '\(docket.number)'")
            }
            
            // Check for reasonable date (not in far future)
            if let updatedAt = docket.updatedAt {
                let oneYearFromNow = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
                if updatedAt > oneYearFromNow {
                    issues.append("Docket \(index) '\(docket.fullName)': suspicious future date \(updatedAt)")
                }
            }
        }
        
        return issues
    }
    
    /// Comprehensive validation combining integrity and data checks
    nonisolated func validate() -> (result: CacheValidationResult, dataIssues: [String]) {
        let integrityResult = validateIntegrity()
        let dataIssues = validateDocketData()
        
        // If integrity check found corruption, return that
        if integrityResult.isCorrupted {
            return (integrityResult, dataIssues)
        }
        
        // If data has significant issues, mark as corrupted
        if dataIssues.count > dockets.count / 10 { // More than 10% of dockets have issues
            return (.corrupted(reason: "Too many data issues (\(dataIssues.count) problems found)"), dataIssues)
        }
        
        return (integrityResult, dataIssues)
    }
}

// MARK: - Project Metadata

struct ProjectMetadata: Codable, Hashable {
    let projectGid: String
    let projectName: String?
    let createdBy: String?
    let owner: String?
    let notes: String?
    let color: String?
    let dueDate: String?
    let team: String?
    let customFields: [String: String] // Field name -> value
    
    enum CodingKeys: String, CodingKey {
        case projectGid = "project_gid"
        case projectName = "project_name"
        case createdBy = "created_by"
        case owner
        case notes
        case color
        case dueDate = "due_date"
        case team
        case customFields = "custom_fields"
    }
}

// MARK: - Docket Hub Data Models

struct DocketHubData {
    let docketNumber: String
    let jobName: String
    
    // Aggregated data (no email/Gmail — that lives only in the notification centre)
    let asanaTasks: [DocketHubAsanaTask]
    let simianProjects: [DocketHubSimianProject]
    let serverFolders: [DocketHubServerFolder]
    
    // Metadata (from existing DocketMetadata)
    let metadata: DocketMetadata?
}

struct DocketHubAsanaTask: Identifiable {
    let id: String // taskGid
    let taskGid: String
    let name: String
    let projectName: String?
    let projectGid: String?
    let dueDate: String?
    let completed: Bool
    let customFields: [String: String]
    let assignee: String?
    let notes: String?
    let tags: [String]?
    let url: URL? // Asana task URL
}

struct DocketHubSimianProject: Identifiable {
    let id: String // projectId
    let projectId: String
    let name: String
    let projectNumber: String?
    let uploadDate: String?
    let startDate: String?
    let completeDate: String?
    let lastAccess: String?
    let projectSize: String?
    let fileCount: Int
    let folderStructure: [SimianFile]?
}

struct DocketHubServerFolder: Identifiable {
    let id: String // path string
    let path: URL
    let folderName: String
    let fileCount: Int
    let lastModified: Date?
    let folderType: String? // e.g., "WORK PICTURE", "PREP", etc.
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let path: String
    let year: String
    
    var fileName: String {
        (path as NSString).lastPathComponent
    }
    
    var parentFolder: String {
        (path as NSString).deletingLastPathComponent
            .components(separatedBy: "/").last ?? ""
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .lineLimit(1)
                
                Text(parentFolder)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

