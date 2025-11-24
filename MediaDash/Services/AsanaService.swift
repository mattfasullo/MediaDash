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
                URLQueryItem(name: "opt_fields", value: "gid,name,archived"),
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
                URLQueryItem(name: "opt_fields", value: "gid,name,custom_fields"),
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
        
        if let projectID = projectID {
            // Fetch tasks from specific project (limit to 500 to avoid pagination issues)
            let tasks = try await fetchTasks(workspaceID: workspaceID, projectID: projectID, maxTasks: 500)
            allTasks = tasks
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
                let projects = try await fetchProjects(workspaceID: workspaceID)
                print("🔄 [SYNC] Found \(projects.count) projects, fetching tasks...")
                
                // Fetch tasks from each project (limit to 500 per project to avoid pagination)
                for (index, project) in projects.enumerated() {
                    // Only log every 10th project to reduce noise
                    if index % 10 == 0 || index == projects.count - 1 {
                        print("🔄 [SYNC] Progress: \(index + 1)/\(projects.count) projects")
                    }
                    
                    do {
                        // Limit to 500 tasks per project to avoid pagination hell
                        let tasks = try await fetchTasks(workspaceID: workspaceID, projectID: project.gid, maxTasks: 500)
                        allTasks.append(contentsOf: tasks)
                    } catch {
                        // Silently continue with other projects
                    }
                }
            }
        }
        
        var dockets: [DocketInfo] = []
        var parsedCount = 0
        
        for task in allTasks {
            // Try to extract docket and job name
            if let docketInfo = parseDocketFromTask(task, docketField: docketField, jobNameField: jobNameField) {
                dockets.append(docketInfo)
                parsedCount += 1
            }
        }
        
        print("✅ [SYNC] Complete: \(parsedCount) dockets from \(allTasks.count) tasks")
        return dockets
    }
    
    /// Parse docket and job name from Asana task
    private func parseDocketFromTask(_ task: AsanaTask, docketField: String?, jobNameField: String?) -> DocketInfo? {
        // Option 1: Use custom fields if specified
        if let docketField = docketField, let jobNameField = jobNameField {
            let docketNumber = task.getCustomFieldValue(name: docketField) ?? ""
            let jobName = task.getCustomFieldValue(name: jobNameField) ?? task.name
            
            if !docketNumber.isEmpty {
                return DocketInfo(
                    number: docketNumber,
                    jobName: jobName.isEmpty ? task.name : jobName,
                    fullName: "\(docketNumber)_\(jobName.isEmpty ? task.name : jobName)"
                )
            }
        }
        
        // Option 2: Parse from task name
        // Try various formats: "Job Name - 12345 (Client) - Producer", "12345_Job Name", "Docket 12345: Job Name", "12345 - Job Name"
        let taskName = task.name
        
        // Format: "Job Name - 12345 (Client) - Producer" or "Job Name - 12345 - Producer"
        // Example: "Vertex The Journey of Pain - 24517 (Klick) - SY"
        // Pattern: Look for " - " followed by digits, optionally followed by " (Client) - Producer"
        if let dashRange = taskName.range(of: " - ") {
            let beforeFirstDash = String(taskName[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let afterFirstDash = String(taskName[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            
            // Try to extract docket number from after the first dash
            // Could be: "24517 (Klick) - SY" or "24517 - SY" or just "24517"
            let docketPattern = #"^(\d+)"#
            if let docketMatch = afterFirstDash.range(of: docketPattern, options: .regularExpression) {
                let docketNumber = String(afterFirstDash[docketMatch])
                let jobName = beforeFirstDash
                
                if !docketNumber.isEmpty && !jobName.isEmpty {
                    return DocketInfo(
                        number: docketNumber,
                        jobName: jobName,
                        fullName: "\(docketNumber)_\(jobName)"
                    )
                }
            }
        }
        
        // Format: "12345_Job Name"
        if let underscoreIndex = taskName.firstIndex(of: "_") {
            let docketPart = String(taskName[..<underscoreIndex]).trimmingCharacters(in: .whitespaces)
            let jobPart = String(taskName[taskName.index(after: underscoreIndex)...]).trimmingCharacters(in: .whitespaces)
            
            if !docketPart.isEmpty && !jobPart.isEmpty {
                let docketNumber = extractDocketNumber(from: docketPart)
                if !docketNumber.isEmpty {
                    return DocketInfo(
                        number: docketNumber,
                        jobName: jobPart,
                        fullName: taskName
                    )
                }
            }
        }
        
        // Format: "Docket 12345: Job Name" or "12345: Job Name"
        if let colonIndex = taskName.firstIndex(of: ":") {
            let beforeColon = String(taskName[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let afterColon = String(taskName[taskName.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            
            let docketNumber = extractDocketNumber(from: beforeColon)
            if !docketNumber.isEmpty && !afterColon.isEmpty {
                return DocketInfo(
                    number: docketNumber,
                    jobName: afterColon,
                    fullName: taskName
                )
            }
        }
        
        // Format: "12345 - Job Name" (docket first)
        if let dashIndex = taskName.range(of: " - ")?.lowerBound {
            let beforeDash = String(taskName[..<dashIndex]).trimmingCharacters(in: .whitespaces)
            let afterDash = String(taskName[taskName.index(dashIndex, offsetBy: 3)...]).trimmingCharacters(in: .whitespaces)
            
            // Check if beforeDash is a docket number
            let docketNumber = extractDocketNumber(from: beforeDash)
            if !docketNumber.isEmpty && !afterDash.isEmpty && docketNumber == beforeDash {
                return DocketInfo(
                    number: docketNumber,
                    jobName: afterDash,
                    fullName: taskName
                )
            }
        }
        
        return nil
    }
    
    /// Extract docket number from string (handles various formats)
    private func extractDocketNumber(from text: String) -> String {
        // Remove "Docket" prefix if present
        let cleaned = text.replacingOccurrences(of: "Docket", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        
        // Extract alphanumeric docket number
        let docketNumber = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return docketNumber.isEmpty ? cleaned : docketNumber
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
    
    var id: String { gid }
}

struct AsanaTask: Codable, Identifiable {
    let gid: String
    let name: String
    let custom_fields: [AsanaCustomField]?
    
    var id: String { gid }
    
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

