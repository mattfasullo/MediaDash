import Foundation
import Combine
import SwiftUI

/// Result of a docket sync operation, including discovered docket-bearing projects
struct DocketSyncResult {
    /// The dockets found during sync
    let dockets: [DocketInfo]
    /// Project GIDs that contained docket tasks (for smart sync optimization)
    let docketBearingProjectIDs: Set<String>
    /// Whether this was a full discovery (scanned all projects)
    let wasDiscovery: Bool
    /// Number of projects that were queried
    let projectsQueried: Int
}

/// Service for interacting with Asana API
/// 
/// **MOSTLY READ-ONLY**: This service performs read operations (GET) and one write used for
/// the Demos+Post flow: updating the Post task's notes with the posting legend.
@MainActor
class AsanaService: ObservableObject {
    @Published var isFetching = false
    @Published var lastError: String?
    
    private let baseURL = "https://app.asana.com/api/1.0"
    private var accessToken: String?
    private var isRefreshing = false
    
    /// Rate limit tracking: when we can resume making requests after a 429
    private var rateLimitResumeTime: Date?
    /// Track consecutive rate limits to detect persistent issues
    private var consecutiveRateLimits = 0
    
    /// Get refresh token from keychain (shared or personal)
    private var refreshToken: String? {
        get {
            return SharedKeychainService.getAsanaRefreshToken()
        }
        set {
            if let token = newValue {
                _ = KeychainService.store(key: "asana_refresh_token", value: token)
            } else {
                KeychainService.delete(key: "asana_refresh_token")
            }
        }
    }
    
    /// Initialize with access token
    init(accessToken: String? = nil) {
        // Check shared key first (for Grayson employees), then personal key
        self.accessToken = accessToken ?? SharedKeychainService.getAsanaAccessToken()
        // Refresh token is loaded lazily via computed property when needed
    }
    
    /// Set access token and optionally refresh token
    /// Note: This stores to personal Keychain. Shared keys are set separately by admins.
    func setAccessToken(_ token: String, refreshToken: String? = nil) {
        self.accessToken = token
        // Store to personal Keychain (shared keys are managed separately)
        _ = KeychainService.store(key: "asana_access_token", value: token)
        
        if let refreshToken = refreshToken {
            self.refreshToken = refreshToken
        }
    }
    
    /// Clear access token and refresh token
    func clearAccessToken() {
        self.accessToken = nil
        self.refreshToken = nil
        KeychainService.delete(key: "asana_access_token")
        KeychainService.delete(key: "asana_refresh_token")
    }
    
    /// Check if authenticated
    var isAuthenticated: Bool {
        return accessToken != nil || refreshToken != nil
    }
    
    /// Refresh access token using refresh token
    private func refreshAccessToken() async throws {
        guard !isRefreshing else {
            // Already refreshing, wait a bit
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            return
        }
        
        guard let refreshToken = refreshToken else {
            throw AsanaError.notAuthenticated
        }
        
        guard OAuthConfig.isAsanaConfigured else {
            throw AsanaError.apiError("Asana OAuth credentials not configured")
        }
        
        isRefreshing = true
        defer { isRefreshing = false }
        
        let url = URL(string: "https://app.asana.com/-/oauth_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "refresh_token",
            "client_id": OAuthConfig.asanaClientID,
            "client_secret": OAuthConfig.asanaClientSecret,
            "refresh_token": refreshToken
        ]
        
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AsanaError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            // If refresh fails, clear tokens - user needs to re-authenticate
            if httpResponse.statusCode == 401 {
                clearAccessToken()
            }
            throw AsanaError.apiError("Token refresh failed: HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        struct RefreshTokenResponse: Codable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
            let token_type: String
        }
        
        let tokenResponse = try JSONDecoder().decode(RefreshTokenResponse.self, from: data)
        // If Asana returns a new refresh token, use it; otherwise keep the existing one
        if let newRefreshToken = tokenResponse.refresh_token {
            setAccessToken(tokenResponse.access_token, refreshToken: newRefreshToken)
        } else {
            // Keep existing refresh token
            setAccessToken(tokenResponse.access_token, refreshToken: nil)
        }
        
        print("AsanaService: Successfully refreshed access token")
    }
    
    /// Make an authenticated request with automatic token refresh on 401 and retry logic for transient failures
    /// Retries up to 3 times for transient network errors (timeouts, connection errors, 5xx server errors)
    /// Handles 429 rate limiting with Retry-After header parsing
    private func makeAuthenticatedRequest(_ request: inout URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let token = accessToken else {
            throw AsanaError.notAuthenticated
        }
        
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        // Check if we're in a rate limit cooldown period
        if let resumeTime = rateLimitResumeTime, Date() < resumeTime {
            let waitTime = resumeTime.timeIntervalSince(Date())
            print("⏳ [AsanaService] Rate limit active, waiting \(String(format: "%.1f", waitTime))s before request...")
            try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
        
        // Retry logic for transient failures
        let maxRetries = 3
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AsanaError.invalidResponse
                }
                
                // Handle 429 Too Many Requests (rate limiting)
                if httpResponse.statusCode == 429 {
                    consecutiveRateLimits += 1
                    
                    // Parse Retry-After header (in seconds)
                    let retryAfter: TimeInterval
                    if let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                       let retryAfterSecs = Double(retryAfterStr) {
                        retryAfter = retryAfterSecs
                    } else {
                        // Default to exponential backoff based on consecutive rate limits
                        retryAfter = min(Double(consecutiveRateLimits) * 10.0, 60.0) // Max 60 seconds
                    }
                    
                    print("⚠️ [AsanaService] Rate limited (429), waiting \(retryAfter)s (consecutive: \(consecutiveRateLimits))")
                    
                    // Set the resume time for other concurrent requests
                    rateLimitResumeTime = Date().addingTimeInterval(retryAfter)
                    
                    // Wait and retry
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    
                    // Retry the request
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                    guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                        throw AsanaError.invalidResponse
                    }
                    
                    // Reset consecutive rate limits on success
                    if retryHttpResponse.statusCode != 429 {
                        consecutiveRateLimits = 0
                        rateLimitResumeTime = nil
                    }
                    
                    return (retryData, retryHttpResponse)
                }
                
                // Reset rate limit tracking on successful non-429 response
                consecutiveRateLimits = 0
                rateLimitResumeTime = nil
                
                // If we get 401, try refreshing the token and retry once
                if httpResponse.statusCode == 401 && refreshToken != nil {
                    print("AsanaService: Access token expired, attempting refresh...")
                    try await refreshAccessToken()
                    
                    // Retry the request with new token
                    guard let newToken = accessToken else {
                        throw AsanaError.notAuthenticated
                    }
                    request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                    guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                        throw AsanaError.invalidResponse
                    }
                    
                    return (retryData, retryHttpResponse)
                }
                
                // Check for transient server errors (5xx) - retry these
                if httpResponse.statusCode >= 500 && httpResponse.statusCode < 600 && attempt < maxRetries - 1 {
                    let delay = Double(attempt + 1) * 0.5 // Exponential backoff: 0.5s, 1s, 1.5s
                    print("AsanaService: Server error \(httpResponse.statusCode), retrying in \(delay)s (attempt \(attempt + 1)/\(maxRetries))...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                // For non-retryable errors or successful responses, return immediately
                return (data, httpResponse)
                
            } catch {
                lastError = error
                
                // Check if this is a transient network error that we should retry
                let isTransientError: Bool
                if let urlError = error as? URLError {
                    isTransientError = urlError.code == .timedOut ||
                                     urlError.code == .networkConnectionLost ||
                                     urlError.code == .cannotConnectToHost ||
                                     urlError.code == .notConnectedToInternet
                } else {
                    isTransientError = false
                }
                
                // Retry if it's a transient error and we have attempts left
                if isTransientError && attempt < maxRetries - 1 {
                    let delay = Double(attempt + 1) * 0.5 // Exponential backoff
                    print("AsanaService: Transient network error, retrying in \(delay)s (attempt \(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                
                // Not a transient error or out of retries - throw the error
                throw error
            }
        }
        
        // If we exhausted all retries, throw the last error
        throw lastError ?? AsanaError.apiError("Request failed after \(maxRetries) attempts")
    }
    
    /// Fetch workspaces
    func fetchWorkspaces() async throws -> [AsanaWorkspace] {
        let url = URL(string: "\(baseURL)/workspaces")!
        var request = URLRequest(url: url)
        
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        
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
        var allProjects: [AsanaProject] = []
        var offset: String? = nil
        let limit = 100 // Asana's max is 100 per page
        
        repeat {
            var components = URLComponents(string: "\(baseURL)/projects")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "workspace", value: workspaceID),
                URLQueryItem(name: "opt_fields", value: "gid,name,archived,created_by,owner,notes,color,due_date,public,team,custom_field_settings"),
                URLQueryItem(name: "limit", value: "\(limit)"),
                // Filter archived projects server-side to reduce data transfer and API processing
                URLQueryItem(name: "archived", value: "false")
            ]
            
            if let offset = offset {
                queryItems.append(URLQueryItem(name: "offset", value: offset))
            }
            
            components.queryItems = queryItems
            
            guard let url = components.url else {
                throw AsanaError.invalidURL
            }
            
            var request = URLRequest(url: url)
            let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
            
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
        
        // Server-side filtering should have already excluded archived projects,
        // but keep client-side filter as a safety net
        let activeProjects = allProjects.filter { !$0.archived }
        
        if activeProjects.count < allProjects.count {
            print("⚠️ [AsanaService] Server returned \(allProjects.count - activeProjects.count) archived projects despite filter")
        }
        
        // Apply max limit after filtering
        let finalProjects: [AsanaProject]
        if let max = maxProjects, activeProjects.count > max {
            finalProjects = Array(activeProjects.prefix(max))
            print("🟢 [AsanaService] Limited to \(max) active projects (out of \(activeProjects.count) total)")
        } else {
            finalProjects = activeProjects
            print("🟢 [AsanaService] Successfully fetched \(activeProjects.count) active projects")
        }
        
        return finalProjects
    }
    
    /// Fetch tasks from a workspace or project
    /// - Parameters:
    ///   - workspaceID: The workspace ID
    ///   - projectID: The project ID (if fetching from a specific project)
    ///   - maxTasks: Maximum number of tasks to fetch per project (stops early if reached)
    ///   - modifiedSince: Optional date to only fetch tasks modified since this date (for incremental sync)
    func fetchTasks(workspaceID: String?, projectID: String?, maxTasks: Int? = nil, modifiedSince: Date? = nil) async throws -> [AsanaTask] {
        #if DEBUG
        print("🔵 [AsanaService] fetchTasks() called - Workspace: \(workspaceID ?? "nil"), Project: \(projectID ?? "nil")")
        #endif
        guard accessToken != nil else {
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
                URLQueryItem(name: "opt_fields", value: "gid,name,custom_fields,modified_at,created_at,parent,memberships,due_on,due_at"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            
            if let offset = offset {
                queryItems.append(URLQueryItem(name: "offset", value: offset))
            }
            
            // Add modified_since parameter for incremental sync
            if let modifiedSince = modifiedSince {
                // Asana expects ISO 8601 format: YYYY-MM-DDTHH:mm:ssZ
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                let modifiedSinceString = formatter.string(from: modifiedSince)
                queryItems.append(URLQueryItem(name: "modified_since", value: modifiedSinceString))
                print("🔄 [AsanaService] Using incremental sync with modified_since: \(modifiedSinceString)")
            }
            
            // Asana requires exactly one of: project, tag, section, user_task_list, or assignee + workspace
            if let projectID = projectID {
                // Use project if specified - this gets ALL tasks in the project (not just assigned)
                queryItems.append(URLQueryItem(name: "project", value: projectID))
            } else if let workspaceID = finalWorkspaceID {
                // When no project is specified, fetchDockets() should fetch all projects and call this with each projectID
                // This branch should rarely be hit in normal flow. If it is hit, we can't fetch company-wide
                // without a project filter, so we'll use workspace + assignee as a fallback (though this limits to user's tasks)
                // For true company-wide access, the caller should fetch all projects first
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
            let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
            
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
    
    /// Search tasks across the entire workspace (Premium feature)
    /// This is much faster than iterating through all projects for incremental syncs
    /// - Parameters:
    ///   - workspaceID: The workspace ID to search in
    ///   - modifiedSince: Only return tasks modified after this date
    ///   - maxTasks: Maximum number of tasks to fetch (for safety, default 5000)
    /// - Returns: Array of tasks matching the search criteria
    func searchWorkspaceTasks(workspaceID: String, modifiedSince: Date, maxTasks: Int? = 5000) async throws -> [AsanaTask] {
        print("🔍 [AsanaService] searchWorkspaceTasks() - searching workspace \(workspaceID)")
        
        guard accessToken != nil else {
            throw AsanaError.notAuthenticated
        }
        
        var allTasks: [AsanaTask] = []
        let limit = 100 // Asana's max is 100 per page
        var offset: String? = nil
        var pageCount = 0
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let modifiedSinceString = formatter.string(from: modifiedSince)
        
        repeat {
            var components = URLComponents(string: "\(baseURL)/workspaces/\(workspaceID)/tasks/search")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "opt_fields", value: "gid,name,custom_fields,modified_at,created_at,parent,memberships,due_on,due_at"),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "modified_at.after", value: modifiedSinceString),
                URLQueryItem(name: "sort_by", value: "modified_at"),
                URLQueryItem(name: "sort_ascending", value: "false") // Most recent first
            ]
            
            if let offset = offset {
                queryItems.append(URLQueryItem(name: "offset", value: offset))
            }
            
            components.queryItems = queryItems
            
            guard let url = components.url else {
                throw AsanaError.invalidURL
            }
            
            var request = URLRequest(url: url)
            let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
            
            // Check for 402 Payment Required (Premium feature not available)
            if httpResponse.statusCode == 402 {
                print("⚠️ [AsanaService] Workspace search requires Asana Premium - falling back to project iteration")
                throw AsanaError.apiError("Premium feature not available")
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
            pageCount += 1
            
            // Check for next page
            if let nextPage = wrapper.nextPage {
                offset = nextPage.offset
            } else {
                offset = nil
            }
            
            // Stop if we've reached the max
            if let max = maxTasks, allTasks.count >= max {
                print("🔍 [AsanaService] Workspace search reached max limit (\(max) tasks)")
                break
            }
            
        } while offset != nil
        
        print("🔍 [AsanaService] Workspace search returned \(allTasks.count) tasks from \(pageCount) pages (modified since \(modifiedSinceString))")
        
        // Apply max limit if specified
        if let max = maxTasks, allTasks.count > max {
            return Array(allTasks.prefix(max))
        }
        
        return allTasks
    }
    
    /// Search for upcoming sessions in the workspace (Premium feature)
    /// Sessions are tasks with "SESSION" in their name and due dates within the specified range
    /// - Parameters:
    ///   - workspaceID: The workspace ID to search in
    ///   - daysAhead: Number of days ahead to search (default 7 to cover 5 business days + weekends)
    /// - Returns: Array of session tasks with due dates in the specified range
    func searchUpcomingSessions(workspaceID: String?, daysAhead: Int = 7) async throws -> [AsanaTask] {
        print("📅 [AsanaService] searchUpcomingSessions() - searching for sessions in next \(daysAhead) days")
        
        guard accessToken != nil else {
            throw AsanaError.notAuthenticated
        }
        
        // If no workspace ID provided, fetch workspaces and use the first one
        var finalWorkspaceID = workspaceID
        if finalWorkspaceID == nil {
            let workspaces = try await fetchWorkspaces()
            if let firstWorkspace = workspaces.first {
                finalWorkspaceID = firstWorkspace.gid
                print("📅 [AsanaService] Resolved workspace: \(firstWorkspace.name) (\(firstWorkspace.gid))")
            } else {
                throw AsanaError.apiError("No workspaces found. Please specify a workspace ID in settings.")
            }
        }
        
        guard let resolvedWorkspaceID = finalWorkspaceID else {
            throw AsanaError.apiError("No workspace ID available")
        }
        
        let limit = 100 // Asana's max is 100 per page
        
        // Calculate date range: today to daysAhead days from now
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        
        // Use yesterday for the 'after' parameter since Asana's due_on.after is EXCLUSIVE
        // This ensures we include tasks due today
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let endDate = calendar.date(byAdding: .day, value: daysAhead, to: today) else {
            throw AsanaError.apiError("Failed to calculate date range")
        }
        
        // Format dates as YYYY-MM-DD for Asana API
        // Use local timezone since Asana due dates are stored as date-only values
        // in the user's workspace timezone
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        let yesterdayString = dateFormatter.string(from: yesterday)
        let endDateString = dateFormatter.string(from: endDate)
        
        print("📅 [AsanaService] Searching sessions with due_on.after=\(yesterdayString) (includes today) to \(endDateString)")
        
        var allSessions: [AsanaTask] = []
        var offset: String? = nil
        
        repeat {
            var components = URLComponents(string: "\(baseURL)/workspaces/\(resolvedWorkspaceID)/tasks/search")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "opt_fields", value: "gid,name,due_on,due_at,memberships,memberships.project,memberships.project.name,custom_fields,modified_at,created_at,completed,parent,assignee,assignee.name,tags,tags.name,tags.color"),
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "text", value: "SESSION"),  // Search for tasks with "SESSION" in name
                URLQueryItem(name: "due_on.after", value: yesterdayString),  // Exclusive, so use yesterday to include today
                URLQueryItem(name: "due_on.before", value: endDateString),
                URLQueryItem(name: "is_subtask", value: "false"),  // Only parent tasks, not subtasks
                URLQueryItem(name: "sort_by", value: "due_date"),  // Valid values: completed_at, created_at, due_date, likes, modified_at, relevance
                URLQueryItem(name: "sort_ascending", value: "true") // Soonest first
            ]
            
            if let offset = offset {
                queryItems.append(URLQueryItem(name: "offset", value: offset))
            }
            
            components.queryItems = queryItems
            
            guard let url = components.url else {
                throw AsanaError.invalidURL
            }
            
            var request = URLRequest(url: url)
            let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
            
            // Check for 402 Payment Required (Premium feature not available)
            if httpResponse.statusCode == 402 {
                print("⚠️ [AsanaService] Workspace search requires Asana Premium")
                throw AsanaError.apiError("Premium feature not available")
            }
            
            if httpResponse.statusCode == 401 {
                throw AsanaError.notAuthenticated
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
            }
            
            let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaTask]>.self, from: data)
            
            // Filter to ensure "SESSION" is actually in the name (text search may be fuzzy)
            // Also filter out subtasks (tasks with a parent) as a backup to the API filter
            let pageSessions = wrapper.data.filter { task in
                task.name.uppercased().contains("SESSION") && task.parent == nil
            }
            
            allSessions.append(contentsOf: pageSessions)
            print("📅 [AsanaService] Page fetched: \(pageSessions.count) sessions (filtered from \(wrapper.data.count) results)")
            
            // Check for next page
            if let nextPage = wrapper.nextPage {
                offset = nextPage.offset
            } else {
                offset = nil
            }
        } while offset != nil
        
        print("📅 [AsanaService] Total parent sessions found: \(allSessions.count)")
        
        return allSessions
    }

    /// Search for all tasks (not just sessions) with due dates in the next N days.
    /// Used by the full calendar view to show tasks, sessions, etc. per day.
    func searchTasksByDueDate(workspaceID: String?, daysAhead: Int = 14) async throws -> [AsanaTask] {
        guard accessToken != nil else { throw AsanaError.notAuthenticated }
        var finalWorkspaceID = workspaceID
        if finalWorkspaceID == nil {
            let workspaces = try await fetchWorkspaces()
            guard let first = workspaces.first else { throw AsanaError.apiError("No workspaces found.") }
            finalWorkspaceID = first.gid
        }
        guard let wid = finalWorkspaceID else { throw AsanaError.apiError("No workspace ID") }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let endDate = calendar.date(byAdding: .day, value: daysAhead, to: today) else {
            throw AsanaError.apiError("Failed to calculate date range")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone.current
        let yesterdayString = df.string(from: yesterday)
        let endDateString = df.string(from: endDate)
        var all: [AsanaTask] = []
        var offset: String? = nil
        repeat {
            var components = URLComponents(string: "\(baseURL)/workspaces/\(wid)/tasks/search")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "opt_fields", value: "gid,name,due_on,due_at,memberships,memberships.project,memberships.project.gid,custom_fields,modified_at,created_at,completed,parent,assignee,assignee.name,tags,tags.name,tags.color"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "due_on.after", value: yesterdayString),
                URLQueryItem(name: "due_on.before", value: endDateString),
                URLQueryItem(name: "is_subtask", value: "false"),
                URLQueryItem(name: "sort_by", value: "due_date"),
                URLQueryItem(name: "sort_ascending", value: "true")
            ]
            if let o = offset { queryItems.append(URLQueryItem(name: "offset", value: o)) }
            components.queryItems = queryItems
            guard let url = components.url else { throw AsanaError.invalidURL }
            var request = URLRequest(url: url)
            let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
            if httpResponse.statusCode == 402 { throw AsanaError.apiError("Premium feature not available") }
            if httpResponse.statusCode == 401 { throw AsanaError.notAuthenticated }
            guard httpResponse.statusCode == 200 else {
                throw AsanaError.apiError("HTTP \(httpResponse.statusCode)")
            }
            let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaTask]>.self, from: data)
            let page = wrapper.data.filter { $0.parent == nil }
            all.append(contentsOf: page)
            offset = wrapper.nextPage?.offset
        } while offset != nil
        return all
    }
    
    /// Fetch a single task by GID, including notes (description) for checklist content
    func fetchTask(taskGid: String) async throws -> AsanaTask {
        guard accessToken != nil else {
            throw AsanaError.notAuthenticated
        }
        
        var components = URLComponents(string: "\(baseURL)/tasks/\(taskGid)")!
        components.queryItems = [
            URLQueryItem(name: "opt_fields", value: "gid,name,notes,html_notes,due_on,due_at,modified_at,created_at,parent,parent.name,custom_fields,custom_fields.name,custom_fields.display_value,memberships,memberships.project,memberships.project.name,completed")
        ]
        
        guard let url = components.url else {
            throw AsanaError.invalidURL
        }
        
        var request = URLRequest(url: url)
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        
        guard httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(msg)")
        }
        
        let wrapper = try JSONDecoder().decode(AsanaDataWrapper<AsanaTask>.self, from: data)
        return wrapper.data
    }
    
    /// Fetch subtasks for a given task, returning assignee names
    /// - Parameter taskGid: The GID of the parent task
    /// - Returns: Array of assignee names from subtasks
    func fetchSubtaskAssignees(taskGid: String) async throws -> [String] {
        guard accessToken != nil else {
            throw AsanaError.notAuthenticated
        }
        
        var components = URLComponents(string: "\(baseURL)/tasks/\(taskGid)/subtasks")!
        components.queryItems = [
            URLQueryItem(name: "opt_fields", value: "gid,name,assignee,assignee.name")
        ]
        
        guard let url = components.url else {
            throw AsanaError.invalidURL
        }
        
        var request = URLRequest(url: url)
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        
        guard httpResponse.statusCode == 200 else {
            return [] // Return empty if we can't fetch subtasks
        }
        
        let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaTask]>.self, from: data)
        
        // Extract unique assignee names
        var assigneeNames: [String] = []
        for subtask in wrapper.data {
            if let assigneeName = subtask.assignee?.name, !assigneeName.isEmpty {
                if !assigneeNames.contains(assigneeName) {
                    assigneeNames.append(assigneeName)
                }
            }
        }
        
        return assigneeNames
    }
    
    /// Fetch full subtasks for a task (name, assignee, tags for Demos/Post detail view).
    /// - Parameter taskGid: The GID of the parent task
    /// - Returns: Array of subtask AsanaTask with gid, name, assignee, tags
    func fetchSubtasks(taskGid: String) async throws -> [AsanaTask] {
        guard accessToken != nil else {
            throw AsanaError.notAuthenticated
        }
        var all: [AsanaTask] = []
        var offset: String? = nil
        let limit = 100
        repeat {
            var components = URLComponents(string: "\(baseURL)/tasks/\(taskGid)/subtasks")!
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "opt_fields", value: "gid,name,assignee,assignee.name,tags,tags.name,tags.color"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            if let o = offset { queryItems.append(URLQueryItem(name: "offset", value: o)) }
            components.queryItems = queryItems
            guard let url = components.url else { throw AsanaError.invalidURL }
            var request = URLRequest(url: url)
            let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
            guard httpResponse.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(msg)")
            }
            let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaTask]>.self, from: data)
            all.append(contentsOf: wrapper.data)
            offset = wrapper.nextPage?.offset
        } while offset != nil
        return all
    }
    
    /// Update a task's notes (description). Used to write the posting legend to the linked Post task.
    func updateTaskNotes(taskGid: String, notes: String) async throws {
        guard accessToken != nil else {
            throw AsanaError.notAuthenticated
        }
        guard let url = URL(string: "\(baseURL)/tasks/\(taskGid)") else {
            throw AsanaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["data": ["notes": notes]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        guard httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(msg)")
        }
    }

    /// Mark a task complete or incomplete in Asana.
    func updateTaskCompleted(taskGid: String, completed: Bool) async throws {
        guard accessToken != nil else {
            throw AsanaError.notAuthenticated
        }
        guard let url = URL(string: "\(baseURL)/tasks/\(taskGid)") else {
            throw AsanaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["data": ["completed": completed]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        guard httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(msg)")
        }
    }

    /// Create a subtask under the given parent task. Used when user drags an "Other folder" into Who's submitting.
    func createSubtask(parentTaskGid: String, name: String) async throws -> AsanaTask {
        guard accessToken != nil else {
            throw AsanaError.notAuthenticated
        }
        guard let url = URL(string: "\(baseURL)/tasks/\(parentTaskGid)/subtasks") else {
            throw AsanaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["data": ["name": name]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, httpResponse) = try await makeAuthenticatedRequest(&request)
        guard httpResponse.statusCode == 201 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AsanaError.apiError("HTTP \(httpResponse.statusCode): \(msg)")
        }
        let wrapper = try JSONDecoder().decode(AsanaDataWrapper<AsanaTask>.self, from: data)
        return wrapper.data
    }

    /// Resolve the Music Demos docket folder name (e.g. "26014_Coors") from Asana task data.
    /// Uses: (1) parent task docket/job if this task is a subtask, (2) project name from memberships
    /// (authoritative for demos/submit tasks – project is the docket, e.g. "26014_Coors"), (3) custom fields, (4) task name.
    func resolveDocketFolder(for task: AsanaTask, docketField: String?, jobNameField: String?) async throws -> String? {
        func folderFrom(docketNumber: String, jobName: String) -> String {
            let safe = jobName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            return "\(docketNumber)_\(safe.isEmpty ? "Job" : safe)"
        }
        
        // 1. If task has a parent, get docket from parent (parent is typically the main docket task)
        if let parentGid = task.parent?.gid {
            let parentTask = try await fetchTask(taskGid: parentGid)
            if let fromParent = docketFolderFrom(task: parentTask, docketField: docketField, jobNameField: jobNameField) {
                return fromParent
            }
        }
        
        // 2. This task's custom fields or name
        return docketFolderFrom(task: task, docketField: docketField, jobNameField: jobNameField)
    }
    
    private func docketFolderFrom(task: AsanaTask, docketField: String?, jobNameField: String?) -> String? {
        func folderFrom(docketNumber: String, jobName: String) -> String {
            let safe = jobName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            return "\(docketNumber)_\(safe.isEmpty ? "Job" : safe)"
        }
        
        // Project name is authoritative for demos/submit tasks (e.g. "26014_Coors", "25464_TD Toddler")
        if let memberships = task.memberships {
            for membership in memberships {
                if let projectName = membership.project?.name, !projectName.isEmpty {
                    let (docket, jobName, _) = parseDocketFromString(projectName)
                    if let docket = docket, !docket.isEmpty {
                        return folderFrom(docketNumber: docket, jobName: jobName)
                    }
                }
            }
        }
        
        // Custom fields if configured
        if let docketField = docketField, !docketField.isEmpty,
           let docketNumber = task.getCustomFieldValue(name: docketField), !docketNumber.isEmpty {
            let jobName = jobNameField.flatMap { task.getCustomFieldValue(name: $0) } ?? ""
            return folderFrom(docketNumber: docketNumber.trimmingCharacters(in: .whitespaces), jobName: jobName)
        }
        
        // Parse task name for docket number and job name
        let (docket, jobName, _) = parseDocketFromString(task.name)
        if let docket = docket, !docket.isEmpty {
            return folderFrom(docketNumber: docket, jobName: jobName)
        }
        
        return nil
    }
    
    /// Progress callback type for sync operations
    /// - Parameters:
    ///   - progress: 0.0 to 1.0 representing overall completion
    ///   - phase: Human-readable description of current phase
    typealias SyncProgressCallback = (_ progress: Double, _ phase: String) -> Void
    
    /// Fetch dockets and job names from Asana
    /// - Parameters:
    ///   - workspaceID: Optional workspace ID
    ///   - projectID: Optional project ID
    ///   - docketField: Optional docket field name
    ///   - jobNameField: Optional job name field name
    ///   - modifiedSince: Optional date to only fetch tasks modified since this date (for incremental sync)
    ///   - knownDocketBearingProjects: Optional list of project GIDs known to contain dockets (for smart sync)
    ///   - forceDiscovery: If true, scan all projects even if knownDocketBearingProjects is provided
    ///   - progressCallback: Optional callback to report sync progress
    /// - Returns: DocketSyncResult containing dockets and discovered docket-bearing project IDs
    func fetchDockets(workspaceID: String?, projectID: String?, docketField: String?, jobNameField: String?, modifiedSince: Date? = nil, knownDocketBearingProjects: [String]? = nil, forceDiscovery: Bool = false, progressCallback: SyncProgressCallback? = nil) async throws -> DocketSyncResult {
        let syncStartTime = Date()
        print("🔄 [SYNC] Starting Asana sync at \(syncStartTime)...")
        
        isFetching = true
        lastError = nil
        
        // Report initial progress
        progressCallback?(0.0, "Starting sync...")
        
        defer {
            isFetching = false
        }
        
        // Always fetch from all projects to ensure company-wide calendar items are available
        // This ensures the calendar shows all tasks across the workspace, not just from a single project
        // Note: Even if projectID is specified in settings, we ignore it and fetch from all projects
        // to provide company-wide calendar access
        var allTasks: [AsanaTask] = []
        var projectMetadataMap: [String: ProjectMetadata] = [:] // project GID -> ProjectMetadata
        
        // Track sync metadata for DocketSyncResult
        var isDiscoverySync = forceDiscovery // Will be set to true if we scan all projects
        var projectsQueried = 0
        
        // Fetch all projects and get tasks from each
        var finalWorkspaceID = workspaceID
        
        progressCallback?(0.02, "Fetching workspaces...")
        
        if finalWorkspaceID == nil {
            let workspaces = try await fetchWorkspaces()
            if let firstWorkspace = workspaces.first {
                finalWorkspaceID = firstWorkspace.gid
            } else {
                throw AsanaError.apiError("No workspaces found")
            }
        }
        
        if let workspaceID = finalWorkspaceID {
            let syncType = modifiedSince != nil ? "incremental" : "full"
            
            // For INCREMENTAL sync, try workspace-level search first (Premium feature)
            // This is MUCH faster than iterating through all projects
            var usedWorkspaceSearch = false
            
            if let modifiedSince = modifiedSince {
                progressCallback?(0.05, "Searching workspace for recent changes...")
                print("🔍 [SYNC] Attempting workspace-level search (Premium feature) for tasks since \(modifiedSince)")
                
                do {
                    let searchStartTime = Date()
                    let searchResults = try await searchWorkspaceTasks(workspaceID: workspaceID, modifiedSince: modifiedSince)
                    let searchDuration = Date().timeIntervalSince(searchStartTime)
                    
                    print("✅ [SYNC] Workspace search found \(searchResults.count) modified tasks in \(String(format: "%.2f", searchDuration))s")
                    
                    allTasks = searchResults
                    usedWorkspaceSearch = true
                    
                    // Still need to fetch projects for metadata, but we can do this quickly
                    progressCallback?(0.50, "Fetching project metadata...")
                    let projects = try await fetchProjects(workspaceID: workspaceID, maxProjects: nil)
                    for project in projects {
                        projectMetadataMap[project.gid] = createProjectMetadata(from: project)
                    }
                    
                    progressCallback?(0.85, "Found \(searchResults.count) modified tasks")
                } catch {
                    // Workspace search failed (likely no Premium) - fall back to parallel project iteration
                    print("⚠️ [SYNC] Workspace search failed: \(error.localizedDescription) - falling back to parallel project iteration")
                    usedWorkspaceSearch = false
                }
            }
            
            // For FULL sync or if workspace search failed, use parallel project iteration
            if !usedWorkspaceSearch {
                progressCallback?(0.05, "Fetching project list (\(syncType) sync)...")
                
                // Fetch ALL projects (no limit to ensure we get all dockets)
                let allProjects = try await fetchProjects(workspaceID: workspaceID, maxProjects: nil)
                
                // SMART SYNC: If we have known docket-bearing projects and not forcing discovery,
                // only query those projects. This dramatically reduces API calls (1800+ down to ~50-200).
                let projects: [AsanaProject]
                
                if let knownProjects = knownDocketBearingProjects, !knownProjects.isEmpty, !forceDiscovery {
                    // Filter to only known docket-bearing projects
                    let knownProjectSet = Set(knownProjects)
                    projects = allProjects.filter { knownProjectSet.contains($0.gid) }
                    isDiscoverySync = false
                    print("🚀 [SMART SYNC] Using \(projects.count) known docket-bearing projects (out of \(allProjects.count) total)")
                    progressCallback?(0.08, "Smart sync: \(projects.count) docket projects")
                } else {
                    // Full discovery: scan all projects
                    projects = allProjects
                    isDiscoverySync = true
                    if modifiedSince != nil {
                        print("🔄 [SYNC] Found \(projects.count) projects, checking for updated tasks since \(modifiedSince!)...")
                    } else {
                        print("🔄 [SYNC] Found \(projects.count) projects, fetching ALL tasks from each (full discovery)...")
                    }
                    progressCallback?(0.08, "Discovery: \(projects.count) projects")
                }
                
                // Track how many projects we're querying
                projectsQueried = projects.count
                
                // Build project metadata map (always include all projects for metadata lookup)
                for project in allProjects {
                    projectMetadataMap[project.gid] = createProjectMetadata(from: project)
                }
                
                // Progress range for fetching tasks: 0.1 to 0.85
                let progressStart = 0.1
                let progressEnd = 0.85
                let progressRange = progressEnd - progressStart
                
                // Fetch ALL tasks from each project using PARALLEL requests with concurrency limit
                // Concurrency is set conservatively to avoid rate limiting (Asana allows 1500 req/min)
                // Using 8 concurrent requests balances speed vs API limits
                let concurrencyLimit = 8
                let totalProjects = projects.count
                
                // Actor to safely track progress, failures, and response times across concurrent tasks
                actor SyncProgressTracker {
                    var completedCount = 0
                    private var responseTimes: [TimeInterval] = []
                    private let maxResponseTimeSamples = 20
                    var failedProjects: [(index: Int, project: AsanaProject, error: Error)] = []
                    let total: Int
                    
                    // Adaptive throttling: add delay between requests if response times are high
                    private var shouldThrottle = false
                    private let responseTimeThreshold: TimeInterval = 2.0 // seconds
                    
                    init(total: Int) {
                        self.total = total
                    }
                    
                    func increment() -> Int {
                        completedCount += 1
                        return completedCount
                    }
                    
                    func recordResponseTime(_ time: TimeInterval) {
                        responseTimes.append(time)
                        // Keep only recent samples
                        if responseTimes.count > maxResponseTimeSamples {
                            responseTimes.removeFirst()
                        }
                        // Check if we should throttle
                        let avgTime = responseTimes.reduce(0, +) / Double(responseTimes.count)
                        shouldThrottle = avgTime > responseTimeThreshold
                        
                        if shouldThrottle && responseTimes.count == maxResponseTimeSamples {
                            print("⚠️ [SYNC] Response times high (avg \(String(format: "%.2f", avgTime))s), enabling throttling")
                        }
                    }
                    
                    func getThrottleDelay() -> TimeInterval {
                        return shouldThrottle ? 0.2 : 0 // 200ms delay between requests when throttling
                    }
                    
                    func recordFailure(index: Int, project: AsanaProject, error: Error) {
                        failedProjects.append((index: index, project: project, error: error))
                    }
                    
                    func getFailedProjects() -> [(index: Int, project: AsanaProject, error: Error)] {
                        return failedProjects
                    }
                    
                    func clearFailures() {
                        failedProjects = []
                    }
                }
                
                let progressTracker = SyncProgressTracker(total: totalProjects)
                
                let parallelFetchStartTime = Date()
                print("🚀 [SYNC] Starting parallel fetch with \(concurrencyLimit) concurrent requests for \(totalProjects) projects")
                
                // Use TaskGroup for parallel fetching with concurrency limit
                // Result includes project index, project info for retry, and the fetched tasks (or empty on error)
                try await withThrowingTaskGroup(of: (index: Int, project: AsanaProject, tasks: [AsanaTask], error: Error?).self) { group in
                    var projectIterator = projects.enumerated().makeIterator()
                    var activeTasks = 0
                    
                    // Helper to process a completed result
                    @Sendable func processResult(_ result: (index: Int, project: AsanaProject, tasks: [AsanaTask], error: Error?)) async {
                        let completed = await progressTracker.increment()
                        
                        if let error = result.error {
                            await progressTracker.recordFailure(index: result.index, project: result.project, error: error)
                            print("⚠️ [SYNC] Error fetching tasks from project \(result.index + 1) '\(result.project.name)': \(error.localizedDescription)")
                        } else if completed % 10 == 0 || completed == totalProjects {
                            print("🔄 [SYNC] Progress: \(completed)/\(totalProjects) projects (\(result.tasks.count) tasks from '\(result.project.name)')")
                        }
                        
                        // Update progress callback
                        let completedProgress = progressStart + (Double(completed) / Double(totalProjects)) * progressRange
                        let finalProgress = min(completedProgress, progressEnd)
                        let phaseText = modifiedSince != nil ? "Checked" : "Fetched"
                        progressCallback?(finalProgress, "\(phaseText) \(completed) of \(totalProjects) projects")
                    }
                    
                    // Start initial batch of tasks up to concurrency limit
                    while activeTasks < concurrencyLimit, let (index, project) = projectIterator.next() {
                        let projectGid = project.gid
                        let wsId = workspaceID
                        let modSince = modifiedSince
                        let proj = project
                        let tracker = progressTracker
                        
                        group.addTask {
                            // Apply adaptive throttle delay if needed
                            let throttleDelay = await tracker.getThrottleDelay()
                            if throttleDelay > 0 {
                                try? await Task.sleep(nanoseconds: UInt64(throttleDelay * 1_000_000_000))
                            }
                            
                            let startTime = Date()
                            do {
                                let tasks = try await self.fetchTasks(workspaceID: wsId, projectID: projectGid, maxTasks: nil, modifiedSince: modSince)
                                let responseTime = Date().timeIntervalSince(startTime)
                                await tracker.recordResponseTime(responseTime)
                                return (index: index, project: proj, tasks: tasks, error: nil)
                            } catch {
                                // Return empty tasks on error, but include the error for retry
                                return (index: index, project: proj, tasks: [], error: error)
                            }
                        }
                        activeTasks += 1
                    }
                    
                    // Process results as they complete and add new tasks to maintain concurrency
                    while let result = try await group.next() {
                        // Collect tasks (even empty arrays on error)
                        allTasks.append(contentsOf: result.tasks)
                        await processResult(result)
                        activeTasks -= 1
                        
                        // Add next project to the group if available
                        if let (index, project) = projectIterator.next() {
                            let projectGid = project.gid
                            let wsId = workspaceID
                            let modSince = modifiedSince
                            let proj = project
                            let tracker = progressTracker
                            
                            group.addTask {
                                // Apply adaptive throttle delay if needed
                                let throttleDelay = await tracker.getThrottleDelay()
                                if throttleDelay > 0 {
                                    try? await Task.sleep(nanoseconds: UInt64(throttleDelay * 1_000_000_000))
                                }
                                
                                let startTime = Date()
                                do {
                                    let tasks = try await self.fetchTasks(workspaceID: wsId, projectID: projectGid, maxTasks: nil, modifiedSince: modSince)
                                    let responseTime = Date().timeIntervalSince(startTime)
                                    await tracker.recordResponseTime(responseTime)
                                    return (index: index, project: proj, tasks: tasks, error: nil)
                                } catch {
                                    return (index: index, project: proj, tasks: [], error: error)
                                }
                            }
                            activeTasks += 1
                        }
                    }
                }
                
                // Retry failed projects once with a small delay
                let failedProjects = await progressTracker.getFailedProjects()
                if !failedProjects.isEmpty {
                    print("🔄 [SYNC] Retrying \(failedProjects.count) failed projects...")
                    progressCallback?(0.86, "Retrying \(failedProjects.count) failed projects...")
                    
                    // Wait a moment before retrying (helps with transient network issues)
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    
                    var retrySuccessCount = 0
                    var retryTaskCount = 0
                    
                    for (_, project, _) in failedProjects {
                        do {
                            let tasks = try await self.fetchTasks(workspaceID: workspaceID, projectID: project.gid, maxTasks: nil, modifiedSince: modifiedSince)
                            allTasks.append(contentsOf: tasks)
                            retrySuccessCount += 1
                            retryTaskCount += tasks.count
                            print("✅ [SYNC] Retry succeeded for '\(project.name)': \(tasks.count) tasks")
                        } catch {
                            print("❌ [SYNC] Retry failed for '\(project.name)': \(error.localizedDescription)")
                        }
                    }
                    
                    let stillFailed = failedProjects.count - retrySuccessCount
                    if stillFailed > 0 {
                        print("⚠️ [SYNC] \(stillFailed) projects still failed after retry - some dockets may be missing")
                    }
                    if retrySuccessCount > 0 {
                        print("✅ [SYNC] Retry recovered \(retryTaskCount) tasks from \(retrySuccessCount) projects")
                    }
                }
                
                let parallelFetchDuration = Date().timeIntervalSince(parallelFetchStartTime)
                let failedCount = await progressTracker.getFailedProjects().count
                if failedCount > 0 {
                    print("✅ [SYNC] Parallel fetch complete: \(allTasks.count) tasks from \(totalProjects) projects in \(String(format: "%.2f", parallelFetchDuration))s (\(failedCount) projects had errors)")
                } else {
                    print("✅ [SYNC] Parallel fetch complete: \(allTasks.count) tasks from \(totalProjects) projects in \(String(format: "%.2f", parallelFetchDuration))s")
                }
                progressCallback?(0.85, "Fetched \(allTasks.count) tasks total")
            } // end if !usedWorkspaceSearch
        }
        
        // First pass: Parse all tasks and identify which have docket numbers
        progressCallback?(0.88, "Processing \(allTasks.count) tasks...")
        
        var tasksWithDockets: [String: (task: AsanaTask, docketInfo: DocketInfo)] = [:] // keyed by task gid
        var tasksWithoutDockets: [AsanaTask] = []
        var parentToChildren: [String: [AsanaTask]] = [:] // parent gid -> children tasks
        var discoveredDocketBearingProjects: Set<String> = [] // Track which projects have dockets
        
        for task in allTasks {
            let parseResult = parseDocketFromString(task.name)
            
            if let docket = parseResult.docket {
                // Get project metadata from task's memberships
                var projectMetadata: ProjectMetadata? = nil
                if let memberships = task.memberships {
                    for membership in memberships {
                        if let projectGid = membership.project?.gid {
                            // Track that this project has dockets
                            discoveredDocketBearingProjects.insert(projectGid)
                            
                            if let metadata = projectMetadataMap[projectGid] {
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
                }
                
                // Task has a docket number - this will be in the main list
                // Use effectiveDueDate which prefers due_on but falls back to date from due_at
                let docketInfo = DocketInfo(
                    number: docket,
                    jobName: parseResult.jobName.isEmpty ? task.name : parseResult.jobName,
                    fullName: "\(docket)_\(parseResult.jobName.isEmpty ? task.name : parseResult.jobName)",
                    updatedAt: task.modified_at,
                    createdAt: task.created_at,
                    metadataType: parseResult.metadataType,
                    subtasks: nil, // Will be populated in second pass
                    projectMetadata: projectMetadata,
                    dueDate: task.effectiveDueDate,
                    completed: task.completed
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
        progressCallback?(0.92, "Building docket hierarchy...")
        
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
            
            // Create final docket info with subtasks, project metadata, and task due date
            let finalDocket = DocketInfo(
                number: taskData.docketInfo.number,
                jobName: taskData.docketInfo.jobName,
                fullName: taskData.docketInfo.fullName,
                updatedAt: taskData.docketInfo.updatedAt,
                createdAt: taskData.docketInfo.createdAt,
                metadataType: taskData.docketInfo.metadataType,
                subtasks: subtasks.isEmpty ? nil : subtasks,
                projectMetadata: taskData.docketInfo.projectMetadata,
                dueDate: taskData.docketInfo.dueDate,
                completed: taskData.docketInfo.completed
            )
            finalDockets.append(finalDocket)
        }
        
        let subtaskCount = finalDockets.compactMap { $0.subtasks?.count }.reduce(0, +)
        let docketsWithDueDate = finalDockets.filter { $0.dueDate != nil && !($0.dueDate?.isEmpty ?? true) }.count
        let syncDuration = Date().timeIntervalSince(syncStartTime)
        print("✅ [SYNC] Complete: \(finalDockets.count) dockets with numbers from \(allTasks.count) tasks")
        print("   - \(tasksWithoutDockets.count) tasks without docket numbers")
        print("   - \(docketsWithDueDate) dockets have due dates (required for calendar)")
        print("   - \(discoveredDocketBearingProjects.count) projects contain dockets (for smart sync)")
        if subtaskCount > 0 {
            print("   - \(subtaskCount) subtasks attached to docket tasks")
        }
        print("⏱️ [SYNC] Total sync time: \(String(format: "%.2f", syncDuration)) seconds")
        
        progressCallback?(1.0, "Sync complete: \(finalDockets.count) dockets")
        
        return DocketSyncResult(
            dockets: finalDockets,
            docketBearingProjectIDs: discoveredDocketBearingProjects,
            wasDiscovery: isDiscoverySync,
            projectsQueried: projectsQueried
        )
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

struct AsanaAssignee: Codable {
    let gid: String
    let name: String?
}

/// Asana tag (e.g. studio: "A - Blue", "B - Green", "C - Red", "M4 - Fuchsia").
struct AsanaTag: Codable {
    let gid: String
    let name: String?
    /// Asana tag color (e.g. "dark-blue", "dark-green", "dark-red", "dark-pink").
    let color: String?
}

struct AsanaTask: Codable, Identifiable {
    let gid: String
    let name: String
    let custom_fields: [AsanaCustomField]?
    let modified_at: Date?
    let created_at: Date?
    let parent: AsanaParent?
    let memberships: [AsanaMembership]?
    let assignee: AsanaAssignee?
    /// Task tags (e.g. studio: "A - Blue", "B - Green", "C - Red", "M4 - Fuchsia").
    let tags: [AsanaTag]?
    /// Task description/notes (e.g. session checklist from Asana). Plain text.
    let notes: String?
    /// Task description as HTML (rich text). Use when notes is empty.
    let html_notes: String?
    /// Task due date (date-only), e.g. "YYYY-MM-DD". Used for calendar view.
    let due_on: String?
    /// Task due datetime, e.g. "2026-02-04T14:00:00.000Z". Used when task has a time.
    let due_at: String?
    /// Whether the task is completed in Asana.
    let completed: Bool?

    /// Effective due date: use due_on if set, otherwise extract date from due_at
    var effectiveDueDate: String? {
        if let dueOn = due_on, !dueOn.isEmpty {
            return dueOn
        }
        // Extract date portion from due_at (YYYY-MM-DDTHH:mm:ss.fffZ -> YYYY-MM-DD)
        if let dueAt = due_at, dueAt.count >= 10 {
            return String(dueAt.prefix(10))
        }
        return nil
    }
    
    var id: String { gid }
    
    enum CodingKeys: String, CodingKey {
        case gid
        case name
        case custom_fields
        case modified_at
        case created_at
        case parent
        case memberships
        case assignee
        case tags
        case notes
        case html_notes
        case due_on
        case due_at
        case completed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gid = try container.decode(String.self, forKey: .gid)
        name = try container.decode(String.self, forKey: .name)
        custom_fields = try container.decodeIfPresent([AsanaCustomField].self, forKey: .custom_fields)
        parent = try container.decodeIfPresent(AsanaParent.self, forKey: .parent)
        memberships = try container.decodeIfPresent([AsanaMembership].self, forKey: .memberships)
        assignee = try container.decodeIfPresent(AsanaAssignee.self, forKey: .assignee)
        tags = try container.decodeIfPresent([AsanaTag].self, forKey: .tags)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        html_notes = try container.decodeIfPresent(String.self, forKey: .html_notes)
        due_on = try container.decodeIfPresent(String.self, forKey: .due_on)
        due_at = try container.decodeIfPresent(String.self, forKey: .due_at)
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed)
        
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
        
        // Parse created_at as ISO8601 date string
        if let createdAtString = try? container.decodeIfPresent(String.self, forKey: .created_at) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // Try with fractional seconds first, then without
            created_at = formatter.date(from: createdAtString) ?? {
                let formatterNoFractional = ISO8601DateFormatter()
                formatterNoFractional.formatOptions = [.withInternetDateTime]
                return formatterNoFractional.date(from: createdAtString)
            }()
        } else {
            created_at = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gid, forKey: .gid)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(custom_fields, forKey: .custom_fields)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encodeIfPresent(memberships, forKey: .memberships)
        try container.encodeIfPresent(assignee, forKey: .assignee)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(html_notes, forKey: .html_notes)
        if let modifiedAt = modified_at {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: modifiedAt), forKey: .modified_at)
        }
        if let createdAt = created_at {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: createdAt), forKey: .created_at)
        }
        try container.encodeIfPresent(completed, forKey: .completed)
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
    case cacheUnavailable(String)
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with Asana. Please connect via OAuth in Settings (or enter a Personal Access Token if using legacy authentication)."
        case .invalidURL:
            return "Invalid Asana API URL"
        case .invalidResponse:
            return "Invalid response from Asana API"
        case .apiError(let message):
            return "Asana API error: \(message)"
        case .cacheUnavailable(let message):
            return message
        }
    }
}

