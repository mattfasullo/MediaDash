import SwiftUI

// MARK: - Docket Info

struct DocketInfo: Identifiable, Hashable, Codable {
    let id: UUID
    let number: String
    let jobName: String
    let fullName: String
    let updatedAt: Date?
    
    // Metadata keywords extracted from the original name (SESSION, PREP, POST, etc.)
    let metadataType: String?
    
    // Subtasks (tasks without docket numbers that are children of this docket)
    let subtasks: [DocketSubtask]?
    
    // Project metadata (from Asana project)
    let projectMetadata: ProjectMetadata?
    
    nonisolated init(id: UUID = UUID(), number: String, jobName: String, fullName: String, updatedAt: Date? = nil, metadataType: String? = nil, subtasks: [DocketSubtask]? = nil, projectMetadata: ProjectMetadata? = nil) {
        self.id = id
        self.number = number
        self.jobName = jobName
        self.fullName = fullName
        self.updatedAt = updatedAt
        self.metadataType = metadataType
        self.subtasks = subtasks
        self.projectMetadata = projectMetadata
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
    
    // Explicit nonisolated initializer to ensure it can be created from any context
    nonisolated init(dockets: [DocketInfo], lastSync: Date) {
        self.dockets = dockets
        self.lastSync = lastSync
    }
    
    // Explicit nonisolated Codable implementation to avoid main actor isolation
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dockets = try container.decode([DocketInfo].self, forKey: .dockets)
        lastSync = try container.decode(Date.self, forKey: .lastSync)
    }
    
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dockets, forKey: .dockets)
        try container.encode(lastSync, forKey: .lastSync)
    }
    
    enum CodingKeys: String, CodingKey {
        case dockets
        case lastSync
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

