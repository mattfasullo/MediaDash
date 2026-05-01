import Foundation
import Combine
import SwiftUI

/// Service for interacting with Simian Projects API
/// 
/// Uses two-step authentication:
/// 1. Get session auth_key
/// 2. Login with username/password to get auth_token
/// All API requests require both auth_key and auth_token
@MainActor
class SimianService: ObservableObject {
    @Published var isFetching = false
    @Published var lastError: String?
    
    private var baseURL: String?
    private var username: String?
    private var password: String?
    
    // Session tokens (stored in memory, refreshed on login)
    private var authKey: String?
    private var authToken: String?
    
    // URLSession with cookie storage for session management
    private let session: URLSession
    // Separate session for archive downloads (longer timeouts)
    private let archiveSession: URLSession
    
    /// Get username from keychain (shared or personal)
    private var usernameValue: String? {
        get {
            return SharedKeychainService.getSimianUsername()
        }
        set {
            if let user = newValue {
                _ = KeychainService.store(key: "simian_username", value: user)
            } else {
                KeychainService.delete(key: "simian_username")
            }
        }
    }
    
    /// Get password from keychain (shared or personal)
    private var passwordValue: String? {
        get {
            return SharedKeychainService.getSimianPassword()
        }
        set {
            if let pass = newValue {
                _ = KeychainService.store(key: "simian_password", value: pass)
            } else {
                KeychainService.delete(key: "simian_password")
            }
        }
    }
    
    init(baseURL: String? = nil, username: String? = nil, password: String? = nil) {
        // Create URLSession with cookie storage for session management
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
        
        let archiveConfig = URLSessionConfiguration.default
        archiveConfig.httpCookieStorage = HTTPCookieStorage.shared
        archiveConfig.httpCookieAcceptPolicy = .always
        archiveConfig.waitsForConnectivity = true
        archiveConfig.timeoutIntervalForRequest = 60 * 30
        archiveConfig.timeoutIntervalForResource = 60 * 60 * 6
        self.archiveSession = URLSession(configuration: archiveConfig)
        
        // Always use Grayson's hardcoded URL - ignore any stored values
        let graysonURL = "https://graysonmusic.gosimian.com/api/prjacc"
        
        // Migrate any old http:// URLs in UserDefaults to https://
        if let oldURL = UserDefaults.standard.string(forKey: "simian_api_base_url"),
           oldURL.hasPrefix("http://") {
            print("⚠️ SimianService: Found old http:// URL in UserDefaults, migrating to https://")
            UserDefaults.standard.set(graysonURL, forKey: "simian_api_base_url")
        }
        
        // Always use hardcoded Grayson URL
        self.baseURL = graysonURL
        UserDefaults.standard.set(graysonURL, forKey: "simian_api_base_url")
        
        // Store credentials if provided
        if let user = username {
            self.username = user
            self.usernameValue = user
        }
        if let pass = password {
            self.password = pass
            self.passwordValue = pass
        }
    }
    
    /// Set API base URL (always uses Grayson's hardcoded URL)
    func setBaseURL(_ url: String) {
        // Always use Grayson's hardcoded URL, ignore the parameter
        let graysonURL = "https://graysonmusic.gosimian.com/api/prjacc"
        self.baseURL = graysonURL
        UserDefaults.standard.set(graysonURL, forKey: "simian_api_base_url")
        // Clear session when URL changes
        self.authKey = nil
        self.authToken = nil
    }
    
    /// Set credentials
    func setCredentials(username: String, password: String) {
        self.username = username
        self.password = password
        self.usernameValue = username
        self.passwordValue = password
        // Clear session when credentials change
        self.authKey = nil
        self.authToken = nil
    }
    
    /// Clear configuration
    func clearConfiguration() {
        self.baseURL = nil
        self.username = nil
        self.password = nil
        self.authKey = nil
        self.authToken = nil
        self.usernameValue = nil
        self.passwordValue = nil
        UserDefaults.standard.removeObject(forKey: "simian_api_base_url")
    }
    
    /// Check if configured
    var isConfigured: Bool {
        guard let url = baseURL, !url.isEmpty,
              URL(string: url) != nil else { return false }
        return usernameValue != nil && !usernameValue!.isEmpty &&
               passwordValue != nil && !passwordValue!.isEmpty
    }
    
    /// Authenticate with Simian API (two-step process)
    private func authenticate() async throws {
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString) else {
            print("❌ SimianService.authenticate() failed: Not configured (no baseURL)")
            throw SimianError.notConfigured
        }
        
        guard let username = usernameValue, !username.isEmpty,
              let password = passwordValue, !password.isEmpty else {
            print("❌ SimianService.authenticate() failed: Not configured (no credentials)")
            throw SimianError.notConfigured
        }
        
        // Step 1: Get session auth_key
        let setupURL = base.appendingPathComponent("prjacc")
        var setupRequest = URLRequest(url: setupURL)
        setupRequest.httpMethod = "POST"
        setupRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let (setupData, setupResponse) = try await session.data(for: setupRequest)
        
        guard let setupHttpResponse = setupResponse as? HTTPURLResponse,
              (200...299).contains(setupHttpResponse.statusCode) else {
            throw SimianError.apiError("Failed to establish session")
        }
        
        // Parse auth_key from response
        let setupResponseObj: SimianSetupResponse
        do {
            setupResponseObj = try JSONDecoder().decode(SimianSetupResponse.self, from: setupData)
        } catch {
            let responseString = String(data: setupData, encoding: .utf8) ?? "Unable to decode as string"
            print("❌ SimianService.authenticate() failed to decode setup response: \(error.localizedDescription)")
            print("   Raw setup response: \(responseString)")
            throw SimianError.apiError("Failed to parse setup response: \(error.localizedDescription). Response: \(responseString.prefix(200))")
        }
        guard setupResponseObj.root.status == "success",
              let authKey = setupResponseObj.root.auth_key else {
            let responseString = String(data: setupData, encoding: .utf8) ?? "Unable to decode as string"
            print("❌ SimianService.authenticate() setup failed: status=\(setupResponseObj.root.status), response=\(responseString.prefix(200))")
            throw SimianError.apiError("Failed to get session key")
        }
        
        self.authKey = authKey
        
        // Step 2: Login with username/password to get auth_token
        // URLSession will automatically include cookies from the previous request
        var loginRequest = URLRequest(url: setupURL)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Form-encoded login data
        let loginParams = [
            "auth_key": authKey,
            "username": username,
            "password": password
        ]
        loginRequest.httpBody = loginParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        
        guard let loginHttpResponse = loginResponse as? HTTPURLResponse,
              (200...299).contains(loginHttpResponse.statusCode) else {
            print("❌ SimianService.authenticate() Login failed: HTTP status not 200-299")
            throw SimianError.apiError("Login failed")
        }
        
        // Parse auth_token from response
        let loginResponseObj: SimianLoginResponse
        do {
            loginResponseObj = try JSONDecoder().decode(SimianLoginResponse.self, from: loginData)
        } catch {
            let responseString = String(data: loginData, encoding: .utf8) ?? "Unable to decode as string"
            print("❌ SimianService.authenticate() failed to decode login response: \(error.localizedDescription)")
            print("   Raw login response (truncated): \(String(responseString.prefix(200)))")
            throw SimianError.apiError("Failed to parse login response: \(error.localizedDescription). Response: \(responseString.prefix(200))")
        }
        guard loginResponseObj.root.status == "success",
              let authToken = loginResponseObj.root.payload?.token else {
            let errorMsg = loginResponseObj.root.message ?? "Login failed"
            let responseString = String(data: loginData, encoding: .utf8) ?? "Unable to decode as string"
            print("❌ SimianService.authenticate() login failed: status=\(loginResponseObj.root.status), message=\(errorMsg), response=\(responseString.prefix(200))")
            throw SimianError.apiError(errorMsg)
        }
        
        self.authToken = authToken
        
        #if DEBUG
        print("✅ SimianService: Authenticated as \(username)")
        #endif
    }
    
    /// Ensure we're authenticated before making API calls
    private func ensureAuthenticated() async throws {
        if authKey == nil || authToken == nil {
            try await authenticate()
        }
    }
    
    /// Create a project in Simian
    /// - Parameters:
    ///   - docketNumber: The docket number
    ///   - jobName: The job name (project_name)
    ///   - projectManager: The project manager user ID (optional)
    ///   - projectTemplate: The project template ID (optional)
    /// - Returns: Success status
    func createJob(docketNumber: String, jobName: String, projectManager: String? = nil, projectTemplate: String? = nil) async throws {
        print("🔔 SimianService.createJob() called")
        print("   docketNumber: \(docketNumber)")
        print("   jobName: \(jobName)")
        print("   projectManager: \(projectManager ?? "nil")")
        print("   projectTemplate: \(projectTemplate ?? "nil")")
        print("   formattedProjectName: \(docketNumber)_\(jobName)")
        
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            print("❌ SimianService.createJob() failed: Not configured")
            throw SimianError.notConfigured
        }
        
        let endpointURL = base.appendingPathComponent("create_project")
        print("   Endpoint: \(endpointURL.absoluteString)")
        
        isFetching = true
        lastError = nil
        
        defer {
            isFetching = false
        }
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLSession will automatically include cookies for the session
        
        // Build form-encoded body
        // Project name format: "25XXX_JobName" (docket number + underscore + job name)
        let formattedProjectName = "\(docketNumber)_\(jobName)"
        
        var params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "project_name": formattedProjectName
        ]
        
        // Add project_number (just the docket number)
        // According to API docs, create_project only accepts project_name
        // We'll need to call set_project_info after creation to set project_number
        // But let's try sending it anyway in case the API accepts it
        if !docketNumber.isEmpty {
            params["project_number"] = docketNumber
            print("   Setting project number: \(docketNumber)")
        }
        
        // Add optional project_manager (user_id)
        if let projectManager = projectManager, !projectManager.isEmpty {
            params["project_manager"] = projectManager
            print("   Setting project manager: \(projectManager)")
        }
        
        // Add optional project template (existing project ID to use as template)
        // Try multiple parameter names - the API might accept different names
        if let projectTemplate = projectTemplate, !projectTemplate.isEmpty {
            print("   Setting template project ID: \(projectTemplate)")
            // Try from_project_id first (common pattern for "create from existing")
            params["from_project_id"] = projectTemplate
            // Also try template_project_id in case that's what the API expects
            // Note: We're sending both to see which one works, but ideally we'd only send one
            // If both are sent, the API might use the last one or ignore duplicates
        } else {
            print("   No template provided (projectTemplate is nil or empty)")
        }
        
        print("   Request params: \(params.keys.joined(separator: ", "))")
        print("   Request param values:")
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            print("     \(key) = \(value)")
        }
        
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        do {
            print("   Sending request to create project...")
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ SimianService.createJob() failed: Invalid response type")
                throw SimianError.apiError("Invalid response from API")
            }
            
            print("   HTTP Status Code: \(httpResponse.statusCode)")
            
            
            // Log raw response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                print("   Raw response: \(responseString)")
            }
            
            // Check for successful response (200-299)
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                print("❌ SimianService.createJob() failed: HTTP \(httpResponse.statusCode) - \(errorMessage)")
                throw SimianError.apiError("API returned error: \(errorMessage)")
            }
            
            // Parse response to get project ID
            // Use do-catch to capture JSON parsing errors
            var createdProjectId: String?
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let root = json["root"] as? [String: Any],
                   let payload = root["payload"] as? [String: Any],
                   let projectId = payload["project_id"] as? String {
                    createdProjectId = projectId
                    print("✅ SimianService: Project created successfully (ID: \(projectId)) for docket \(docketNumber): \(jobName)")
                } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("✅ SimianService: Project created successfully for docket \(docketNumber): \(jobName)")
                    print("   Response JSON: \(json)")
                    // Try to extract project_id from different response formats
                    if let root = json["root"] as? [String: Any],
                       let payload = root["payload"] as? [String: Any],
                       let projectId = payload["project_id"] as? String {
                        createdProjectId = projectId
                    } else if let root = json["root"] as? [String: Any],
                              let projectId = root["project_id"] as? String {
                        createdProjectId = projectId
                    }
                } else {
                    print("✅ SimianService: Project created successfully for docket \(docketNumber): \(jobName)")
                    print("   (Could not parse response JSON)")
                }
            } catch {
                // JSON parsing failed, but HTTP status was 200-299, so assume success
                let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode as string"
                print("⚠️ SimianService.createJob() JSON parsing failed, but HTTP status was successful")
                print("   Error: \(error.localizedDescription)")
                print("   Raw response: \(responseString)")
                // Don't throw - HTTP status indicates success
            }
            
            // If project_number wasn't set during creation, update it using set_project_info
            // According to API docs, create_project only accepts project_name, so we need to set project_number separately
            // Also copy template settings and folder structure if a template was provided
            if let projectId = createdProjectId {
                print("   Updating project settings using set_project_info for project ID: \(projectId)")
                do {
                    // First, get template project settings and folder structure if template was provided
                    var templateSettings: [String: Any]? = nil
                    if let projectTemplate = projectTemplate, !projectTemplate.isEmpty {
                        print("   Fetching template project settings from project ID: \(projectTemplate)")
                        templateSettings = try await getProjectInfo(projectId: projectTemplate)
                        
                        // Copy folder structure from template
                        print("   Copying folder structure from template project...")
                        try await copyFolderStructure(fromTemplateProjectId: projectTemplate, toProjectId: projectId)
                        print("✅ SimianService: Successfully copied folder structure from template")
                    }
                    
                    // Look up user ID from email if projectManager looks like an email address
                    var projectManagerUserId: String? = projectManager
                    if let pm = projectManager, !pm.isEmpty, pm.contains("@") {
                        print("   projectManager looks like an email address, looking up user ID...")
                        if let userId = try await getUserIdByEmail(email: pm) {
                            projectManagerUserId = userId
                            print("   ✅ Resolved email \(pm) to user ID: \(userId)")
                        } else {
                            print("   ⚠️ Could not resolve email \(pm) to user ID, will try passing email directly")
                            // Keep the email - maybe the API accepts it
                        }
                    }
                    
                    // Set project_number and project_manager, and copy template settings
                    try await setProjectInfo(
                        projectId: projectId,
                        projectNumber: docketNumber,
                        projectManager: projectManagerUserId,
                        templateSettings: templateSettings
                    )
                    print("✅ SimianService: Successfully set project_number to \(docketNumber)")
                    if templateSettings != nil {
                        print("✅ SimianService: Successfully copied template settings")
                    }
                } catch {
                    print("⚠️ SimianService: Failed to set project settings: \(error.localizedDescription)")
                    // Don't throw - project was created successfully, just the settings update failed
                }
            }
            
        } catch let error as SimianError {
            print("❌ SimianService.createJob() failed with SimianError: \(error.localizedDescription)")
            lastError = error.localizedDescription
            throw error
        } catch {
            let errorMessage = error.localizedDescription
            print("❌ SimianService.createJob() failed with error: \(errorMessage)")
            lastError = errorMessage
            throw SimianError.apiError("Network error: \(errorMessage)")
        }
    }
    
    /// Get project information
    /// - Parameter projectId: The project ID
    /// - Returns: Dictionary of project settings
    private func getProjectInfo(projectId: String) async throws -> [String: Any] {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        let endpointURL = base.appendingPathComponent("get_project_info").appendingPathComponent(projectId)
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "auth_token": authToken,
            "auth_key": authKey
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to get project info: \(errorMessage)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any],
              let payload = root["payload"] as? [[String: Any]],
              let projectInfo = payload.first else {
            throw SimianError.apiError("Invalid response format from get_project_info")
        }
        
        return projectInfo
    }

    /// Check if a project with the given docket number and job name already exists
    func projectExists(docketNumber: String, jobName: String) async throws -> Bool {
        let projects = try await getProjectList()
        let expectedName = "\(docketNumber)_\(jobName)"
        
        // Check for exact match or partial match (project name contains docket number)
        for project in projects {
            let projectNameLower = project.name.lowercased()
            let expectedNameLower = expectedName.lowercased()
            let docketLower = docketNumber.lowercased()
            
            if projectNameLower == expectedNameLower {
                print("🔔 SimianService: Found exact match for project '\(expectedName)'")
                return true
            }
            
            // Also check if project name starts with docket number (e.g., "26XXX_TEST01" matches "26XXX_TEST01_v2")
            if projectNameLower.hasPrefix(docketLower + "_") && projectNameLower.contains(jobName.lowercased()) {
                print("🔔 SimianService: Found partial match for project '\(project.name)' (looking for '\(expectedName)')")
                return true
            }
        }
        
        return false
    }

    /// Fetch list of projects current user has access to
    func getProjectList() async throws -> [SimianProject] {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        let endpointURL = base.appendingPathComponent("get_project_list")
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "auth_token": authToken,
            "auth_key": authKey
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to fetch project list: \(errorMessage)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any] else {
            throw SimianError.apiError("Invalid response format from get_project_list")
        }
        
        let projectId = "project_list"
        let folderId: String? = nil
        _ = (projectId, folderId)
        
        let payloadArray: [[String: Any]]
        if let payload = root["payload"] as? [[String: Any]] {
            payloadArray = payload
        } else if let payload = root["payload"] as? [String: Any] {
            payloadArray = [payload]
        } else {
            payloadArray = []
        }
        
        return payloadArray.compactMap { projectDict in
            guard let id = projectDict["id"] as? String,
                  let name = projectDict["project_name"] as? String else {
                return nil
            }
            return SimianProject(
                id: id,
                name: name,
                accessAreas: SimianService.stringArrayValue(projectDict["access_areas"])
            )
        }
    }

    /// Fetch detailed project info for filtering and display
    func getProjectInfoDetails(projectId: String) async throws -> SimianProjectInfo {
        let info = try await getProjectInfo(projectId: projectId)
        let projectSize = SimianService.stringValue(info["project_size"])
            ?? SimianService.stringValue(info["project_size_total"])
            ?? SimianService.stringValue(info["total_size"])
            ?? SimianService.stringValue(info["size"])
            ?? SimianService.stringValue(info["media_size"])
        return SimianProjectInfo(
            id: projectId,
            name: SimianService.stringValue(info["project_name"]),
            projectNumber: SimianService.stringValue(info["project_number"]),
            uploadDate: SimianService.stringValue(info["upload_date"]),
            startDate: SimianService.stringValue(info["start_date"]),
            completeDate: SimianService.stringValue(info["complete_date"]),
            lastAccess: SimianService.stringValue(info["last_access"]),
            projectSize: projectSize
        )
    }
    
    /// Set project information (project_number, project_manager, etc.)
    /// - Parameters:
    ///   - projectId: The project ID
    ///   - projectNumber: The project number (docket number)
    ///   - projectManager: The project manager user ID (optional)
    ///   - templateSettings: Optional dictionary of settings to copy from template project
    private func setProjectInfo(projectId: String, projectNumber: String, projectManager: String?, templateSettings: [String: Any]? = nil) async throws {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        let endpointURL = base.appendingPathComponent("set_project_info").appendingPathComponent(projectId)
        print("   setProjectInfo endpoint: \(endpointURL.absoluteString)")
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "project_number": projectNumber
        ]
        
        // Add optional project_manager (user_id)
        if let projectManager = projectManager, !projectManager.isEmpty {
            params["project_manager"] = projectManager
        }
        
        // Copy template settings if provided
        if let template = templateSettings {
            print("   Copying template settings to new project...")
            // Copy presentation template settings
            if let presentTemplate = template["present_template"] as? String, !presentTemplate.isEmpty {
                params["present_template"] = presentTemplate
                print("     present_template: \(presentTemplate)")
            }
            if let presentBranding = template["present_branding"] as? String, !presentBranding.isEmpty {
                params["present_branding"] = presentBranding
            }
            if let presentType = template["present_type"] as? String, !presentType.isEmpty {
                params["present_type"] = presentType
            }
            if let presentEmailTemplate = template["present_email_template"] as? String, !presentEmailTemplate.isEmpty {
                params["present_email_template"] = presentEmailTemplate
            }
            
            // Copy notification settings
            if let notifyMember = template["notify_member"] as? String {
                params["notify_member"] = notifyMember
            }
            if let notifyFiles = template["notify_files"] as? String {
                params["notify_files"] = notifyFiles
            }
            if let notifyUpload = template["notify_upload"] as? String {
                params["notify_upload"] = notifyUpload
            }
            if let notifyApproval = template["notify_approval"] as? String {
                params["notify_approval"] = notifyApproval
            }
            if let notifyComment = template["notify_comment"] as? String {
                params["notify_comment"] = notifyComment
            }
            if let notifyForward = template["notify_forward"] as? String {
                params["notify_forward"] = notifyForward
            }
            
            // Copy presentation options
            if let presentOptEmailcc = template["present_opt_emailcc"] as? String {
                params["present_opt_emailcc"] = presentOptEmailcc
            }
            if let presentOptNotify = template["present_opt_notify"] as? String {
                params["present_opt_notify"] = presentOptNotify
            }
            if let presentOptComments = template["present_opt_comments"] as? String {
                params["present_opt_comments"] = presentOptComments
            }
            if let presentOptDownload = template["present_opt_download"] as? String {
                params["present_opt_download"] = presentOptDownload
            }
            if let presentOptForward = template["present_opt_forward"] as? String {
                params["present_opt_forward"] = presentOptForward
            }
            if let presentOptShowCmt = template["present_opt_show_cmt"] as? String {
                params["present_opt_show_cmt"] = presentOptShowCmt
            }
            if let presentOptApproval = template["present_opt_approval"] as? String {
                params["present_opt_approval"] = presentOptApproval
            }
            if let presentOptSearch = template["present_opt_search"] as? String {
                params["present_opt_search"] = presentOptSearch
            }
            
            print("   Copied \(params.count - 3) template settings (excluding auth params)")
        }
        
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            print("❌ SimianService.setProjectInfo() failed: HTTP \(httpResponse.statusCode) - \(errorMessage)")
            throw SimianError.apiError("Failed to set project info: \(errorMessage)")
        }
        
        if let responseString = String(data: data, encoding: .utf8) {
            print("   setProjectInfo response: \(responseString)")
        }
    }
    
    /// Get folders from a project
    /// - Parameters:
    ///   - projectId: The project ID
    ///   - parentFolderId: Optional parent folder ID (nil for root level)
    /// - Returns: Array of folder dictionaries
    private func getFolders(projectId: String, parentFolderId: String? = nil) async throws -> [[String: Any]] {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        let endpointURL = base.appendingPathComponent("get_folders").appendingPathComponent(projectId)
        
        var params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey
        ]
        if let parentId = parentFolderId, !parentId.isEmpty {
            params["folder_id"] = parentId
        }
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to get folders: \(errorMessage)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any],
              let payload = root["payload"] as? [[String: Any]] else {
            // Return empty array if no folders found
            return []
        }
        
        return payload
    }

    /// Get folders from a project with typed models
    func getProjectFolders(projectId: String, parentFolderId: String? = nil) async throws -> [SimianFolder] {
        let rawFolders = try await getFolders(projectId: projectId, parentFolderId: parentFolderId)
        
        return rawFolders.compactMap { folder in
            guard let id = SimianService.stringValue(folder["id"]),
                  let name = SimianService.stringValue(folder["name"]) else {
                return nil
            }
            return SimianFolder(
                id: id,
                name: name,
                parentId: SimianService.stringValue(folder["parent"]),
                uploadedAt: SimianService.uploadDateFromPayload(folder)
            )
        }
    }

    /// Short user-facing description when the server returns non-JSON (e.g. HTML 404/502 pages from a proxy).
    private static func describeSimianHTTPFailure(status: Int, body: Data, url: URL) -> String {
        let raw = String(data: body, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<!DOCTYPE") || trimmed.lowercased().contains("<html") {
            if let open = raw.range(of: "<title>", options: .caseInsensitive),
               let close = raw.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<raw.endIndex) {
                let title = String(raw[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return "HTTP \(status) — \(title). Request: \(url.absoluteString)"
            }
            return "HTTP \(status) — server returned HTML (not Simian JSON). Request: \(url.absoluteString)"
        }
        if trimmed.count > 600 { return String(trimmed.prefix(600)) + "…" }
        return trimmed.isEmpty ? "HTTP \(status)" : trimmed
    }

    /// Validate the common Simian JSON envelope (`root.status`) and surface API-level errors.
    private static func requireSuccessRootResponse(_ data: Data, action: String) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any] else {
            let snippet = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Empty response"
            throw SimianError.apiError("Failed to \(action): unexpected response format (\(snippet.prefix(200)))")
        }
        let status = (root["status"] as? String ?? "").lowercased()
        guard status == "success" else {
            let message = root["message"] as? String ?? "Unknown API error"
            throw SimianError.apiError("Failed to \(action): \(message)")
        }
    }

    /// Parses date strings from Simian list/detail payloads (`upload_date`, etc.).
    nonisolated static func parseSimianMetadataDate(_ raw: String?) -> Date? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return nil }
        let formats = [
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd hh:mm a",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
            "MM/dd/yyyy",
            "MM/dd/yy",
            "yyyy-MM-dd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }

    /// Best-effort “added to Simian” time from folder/file payload dictionaries.
    /// Scans the root object plus common nested containers (`file`, `metadata`, …) so list payloads that nest metadata still work.
    /// Avoids generic keys like `date` / `time`, which often reflect “today” or unrelated project fields rather than upload time.
    nonisolated static func uploadDateFromPayload(_ dict: [String: Any]) -> Date? {
        var sources: [[String: Any]] = [dict]
        let nestedContainerKeys = ["file", "metadata", "meta", "details", "item", "properties", "data", "payload"]
        for k in nestedContainerKeys {
            if let inner = dict[k] as? [String: Any] {
                sources.append(inner)
            }
        }
        let uploadKeys = [
            "upload_date", "upload_date_time", "uploaded_at", "uploadedAt", "uploadDate",
            "file_upload_date", "date_added", "dateAdded", "added_at", "addedAt", "inserted_at", "insertedAt"
        ]
        for key in uploadKeys {
            for src in sources {
                if let d = dateFromLooseMetadataValue(src[key]) { return d }
            }
        }
        let createdKeys = ["created_at", "createdAt", "creation_date", "creationDate", "created"]
        for key in createdKeys {
            for src in sources {
                if let d = dateFromLooseMetadataValue(src[key]) { return d }
            }
        }
        return nil
    }

    nonisolated private static func dateFromLooseMetadataValue(_ value: Any?) -> Date? {
        if let interval = epochSecondsFromJSONScalar(value) {
            return Date(timeIntervalSince1970: interval)
        }
        if let s = metadataDisplayString(forJSONScalar: value), let d = parseSimianMetadataDate(s) {
            return d
        }
        if let s = metadataDisplayString(forJSONScalar: value), let interval = epochSecondsFromNumericString(s) {
            return Date(timeIntervalSince1970: interval)
        }
        return nil
    }

    /// String forms of JSON scalars for calendar-style date parsing (includes `NSNumber` → string for numeric timestamps).
    nonisolated private static func metadataDisplayString(forJSONScalar value: Any?) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = value as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    nonisolated private static func epochSecondsFromJSONScalar(_ value: Any?) -> TimeInterval? {
        switch value {
        case let n as NSNumber:
            return normalizeEpochSecondsToUnix(n.doubleValue)
        case let i as Int:
            return normalizeEpochSecondsToUnix(TimeInterval(i))
        case let i as Int64:
            return normalizeEpochSecondsToUnix(TimeInterval(i))
        case let u as UInt64:
            return normalizeEpochSecondsToUnix(TimeInterval(u))
        case let d as Double:
            return normalizeEpochSecondsToUnix(d)
        default:
            return nil
        }
    }

    nonisolated private static func epochSecondsFromNumericString(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
        guard let raw = Double(trimmed) else { return nil }
        return normalizeEpochSecondsToUnix(raw)
    }

    /// Epoch in seconds, accepting values sent as milliseconds since 1970.
    nonisolated private static func normalizeEpochSecondsToUnix(_ raw: TimeInterval) -> TimeInterval? {
        guard raw.isFinite else { return nil }
        var s = raw
        if s > 1_000_000_000_000 {
            s /= 1000
        }
        if s >= 631_152_000 && s < 4_102_444_800 {
            return s
        }
        return nil
    }

    /// Upload a single file to a Simian project (root or into a folder).
    /// - Parameters:
    ///   - projectId: Simian project ID
    ///   - folderId: Optional folder ID (nil = project root)
    ///   - fileURL: Local file URL to upload
    ///   - musicExtensionsForUploadNaming: Used with ``SimianFolderNaming/simianUploadVideoExtensions`` so video/audio uploads get `_Mmmdd.yy` before the extension when the name does not already end with that stamp.
    /// - Returns: Uploaded file ID from response
    func uploadFile(
        projectId: String,
        folderId: String?,
        fileURL: URL,
        musicExtensionsForUploadNaming: [String]? = nil
    ) async throws -> String {
        try await ensureAuthenticated()

        let trimmedProjectId = projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProjectId.isEmpty else {
            throw SimianError.apiError("Upload failed: missing project id")
        }

        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }

        let endpointURL = base.appendingPathComponent("upload_file").appendingPathComponent(trimmedProjectId)
        let boundary = "SimianBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()

        func appendPart(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendPart(name: "auth_token", value: authToken)
        appendPart(name: "auth_key", value: authKey)
        if let folderId = folderId, !folderId.isEmpty {
            appendPart(name: "folder_id", value: folderId)
        }

        let resolvedMusicExtensions = musicExtensionsForUploadNaming ?? AppSettings.default.musicExtensions
        let musicExtSet = Set(resolvedMusicExtensions.map { $0.lowercased() })
        let filename = SimianFolderNaming.multipartUploadFilename(forLocalFileURL: fileURL, musicExtensionsLowercased: musicExtSet)
        guard let fileData = try? Data(contentsOf: fileURL) else {
            throw SimianError.apiError("Could not read file: \(fileURL.path)")
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"Filedata\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, */*;q=0.8", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let uploadSession: URLSession
        if fileData.count > 50 * 1024 * 1024 {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 3600
            config.httpCookieStorage = HTTPCookieStorage.shared
            uploadSession = URLSession(configuration: config)
        } else {
            uploadSession = session
        }

        let (data, response) = try await uploadSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = Self.describeSimianHTTPFailure(status: httpResponse.statusCode, body: data, url: endpointURL)
            throw SimianError.apiError("Upload failed: \(errorMessage)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any] else {
            let snippet = Self.describeSimianHTTPFailure(status: httpResponse.statusCode, body: data, url: endpointURL)
            throw SimianError.apiError("Invalid upload response (missing JSON root). \(snippet)")
        }

        let status = root["status"] as? String ?? ""
        let message = root["message"] as? String ?? ""
        guard status.lowercased() == "success" else {
            throw SimianError.apiError("Upload failed: \(message)")
        }

        // API may return file_id, id, or only a link (all indicate success)
        let payload = root["payload"] as? [String: Any]
        if let dict = payload {
            if let s = dict["file_id"] as? String, !s.isEmpty { return s }
            if let s = dict["id"] as? String, !s.isEmpty { return s }
            if let n = dict["file_id"] as? Int { return String(n) }
            if let n = dict["id"] as? Int { return String(n) }
            if let link = dict["link"] as? String, !link.isEmpty {
                // Extract last path component as id if present (e.g. .../1328/137962 -> 137962)
                let parts = link.split(separator: "/")
                if let last = parts.last, last.allSatisfy(\.isNumber) { return String(last) }
                return link
            }
        }
        if let s = root["file_id"] as? String, !s.isEmpty { return s }
        if let s = root["id"] as? String, !s.isEmpty { return s }

        // Success with no file_id (e.g. payload only has "link") — treat as success
        return "uploaded"
    }

    /// Get files in a project folder
    func getProjectFiles(projectId: String, folderId: String? = nil) async throws -> [SimianFile] {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        let endpointURL = base.appendingPathComponent("get_files").appendingPathComponent(projectId)
        
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey
        ]
        if let folderId = folderId, !folderId.isEmpty {
            params["folder_id"] = folderId
        }
        
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to get files: \(errorMessage)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any] else {
            throw SimianError.apiError("Invalid response format from get_files")
        }
        
        let payloadArray: [[String: Any]]
        if let payload = root["payload"] as? [[String: Any]] {
            payloadArray = payload
        } else if let payload = root["payload"] as? [String: Any] {
            payloadArray = [payload]
        } else {
            payloadArray = []
        }

        if payloadArray.isEmpty {
            
            if let folderId = folderId, !folderId.isEmpty {
                // Attempt alternate URL format for diagnostics
                let altEndpointURL = base.appendingPathComponent("get_files")
                    .appendingPathComponent(projectId)
                    .appendingPathComponent(folderId)
                
                var altRequest = URLRequest(url: altEndpointURL)
                altRequest.httpMethod = "POST"
                altRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                
                let altParams = [
                    "auth_token": authToken,
                    "auth_key": authKey
                ]
                altRequest.httpBody = altParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
                    .joined(separator: "&")
                    .data(using: .utf8)
                
                if let (altData, altResponse) = try? await session.data(for: altRequest),
                   let altHttp = altResponse as? HTTPURLResponse,
                   (200...299).contains(altHttp.statusCode),
                   let altJson = try? JSONSerialization.jsonObject(with: altData) as? [String: Any],
                   let altRoot = altJson["root"] as? [String: Any] {
                    _ = (altRoot["payload"] as? [[String: Any]]) ??
                        ((altRoot["payload"] as? [String: Any]).map { [$0] } ?? [])
                }
            }
        }

        return payloadArray.compactMap { fileDict in
            guard let id = SimianService.stringValue(fileDict["id"]),
                  let title = SimianService.stringValue(fileDict["title"]) else {
                return nil
            }
            
            let mediaFileURL: URL?
            if let mediaFile = SimianService.stringValue(fileDict["media_file"]),
               let url = URL(string: mediaFile) {
                mediaFileURL = url
            } else {
                mediaFileURL = nil
            }
            
            return SimianFile(
                id: id,
                title: title,
                fileName: SimianService.stringValue(fileDict["file_name"]),
                fileType: SimianService.stringValue(fileDict["file_type"]),
                mediaURL: mediaFileURL,
                folderId: folderId,
                projectId: projectId,
                uploadedAt: SimianService.uploadDateFromPayload(fileDict)
            )
        }
    }

    /// Get detailed info for a file in a project
    func getFileInfo(projectId: String, fileId: String) async throws -> SimianFileInfo {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        let endpointURL = base.appendingPathComponent("get_file_info").appendingPathComponent(projectId)
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "auth_token": authToken,
            "auth_key": authKey,
            "file_id": fileId
        ]
        
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to get file info: \(errorMessage)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any] else {
            throw SimianError.apiError("Invalid response format from get_file_info")
        }
        let fileInfo: [String: Any]
        if let rows = root["payload"] as? [[String: Any]], let first = rows.first {
            fileInfo = first
        } else if let dict = root["payload"] as? [String: Any] {
            fileInfo = dict
        } else {
            throw SimianError.apiError("Invalid response format from get_file_info")
        }
        
        return SimianFileInfo(
            id: fileId,
            title: SimianService.stringValue(fileInfo["title"]),
            fileName: SimianService.stringValue(fileInfo["file_name"]),
            mediaSize: SimianService.stringValue(fileInfo["media_size"]),
            uploadedAt: SimianService.uploadDateFromPayload(fileInfo)
        )
    }

    /// Download a file using the Simian session (cookies included)
    func downloadFile(from sourceURL: URL, to destinationURL: URL) async throws {
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        
        
        let (tempURL, response) = try await session.download(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SimianError.apiError("Failed to download file: \(sourceURL.lastPathComponent)")
        }
        
        
        let fileManager = FileManager.default
        let destinationFolder = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard fileManager.fileExists(atPath: tempURL.path) else {
            throw SimianError.apiError("Download temp file missing before move: \(tempURL.lastPathComponent)")
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }

    // MARK: - Folder / multi-file download (Simian Post browser)

    /// Sanitize a single path segment for local filenames (matches SimianArchiver-style naming).
    static func sanitizeFileNameForDownload(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value.components(separatedBy: invalidCharacters).joined(separator: "_")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Preferred local filename for a Simian file (title + extension from media URL when present).
    static func buildDownloadFileName(for file: SimianFile, mediaURL: URL?) -> String {
        let sanitizedTitle = sanitizeFileNameForDownload(file.title.isEmpty ? "file_\(file.id)" : file.title)
        guard let mediaURL = mediaURL else { return sanitizedTitle }
        let fileExtension = mediaURL.pathExtension
        if fileExtension.isEmpty { return sanitizedTitle }
        if sanitizedTitle.lowercased().hasSuffix(".\(fileExtension.lowercased())") { return sanitizedTitle }
        return "\(sanitizedTitle).\(fileExtension)"
    }

    /// Lists every file under `folderId` (or project root when `folderId` is nil), with paths relative to that folder (e.g. `Subfolder/clip.wav`).
    func enumerateFilesInFolderSubtree(projectId: String, folderId: String?) async throws -> [(relativePath: String, file: SimianFile)] {
        try await ensureAuthenticated()
        return try await collectFilesRecursive(projectId: projectId, folderId: folderId, relativePrefix: "")
    }

    private func collectFilesRecursive(projectId: String, folderId: String?, relativePrefix: String) async throws -> [(relativePath: String, file: SimianFile)] {
        var result: [(relativePath: String, file: SimianFile)] = []
        let files = try await getProjectFiles(projectId: projectId, folderId: folderId)
        for file in files {
            let baseName = Self.buildDownloadFileName(for: file, mediaURL: file.mediaURL)
            let rel = relativePrefix.isEmpty ? baseName : "\(relativePrefix)/\(baseName)"
            result.append((rel, file))
        }
        let folders = try await getProjectFolders(projectId: projectId, parentFolderId: folderId)
        for folder in folders {
            let seg = Self.sanitizeFileNameForDownload(folder.name)
            guard !seg.isEmpty else { continue }
            let nextPrefix = relativePrefix.isEmpty ? seg : "\(relativePrefix)/\(seg)"
            result.append(contentsOf: try await collectFilesRecursive(projectId: projectId, folderId: folder.id, relativePrefix: nextPrefix))
        }
        return result
    }

    /// Downloads enumerated files into `destinationRootURL`, preserving relative paths. Skips entries with no `mediaURL`.
    /// - Parameter progress: Called on the main actor with (completedCount, totalWithURLs, lastRelativePath).
    func downloadFilesWithRelativePaths(
        _ items: [(relativePath: String, file: SimianFile)],
        to destinationRootURL: URL,
        progress: ((Int, Int, String) -> Void)? = nil
    ) async throws {
        try await ensureAuthenticated()
        let fm = FileManager.default
        try fm.createDirectory(at: destinationRootURL, withIntermediateDirectories: true)

        let withURLs: [(String, SimianFile, URL)] = items.compactMap { item in
            guard let u = item.file.mediaURL else { return nil }
            return (item.relativePath, item.file, u)
        }
        guard !withURLs.isEmpty else {
            throw SimianError.apiError("No files with download URLs in this folder.")
        }
        let total = withURLs.count
        for (idx, entry) in withURLs.enumerated() {
            try Task.checkCancellation()
            let (relPath, file, mediaURL) = entry
            var destinationURL = destinationRootURL.appendingPathComponent(relPath)
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                let ext = mediaURL.pathExtension
                let base = destinationURL.deletingPathExtension().lastPathComponent
                let deduped = ext.isEmpty ? "\(base)_\(file.id)" : "\(base)_\(file.id).\(ext)"
                destinationURL = destinationURL.deletingLastPathComponent().appendingPathComponent(deduped)
            }
            try await downloadFile(from: mediaURL, to: destinationURL)
            await MainActor.run {
                progress?(idx + 1, total, relPath)
            }
        }
    }

    /// Download a project ZIP archive from the Simian web UI
    func downloadProjectArchive(
        projectId: String,
        to destinationURL: URL,
        progress: ((Int64, Int64?) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard let baseURLString = baseURL, let base = URL(string: baseURLString) else {
            throw SimianError.notConfigured
        }
        // Convert API base (https://host/api/prjacc) -> https://host
        let hostBase = base.deletingLastPathComponent().deletingLastPathComponent()
        let archiveURL = hostBase
            .appendingPathComponent("simian")
            .appendingPathComponent("projects")
            .appendingPathComponent("download_archive")
            .appendingPathComponent(projectId)
        
        var headRequest = URLRequest(url: archiveURL)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 60 * 10
        
        
        let (_, headResponse) = try await archiveSession.data(for: headRequest)
        let headSize = (headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-archive-estimated-size") ?? "nil"
        let estimatedBytes: Int64? = {
            if let value = Int64(headSize) {
                return value
            }
            return SimianService.parseMediaSize(headSize)
        }()
        if let estimatedBytes {
            progress?(0, estimatedBytes)
        }
        
        try Task.checkCancellation()
        
        
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            var request = URLRequest(url: archiveURL)
            request.httpMethod = "GET"
            
            do {
                let downloadDelegate = ArchiveDownloadDelegate(
                    progress: progress,
                    stagingDirectory: destinationURL.deletingLastPathComponent()
                )
                let downloadSession = URLSession(
                    configuration: archiveSession.configuration,
                    delegate: downloadDelegate,
                    delegateQueue: nil
                )
                defer { downloadSession.finishTasksAndInvalidate() }
                
                let taskHolder = DownloadTaskHolder()
                let result: ArchiveDownloadResult = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        downloadDelegate.attachContinuation(continuation)
                        taskHolder.task = downloadSession.downloadTask(with: request)
                        taskHolder.task?.resume()
                    }
                } onCancel: {
                    taskHolder.task?.cancel()
                }
                guard let httpResponse = result.response as? HTTPURLResponse else {
                    throw SimianError.apiError("Archive download failed: \(archiveURL.lastPathComponent)")
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw SimianError.apiError("Archive download failed: \(archiveURL.lastPathComponent)")
                }
        
        
                let fileManager = FileManager.default
                let destinationFolder = destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                guard fileManager.fileExists(atPath: result.tempURL.path) else {
                    throw SimianError.apiError("Archive temp file missing before copy: \(result.tempURL.lastPathComponent)")
                }
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                if result.tempURL.deletingLastPathComponent() == destinationFolder,
                   result.tempURL.lastPathComponent.hasPrefix(".staged_") {
                    try fileManager.moveItem(at: result.tempURL, to: destinationURL)
                } else {
                    let stagedURL = destinationFolder.appendingPathComponent(".staged_\(UUID().uuidString).zip")
                    if fileManager.fileExists(atPath: stagedURL.path) {
                        try fileManager.removeItem(at: stagedURL)
                    }
                    try fileManager.copyItem(at: result.tempURL, to: stagedURL)
                    try fileManager.moveItem(at: stagedURL, to: destinationURL)
                }
                return
            } catch {
                lastError = error
                if let urlError = error as? URLError,
                   urlError.code == .timedOut,
                   attempt < maxAttempts {
                    let backoffSeconds = Double(attempt) * 2.0
                    try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
        if let lastError = lastError {
            throw lastError
        }
    }
    
    /// Create a folder in a project
    /// - Parameters:
    ///   - projectId: The project ID
    ///   - folderName: The folder name
    ///   - parentFolderId: Optional parent folder ID (nil for root level)
    /// - Returns: The created folder ID
    private func createFolder(projectId: String, folderName: String, parentFolderId: String? = nil) async throws -> String {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        // According to API docs, folder_id goes in POST body, not URL
        let endpointURL = base.appendingPathComponent("create_folder").appendingPathComponent(projectId)
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        var params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "name": folderName
        ]
        
        // Add folder_id to POST body if creating a sub-folder
        if let parentId = parentFolderId, !parentId.isEmpty {
            params["folder_id"] = parentId
            print("     Creating sub-folder '\(folderName)' under parent folder ID: \(parentId)")
        } else {
            print("     Creating root folder '\(folderName)'")
        }
        
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to create folder: \(errorMessage)")
        }
        
        // Parse response to get folder_id
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let folderId = payload["folder_id"] as? String else {
            // Try alternative response format
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let root = json["root"] as? [String: Any],
               let payload = root["payload"] as? [String: Any],
               let folderId = payload["id"] as? String {
                return folderId
            }
            throw SimianError.apiError("Failed to parse folder_id from create_folder response")
        }
        
        return folderId
    }
    
    /// Create a folder in a project (public API for SimianPostView uploads)
    /// - Parameters:
    ///   - projectId: The project ID
    ///   - folderName: The folder name
    ///   - parentFolderId: Optional parent folder ID (nil for root level)
    /// - Returns: The created folder ID
    func createFolderPublic(projectId: String, folderName: String, parentFolderId: String? = nil) async throws -> String {
        try await createFolder(projectId: projectId, folderName: folderName, parentFolderId: parentFolderId)
    }

    /// Rename a folder
    func renameFolder(projectId: String, folderId: String, newName: String) async throws {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("rename_folder").appendingPathComponent(projectId)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "folder_id": folderId,
            "name": newName
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to rename folder: \(msg)")
        }
        try Self.requireSuccessRootResponse(data, action: "rename folder")
    }

    private func performRenameFileRequest(endpointURL: URL, params: [String: String]) async throws {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to rename file: \(msg)")
        }
        try Self.requireSuccessRootResponse(data, action: "rename file")
    }

    private static func expectedRenamedFileName(newTitle: String, currentFileName: String?) -> String {
        guard let currentFileName, !currentFileName.isEmpty else { return newTitle }
        let ext = (currentFileName as NSString).pathExtension
        guard !ext.isEmpty else { return newTitle }
        if newTitle.lowercased().hasSuffix(".\(ext.lowercased())") { return newTitle }
        return "\(newTitle).\(ext)"
    }

    /// Rename a file and verify title changed; `file_name` may be immutable on some Simian installs.
    @discardableResult
    func renameFile(projectId: String, fileId: String, newName: String, currentFileName: String? = nil) async throws -> SimianFileInfo {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("rename_file").appendingPathComponent(projectId)
        let expectedFileName = Self.expectedRenamedFileName(newTitle: newName, currentFileName: currentFileName)
        let params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "file_id": fileId,
            // Simian Projects API expects `name` for rename_file.
            "name": newName,
            // Include both explicit fields so backends that support them can update both values.
            "title": newName,
            "file_name": expectedFileName
        ]
        try await performRenameFileRequest(endpointURL: endpointURL, params: params)

        let info = try await getFileInfo(projectId: projectId, fileId: fileId)
        if info.title != newName {
            throw SimianError.apiError("Rename partially applied: expected title '\(newName)', got '\(info.title ?? "nil")'")
        }
        return info
    }

    /// Delete a folder (and its contents) from a project
    func deleteFolder(projectId: String, folderId: String) async throws {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("delete_folder").appendingPathComponent(projectId)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "folder_id": folderId
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to delete folder: \(msg)")
        }
    }

    /// Delete a file from a project
    func deleteFile(projectId: String, fileId: String) async throws {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("delete_file").appendingPathComponent(projectId)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "file_id": fileId
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to delete file: \(msg)")
        }
    }

    /// Delete an entire project from Simian. Use with care — this is irreversible.
    func deleteProject(projectId: String) async throws {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("delete_project").appendingPathComponent(projectId)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to delete project: \(msg)")
        }
    }

    /// Move a file to a different folder
    func moveFile(projectId: String, fileId: String, folderId: String) async throws {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("move_file").appendingPathComponent(projectId)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "file_id": fileId,
            "folder_id": folderId
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to move file: \(msg)")
        }
    }

    /// Update folder sort order within a parent folder
    /// - Parameters:
    ///   - projectId: Project ID
    ///   - parentFolderId: Parent folder ID (nil for root)
    ///   - folderIds: Folder IDs in desired order (comma-separated)
    func updateFolderSort(projectId: String, parentFolderId: String?, folderIds: [String]) async throws {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("update_folder_sort").appendingPathComponent(projectId)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "folders": folderIds.joined(separator: ",")
        ]
        if let pid = parentFolderId, !pid.isEmpty {
            params["folder_id"] = pid
        }
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to update folder sort: \(msg)")
        }
    }

    /// Update file sort order within a folder
    func updateFileSort(projectId: String, folderId: String, fileIds: [String]) async throws {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("update_file_sort").appendingPathComponent(projectId)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "files": fileIds.joined(separator: ",")
        ]
        if !folderId.isEmpty {
            params["folder_id"] = folderId
        }
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to update file sort: \(msg)")
        }
    }

    /// Get a Simian short link for a folder (same as Share → Get Shortlink → Create Link in Simian UI).
    /// - Parameters:
    ///   - projectId: The project ID
    ///   - folderId: The folder ID (required - API does not support project root)
    /// - Returns: The short link URL string (e.g. https://reel.io/6mq)
    func getShortLink(projectId: String, folderId: String) async throws -> String {
        try await ensureAuthenticated()
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        let endpointURL = base.appendingPathComponent("get_short_link").appendingPathComponent(projectId)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params: [String: String] = [
            "auth_token": authToken,
            "auth_key": authKey,
            "folder_id": folderId,
            "present_opt_download": "true"
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw SimianError.apiError("Failed to get short link: \(msg)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any],
              root["status"] as? String == "success",
              let payload = root["payload"] as? [String: Any],
              let shortLink = payload["short_link"] as? String,
              !shortLink.isEmpty else {
            throw SimianError.apiError("Invalid short link response")
        }
        return shortLink
    }

    /// Build a shareable web URL for a Simian project or folder.
    /// - Parameters:
    ///   - projectId: The project ID
    ///   - folderId: Optional folder ID (nil for project root)
    /// - Returns: URL like https://graysonmusic.gosimian.com/simian/projects/123 or ...?folder_id=456
    /// Web UI lives under `/simian/projects/` (same tree as archive download); `/projects/` routes 404 when logged in.
    static func folderLinkURL(projectId: String, folderId: String?) -> URL? {
        let base = "https://graysonmusic.gosimian.com"
        var path = "\(base)/simian/projects/\(projectId)"
        if let folderId = folderId, !folderId.isEmpty {
            path += "?folder_id=\(folderId)"
        }
        return URL(string: path)
    }

    /// Copy folder structure from template project to new project
    /// - Parameters:
    ///   - fromTemplateProjectId: The template project ID
    ///   - toProjectId: The new project ID
    private func copyFolderStructure(fromTemplateProjectId: String, toProjectId: String) async throws {
        print("   Copying folder structure from project \(fromTemplateProjectId) to project \(toProjectId)")
        
        // Recursive function to copy folders
        func copyFoldersRecursive(templateProjectId: String, newProjectId: String, parentFolderId: String? = nil, newParentFolderId: String? = nil) async throws {
            // Get folders from template project at this level
            let templateFolders = try await getFolders(projectId: templateProjectId, parentFolderId: parentFolderId)
            
            print("   Found \(templateFolders.count) folders at level (parent: \(parentFolderId ?? "root"))")
            
            // Create each folder in the new project
            for templateFolder in templateFolders {
                guard let folderName = templateFolder["name"] as? String,
                      let folderId = templateFolder["id"] as? String else {
                    continue
                }
                
                print("     Creating folder: \(folderName)")
                
                // Create the folder in the new project
                let newFolderId = try await createFolder(
                    projectId: newProjectId,
                    folderName: folderName,
                    parentFolderId: newParentFolderId
                )
                
                print("     ✅ Created folder '\(folderName)' with ID: \(newFolderId)")
                
                // Check if this folder has sub-folders and recursively copy them
                if let subFolders = templateFolder["sub_folders"] as? String,
                   let subFolderCount = Int(subFolders),
                   subFolderCount > 0 {
                    print("     Folder '\(folderName)' has \(subFolderCount) sub-folders, copying...")
                    try await copyFoldersRecursive(
                        templateProjectId: templateProjectId,
                        newProjectId: newProjectId,
                        parentFolderId: folderId,
                        newParentFolderId: newFolderId
                    )
                }
            }
        }
        
        // Start copying from root level
        try await copyFoldersRecursive(
            templateProjectId: fromTemplateProjectId,
            newProjectId: toProjectId,
            parentFolderId: nil,
            newParentFolderId: nil
        )
        
        print("✅ Successfully copied folder structure from template")
    }
    
    /// Essential users that must be included in the user list
    /// These are producers who send new docket emails and need to be available as project managers
    private let essentialUserEmails: Set<String> = [
        "kelly@graysonmusicgroup.com",
        "clare@graysonmusicgroup.com",
        "sharon@graysonmusicgroup.com",
        "nicholas@graysonmusicgroup.com"
    ]
    
    /// Fetch list of Simian users
    /// - Returns: Array of Simian users
    /// Per API docs: get_users - Get all system users that have project access
    func getUsers() async throws -> [SimianUser] {
        
        try await ensureAuthenticated()
        
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        // Use get_users endpoint per API documentation
        let endpointURL = base.appendingPathComponent("get_users")
        
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "auth_token": authToken,
            "auth_key": authKey
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to fetch users: \(errorMessage)")
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ SimianService.getUsers() failed to parse JSON")
            throw SimianError.apiError("Invalid JSON response")
        }
        
        guard let root = json["root"] as? [String: Any] else {
            print("⚠️ SimianService.getUsers() missing 'root' key. JSON: \(json)")
            throw SimianError.apiError("Invalid response format: missing 'root'")
        }
        
        
        guard let payload = root["payload"] else {
            print("⚠️ SimianService.getUsers() missing 'payload' key. Root: \(root)")
            throw SimianError.apiError("Invalid response format: missing 'payload'")
        }
        
        
        var userArray: [[String: Any]] = []
        if let payloadArray = payload as? [[String: Any]] {
            userArray = payloadArray
        } else if let payloadDict = payload as? [String: Any] {
            if let users = payloadDict["users"] as? [[String: Any]] {
                userArray = users
            } else if let users = payloadDict["data"] as? [[String: Any]] {
                userArray = users
            } else {
                #if DEBUG
                print("⚠️ SimianService.getUsers() unexpected payload; keys: \(payloadDict.keys.sorted().joined(separator: ", "))")
                #endif
            }
        } else {
            #if DEBUG
            print("⚠️ SimianService.getUsers() payload type: \(String(describing: type(of: payload)))")
            #endif
        }
        
        var users = userArray.compactMap { userDict -> SimianUser? in
            // Handle id as either String or Number
            let idString: String?
            if let id = userDict["id"] as? String {
                idString = id
            } else if let id = userDict["id"] as? Int {
                idString = String(id)
            } else if let id = userDict["id"] as? NSNumber {
                idString = id.stringValue
            } else if let userID = userDict["userID"] as? String {
                // Try userID as alternative (seen in API example)
                idString = userID
            } else if let userID = userDict["userID"] as? Int {
                idString = String(userID)
            } else {
                #if DEBUG
                print("⚠️ SimianService.getUsers() user missing or invalid 'id' field: \(userDict["id"] ?? "nil")")
                #endif
                idString = nil
            }
            
            // Try different case variations for field names
            let firstName = (userDict["firstname"] as? String) ?? 
                           (userDict["firstName"] as? String) ?? 
                           (userDict["first_name"] as? String) ?? ""
            let lastName = (userDict["lastname"] as? String) ?? 
                          (userDict["lastName"] as? String) ?? 
                          (userDict["last_name"] as? String) ?? ""
            let email = (userDict["email"] as? String) ?? ""
            
            guard let id = idString, !id.isEmpty,
                  !firstName.isEmpty,
                  !lastName.isEmpty,
                  !email.isEmpty else {
                #if DEBUG
                print("⚠️ SimianService.getUsers() skipped user row (missing id/name/email): id=\(idString ?? "nil") email='\(email)'")
                #endif
                return nil
            }
            
            return SimianUser(
                id: id,
                firstName: firstName,
                lastName: lastName,
                email: email,
                username: (userDict["username"] as? String) ?? (userDict["userName"] as? String)
            )
        }
        
        #if DEBUG
        print("✅ SimianService.getUsers: \(users.count) user(s)")
        #endif
        
        // If get_users returned empty, try fallback: get_project_users from a template project
        if users.isEmpty && userArray.isEmpty {
            #if DEBUG
            print("⚠️ SimianService.getUsers: empty payload — trying template-project fallback…")
            #endif
            
            // Try to get users from template projects
            var projectsChecked = 0
            do {
                let templates = try await getTemplates()
                #if DEBUG
                print("   …scanning up to 20 of \(templates.count) template project(s) for users")
                #endif
                
                // Try all templates to aggregate users from multiple projects
                // This ensures we get all users, not just from one project
                var existingEmails = Set(users.map { $0.email.lowercased() })
                let maxProjectsToCheck = min(templates.count, 20) // Check up to 20 projects to get comprehensive user list
                
                for template in templates.prefix(maxProjectsToCheck) {
                    do {
                        let projectUsers = try await getProjectUsers(projectId: template.id)
                        projectsChecked += 1
                        
                        if !projectUsers.isEmpty {
                            // Merge with existing users (avoid duplicates by email)
                            for projectUser in projectUsers {
                                if !existingEmails.contains(projectUser.email.lowercased()) {
                                    users.append(projectUser)
                                    existingEmails.insert(projectUser.email.lowercased())
                                }
                            }
                        }
                    } catch {
                        #if DEBUG
                        print("   ⚠️ Failed to get users from template '\(template.name)': \(error.localizedDescription)")
                        #endif
                        continue
                    }
                }
                
                // Check if essential users are present
                let foundEmails = Set(users.map { $0.email.lowercased() })
                let missingEssentialEmails = essentialUserEmails.filter { !foundEmails.contains($0.lowercased()) }
                
                if !missingEssentialEmails.isEmpty {
                    #if DEBUG
                    print("   ⚠️ Missing essential users: \(missingEssentialEmails.joined(separator: ", ")) — scanning more templates…")
                    #endif
                    
                    // Try to find essential users in remaining projects
                    let remainingProjects = Array(templates.dropFirst(maxProjectsToCheck))
                    let maxAdditionalProjects = min(remainingProjects.count, 30) // Check up to 30 more projects
                    
                    for template in remainingProjects.prefix(maxAdditionalProjects) {
                        do {
                            let projectUsers = try await getProjectUsers(projectId: template.id)
                            
                            for projectUser in projectUsers {
                                let userEmail = projectUser.email.lowercased()
                                if missingEssentialEmails.contains(userEmail) && !existingEmails.contains(userEmail) {
                                    users.append(projectUser)
                                    existingEmails.insert(userEmail)
                                } else if !existingEmails.contains(userEmail) {
                                    // Also add other users we find
                                    users.append(projectUser)
                                    existingEmails.insert(userEmail)
                                }
                            }
                            
                            // If we found all essential users, we can stop early
                            let stillMissing = essentialUserEmails.filter { !existingEmails.contains($0.lowercased()) }
                            if stillMissing.isEmpty {
                                break
                            }
                        } catch {
                            continue
                        }
                    }
                    
                    // Check again after additional search
                    let finalFoundEmails = Set(users.map { $0.email.lowercased() })
                    let stillMissing = essentialUserEmails.filter { !finalFoundEmails.contains($0.lowercased()) }
                    #if DEBUG
                    if !stillMissing.isEmpty {
                        print("   ⚠️ Still missing essential users after extended search: \(stillMissing.joined(separator: ", "))")
                    }
                    #endif
                }
            } catch {
                #if DEBUG
                print("   ⚠️ Failed to get templates for fallback: \(error.localizedDescription)")
                #endif
            }
            
            #if DEBUG
            if !users.isEmpty {
                print("✅ SimianService.getUsers: template fallback → \(users.count) user(s) (checked \(projectsChecked) template project(s))")
            }
            #endif
        }
        
        // If get_users returns empty, it might mean:
        // 1. No users have been granted project access
        // 2. The authenticated user doesn't have permission to see other users
        // 3. Users exist but haven't been configured with project access
        // 
        // Note: The API docs say "Get all system users that have project access"
        // This suggests it only returns users explicitly granted project access.
        // If the list is empty, users may need to be granted project access in Simian first.
        
        if users.isEmpty {
            print("⚠️ SimianService.getUsers: 0 users (check Simian project access; template fallback may also return empty)")
        }
        
        return users
    }
    
    /// Get users for a specific project (workaround when get_users returns empty)
    /// - Parameter projectId: The project ID
    /// - Returns: Array of Simian users
    private func getProjectUsers(projectId: String) async throws -> [SimianUser] {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        let endpointURL = base.appendingPathComponent("get_project_users").appendingPathComponent(projectId)
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "auth_token": authToken,
            "auth_key": authKey
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to fetch project users: \(errorMessage)")
        }
        
        // Parse response (similar structure to get_users)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = json["root"] as? [String: Any],
              let payload = root["payload"] else {
            return []
        }
        
        var userArray: [[String: Any]] = []
        if let payloadArray = payload as? [[String: Any]] {
            userArray = payloadArray
        } else if let payloadDict = payload as? [String: Any],
                  let users = payloadDict["users"] as? [[String: Any]] {
            userArray = users
        } else if let payloadDict = payload as? [String: Any],
                  let users = payloadDict["data"] as? [[String: Any]] {
            userArray = users
        }
        
        let users = userArray.compactMap { userDict -> SimianUser? in
            // Handle id as either String or Number
            let idString: String?
            if let id = userDict["id"] as? String {
                idString = id
            } else if let id = userDict["id"] as? Int {
                idString = String(id)
            } else if let id = userDict["id"] as? NSNumber {
                idString = id.stringValue
            } else if let userID = userDict["userID"] as? String {
                idString = userID
            } else if let userID = userDict["userID"] as? Int {
                idString = String(userID)
            } else {
                idString = nil
            }
            
            // Try different case variations for field names
            let firstName = (userDict["firstname"] as? String) ??
                           (userDict["firstName"] as? String) ??
                           (userDict["first_name"] as? String) ?? ""
            let lastName = (userDict["lastname"] as? String) ??
                          (userDict["lastName"] as? String) ??
                          (userDict["last_name"] as? String) ?? ""
            let email = (userDict["email"] as? String) ?? ""
            
            guard let id = idString, !id.isEmpty,
                  !firstName.isEmpty,
                  !lastName.isEmpty,
                  !email.isEmpty else {
                return nil
            }
            
            return SimianUser(
                id: id,
                firstName: firstName,
                lastName: lastName,
                email: email,
                username: (userDict["username"] as? String) ?? (userDict["userName"] as? String)
            )
        }
        
        return users
    }
    
    /// Look up a user ID from an email address by searching template projects
    /// - Parameter email: The email address to look up
    /// - Returns: The user ID if found, or nil if not found
    private func getUserIdByEmail(email: String) async throws -> String? {
        print("🔍 SimianService.getUserIdByEmail() looking up email: \(email)")
        
        // First try get_users (fastest if it works)
        do {
            let users = try await getUsers()
            if let user = users.first(where: { $0.email.lowercased() == email.lowercased() }) {
                print("✅ Found user ID \(user.id) for email \(email) via get_users")
                return user.id
            }
        } catch {
            print("⚠️ get_users failed, trying template projects: \(error.localizedDescription)")
        }
        
        // Fallback: search template projects
        do {
            let templates = try await getTemplates()
            print("   Searching \(templates.count) template projects for email: \(email)")
            
            // Check up to 10 template projects (should be enough to find common users)
            for template in templates.prefix(10) {
                do {
                    let projectUsers = try await getProjectUsers(projectId: template.id)
                    if let user = projectUsers.first(where: { $0.email.lowercased() == email.lowercased() }) {
                        print("✅ Found user ID \(user.id) for email \(email) in template project '\(template.name)'")
                        return user.id
                    }
                } catch {
                    // Continue to next template if this one fails
                    continue
                }
            }
            
            print("⚠️ Could not find user ID for email: \(email)")
            return nil
        } catch {
            print("⚠️ Failed to search template projects for email: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Fetch list of Simian projects to use as templates
    /// Templates are actually existing projects that can be used as templates
    /// - Returns: Array of Simian projects (used as templates)
    func getTemplates() async throws -> [SimianTemplate] {
        try await ensureAuthenticated()
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        // Use get_project_list - templates are existing projects
        let endpointURL = base.appendingPathComponent("get_project_list")
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "auth_token": authToken,
            "auth_key": authKey
        ]
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to fetch project templates: \(errorMessage)")
        }
        
        // Parse response - get_project_list returns array of projects
        // Use do-catch to capture JSON parsing errors
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode as string"
                print("❌ SimianService.getTemplates() failed: Response is not a JSON object")
                print("   Raw response: \(responseString)")
                throw SimianError.apiError("Invalid response format: Expected JSON object, got: \(responseString.prefix(200))")
            }
            
            guard let root = json["root"] as? [String: Any] else {
                print("❌ SimianService.getTemplates() failed: Missing 'root' key")
                print("   JSON keys: \(json.keys.joined(separator: ", "))")
                throw SimianError.apiError("Invalid response format: Missing 'root' key. Available keys: \(json.keys.joined(separator: ", "))")
            }
            
            // Handle different payload formats
            var payloadArray: [[String: Any]] = []
            if let payload = root["payload"] as? [[String: Any]] {
                payloadArray = payload
            } else if let payload = root["payload"] as? [String: Any] {
                // Single project object, wrap in array
                payloadArray = [payload]
            } else {
                print("❌ SimianService.getTemplates() failed: Payload is not an array")
                print("   Payload type: \(type(of: root["payload"]))")
                print("   Payload value: \(root["payload"] ?? "nil")")
                throw SimianError.apiError("Invalid response format: Payload is not an array")
            }
            
            let templates = payloadArray.compactMap { projectDict -> SimianTemplate? in
                // get_project_list returns: {"id":"3","project_name":"3.0 Test Project"}
                guard let id = projectDict["id"] as? String,
                      let name = projectDict["project_name"] as? String else {
                    return nil
                }
                
                return SimianTemplate(
                    id: id,
                    name: name
                )
            }
            #if DEBUG
            print("SimianService.getTemplates: \(templates.count) template project(s)")
            #endif
            return templates
        } catch let error as SimianError {
            throw error
        } catch {
            let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode as string"
            print("❌ SimianService.getTemplates() JSON parsing failed: \(error.localizedDescription)")
            print("   Raw response: \(responseString)")
            throw SimianError.apiError("Failed to parse JSON response: \(error.localizedDescription). Raw response: \(responseString.prefix(200))")
        }
    }
}

// MARK: - User Model

struct SimianUser: Identifiable, Hashable {
    let id: String
    let firstName: String
    let lastName: String
    let email: String
    let username: String?
    
    var displayName: String {
        "\(firstName) \(lastName)"
    }
    
    var fullDisplayName: String {
        "\(displayName) (\(email))"
    }
}

// MARK: - Template Model

struct SimianTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    
    /// The standard default template name (e.g. "O_NEW PROJECT TEMPLATE"). When MediaDash finds this in the template list, it is used as the default.
    static let defaultTemplateName = "O_NEW PROJECT TEMPLATE"
    
    /// Returns the default project template from the list when present (exact match for "O_NEW PROJECT TEMPLATE", or first containing "NEW PROJECT TEMPLATE").
    static func defaultTemplate(from templates: [SimianTemplate]) -> SimianTemplate? {
        let upper = defaultTemplateName.uppercased()
        if let exact = templates.first(where: { $0.name.trimmingCharacters(in: .whitespaces).uppercased() == upper }) {
            return exact
        }
        return templates.first(where: { $0.name.uppercased().contains("NEW PROJECT TEMPLATE") })
    }
}

// MARK: - Project Models

struct SimianProject: Identifiable, Hashable {
    let id: String
    let name: String
    let accessAreas: [String]?
}

struct SimianProjectInfo: Identifiable, Hashable {
    let id: String
    let name: String?
    let projectNumber: String?
    let uploadDate: String?
    let startDate: String?
    let completeDate: String?
    let lastAccess: String?
    let projectSize: String?
    
    nonisolated func dateValue(for field: SimianProjectDateField) -> Date? {
        let rawValue: String?
        switch field {
        case .uploadDate:
            rawValue = uploadDate
        case .startDate:
            rawValue = startDate
        case .completeDate:
            rawValue = completeDate
        case .lastAccess:
            rawValue = lastAccess
        }
        guard let rawValue = rawValue, !rawValue.isEmpty else {
            return nil
        }
        return SimianService.parseSimianMetadataDate(rawValue)
    }

    var projectSizeBytes: Int64? {
        guard let projectSize = projectSize else { return nil }
        return SimianService.parseMediaSize(projectSize)
    }
}

struct SimianFolder: Identifiable, Hashable {
    let id: String
    let name: String
    let parentId: String?
    /// When the API includes it (e.g. `upload_date`), the time the folder was added to Simian.
    let uploadedAt: Date?
}

struct SimianFile: Identifiable, Hashable {
    let id: String
    let title: String
    /// The stored filename on the server (e.g. "clip.wav"), as returned by `get_file_info` / `get_project_files`.
    let fileName: String?
    let fileType: String?
    let mediaURL: URL?
    let folderId: String?
    let projectId: String?
    /// When the API includes it (e.g. `upload_date`), the time the file was added to Simian.
    let uploadedAt: Date?
}

// MARK: - Project Date Filter

enum SimianProjectDateField: String, CaseIterable, Identifiable {
    case lastAccess = "last_access"
    case uploadDate = "upload_date"
    case startDate = "start_date"
    case completeDate = "complete_date"
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .uploadDate:
            return "Upload Date"
        case .startDate:
            return "Start Date"
        case .completeDate:
            return "Complete Date"
        case .lastAccess:
            return "Last Accessed"
        }
    }
}

struct SimianFileInfo: Identifiable, Hashable {
    let id: String
    let title: String?
    /// The stored filename on the server (e.g. "clip.wav"), as returned by `get_file_info`.
    let fileName: String?
    let mediaSize: String?
    /// Present when `get_file_info` includes upload/created metadata (list APIs sometimes omit it).
    let uploadedAt: Date?
    
    var mediaSizeBytes: Int64? {
        guard let mediaSize = mediaSize else { return nil }
        return SimianService.parseMediaSize(mediaSize)
    }
}

// MARK: - Response Models

struct SimianSetupResponse: Codable {
    let root: SetupRoot
    
    struct SetupRoot: Codable {
        let status: String
        let auth_key: String?
        let apiver: String?
    }
}

struct SimianLoginResponse: Codable {
    let root: LoginRoot
    
    struct LoginRoot: Codable {
        let status: String
        let message: String?
        let apiver: String?
        let payload: LoginPayload?
    }
    
    struct LoginPayload: Codable {
        let user_id: String?
        let email: String?
        let token: String?
        let project_access: String?
        let add_projects: [String]? // Can be array, empty array, or string "1"/"0"
        
        enum CodingKeys: String, CodingKey {
            case user_id
            case email
            case token
            case project_access
            case add_projects
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            user_id = try container.decodeIfPresent(String.self, forKey: .user_id)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            token = try container.decodeIfPresent(String.self, forKey: .token)
            project_access = try container.decodeIfPresent(String.self, forKey: .project_access)
            
            // Handle add_projects as either array or string
            if let arrayValue = try? container.decode([String].self, forKey: .add_projects) {
                add_projects = arrayValue
            } else if let stringValue = try? container.decode(String.self, forKey: .add_projects) {
                // If it's a string like "1" or "0", convert to array
                add_projects = stringValue.isEmpty ? [] : [stringValue]
            } else {
                add_projects = nil
            }
        }
    }
}

// MARK: - Helpers

extension SimianService {
    nonisolated fileprivate static func stringValue(_ value: Any?) -> String? {
        if let stringValue = value as? String, !stringValue.isEmpty {
            return stringValue
        }
        return nil
    }
    
    fileprivate static func stringArrayValue(_ value: Any?) -> [String]? {
        if let arrayValue = value as? [String] {
            return arrayValue.isEmpty ? nil : arrayValue
        }
        if let stringValue = value as? String, !stringValue.isEmpty {
            return [stringValue]
        }
        return nil
    }

    fileprivate static func parseMediaSize(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        
        let parts = trimmed.split(separator: " ")
        guard let numberPart = parts.first else { return nil }
        
        let unit = parts.count > 1 ? parts[1].uppercased() : "B"
        let numberString = numberPart.replacingOccurrences(of: ",", with: "")
        guard let number = Double(numberString) else { return nil }
        
        switch unit {
        case "B":
            return Int64(number)
        case "KB":
            return Int64(number * 1024)
        case "MB":
            return Int64(number * 1024 * 1024)
        case "GB":
            return Int64(number * 1024 * 1024 * 1024)
        default:
            return Int64(number)
        }
    }
}

private struct ArchiveDownloadResult {
    let tempURL: URL
    let response: URLResponse?
}

/// Holds the download task so cancellation handler can reference it without capturing a var (Swift 6).
private final class DownloadTaskHolder: @unchecked Sendable {
    nonisolated(unsafe) var task: URLSessionDownloadTask?
}

private final class ArchiveDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: ((Int64, Int64?) -> Void)?
    private let stagingDirectory: URL?
    private var continuation: CheckedContinuation<ArchiveDownloadResult, Error>?
    private var tempURL: URL?
    private var didComplete = false
    private var finishError: Error?
    
    init(progress: ((Int64, Int64?) -> Void)?, stagingDirectory: URL?) {
        self.progressHandler = progress
        self.stagingDirectory = stagingDirectory
    }
    
    func attachContinuation(_ continuation: CheckedContinuation<ArchiveDownloadResult, Error>) {
        self.continuation = continuation
    }
    
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progressHandler?(totalBytesWritten, expected)
    }
    
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let stagingDirectory else {
            tempURL = location
            return
        }
        
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let stagedURL = stagingDirectory.appendingPathComponent(".staged_\(UUID().uuidString).zip")
            if fileManager.fileExists(atPath: stagedURL.path) {
                try fileManager.removeItem(at: stagedURL)
            }
            try fileManager.copyItem(at: location, to: stagedURL)
            tempURL = stagedURL
        } catch {
            finishError = error
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !didComplete else { return }
        didComplete = true
        
        if let error = error {
            continuation?.resume(throwing: error)
            return
        }
        
        if let finishError {
            continuation?.resume(throwing: finishError)
            return
        }
        
        guard let tempURL = tempURL else {
            continuation?.resume(throwing: SimianError.apiError("Archive download failed."))
            return
        }
        
        continuation?.resume(returning: ArchiveDownloadResult(tempURL: tempURL, response: task.response))
    }
}

// MARK: - Errors

enum SimianError: LocalizedError {
    case notConfigured
    case apiError(String)
    case authenticationFailed
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Simian API is not configured. Please set the API base URL, username, and password in settings."
        case .apiError(let message):
            return "Simian API error: \(message)"
        case .authenticationFailed:
            return "Simian authentication failed. Please check your credentials."
        }
    }
}
