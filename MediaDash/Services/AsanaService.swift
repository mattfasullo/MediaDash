import Foundation
import Combine
import SwiftUI

/// Service for interacting with Asana API
/// 
/// **READ-ONLY INTEGRATION**: This service only performs read operations (GET requests).
/// MediaDash does NOT create, update, or delete any data in Asana.
/// All operations are fetch-only: workspaces, projects, and tasks.
@MainActor
class AsanaService: ObservableObject {
    @Published var isFetching = false
    @Published var lastError: String?
    
    private let baseURL = "https://app.asana.com/api/1.0"
    private var accessToken: String?
    
    /// Initialize with access token
    init(accessToken: String? = nil) {
        self.accessToken = accessToken ?? KeychainService.retrieve(key: "asana_access_token")
    }
    
    /// Set access token
    func setAccessToken(_ token: String) {
        self.accessToken = token
        _ = KeychainService.store(key: "asana_access_token", value: token)
    }
    
    /// Clear access token
    func clearAccessToken() {
        self.accessToken = nil
        KeychainService.delete(key: "asana_access_token")
    }
    
    /// Check if authenticated
    var isAuthenticated: Bool {
        return accessToken != nil
    }
    
    /// Fetch workspaces
    func fetchWorkspaces() async throws -> [AsanaWorkspace] {
        guard let token = accessToken else {
            throw AsanaError.notAuthenticated
        }
        
        let url = URL(string: "\(baseURL)/workspaces")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AsanaError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw AsanaError.notAuthenticated
        }
        
        guard httpResponse.statusCode == 200 else {
            throw AsanaError.apiError("HTTP \(httpResponse.statusCode)")
        }
        
        let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaWorkspace]>.self, from: data)
        return wrapper.data
    }
    
    /// Fetch projects in a workspace (with pagination)
    /// - Parameters:
    ///   - workspaceID: The workspace ID
    ///   - maxProjects: Maximum number of projects to fetch (stops early if reached)
    func fetchProjects(workspaceID: String, maxProjects: Int? = nil) async throws -> [AsanaProject] {
        guard let token = accessToken else {
            throw AsanaError.notAuthenticated
        }
        
        var allProjects: [AsanaProject] = []
        var offset: String? = nil
        let limit = 100 // Asana's max is 100 per page
        
        repeat {
            var components = URLComponents(string: "\(baseURL)/projects")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "workspace", value: workspaceID),
                URLQueryItem(name: "opt_fields", value: "gid,name,archived,created_by,owner,notes,color,due_date,public,team,custom_field_settings"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            
            if let offset = offset {
                queryItems.append(URLQueryItem(name: "offset", value: offset))
            }
            
            components.queryItems = queryItems
            
            guard let url = components.url else {
                throw AsanaError.invalidURL
            }
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AsanaError.invalidResponse
            }
            
            if httpResponse.statusCode == 401 {
                throw AsanaError.notAuthenticated
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }
            
            let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaProject]>.self, from: data)
            allProjects.append(contentsOf: wrapper.data)
            
            // Check for next page
            if let nextPage = wrapper.nextPage {
                offset = nextPage.offset
            } else {
                offset = nil
            }
            
            // Stop early if we've reached the max
            if let max = maxProjects, allProjects.count >= max {
                break
            }
        } while offset != nil
        
        let activeProjects = allProjects.filter { !$0.archived }
        
        // Apply max limit after filtering
        let finalProjects: [AsanaProject]
        if let max = maxProjects, activeProjects.count > max {
            finalProjects = Array(activeProjects.prefix(max))
            print("🟢 [AsanaService] Limited to \(max) active projects (out of \(activeProjects.count) total)")
        } else {
            finalProjects = activeProjects
            print("🟢 [AsanaService] Successfully fetched \(activeProjects.count) active projects (total: \(allProjects.count))")
        }
        
        return finalProjects
    }
    
    /// Fetch tasks from a workspace or project
    /// - Parameters:
    ///   - workspaceID: The workspace ID
    ///   - projectID: The project ID (if fetching from a specific project)
    ///   - maxTasks: Maximum number of tasks to fetch per project (stops early if reached)
    func fetchTasks(workspaceID: String?, projectID: String?, maxTasks: Int? = nil) async throws -> [AsanaTask] {
        print("🔵 [AsanaService] fetchTasks() called")
        print("   - Workspace ID: \(workspaceID ?? "nil")")
        print("   - Project ID: \(projectID ?? "nil")")
        
        guard let token = accessToken else {
            print("🔴 [AsanaService] ERROR: No access token")
            throw AsanaError.notAuthenticated
        }
        
        // If no workspace or project specified, fetch workspaces and use the first one
        var finalWorkspaceID = workspaceID
        if finalWorkspaceID == nil && projectID == nil {
            let workspaces = try await fetchWorkspaces()
            if let firstWorkspace = workspaces.first {
                finalWorkspaceID = firstWorkspace.gid
            } else {
                throw AsanaError.apiError("No workspaces found. Please specify a workspace ID in settings.")
            }
        }
        
        var allTasks: [AsanaTask] = []
        var offset: String? = nil
        let limit = 100 // Asana's max is 100 per page
        
        repeat {
            var components = URLComponents(string: "\(baseURL)/tasks")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "opt_fields", value: "gid,name,custom_fields,modified_at,parent,memberships"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            
            if let offset = offset {
                queryItems.append(URLQueryItem(name: "offset", value: offset))
            }
            
            // Asana requires exactly one of: project, tag, section, user_task_list, or assignee + workspace
            if let projectID = projectID {
                // Use project if specified - this gets ALL tasks in the project (not just assigned)
                queryItems.append(URLQueryItem(name: "project", value: projectID))
            } else if let workspaceID = finalWorkspaceID {
                // Use assignee + workspace (required: both must be specified together)
                queryItems.append(URLQueryItem(name: "assignee", value: "me"))
                queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
            } else {
                throw AsanaError.apiError("Must specify either a project ID or workspace ID in settings.")
            }
            
            components.queryItems = queryItems
            
            guard let url = components.url else {
                throw AsanaError.invalidURL
            }
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AsanaError.invalidResponse
            }
            
            if httpResponse.statusCode == 401 {
                throw AsanaError.notAuthenticated
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }
            
            let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaTask]>.self, from: data)
            allTasks.append(contentsOf: wrapper.data)
            
            // Stop early if we've reached the max
            if let max = maxTasks, allTasks.count >= max {
                break
            }
            
            // Check for next page
            if let nextPage = wrapper.nextPage {
                offset = nextPage.offset
            } else {
                offset = nil
            }
        } while offset != nil
        
        // Apply max limit after filtering
        let finalTasks: [AsanaTask]
        if let max = maxTasks, allTasks.count > max {
            finalTasks = Array(allTasks.prefix(max))
        } else {
            finalTasks = allTasks
        }
        
        return finalTasks
    }
    
    /// Fetch dockets and job names from Asana
    func fetchDockets(workspaceID: String?, projectID: String?, docketField: String?, jobNameField: String?) async throws -> [DocketInfo] {
        print("🔄 [SYNC] Starting Asana sync...")
        
        isFetching = true
        lastError = nil
        
        defer {
            isFetching = false
        }
        
        // If no project specified, fetch all projects from workspace and get tasks from all of them
        var allTasks: [AsanaTask] = []
        var projectMetadataMap: [String: ProjectMetadata] = [:] // project GID -> ProjectMetadata
        
        if let projectID = projectID {
            // Fetch project metadata for the specific project
            if let workspaceID = workspaceID {
                let projects = try await fetchProjects(workspaceID: workspaceID, maxProjects: nil)
                if let project = projects.first(where: { $0.gid == projectID }) {
                    projectMetadataMap[projectID] = createProjectMetadata(from: project)
                }
            }
            
            // Fetch ALL tasks from specific project (no limit to get all dockets)
            let tasks = try await fetchTasks(workspaceID: workspaceID, projectID: projectID, maxTasks: nil)
            allTasks = tasks
            print("🔄 [SYNC] Fetched \(tasks.count) tasks from project")
        } else {
            // Fetch all projects and get tasks from each
            var finalWorkspaceID = workspaceID
            if finalWorkspaceID == nil {
                let workspaces = try await fetchWorkspaces()
                if let firstWorkspace = workspaces.first {
                    finalWorkspaceID = firstWorkspace.gid
                } else {
                    throw AsanaError.apiError("No workspaces found")
                }
            }
            
            if let workspaceID = finalWorkspaceID {
                // Fetch ALL projects (no limit to ensure we get all dockets)
                let projects = try await fetchProjects(workspaceID: workspaceID, maxProjects: nil)
                print("🔄 [SYNC] Found \(projects.count) projects, fetching ALL tasks from each...")
                
                // Build project metadata map
                for project in projects {
                    projectMetadataMap[project.gid] = createProjectMetadata(from: project)
                }
                
                // Fetch ALL tasks from each project (no limit to ensure we get all dockets)
                for (index, project) in projects.enumerated() {
                    // Only log every 10th project to reduce noise
                    if index % 10 == 0 || index == projects.count - 1 {
                        print("🔄 [SYNC] Progress: \(index + 1)/\(projects.count) projects")
                    }
                    
                    do {
                        // Fetch ALL tasks (no limit) to ensure we get all dockets including current year
                        let tasks = try await fetchTasks(workspaceID: workspaceID, projectID: project.gid, maxTasks: nil)
                        allTasks.append(contentsOf: tasks)
                        if index % 10 == 0 || index == projects.count - 1 {
                            print("   Project \(index + 1): \(tasks.count) tasks")
                        }
                    } catch {
                        // Log error but continue with other projects
                        print("⚠️ [SYNC] Error fetching tasks from project \(index + 1): \(error.localizedDescription)")
                    }
                }
            }
        }
        
        // First pass: Parse all tasks and identify which have docket numbers
        var tasksWithDockets: [String: (task: AsanaTask, docketInfo: DocketInfo)] = [:] // keyed by task gid
        var tasksWithoutDockets: [AsanaTask] = []
        var parentToChildren: [String: [AsanaTask]] = [:] // parent gid -> children tasks
        
        for task in allTasks {
            let parseResult = parseDocketFromString(task.name)
            
            if let docket = parseResult.docket {
                // Get project metadata from task's memberships
                var projectMetadata: ProjectMetadata? = nil
                if let memberships = task.memberships {
                    for membership in memberships {
                        if let projectGid = membership.project?.gid,
                           let metadata = projectMetadataMap[projectGid] {
                            // Enhance metadata with custom field values from the task
                            if let customFields = task.custom_fields {
                                var taskCustomFields = metadata.customFields
                                for field in customFields {
                                    if let value = field.display_value, !value.isEmpty {
                                        taskCustomFields[field.name] = value
                                    }
                                }
                                // Create updated metadata with task-specific custom field values
                                projectMetadata = ProjectMetadata(
                                    projectGid: metadata.projectGid,
                                    projectName: metadata.projectName,
                                    createdBy: metadata.createdBy,
                                    owner: metadata.owner,
                                    notes: metadata.notes,
                                    color: metadata.color,
                                    dueDate: metadata.dueDate,
                                    team: metadata.team,
                                    customFields: taskCustomFields
                                )
                            } else {
                                projectMetadata = metadata
                            }
                            break // Use first project found
                        }
                    }
                }
                
                // Task has a docket number - this will be in the main list
                let docketInfo = DocketInfo(
                    number: docket,
                    jobName: parseResult.jobName.isEmpty ? task.name : parseResult.jobName,
                    fullName: "\(docket)_\(parseResult.jobName.isEmpty ? task.name : parseResult.jobName)",
                    updatedAt: task.modified_at,
                    metadataType: parseResult.metadataType,
                    subtasks: nil, // Will be populated in second pass
                    projectMetadata: projectMetadata
                )
                tasksWithDockets[task.gid] = (task: task, docketInfo: docketInfo)
            } else {
                // Task doesn't have a docket number
                tasksWithoutDockets.append(task)
                
                // Track parent-child relationships
                if let parentGid = task.parent?.gid {
                    if parentToChildren[parentGid] == nil {
                        parentToChildren[parentGid] = []
                    }
                    parentToChildren[parentGid]?.append(task)
                }
            }
        }
        
        // Second pass: Attach subtasks to their parent docket tasks
        var finalDockets: [DocketInfo] = []
        
        for (taskGid, taskData) in tasksWithDockets {
            var subtasks: [DocketSubtask] = []
            
            // Find all children of this task that don't have docket numbers
            if let children = parentToChildren[taskGid] {
                for childTask in children {
                    let childParseResult = parseDocketFromString(childTask.name)
                    let subtask = DocketSubtask(
                        name: childParseResult.jobName.isEmpty ? childTask.name : childParseResult.jobName,
                        updatedAt: childTask.modified_at,
                        metadataType: childParseResult.metadataType
                    )
                    subtasks.append(subtask)
                }
            }
            
            // Create final docket info with subtasks and project metadata
            let finalDocket = DocketInfo(
                number: taskData.docketInfo.number,
                jobName: taskData.docketInfo.jobName,
                fullName: taskData.docketInfo.fullName,
                updatedAt: taskData.docketInfo.updatedAt,
                metadataType: taskData.docketInfo.metadataType,
                subtasks: subtasks.isEmpty ? nil : subtasks,
                projectMetadata: taskData.docketInfo.projectMetadata
            )
            finalDockets.append(finalDocket)
        }
        
        let subtaskCount = finalDockets.compactMap { $0.subtasks?.count }.reduce(0, +)
        print("✅ [SYNC] Complete: \(finalDockets.count) dockets with numbers from \(allTasks.count) tasks")
        print("   - \(tasksWithoutDockets.count) tasks without docket numbers")
        if subtaskCount > 0 {
            print("   - \(subtaskCount) subtasks attached to docket tasks")
        }
        
        return finalDockets
    }
    
    
    /// Extract docket number and job name from any string
    /// Docket is defined as exactly 5 digits, optionally followed by -XX suffix (like -US, -CA)
    func parseDocketFromString(_ text: String) -> (docket: String?, jobName: String, metadataType: String?) {
        // Pattern: 5 digits, optionally followed by -XX suffix (1-3 uppercase letters)
        let docketPattern = #"\d{5}(?:-[A-Z]{1,3})?"#
        
        guard let regex = try? NSRegularExpression(pattern: docketPattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let docketRange = Range(match.range, in: text) else {
            // No docket found - return cleaned job name
            let cleaned = cleanJobName(from: text, docketRange: nil)
            let metadata = extractMetadataType(from: text)
            return (nil, cleaned, metadata)
        }
        
        let docket = String(text[docketRange])
        let metadata = extractMetadataType(from: text)
        let jobName = cleanJobName(from: text, docketRange: docketRange)
        
        return (docket, jobName, metadata)
    }
    
    /// Extract metadata type (SESSION, PREP, POST, JOB INFO, SESSION REPORT) from text
    private func extractMetadataType(from text: String) -> String? {
        let metadataKeywords = ["SESSION REPORT", "JOB INFO", "SESSION", "PREP", "POST"]
        
        for keyword in metadataKeywords {
            let escapedKeyword = NSRegularExpression.escapedPattern(for: keyword)
            // Match keyword at start (with optional leading whitespace) followed by " - " or space
            let pattern = #"^\s*"# + escapedKeyword + #"(\s*-\s*|\s+|$)"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                return keyword.uppercased()
            }
        }
        
        return nil
    }
    
    /// Clean up the job name by removing docket, production company, and initials
    private func cleanJobName(from text: String, docketRange: Range<String.Index>?) -> String {
        var result = text
        
        // Remove the docket number if we have its range
        if let range = docketRange {
            result.removeSubrange(range)
        }
        
        // Remove underscores at start (from "12345_JobName" format after docket removal)
        if let regex = try? NSRegularExpression(pattern: #"^_+"#, options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        
        // Remove metadata keywords FIRST (before other cleaning): "JOB INFO", "SESSION REPORT", "SESSION" (case-insensitive)
        // These should be treated as metadata, not part of the job name
        // Process in order: longest first to avoid partial matches
        let metadataKeywords = ["SESSION REPORT", "JOB INFO", "SESSION"]
        for keyword in metadataKeywords {
            let escapedKeyword = NSRegularExpression.escapedPattern(for: keyword)
            
            // Pattern 1: Keyword at start (with optional leading whitespace) followed by " - " or space
            // Handles: "SESSION - ", " SESSION - ", "SESSION ", etc.
            let pattern1 = #"^\s*"# + escapedKeyword + #"\s*-\s*"#
            if let regex = try? NSRegularExpression(pattern: pattern1, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
            
            // Pattern 2: Keyword at start followed by space (no dash)
            let pattern2 = #"^\s*"# + escapedKeyword + #"\s+"#
            if let regex = try? NSRegularExpression(pattern: pattern2, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
            
            // Pattern 3: Keyword with dashes/spaces around it (anywhere in string)
            let pattern3 = #"\s*-\s*"# + escapedKeyword + #"(\s*-\s*|\s+|$)"#
            if let regex = try? NSRegularExpression(pattern: pattern3, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: " ")
            }
            
            // Pattern 4: Standalone keyword with spaces (middle or end of string)
            let pattern4 = #"\s+"# + escapedKeyword + #"(\s+|$)"#
            if let regex = try? NSRegularExpression(pattern: pattern4, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: " ")
            }
        }
        
        // Remove production company in parentheses: (Publicis), (Klick), etc.
        if let regex = try? NSRegularExpression(pattern: #"\([^)]+\)"#, options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        
        // Remove trailing initials pattern: - CM/KM, - SY, - AB/CD/EF etc.
        if let regex = try? NSRegularExpression(pattern: #"\s*-\s*[A-Z]{1,3}(/[A-Z]{1,3})*\s*$"#, options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        
        // Clean up leftover separators
        // Remove trailing " - " or " -" or "- "
        if let regex = try? NSRegularExpression(pattern: #"\s*-\s*$"#, options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        
        // Remove leading " - " or " -" or "- "
        if let regex = try? NSRegularExpression(pattern: #"^\s*-\s*"#, options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        
        // Clean up multiple consecutive separators " - - " -> " - "
        if let regex = try? NSRegularExpression(pattern: #"\s*-\s*-\s*"#, options: []) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(result.startIndex..., in: result), withTemplate: " - ")
        }
        
        // Final cleanup: trim whitespace and collapse multiple spaces
        result = result.trimmingCharacters(in: .whitespaces)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        
        return result.isEmpty ? "Untitled Job" : result
    }
}

// MARK: - Asana Models

struct AsanaDataWrapper<T: Codable>: Codable {
    let data: T
    let nextPage: AsanaNextPage?
    
    enum CodingKeys: String, CodingKey {
        case data
        case nextPage = "next_page"
    }
}

struct AsanaNextPage: Codable {
    let offset: String
    let path: String
    let uri: String
}

struct AsanaWorkspace: Codable, Identifiable {
    let gid: String
    let name: String
    
    var id: String { gid }
}

struct AsanaProject: Codable, Identifiable {
    let gid: String
    let name: String
    let archived: Bool
    let created_by: AsanaUser?
    let owner: AsanaUser?
    let notes: String?
    let color: String?
    let due_date: String?
    let isPublic: Bool?
    let team: AsanaTeam?
    let custom_field_settings: [AsanaCustomFieldSetting]?
    
    var id: String { gid }
    
    enum CodingKeys: String, CodingKey {
        case gid
        case name
        case archived
        case created_by
        case owner
        case notes
        case color
        case due_date
        case isPublic = "public"
        case team
        case custom_field_settings
    }
}

struct AsanaUser: Codable {
    let gid: String
    let name: String?
    let email: String?
}

struct AsanaTeam: Codable {
    let gid: String
    let name: String?
}

struct AsanaCustomFieldSetting: Codable {
    let gid: String
    let custom_field: AsanaCustomFieldDefinition?
    let is_important: Bool?
    
    enum CodingKeys: String, CodingKey {
        case gid
        case custom_field
        case is_important
    }
}

struct AsanaCustomFieldDefinition: Codable {
    let gid: String
    let name: String
    let resource_subtype: String? // text, number, enum, multi_enum, date, etc.
    let enum_options: [AsanaEnumOption]?
}

struct AsanaEnumOption: Codable {
    let gid: String
    let name: String
    let color: String?
    let enabled: Bool?
}

struct AsanaTask: Codable, Identifiable {
    let gid: String
    let name: String
    let custom_fields: [AsanaCustomField]?
    let modified_at: Date?
    let parent: AsanaParent?
    let memberships: [AsanaMembership]?
    
    var id: String { gid }
    
    enum CodingKeys: String, CodingKey {
        case gid
        case name
        case custom_fields
        case modified_at
        case parent
        case memberships
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gid = try container.decode(String.self, forKey: .gid)
        name = try container.decode(String.self, forKey: .name)
        custom_fields = try container.decodeIfPresent([AsanaCustomField].self, forKey: .custom_fields)
        parent = try container.decodeIfPresent(AsanaParent.self, forKey: .parent)
        memberships = try container.decodeIfPresent([AsanaMembership].self, forKey: .memberships)
        
        // Parse modified_at as ISO8601 date string
        if let modifiedAtString = try? container.decodeIfPresent(String.self, forKey: .modified_at) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Try with fractional seconds first, then without
            modified_at = formatter.date(from: modifiedAtString) ?? {
                let formatterNoFractional = ISO8601DateFormatter()
                formatterNoFractional.formatOptions = [.withInternetDateTime]
                return formatterNoFractional.date(from: modifiedAtString)
            }()
        } else {
            modified_at = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gid, forKey: .gid)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(custom_fields, forKey: .custom_fields)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encodeIfPresent(memberships, forKey: .memberships)
        if let modifiedAt = modified_at {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: modifiedAt), forKey: .modified_at)
        }
    }
    
    func getCustomFieldValue(name: String) -> String? {
        guard let fields = custom_fields else { return nil }
        return fields.first { $0.name.lowercased() == name.lowercased() }?.display_value
    }
}

struct AsanaCustomField: Codable {
    let gid: String
    let name: String
    let display_value: String?
}

struct AsanaParent: Codable {
    let gid: String
    let name: String?
}

struct AsanaMembership: Codable {
    let project: AsanaProjectRef?
}

struct AsanaProjectRef: Codable {
    let gid: String
    let name: String?
}

extension AsanaService {
    /// Create ProjectMetadata from AsanaProject
    func createProjectMetadata(from project: AsanaProject) -> ProjectMetadata {
        // Extract custom fields from custom_field_settings
        var customFields: [String: String] = [:]
        if let settings = project.custom_field_settings {
            for setting in settings {
                if let field = setting.custom_field {
                    let name = field.name
                    // For enum fields, get the display value
                    if let enumOptions = field.enum_options,
                       let firstOption = enumOptions.first {
                        customFields[name] = firstOption.name
                    } else {
                        // For other field types, we'd need to get the value from the task
                        // For now, just store the field name
                        customFields[name] = ""
                    }
                }
            }
        }
        
        // Format dates - due_date is a string from Asana API
        let dueDateString = project.due_date
        
        return ProjectMetadata(
            projectGid: project.gid,
            projectName: project.name,
            createdBy: project.created_by?.name ?? project.created_by?.email,
            owner: project.owner?.name ?? project.owner?.email,
            notes: project.notes,
            color: project.color,
            dueDate: dueDateString,
            team: project.team?.name,
            customFields: customFields
        )
    }
}

enum AsanaError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with Asana. Please enter your Personal Access Token in Settings."
        case .invalidURL:
            return "Invalid Asana API URL"
        case .invalidResponse:
            return "Invalid response from Asana API"
        case .apiError(let message):
            return "Asana API error: \(message)"
        }
    }
}

