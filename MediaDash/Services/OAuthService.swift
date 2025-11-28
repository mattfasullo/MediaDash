import Foundation
import AppKit
import Combine
import Network

/// Service for handling OAuth2 authentication flows
@MainActor
class OAuthService: ObservableObject {
    @Published var isAuthenticating = false
    @Published var authenticationError: String?
    
    private var authState: String?
    private var localServer: LocalOAuthServer?
    private var authContinuation: CheckedContinuation<String, Error>?
    
    /// Start OAuth2 flow for Asana with local server callback
    func authenticateAsana(clientId: String, clientSecret: String, useOutOfBand: Bool = false) async throws -> OAuthToken {
        isAuthenticating = true
        authenticationError = nil
        
        defer {
            isAuthenticating = false
        }
        
        // Generate state for CSRF protection
        let state = UUID().uuidString
        self.authState = state
        
        // Use out-of-band flow for native apps, or localhost for web apps
        let redirectURI = useOutOfBand ? "urn:ietf:wg:oauth:2.0:oob" : "http://localhost:8080/callback"
        
        // Build authorization URL
        // Note: We don't include a 'scope' parameter - Asana will use the app's default permissions
        // If your app has "Full Permissions" enabled, this should work without specifying scopes
        var components = URLComponents(string: "https://app.asana.com/-/oauth_authorize")!
        let queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state)
        ]
        
        // Only add scope if explicitly needed - for now, omit it to use app's default permissions
        // If you need specific scopes, uncomment and add them:
        // let queryItemsWithScope = queryItems + [URLQueryItem(name: "scope", value: "default")]
        
        components.queryItems = queryItems
        
        guard let authURL = components.url else {
            throw OAuthError.invalidURL
        }
        
        if useOutOfBand {
            // Out-of-band flow: user will see code in browser and paste it
            // For now, throw an error that we'll handle in the UI
            throw OAuthError.manualCodeRequired(state: state, authURL: authURL)
        } else {
            // Local server flow
            let server = LocalOAuthServer(port: 8080)
            self.localServer = server
            
            // Start listening for callback
            let authCode = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                self.authContinuation = continuation
                
                server.start { [weak self] code, receivedState in
                    guard let self = self else { return }
                    
                    // Verify state matches
                    guard receivedState == self.authState else {
                        continuation.resume(throwing: OAuthError.invalidState)
                        return
                    }
                    
                    continuation.resume(returning: code)
                }
                
                // Open browser for authentication after server is ready
                NSWorkspace.shared.open(authURL)
            }
            
            // Wait for callback (server will call continuation when callback is received)
            let code = authCode
            
            // Stop the server
            server.stop()
            self.localServer = nil
            self.authContinuation = nil
            
            // Exchange code for token
            let token = try await exchangeCodeForToken(
                code: code,
                clientId: clientId,
                clientSecret: clientSecret,
                redirectURI: redirectURI
            )
            
            return token
        }
    }
    
    /// Exchange authorization code for access token (for manual code entry)
    func exchangeCodeForTokenManually(code: String, clientId: String, clientSecret: String) async throws -> OAuthToken {
        return try await exchangeCodeForToken(
            code: code,
            clientId: clientId,
            clientSecret: clientSecret,
            redirectURI: "urn:ietf:wg:oauth:2.0:oob"
        )
    }
    
    /// Exchange authorization code for access token
    func exchangeCodeForToken(code: String, clientId: String, clientSecret: String, redirectURI: String) async throws -> OAuthToken {
        let url = URL(string: "https://app.asana.com/-/oauth_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "code": code
        ]
        
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(AsanaTokenResponse.self, from: data)
        return OAuthToken(accessToken: tokenResponse.access_token, refreshToken: tokenResponse.refresh_token)
    }
    
    /// Store access token securely
    func storeToken(_ token: String, for service: String) {
        _ = KeychainService.store(key: "\(service)_access_token", value: token)
    }
    
    /// Retrieve stored access token
    func retrieveToken(for service: String) -> String? {
        return KeychainService.retrieve(key: "\(service)_access_token")
    }
    
    /// Clear stored token
    func clearToken(for service: String) {
        KeychainService.delete(key: "\(service)_access_token")
    }
    
    // MARK: - Convenience Methods (using hardcoded credentials)
    
    /// Start OAuth2 flow for Asana using hardcoded credentials from OAuthConfig
    func authenticateAsana(useOutOfBand: Bool = false) async throws -> OAuthToken {
        guard OAuthConfig.isAsanaConfigured else {
            throw OAuthError.serverError("Asana OAuth credentials not configured. Please update OAuthConfig.swift with your credentials.")
        }
        return try await authenticateAsana(
            clientId: OAuthConfig.asanaClientID,
            clientSecret: OAuthConfig.asanaClientSecret,
            useOutOfBand: useOutOfBand
        )
    }
    
    /// Exchange authorization code for access token (for manual code entry) using hardcoded credentials
    func exchangeCodeForTokenManually(code: String) async throws -> OAuthToken {
        guard OAuthConfig.isAsanaConfigured else {
            throw OAuthError.serverError("Asana OAuth credentials not configured. Please update OAuthConfig.swift with your credentials.")
        }
        return try await exchangeCodeForTokenManually(
            code: code,
            clientId: OAuthConfig.asanaClientID,
            clientSecret: OAuthConfig.asanaClientSecret
        )
    }
    
    // MARK: - Gmail OAuth
    
    /// Start OAuth2 flow for Gmail with local server callback
    func authenticateGmail(clientId: String, clientSecret: String, useOutOfBand: Bool = false) async throws -> OAuthToken {
        isAuthenticating = true
        authenticationError = nil
        
        defer {
            isAuthenticating = false
        }
        
        // Generate state for CSRF protection
        let state = UUID().uuidString
        self.authState = state
        
        // Gmail OAuth scopes
        let scopes = [
            "https://www.googleapis.com/auth/gmail.readonly",
            "https://www.googleapis.com/auth/gmail.modify",
            "https://www.googleapis.com/auth/gmail.send"
        ]
        let scopeString = scopes.joined(separator: " ")
        
        // Use out-of-band flow for native apps, or localhost for web apps
        let redirectURI = useOutOfBand ? "urn:ietf:wg:oauth:2.0:oob" : "http://localhost:8081/callback"
        
        // Build authorization URL for Google OAuth
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopeString),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        
        // Debug: Log what we're sending
        #if DEBUG
        print("🔍 Gmail OAuth Debug:")
        print("  Client ID: \(clientId)")
        print("  Client ID length: \(clientId.count)")
        print("  Redirect URI: \(redirectURI)")
        print("  Scopes: \(scopeString)")
        #endif
        
        components.queryItems = queryItems
        
        guard let authURL = components.url else {
            throw OAuthError.invalidURL
        }
        
        #if DEBUG
        print("  Authorization URL: \(authURL.absoluteString)")
        #endif
        
        if useOutOfBand {
            // Out-of-band flow: user will see code in browser and paste it
            throw OAuthError.manualCodeRequired(state: state, authURL: authURL)
        } else {
            // Local server flow - use port 8081 for Gmail to avoid conflict with Asana (8080)
            let server = LocalOAuthServer(port: 8081)
            self.localServer = server
            
            // Start listening for callback
            let authCode = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                self.authContinuation = continuation
                
                server.start { [weak self] code, receivedState in
                    guard let self = self else { return }
                    
                    // Verify state matches
                    guard receivedState == self.authState else {
                        continuation.resume(throwing: OAuthError.invalidState)
                        return
                    }
                    
                    continuation.resume(returning: code)
                }
                
                // Open browser for authentication after server is ready
                NSWorkspace.shared.open(authURL)
            }
            
            // Wait for callback (server will call continuation when callback is received)
            let code = authCode
            
            // Stop the server
            server.stop()
            self.localServer = nil
            self.authContinuation = nil
            
            // Exchange code for token
            let token = try await exchangeCodeForGmailToken(
                code: code,
                clientId: clientId,
                clientSecret: clientSecret,
                redirectURI: redirectURI
            )
            
            return token
        }
    }
    
    /// Exchange authorization code for access token (for manual code entry)
    func exchangeCodeForGmailTokenManually(code: String, clientId: String, clientSecret: String) async throws -> OAuthToken {
        return try await exchangeCodeForGmailToken(
            code: code,
            clientId: clientId,
            clientSecret: clientSecret,
            redirectURI: "urn:ietf:wg:oauth:2.0:oob"
        )
    }
    
    /// Exchange authorization code for access token (Gmail)
    func exchangeCodeForGmailToken(code: String, clientId: String, clientSecret: String, redirectURI: String) async throws -> OAuthToken {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "code": code
        ]
        
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            
            // Provide more helpful error messages
            if httpResponse.statusCode == 401 {
                if errorMessage.contains("invalid_client") {
                    throw OAuthError.serverError("Invalid Client ID or Secret. Please verify:\n1. Client ID and Secret are correct in OAuthConfig.swift\n2. Redirect URI 'http://localhost:8081/callback' is added in Google Cloud Console\n3. OAuth consent screen is configured\n\nError: \(errorMessage)")
                } else {
                    throw OAuthError.serverError("Authentication failed (401). Error: \(errorMessage)")
                }
            }
            
            throw OAuthError.serverError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        let tokenResponse = try JSONDecoder().decode(GmailTokenResponse.self, from: data)
        return OAuthToken(accessToken: tokenResponse.access_token, refreshToken: tokenResponse.refresh_token)
    }
    
    /// Start OAuth2 flow for Gmail using hardcoded credentials from OAuthConfig
    func authenticateGmail(useOutOfBand: Bool = false) async throws -> OAuthToken {
        guard OAuthConfig.isGmailConfigured else {
            throw OAuthError.serverError("Gmail OAuth credentials not configured. Please update OAuthConfig.swift with your credentials.")
        }
        return try await authenticateGmail(
            clientId: OAuthConfig.gmailClientID,
            clientSecret: OAuthConfig.gmailClientSecret,
            useOutOfBand: useOutOfBand
        )
    }
    
    /// Exchange authorization code for access token (for manual code entry) using hardcoded credentials
    func exchangeCodeForGmailTokenManually(code: String) async throws -> OAuthToken {
        guard OAuthConfig.isGmailConfigured else {
            throw OAuthError.serverError("Gmail OAuth credentials not configured. Please update OAuthConfig.swift with your credentials.")
        }
        return try await exchangeCodeForGmailTokenManually(
            code: code,
            clientId: OAuthConfig.gmailClientID,
            clientSecret: OAuthConfig.gmailClientSecret
        )
    }
}

// MARK: - Models

struct OAuthToken {
    let accessToken: String
    let refreshToken: String?
}

struct AsanaTokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let token_type: String
}

enum OAuthError: LocalizedError {
    case invalidURL
    case tokenExchangeFailed
    case invalidState
    case serverError(String)
    case manualCodeRequired(state: String, authURL: URL)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OAuth URL"
        case .tokenExchangeFailed:
            return "Failed to exchange authorization code for token"
        case .invalidState:
            return "Invalid OAuth state parameter"
        case .serverError(let message):
            return "OAuth server error: \(message)"
        case .manualCodeRequired:
            return "Please copy the authorization code from your browser and paste it below"
        }
    }
}

// MARK: - Local OAuth Server

/// Simple HTTP server to catch OAuth callback
class LocalOAuthServer {
    private let port: UInt16
    private var listener: NWListener?
    private var callback: ((String, String) -> Void)?
    
    init(port: UInt16 = 8080) {
        self.port = port
    }
    
    func start(callback: @escaping (String, String) -> Void) {
        self.callback = callback
        
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .main)
        } catch {
            callback("", "")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        callback = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, let request = String(data: data, encoding: .utf8) {
                self.handleRequest(request, connection: connection)
            }
            
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }
    
    private func handleRequest(_ request: String, connection: NWConnection) {
        // Parse GET request
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first, firstLine.hasPrefix("GET") else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        // Extract URL path and query
        let components = firstLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        let pathWithQuery = components[1]
        guard let url = URL(string: "http://localhost\(pathWithQuery)"),
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        // Extract code and state from query
        var code: String?
        var state: String?
        
        for item in queryItems {
            if item.name == "code" {
                code = item.value
            } else if item.name == "state" {
                state = item.value
            }
        }
        
        if let code = code, let state = state {
            // Send success response
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>Authorization Successful</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; padding: 50px; }
                    h1 { color: #36C5F0; }
                </style>
            </head>
            <body>
                <h1>✓ Authorization Successful</h1>
                <p>You can close this window and return to MediaDash.</p>
            </body>
            </html>
            """
            sendResponse(connection: connection, statusCode: 200, body: html)
            
            // Call callback with code and state
            callback?(code, state)
        } else {
            // Send error response
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>Authorization Failed</title>
                <style>
                    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; text-align: center; padding: 50px; }
                    h1 { color: #FF5630; }
                </style>
            </head>
            <body>
                <h1>✗ Authorization Failed</h1>
                <p>Please try again.</p>
            </body>
            </html>
            """
            sendResponse(connection: connection, statusCode: 400, body: html)
            callback?("", "")
        }
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, body: String) {
        let response = """
        HTTP/1.1 \(statusCode) \(statusCode == 200 ? "OK" : "Bad Request")
        Content-Type: text/html; charset=utf-8
        Content-Length: \(body.utf8.count)
        Connection: close
        
        \(body)
        """
        
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
    }
}
