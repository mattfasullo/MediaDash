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
        print("🔐 SimianService.authenticate() called")
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
        
        print("🔐 SimianService.authenticate() Step 1: Getting auth_key from \(baseURLString)")
        
        // Step 1: Get session auth_key
        let setupURL = base.appendingPathComponent("prjacc")
        var setupRequest = URLRequest(url: setupURL)
        setupRequest.httpMethod = "POST"
        setupRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        print("🔐 SimianService.authenticate() Sending setup request to: \(setupURL.absoluteString)")
        let (setupData, setupResponse) = try await session.data(for: setupRequest)
        
        if let httpResponse = setupResponse as? HTTPURLResponse {
            print("🔐 SimianService.authenticate() Setup response status: \(httpResponse.statusCode)")
        }
        
        let setupResponseString = String(data: setupData, encoding: .utf8) ?? "Unable to decode as string"
        print("🔐 SimianService.authenticate() Setup raw response: \(setupResponseString.prefix(500))")
        
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
        
        print("🔐 SimianService.authenticate() Step 2: Logging in with username: \(username)")
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        
        if let httpResponse = loginResponse as? HTTPURLResponse {
            print("🔐 SimianService.authenticate() Login response status: \(httpResponse.statusCode)")
        }
        
        let loginResponseString = String(data: loginData, encoding: .utf8) ?? "Unable to decode as string"
        print("🔐 SimianService.authenticate() Login raw response: \(loginResponseString.prefix(500))")
        
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
            print("   Raw login response: \(responseString)")
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
        
        // #region agent log
        let logDataAuth: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "F",
            "location": "SimianService.swift:180",
            "message": "Login response parsed",
            "data": [
                "hasToken": !authToken.isEmpty,
                "projectAccess": loginResponseObj.root.payload?.project_access ?? "nil",
                "addProjects": loginResponseObj.root.payload?.add_projects?.description ?? "nil",
                "userId": loginResponseObj.root.payload?.user_id ?? "nil"
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logDataAuth)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
        print("✅ SimianService: Successfully authenticated")
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
            
            // #region agent log
            let logDataCreateJob: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "CREATE_JOB",
                "location": "SimianService.swift:318",
                "message": "createJob() response received",
                "data": [
                    "statusCode": httpResponse.statusCode,
                    "dataLength": data.count,
                    "responseString": String(data: data, encoding: .utf8) ?? "nil"
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let logLine = (try? JSONSerialization.data(withJSONObject: logDataCreateJob)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(logLine)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
            // #endregion
            
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
        print("   getProjectInfo endpoint: \(endpointURL.absoluteString)")
        
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
        
        var endpointURL = base.appendingPathComponent("get_folders").appendingPathComponent(projectId)
        if let parentId = parentFolderId, !parentId.isEmpty {
            endpointURL = endpointURL.appendingPathComponent(parentId)
        }
        
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
        
        // #region agent log
        do {
            let sample = rawFolders.prefix(3).map { folder -> [String: Any] in
                [
                    "id": folder["id"] ?? "nil",
                    "name": folder["name"] ?? "nil",
                    "sub_files": folder["sub_files"] ?? "nil",
                    "sub_folders": folder["sub_folders"] ?? "nil"
                ]
            }
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H5",
                "location": "SimianService.swift:getProjectFolders",
                "message": "getProjectFolders payload",
                "data": [
                    "projectId": projectId,
                    "parentFolderId": parentFolderId ?? "root",
                    "folderCount": rawFolders.count,
                    "sample": sample
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion
        return rawFolders.compactMap { folder in
            guard let id = SimianService.stringValue(folder["id"]),
                  let name = SimianService.stringValue(folder["name"]) else {
                return nil
            }
            return SimianFolder(
                id: id,
                name: name,
                parentId: SimianService.stringValue(folder["parent"])
            )
        }
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
        
        // #region agent log
        do {
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H1",
                "location": "SimianService.swift:getProjectFiles",
                "message": "getProjectFiles request",
                "data": [
                    "projectId": projectId,
                    "folderId": folderId ?? "root",
                    "endpoint": endpointURL.absoluteString
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion
        
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
        
        // #region agent log
        do {
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H1",
                "location": "SimianService.swift:getProjectFiles",
                "message": "getProjectFiles response",
                "data": [
                    "projectId": projectId,
                    "folderId": folderId ?? "root",
                    "statusCode": httpResponse.statusCode,
                    "dataLength": data.count
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion
        
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

        // #region agent log
        do {
            let statusValue = root["status"] as? String ?? "unknown"
            let messageValue = root["message"] as? String ?? "unknown"
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H1",
                "location": "SimianService.swift:getProjectFiles",
                "message": "getProjectFiles payload parsed",
                "data": [
                    "projectId": projectId,
                    "folderId": folderId ?? "root",
                    "payloadCount": payloadArray.count,
                    "status": statusValue,
                    "message": messageValue,
                    "dataLength": data.count
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion

        if data.count < 512, let responseString = String(data: data, encoding: .utf8) {
            // #region agent log
            do {
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "H1",
                    "location": "SimianService.swift:getProjectFiles",
                    "message": "getProjectFiles raw response",
                    "data": [
                        "projectId": projectId,
                        "folderId": folderId ?? "root",
                        "response": responseString
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                    let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                    logFile.seekToEndOfFile()
                    logFile.write(line)
                    logFile.write("\n".data(using: .utf8)!)
                    logFile.closeFile()
                }
            }
            // #endregion
        }
        
        if payloadArray.isEmpty {
            // #region agent log
            do {
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "H6",
                    "location": "SimianService.swift:getProjectFiles",
                    "message": "getProjectFiles empty payload",
                    "data": [
                        "projectId": projectId,
                        "folderId": folderId ?? "root"
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                    let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                    logFile.seekToEndOfFile()
                    logFile.write(line)
                    logFile.write("\n".data(using: .utf8)!)
                    logFile.closeFile()
                }
            }
            // #endregion
            
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
                    let altPayload = (altRoot["payload"] as? [[String: Any]]) ??
                        ((altRoot["payload"] as? [String: Any]).map { [$0] } ?? [])
                    // #region agent log
                    do {
                        let logData: [String: Any] = [
                            "sessionId": "debug-session",
                            "runId": "run1",
                            "hypothesisId": "H6",
                            "location": "SimianService.swift:getProjectFiles",
                            "message": "alternate get_files result",
                            "data": [
                                "projectId": projectId,
                                "folderId": folderId,
                                "statusCode": altHttp.statusCode,
                                "payloadCount": altPayload.count
                            ],
                            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                        ]
                        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                            let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                            logFile.seekToEndOfFile()
                            logFile.write(line)
                            logFile.write("\n".data(using: .utf8)!)
                            logFile.closeFile()
                        }
                    }
                    // #endregion
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
                fileType: SimianService.stringValue(fileDict["file_type"]),
                mediaURL: mediaFileURL,
                folderId: folderId,
                projectId: projectId
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
              let root = json["root"] as? [String: Any],
              let payload = root["payload"] as? [[String: Any]],
              let fileInfo = payload.first else {
            throw SimianError.apiError("Invalid response format from get_file_info")
        }
        
        return SimianFileInfo(
            id: fileId,
            title: SimianService.stringValue(fileInfo["title"]),
            mediaSize: SimianService.stringValue(fileInfo["media_size"])
        )
    }

    /// Download a file using the Simian session (cookies included)
    func downloadFile(from sourceURL: URL, to destinationURL: URL) async throws {
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "GET"
        
        // #region agent log
        do {
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H2",
                "location": "SimianService.swift:downloadFile",
                "message": "downloadFile request",
                "data": [
                    "host": sourceURL.host ?? "nil",
                    "path": sourceURL.path
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion
        
        let (tempURL, response) = try await session.download(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw SimianError.apiError("Failed to download file: \(sourceURL.lastPathComponent)")
        }
        
        // #region agent log
        do {
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H2",
                "location": "SimianService.swift:downloadFile",
                "message": "downloadFile response",
                "data": [
                    "statusCode": httpResponse.statusCode,
                    "host": sourceURL.host ?? "nil",
                    "path": sourceURL.path
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion
        
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: tempURL, to: destinationURL)
    }

    /// Download a project ZIP archive from the Simian web UI
    func downloadProjectArchive(
        projectId: String,
        to destinationURL: URL,
        progress: ((Int64, Int64?) -> Void)? = nil
    ) async throws {
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
        
        // #region agent log
        do {
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H7",
                "location": "SimianService.swift:downloadProjectArchive",
                "message": "archive download request",
                "data": [
                    "projectId": projectId,
                    "url": archiveURL.absoluteString
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion
        
        let (_, headResponse) = try await archiveSession.data(for: headRequest)
        let headStatus = (headResponse as? HTTPURLResponse)?.statusCode ?? -1
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
        
        // #region agent log
        do {
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H7",
                "location": "SimianService.swift:downloadProjectArchive",
                "message": "archive HEAD response",
                "data": [
                    "projectId": projectId,
                    "statusCode": headStatus,
                    "estimatedSize": headSize
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion
        
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            var request = URLRequest(url: archiveURL)
            request.httpMethod = "GET"
            
            do {
                let downloadDelegate = ArchiveDownloadDelegate(progress: progress)
                let downloadSession = URLSession(
                    configuration: archiveSession.configuration,
                    delegate: downloadDelegate,
                    delegateQueue: nil
                )
                defer { downloadSession.finishTasksAndInvalidate() }
                
                let result: ArchiveDownloadResult = try await withCheckedThrowingContinuation { continuation in
                    downloadDelegate.attachContinuation(continuation)
                    let task = downloadSession.downloadTask(with: request)
                    task.resume()
                }
                guard let httpResponse = result.response as? HTTPURLResponse else {
                    throw SimianError.apiError("Archive download failed: \(archiveURL.lastPathComponent)")
                }
                guard (200...299).contains(httpResponse.statusCode) else {
            // #region agent log
            do {
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "H7",
                    "location": "SimianService.swift:downloadProjectArchive",
                    "message": "archive download non-2xx",
                    "data": [
                        "projectId": projectId,
                        "statusCode": httpResponse.statusCode,
                        "contentType": httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil"
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                    let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                    logFile.seekToEndOfFile()
                    logFile.write(line)
                    logFile.write("\n".data(using: .utf8)!)
                    logFile.closeFile()
                }
            }
            // #endregion
                    throw SimianError.apiError("Archive download failed: \(archiveURL.lastPathComponent)")
                }
        
        // #region agent log
        do {
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H7",
                "location": "SimianService.swift:downloadProjectArchive",
                "message": "archive download response",
                "data": [
                    "projectId": projectId,
                    "statusCode": httpResponse.statusCode,
                    "contentType": httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil",
                    "contentDisposition": httpResponse.value(forHTTPHeaderField: "Content-Disposition") ?? "nil"
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion
        
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: result.tempURL, to: destinationURL)
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
        // #region agent log
        let logData: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "A",
            "location": "SimianService.swift:322",
            "message": "getUsers() called",
            "data": [
                "baseURL": baseURL ?? "nil",
                "hasAuthToken": authToken != nil,
                "hasAuthKey": authKey != nil
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
        try await ensureAuthenticated()
        
        // #region agent log
        let logDataAuthState: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "G",
            "location": "SimianService.swift:863",
            "message": "Authentication state after ensureAuthenticated",
            "data": [
                "hasAuthToken": authToken != nil,
                "hasAuthKey": authKey != nil,
                "authTokenLength": authToken?.count ?? 0,
                "authKeyLength": authKey?.count ?? 0
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logDataAuthState)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
        guard let baseURLString = baseURL, !baseURLString.isEmpty,
              let base = URL(string: baseURLString),
              let authKey = authKey,
              let authToken = authToken else {
            throw SimianError.notConfigured
        }
        
        // Use get_users endpoint per API documentation
        let endpointURL = base.appendingPathComponent("get_users")
        
        // #region agent log
        let logData2: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "B",
            "location": "SimianService.swift:333",
            "message": "Request URL and params",
            "data": [
                "endpointURL": endpointURL.absoluteString,
                "hasAuthKey": !authKey.isEmpty,
                "hasAuthToken": !authToken.isEmpty
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logData2)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
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
        
        // #region agent log
        let logData3: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "C",
            "location": "SimianService.swift:347",
            "message": "Response received",
            "data": [
                "statusCode": (response as? HTTPURLResponse)?.statusCode ?? -1,
                "dataLength": data.count,
                "responseString": String(data: data, encoding: .utf8) ?? "nil"
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logData3)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to fetch users: \(errorMessage)")
        }
        
        // Parse response
        let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode"
        print("🔍 SimianService.getUsers() raw response: \(responseString)")
        
        // #region agent log
        let logDataResponse: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "H",
            "location": "SimianService.swift:945",
            "message": "getUsers API response received",
            "data": [
                "statusCode": (response as? HTTPURLResponse)?.statusCode ?? -1,
                "responseLength": data.count,
                "responsePreview": String(responseString.prefix(500))
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logDataResponse)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("⚠️ SimianService.getUsers() failed to parse JSON")
            throw SimianError.apiError("Invalid JSON response")
        }
        
        guard let root = json["root"] as? [String: Any] else {
            print("⚠️ SimianService.getUsers() missing 'root' key. JSON: \(json)")
            throw SimianError.apiError("Invalid response format: missing 'root'")
        }
        
        // #region agent log
        let logData4: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "D",
            "location": "SimianService.swift:368",
            "message": "Root object parsed",
            "data": [
                "rootKeys": Array(root.keys),
                "status": root["status"] as? String ?? "nil",
                "message": root["message"] as? String ?? "nil"
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logData4)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
        guard let payload = root["payload"] else {
            print("⚠️ SimianService.getUsers() missing 'payload' key. Root: \(root)")
            throw SimianError.apiError("Invalid response format: missing 'payload'")
        }
        
        // #region agent log
        let logData5: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "E",
            "location": "SimianService.swift:373",
            "message": "Payload extracted",
            "data": [
                "payloadType": String(describing: type(of: payload)),
                "isArray": payload is [Any],
                "isDict": payload is [String: Any],
                "payloadValue": String(describing: payload)
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logData5)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
        // Handle different payload formats
        var userArray: [[String: Any]] = []
        if let payloadArray = payload as? [[String: Any]] {
            userArray = payloadArray
            print("🔍 SimianService.getUsers() payload is an array with \(payloadArray.count) items")
        } else if let payloadDict = payload as? [String: Any] {
            // Maybe payload is a dictionary with users inside?
            print("🔍 SimianService.getUsers() payload is a dictionary, not array: \(payloadDict)")
            print("🔍 SimianService.getUsers() dictionary keys: \(payloadDict.keys.joined(separator: ", "))")
            // Try to find users array within the dictionary
            if let users = payloadDict["users"] as? [[String: Any]] {
                userArray = users
                print("🔍 SimianService.getUsers() found 'users' key with \(users.count) items")
            } else if let users = payloadDict["data"] as? [[String: Any]] {
                userArray = users
                print("🔍 SimianService.getUsers() found 'data' key with \(users.count) items")
            } else {
                // Log all keys to help debug
                print("⚠️ SimianService.getUsers() payload dictionary doesn't contain 'users' or 'data' keys")
                print("   Available keys: \(payloadDict.keys.joined(separator: ", "))")
            }
        } else {
            print("⚠️ SimianService.getUsers() payload is neither array nor dict: \(type(of: payload))")
            print("   Payload value: \(payload)")
        }
        
        print("🔍 SimianService.getUsers() found \(userArray.count) users in payload")
        
        // Log first user structure for debugging
        if let firstUser = userArray.first {
            print("🔍 SimianService.getUsers() first user structure: \(firstUser)")
            print("   Keys: \(firstUser.keys.joined(separator: ", "))")
        } else if userArray.isEmpty {
            print("⚠️ SimianService.getUsers() payload is empty array")
            print("   This could mean:")
            print("   1. No users have 'project access' permissions in Simian")
            print("   2. The authenticated user doesn't have permission to view other users")
            print("   3. Users exist but need to be granted project access")
            print("   Note: get_users only returns users with 'project access' permissions")
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
                print("⚠️ SimianService.getUsers() user missing or invalid 'id' field: \(userDict["id"] ?? "nil")")
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
                print("⚠️ SimianService.getUsers() failed to parse user:")
                print("   id: \(idString ?? "nil")")
                print("   firstname: '\(firstName)'")
                print("   lastname: '\(lastName)'")
                print("   email: '\(email)'")
                print("   Full dict: \(userDict)")
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
        
        print("✅ SimianService.getUsers() successfully parsed \(users.count) users")
        
        // If get_users returned empty, try fallback: get_project_users from a template project
        if users.isEmpty && userArray.isEmpty {
            print("⚠️ WARNING: get_users returned empty array, trying fallback with get_project_users")
            print("   Attempting to get users from template projects as workaround...")
            
            // Try to get users from template projects
            do {
                let templates = try await getTemplates()
                print("   Found \(templates.count) template projects, trying to get users from them...")
                
                // Try all templates to aggregate users from multiple projects
                // This ensures we get all users, not just from one project
                var existingEmails = Set(users.map { $0.email.lowercased() })
                var projectsChecked = 0
                let maxProjectsToCheck = min(templates.count, 20) // Check up to 20 projects to get comprehensive user list
                
                for template in templates.prefix(maxProjectsToCheck) {
                    do {
                        let projectUsers = try await getProjectUsers(projectId: template.id)
                        projectsChecked += 1
                        
                        if !projectUsers.isEmpty {
                            print("   ✅ Found \(projectUsers.count) users from template project '\(template.name)' (ID: \(template.id))")
                            
                            // Merge with existing users (avoid duplicates by email)
                            var newUsersCount = 0
                            for projectUser in projectUsers {
                                if !existingEmails.contains(projectUser.email.lowercased()) {
                                    users.append(projectUser)
                                    existingEmails.insert(projectUser.email.lowercased())
                                    newUsersCount += 1
                                }
                            }
                            
                            if newUsersCount > 0 {
                                print("   Added \(newUsersCount) new users (total: \(users.count))")
                            } else {
                                print("   All users already in list (total: \(users.count))")
                            }
                        } else {
                            print("   ⚠️ Template project '\(template.name)' has no users")
                        }
                    } catch {
                        print("   ⚠️ Failed to get users from template '\(template.name)': \(error.localizedDescription)")
                        continue
                    }
                }
                
                print("   Checked \(projectsChecked) template projects, found \(users.count) total unique users")
                
                // Check if essential users are present
                let foundEmails = Set(users.map { $0.email.lowercased() })
                let missingEssentialEmails = essentialUserEmails.filter { !foundEmails.contains($0.lowercased()) }
                
                if !missingEssentialEmails.isEmpty {
                    print("   ⚠️ Missing essential users: \(missingEssentialEmails.joined(separator: ", "))")
                    print("   Searching through more projects to find essential users...")
                    
                    // Try to find essential users in remaining projects
                    let remainingProjects = Array(templates.dropFirst(maxProjectsToCheck))
                    var additionalProjectsChecked = 0
                    let maxAdditionalProjects = min(remainingProjects.count, 30) // Check up to 30 more projects
                    
                    for template in remainingProjects.prefix(maxAdditionalProjects) {
                        do {
                            let projectUsers = try await getProjectUsers(projectId: template.id)
                            additionalProjectsChecked += 1
                            
                            for projectUser in projectUsers {
                                let userEmail = projectUser.email.lowercased()
                                if missingEssentialEmails.contains(userEmail) && !existingEmails.contains(userEmail) {
                                    users.append(projectUser)
                                    existingEmails.insert(userEmail)
                                    print("   ✅ Found essential user: \(projectUser.email) from project '\(template.name)'")
                                } else if !existingEmails.contains(userEmail) {
                                    // Also add other users we find
                                    users.append(projectUser)
                                    existingEmails.insert(userEmail)
                                }
                            }
                            
                            // If we found all essential users, we can stop early
                            let stillMissing = essentialUserEmails.filter { !existingEmails.contains($0.lowercased()) }
                            if stillMissing.isEmpty {
                                print("   ✅ Found all essential users! Stopping search.")
                                break
                            }
                        } catch {
                            continue
                        }
                    }
                    
                    print("   Checked \(additionalProjectsChecked) additional projects for essential users")
                    
                    // Check again after additional search
                    let finalFoundEmails = Set(users.map { $0.email.lowercased() })
                    let stillMissing = essentialUserEmails.filter { !finalFoundEmails.contains($0.lowercased()) }
                    if !stillMissing.isEmpty {
                        print("   ⚠️ WARNING: Still missing essential users after extended search: \(stillMissing.joined(separator: ", "))")
                        print("   These users may not exist in Simian or may not be assigned to any projects.")
                    } else {
                        print("   ✅ All essential users found!")
                    }
                } else {
                    print("   ✅ All essential users are present in the list")
                }
            } catch {
                print("   ⚠️ Failed to get templates for fallback: \(error.localizedDescription)")
            }
            
            if users.isEmpty {
                print("⚠️ WARNING: Both get_users and get_project_users fallback returned empty")
                print("   The API endpoint is working, but no users are being returned.")
                print("   This typically means:")
                print("   1. No users have been granted 'project access' permissions in Simian")
                print("   2. The authenticated user doesn't have admin permissions to view all users")
                print("   3. Template projects don't have any users assigned")
                print("   Solution: Check Simian admin settings to ensure users have project access")
            } else {
                print("✅ Successfully retrieved \(users.count) users using fallback method")
            }
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
            print("⚠️ SimianService.getUsers() returned 0 users")
            print("   This could mean:")
            print("   1. No users have been granted 'project access' in Simian")
            print("   2. The authenticated user doesn't have admin permissions")
            print("   3. Users exist but need to be configured with project access")
            print("   Note: get_users only returns users with project access permissions")
        }
        
        // #region agent log
        let logData6: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "G",
            "location": "SimianService.swift:414",
            "message": "getUsers() completed",
            "data": [
                "usersCount": users.count,
                "userArrayCount": userArray.count,
                "parsedSuccessfully": users.count > 0,
                "payloadWasEmpty": userArray.isEmpty
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logData6)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
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
        
        // #region agent log
        let logDataTemplates: [String: Any] = [
            "sessionId": "debug-session",
            "runId": "run1",
            "hypothesisId": "TEMPLATES",
            "location": "SimianService.swift:683",
            "message": "getTemplates() response received",
            "data": [
                "statusCode": (response as? HTTPURLResponse)?.statusCode ?? -1,
                "dataLength": data.count,
                "responseString": String(data: data, encoding: .utf8) ?? "nil"
            ],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
        ]
        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
            let logLine = (try? JSONSerialization.data(withJSONObject: logDataTemplates)) ?? Data()
            logFile.seekToEndOfFile()
            logFile.write(logLine)
            logFile.write("\n".data(using: .utf8)!)
            logFile.closeFile()
        }
        // #endregion
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimianError.apiError("Invalid response from API")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw SimianError.apiError("Failed to fetch project templates: \(errorMessage)")
        }
        
        // Log raw response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            print("🔍 SimianService.getTemplates() raw response: \(responseString)")
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
            
            return payloadArray.compactMap { projectDict in
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
    
    func dateValue(for field: SimianProjectDateField) -> Date? {
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
        return SimianProjectInfo.parseDate(rawValue)
    }

    var projectSizeBytes: Int64? {
        guard let projectSize = projectSize else { return nil }
        return SimianService.parseMediaSize(projectSize)
    }
    
    private static func parseDate(_ rawValue: String) -> Date? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        
        let formats = [
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd hh:mm a",
            "yyyy-MM-dd HH:mm:ss",
            "MM/dd/yyyy",
            "MM/dd/yy"
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
        
        return nil
    }
}

struct SimianFolder: Identifiable, Hashable {
    let id: String
    let name: String
    let parentId: String?
}

struct SimianFile: Identifiable, Hashable {
    let id: String
    let title: String
    let fileType: String?
    let mediaURL: URL?
    let folderId: String?
    let projectId: String?
}

// MARK: - Project Date Filter

enum SimianProjectDateField: String, CaseIterable, Identifiable {
    case uploadDate = "upload_date"
    case startDate = "start_date"
    case completeDate = "complete_date"
    case lastAccess = "last_access"
    
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
    let mediaSize: String?
    
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
    fileprivate static func stringValue(_ value: Any?) -> String? {
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

private final class ArchiveDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: ((Int64, Int64?) -> Void)?
    private var continuation: CheckedContinuation<ArchiveDownloadResult, Error>?
    private var tempURL: URL?
    private var didComplete = false
    
    init(progress: ((Int64, Int64?) -> Void)?) {
        self.progressHandler = progress
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
        tempURL = location
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !didComplete else { return }
        didComplete = true
        
        if let error = error {
            continuation?.resume(throwing: error)
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
