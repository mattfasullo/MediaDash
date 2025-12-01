import Foundation
import CodeMind
import Combine

/// Service that uses CodeMind AI to classify and understand email content
/// for identifying new docket emails and file delivery emails
@MainActor
class CodeMindEmailClassifier: ObservableObject {
    var objectWillChange = PassthroughSubject<Void, Never>()
    private var codeMind: CodeMind?
    private var isInitialized = false
    private var initializationTask: Task<Void, Error>?
    
    /// Detect provider from API key format
    /// - Parameter apiKey: The API key to analyze
    /// - Returns: Always returns "gemini" (only provider supported)
    private func detectProviderFromAPIKey(_ apiKey: String) -> String {
        // Only Gemini is supported
        return "gemini"
    }
    
    /// Initialize CodeMind with API key from environment or settings
    /// - Parameters:
    ///   - apiKey: Optional API key. If nil, will try to get from Keychain/shared keys
    ///   - provider: Provider name ("gemini" or "grok"). If nil, will try to get from settings or default to Gemini
    ///   - codebasePath: Optional codebase path for context
    func initialize(apiKey: String? = nil, provider: String? = nil, codebasePath: String? = nil) async throws {
        // Prevent multiple simultaneous initializations
        if let existingTask = initializationTask {
            try await existingTask.value
            return
        }
        
        guard !isInitialized else { return }
        
        let task = Task { [weak self] in
            guard let self = self else { return }
            
            // Determine provider: use provided, then try settings, then default
            var selectedProvider = provider?.lowercased() ?? 
                                  UserDefaults.standard.string(forKey: "codemind_provider")?.lowercased() ??
                                  CodeMindConfig.getDefaultProvider()
            
            // Ensure provider is supported
            if !CodeMindConfig.supportedProviders.contains(selectedProvider) {
                selectedProvider = CodeMindConfig.getDefaultProvider()
            }
            
            CodeMindLogger.shared.log(.info, "Initializing CodeMind with \(selectedProvider.capitalized)", category: .initialization)
            
            // Get API key for selected provider - try multiple sources in order
            var finalApiKey = apiKey
            var keySource = "parameter"
            
            if finalApiKey == nil {
                // Try provider key from SharedKeychainService or personal Keychain
                finalApiKey = CodeMindConfig.getAPIKey(for: selectedProvider)
                if finalApiKey != nil {
                    keySource = "Keychain/SharedKeychain"
                }
            }
            
            if finalApiKey == nil {
                // Fallback to environment variables
                if selectedProvider == "gemini" {
                    finalApiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
                    if finalApiKey != nil {
                        keySource = "Environment (GEMINI_API_KEY)"
                    }
                } else if selectedProvider == "grok" {
                    finalApiKey = ProcessInfo.processInfo.environment["GROK_API_KEY"]
                    if finalApiKey != nil {
                        keySource = "Environment (GROK_API_KEY)"
                    }
                } else if selectedProvider == "groq" {
                    finalApiKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"]
                    if finalApiKey != nil {
                        keySource = "Environment (GROQ_API_KEY)"
                    }
                }
            }
            
            // If no key found, provide clear error message
            guard let key = finalApiKey else {
                let providerName = selectedProvider.capitalized
                let envVarName: String
                switch selectedProvider {
                case "grok":
                    envVarName = "GROK_API_KEY"
                case "groq":
                    envVarName = "GROQ_API_KEY"
                default:
                    envVarName = "GEMINI_API_KEY"
                }
                let errorMsg = "\(providerName) API key not found. Configure an API key in Settings > CodeMind AI or set the \(envVarName) environment variable."
                CodeMindLogger.shared.log(.error, errorMsg, category: .initialization, metadata: ["provider": selectedProvider])
                print("❌ CodeMind: \(errorMsg)")
                throw CodeMindError.notConfigured(errorMsg)
            }
            
            // Log that we found a key (but don't log the actual key for security)
            let providerName = selectedProvider.capitalized
            print("✅ CodeMind: \(providerName) API key found from \(keySource) (length: \(key.count), prefix: \(String(key.prefix(10)))...)")
            CodeMindLogger.shared.log(.info, "API key found from \(keySource)", category: .initialization, metadata: ["provider": selectedProvider, "keyLength": key.count, "keySource": keySource])
            CodeMindLogger.shared.log(.info, "Initializing CodeMind", category: .initialization, metadata: ["hasApiKey": true, "provider": selectedProvider])
            
            // Convert provider string to CloudProvider enum
            let cloudProvider: CloudProvider
            switch selectedProvider.lowercased() {
            case "gemini":
                cloudProvider = .gemini
            case "grok":
                cloudProvider = .grok
                CodeMindLogger.shared.log(.info, "Using Grok (xAI) provider", category: .initialization)
                print("✅ CodeMind: Using Grok (xAI) provider")
            case "groq":
                // Groq uses OpenAI-compatible API, mapped to .grok CloudProvider
                cloudProvider = .grok
                CodeMindLogger.shared.log(.info, "Using Groq provider (OpenAI-compatible)", category: .initialization)
                print("✅ CodeMind: Using Groq provider (OpenAI-compatible)")
            default:
                let errorMsg = "Unsupported provider: \(selectedProvider). Supported providers: Gemini, Grok, Groq"
                CodeMindLogger.shared.log(.error, errorMsg, category: .initialization)
                throw CodeMindError.notConfigured(errorMsg)
            }
            
            CodeMindLogger.shared.log(.debug, "Using provider: \(providerName)", category: .initialization)
            
            // For email classification, we don't need the entire codebase as context
            // This prevents huge API responses and improves performance
            // Pass nil for codebasePath to skip codebase indexing
            let config = Configuration(
                llmMode: .cloud(cloudProvider),
                apiKey: key,
                codebasePath: nil  // Don't include codebase context for email classification
            )
            
            CodeMindLogger.shared.log(.info, "Creating CodeMind instance (without codebase context)", category: .initialization)
            
            // Try to create CodeMind instance - catch DecodingError specifically as it indicates API response issues
            do {
            self.codeMind = try await CodeMind.create(config: config)
            CodeMindLogger.shared.log(.success, "CodeMind instance created", category: .initialization)
            } catch let error as DecodingError {
                // DecodingError during CodeMind.create() suggests the API returned malformed/large response
                CodeMindLogger.shared.log(.error, "CodeMind.create() failed with DecodingError", category: .initialization, metadata: [
                    "error": "\(error)",
                    "provider": providerName
                ])
                
                // Provide more helpful error
                throw CodeMindError.apiError("""
                CodeMind initialization failed: The API returned an invalid response.
                
                This appears to be an issue with the \(providerName) provider - it's returning a very large 
                response that can't be parsed.
                
                Suggestions:
                • Verify your \(providerName) API key is correct
                • Check if the \(providerName) API service is experiencing issues
                • Try again later
                
                Error: \(error.localizedDescription)
                """)
            }
            
            // Skip codebase indexing for email classification - it's not needed and causes huge responses
            CodeMindLogger.shared.log(.debug, "Skipping codebase indexing for email classifier (not needed)", category: .indexing)
            
            self.isInitialized = true
            CodeMindLogger.shared.log(.success, "CodeMind initialized successfully", category: .initialization)
            
            // Sync with shared cache after initialization
            CodeMindLogger.shared.log(.info, "Syncing with shared cache", category: .cache)
            await CodeMindSharedCacheManager.shared.syncWithSharedCache()
        }
        
        initializationTask = task
        
        do {
        try await task.value
        print("CodeMindEmailClassifier: Initialized successfully")
            initializationTask = nil
        } catch {
            // If initialization fails, clear the codeMind instance to force fresh initialization next time
            self.codeMind = nil
            self.isInitialized = false
            initializationTask = nil
            CodeMindLogger.shared.log(.error, "CodeMind initialization failed: \(error)", category: .initialization)
            throw error
        }
    }
    
    /// Classify an email to determine if it's a new docket email
    /// - Parameters:
    ///   - subject: Email subject
    ///   - body: Email body (plain text or HTML)
    ///   - from: Sender email address
    /// - Returns: Classification result with confidence and extracted information, plus the CodeMind response for feedback
    func classifyNewDocketEmail(
        subject: String?,
        body: String?,
        from: String?
    ) async throws -> (classification: DocketEmailClassification, response: CodeMindResponse) {
        // Log at the VERY START to confirm function is called - use print for immediate visibility
        print("🚀 classifyNewDocketEmail START - Function called")
        CodeMindLogger.shared.log(.info, "🚀 classifyNewDocketEmail START", category: .classification)
        
        guard let codeMind = codeMind else {
            print("❌ CodeMind not initialized")
            CodeMindLogger.shared.log(.error, "❌ CodeMind not initialized", category: .classification)
            throw CodeMindError.notInitialized
        }
        
        print("✅ CodeMind instance exists, proceeding with classification")
        
        let emailContent = buildEmailContext(subject: subject, body: body, from: from)
        
            CodeMindLogger.shared.log(.info, "Classifying new docket email", category: .classification, metadata: [
            "hasSubject": subject != nil,
            "hasBody": body != nil,
            "hasFrom": from != nil,
            "subjectPreview": subject?.prefix(50) ?? "nil",
            "bodyLength": body?.count ?? 0,
            "fromEmail": from ?? "nil"
        ])
        
        let prompt = """
        You must respond with ONLY valid JSON. Do not include any text, explanation, or content before or after the JSON object.
        
        Analyze this email to determine if it's a "new docket" email - an email that announces or creates a new docket/job for a media production project.
        
        Email content:
        \(emailContent)
        
        Instructions:
        1. Determine if this email is announcing a new docket/job (not a reply, not a file delivery, not a status update)
        2. If it IS a new docket email, extract:
           - Docket number (format: usually numbers/letters like "12345" or "ABC-123")
           - Job name/Client name (the project or client name)
           - Any other relevant metadata
        3. Respond with ONLY this JSON object, nothing else:
        {
          "isNewDocket": true/false,
          "confidence": 0.0-1.0,
          "docketNumber": "12345" or null,
          "jobName": "Client Name" or null,
          "reasoning": "Brief explanation of why this is/isn't a new docket email",
          "extractedMetadata": {
            "agency": "Agency name if mentioned",
            "client": "Client name if mentioned",
            "projectManager": "PM name if mentioned"
          }
        }
        
        CRITICAL: Respond with ONLY the JSON object above. No markdown, no code blocks, no explanations, no additional text. Start with { and end with }.
        """
        
        CodeMindLogger.shared.log(.debug, "Sending prompt to LLM", category: .llm, metadata: ["promptLength": "\(prompt.count)"])
        
        let response: CodeMindResponse
        do {
            response = try await codeMind.process(prompt)
            CodeMindLogger.shared.log(.success, "✅ CodeMind.process() completed", category: .llm, metadata: ["responseLength": "\(response.content.count)"])
        } catch let error as DecodingError {
            // Handle JSON decoding errors that occur inside CodeMind.process()
            // This can happen if Gemini returns a malformed or very large response
            CodeMindLogger.shared.log(.error, "❌ CodeMind.process() failed with DecodingError", category: .llm, metadata: [
                "error": "\(error)",
                "errorDescription": error.localizedDescription
            ])
            
            // Provide a more helpful error message
            throw CodeMindError.invalidResponse("""
            CodeMind API returned an invalid response that couldn't be parsed. 
            This usually means:
            • The API key is invalid or expired
            • The provider (Gemini) is experiencing issues
            • The response was too large or malformed
            
            Error: \(error.localizedDescription)
            
            Please verify your API key is correct for the selected provider.
            """)
        } catch let llmError {
            CodeMindLogger.shared.log(.error, "❌ CodeMind.process() threw: \(llmError)", category: .llm, metadata: [
                "errorType": String(describing: type(of: llmError)),
                "error": "\(llmError)",
                "errorDescription": llmError.localizedDescription
            ])
            
            // Convert LLMError to CodeMindError for consistent error handling
            // LLMError from CodeMind package has cases: apiError, parseError, rateLimited, timeout, etc.
            let errorString = "\(llmError)"
            let errorDesc = llmError.localizedDescription
            
            // Check for API errors (most common - invalid API key, service errors, etc.)
            if errorString.contains("apiError") || errorDesc.contains("API error:") || errorDesc.contains("API key") {
                // Extract error message - LLMError.apiError format is "API error: {message}"
                let message: String
                if let apiErrorRange = errorDesc.range(of: "API error:") {
                    message = String(errorDesc[apiErrorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if errorDesc.contains("API key not valid") || errorDesc.contains("INVALID_ARGUMENT") {
                    message = "Invalid or expired API key. Please verify your API key is correct for the selected provider (Gemini)."
                } else {
                    message = errorDesc.isEmpty ? "Unknown API error" : errorDesc
                }
                throw CodeMindError.apiError(message)
            } else if errorString.contains("parseError") || errorDesc.contains("parse") {
                // Parse errors from LLM responses
                throw CodeMindError.invalidResponse("Failed to parse API response: \(errorDesc)")
            } else if errorString.contains("rateLimited") || errorDesc.contains("rate limit") {
                // Rate limiting
                throw CodeMindError.apiError("Rate limit exceeded. Please try again later.")
            } else if errorString.contains("timeout") || errorDesc.contains("timeout") {
                // Timeout errors
                throw CodeMindError.apiError("Request timed out. Please try again.")
            } else {
                // For other errors, wrap in apiError or invalidResponse
                throw CodeMindError.apiError("CodeMind API error: \(errorDesc)")
            }
        }
        
        CodeMindLogger.shared.log(.success, "Received LLM response", category: .llm, metadata: ["responseLength": "\(response.content.count)"])
        
        // Log actual response content for debugging (first 1000 chars for better diagnosis)
        let responsePreview = response.content.prefix(1000)
        CodeMindLogger.shared.log(.debug, "LLM Response received", category: .llm, metadata: [
            "preview": String(responsePreview),
            "fullLength": "\(response.content.count)"
        ])
        
        // For very large responses, try to extract just the JSON portion first
        let contentToParse: String
        if response.content.count > 1_000_000 { // If response is > 1MB, extract JSON first
            CodeMindLogger.shared.log(.debug, "Response is very large (\(response.content.count) chars), attempting to extract JSON", category: .classification)
            if let jsonRange = extractJSONFromResponse(response.content) {
                contentToParse = String(response.content[jsonRange])
                CodeMindLogger.shared.log(.debug, "Extracted JSON from large response", category: .classification, metadata: [
                    "extractedLength": "\(contentToParse.count)",
                    "originalLength": "\(response.content.count)"
                ])
            } else {
                contentToParse = response.content
            }
        } else {
            contentToParse = response.content
        }
        
        // Parse JSON response
        guard let jsonData = contentToParse.data(using: .utf8) else {
            CodeMindLogger.shared.log(.error, "Could not convert response to data", category: .classification, metadata: ["responsePreview": String(responsePreview)])
            throw CodeMindError.invalidResponse("Could not convert response to data")
        }
        
        // Try to decode JSON, with better error handling
        let classification: DocketEmailClassification
        do {
            classification = try JSONDecoder().decode(DocketEmailClassification.self, from: jsonData)
        } catch let decodingError as DecodingError {
            // Log the actual response for debugging (truncate if too large)
            let logResponse = response.content.count > 10_000 
                ? String(response.content.prefix(10_000)) + "... (truncated, total length: \(response.content.count))"
                : response.content
            CodeMindLogger.shared.log(.error, "JSON decoding failed", category: .classification, metadata: [
                "error": "\(decodingError)",
                "responsePreview": String(responsePreview),
                "responseLength": "\(response.content.count)",
                "fullResponse": logResponse
            ])
            
            // Try to extract JSON from response if it has extra text
            if let jsonRange = extractJSONFromResponse(response.content) {
                let jsonString = String(response.content[jsonRange])
                CodeMindLogger.shared.log(.debug, "Attempting to parse extracted JSON", category: .classification, metadata: [
                    "extractedJSONLength": "\(jsonString.count)",
                    "extractedJSONPreview": jsonString.count > 500 ? String(jsonString.prefix(500)) + "..." : jsonString
                ])
                if let extractedData = jsonString.data(using: .utf8),
                   let extracted = try? JSONDecoder().decode(DocketEmailClassification.self, from: extractedData) {
                    classification = extracted
                    CodeMindLogger.shared.log(.success, "Successfully parsed extracted JSON", category: .classification)
                } else {
                    throw CodeMindError.invalidResponse("Response is not valid JSON. Error: \(decodingError.localizedDescription). Response preview: \(String(responsePreview.prefix(200)))")
                }
            } else {
                throw CodeMindError.invalidResponse("Response is not valid JSON. Error: \(decodingError.localizedDescription). Response preview: \(String(responsePreview.prefix(200)))")
            }
        }
        
        CodeMindLogger.shared.log(.success, "Classification complete", category: .classification, metadata: [
            "isNewDocket": "\(classification.isNewDocket)",
            "confidence": String(format: "%.2f", classification.confidence),
            "hasDocketNumber": classification.docketNumber != nil,
            "hasJobName": classification.jobName != nil
        ])
        
        return (classification, response)
    }
    
    /// Classify an email to determine if it's a file delivery email
    /// - Parameters:
    ///   - subject: Email subject
    ///   - body: Email body (plain text or HTML)
    ///   - from: Sender email address
    ///   - recipients: Array of recipient email addresses
    /// - Returns: Classification result with confidence and file links, plus the CodeMind response for feedback
    func classifyFileDeliveryEmail(
        subject: String?,
        body: String?,
        from: String?,
        recipients: [String] = []
    ) async throws -> (classification: FileDeliveryClassification, response: CodeMindResponse) {
        guard let codeMind = codeMind else {
            throw CodeMindError.notInitialized
        }
        
        let emailContent = buildEmailContext(subject: subject, body: body, from: from, recipients: recipients)
        
        CodeMindLogger.shared.log(.info, "Classifying file delivery email", category: .classification, metadata: [
            "hasSubject": subject != nil,
            "hasBody": body != nil,
            "hasFrom": from != nil,
            "recipientCount": "\(recipients.count)",
            "subjectPreview": subject?.prefix(50) ?? "nil",
            "bodyLength": body?.count ?? 0,
            "fromEmail": from ?? "nil"
        ])
        
        let prompt = """
        Analyze this email to determine if it's a file delivery email - an email that contains links to files hosted on file sharing services (Dropbox, WeTransfer, Google Drive, etc.) or contains file attachments.
        
        Email content:
        \(emailContent)
        
        Instructions:
        1. Determine if this email is delivering files (not a new docket, not a status update, not a general communication)
        2. If it IS a file delivery email, extract:
           - File hosting links (Dropbox, WeTransfer, Google Drive, OneDrive, etc.)
           - Any indication of what files are being shared
           - Whether files are attached directly
        3. Respond in JSON format:
        {
          "isFileDelivery": true/false,
          "confidence": 0.0-1.0,
          "fileLinks": ["https://...", "https://..."],
          "fileHostingServices": ["Dropbox", "WeTransfer"],
          "reasoning": "Brief explanation of why this is/isn't a file delivery email",
          "hasAttachments": true/false
        }
        
        Only respond with valid JSON, no additional text.
        """
        
        CodeMindLogger.shared.log(.debug, "Sending prompt to LLM", category: .llm, metadata: ["promptLength": "\(prompt.count)"])
        let response = try await codeMind.process(prompt)
        CodeMindLogger.shared.log(.success, "Received LLM response", category: .llm, metadata: ["responseLength": "\(response.content.count)"])
        
        // Log actual response content for debugging (first 1000 chars for better diagnosis)
        let responsePreview = response.content.prefix(1000)
        CodeMindLogger.shared.log(.debug, "LLM Response received", category: .llm, metadata: [
            "preview": String(responsePreview),
            "fullLength": "\(response.content.count)"
        ])
        
        // For very large responses, try to extract just the JSON portion first
        let contentToParse: String
        if response.content.count > 1_000_000 { // If response is > 1MB, extract JSON first
            CodeMindLogger.shared.log(.debug, "Response is very large (\(response.content.count) chars), attempting to extract JSON", category: .classification)
            if let jsonRange = extractJSONFromResponse(response.content) {
                contentToParse = String(response.content[jsonRange])
                CodeMindLogger.shared.log(.debug, "Extracted JSON from large response", category: .classification, metadata: [
                    "extractedLength": "\(contentToParse.count)",
                    "originalLength": "\(response.content.count)"
                ])
            } else {
                contentToParse = response.content
            }
        } else {
            contentToParse = response.content
        }
        
        // Parse JSON response
        guard let jsonData = contentToParse.data(using: .utf8) else {
            CodeMindLogger.shared.log(.error, "Could not convert response to data", category: .classification, metadata: ["responsePreview": String(responsePreview)])
            throw CodeMindError.invalidResponse("Could not convert response to data")
        }
        
        // Try to decode JSON, with better error handling
        let classification: FileDeliveryClassification
        do {
            classification = try JSONDecoder().decode(FileDeliveryClassification.self, from: jsonData)
        } catch let decodingError as DecodingError {
            // Log the actual response for debugging (truncate if too large)
            let logResponse = response.content.count > 10_000 
                ? String(response.content.prefix(10_000)) + "... (truncated, total length: \(response.content.count))"
                : response.content
            CodeMindLogger.shared.log(.error, "JSON decoding failed", category: .classification, metadata: [
                "error": "\(decodingError)",
                "responsePreview": String(responsePreview),
                "responseLength": "\(response.content.count)",
                "fullResponse": logResponse
            ])
            
            // Try to extract JSON from response if it has extra text
            if let jsonRange = extractJSONFromResponse(response.content) {
                let jsonString = String(response.content[jsonRange])
                CodeMindLogger.shared.log(.debug, "Attempting to parse extracted JSON", category: .classification, metadata: [
                    "extractedJSONLength": "\(jsonString.count)",
                    "extractedJSONPreview": jsonString.count > 500 ? String(jsonString.prefix(500)) + "..." : jsonString
                ])
                if let extractedData = jsonString.data(using: .utf8),
                   let extracted = try? JSONDecoder().decode(FileDeliveryClassification.self, from: extractedData) {
                    classification = extracted
                    CodeMindLogger.shared.log(.success, "Successfully parsed extracted JSON", category: .classification)
                } else {
                    throw CodeMindError.invalidResponse("Response is not valid JSON. Error: \(decodingError.localizedDescription). Response preview: \(String(responsePreview.prefix(200)))")
                }
            } else {
                throw CodeMindError.invalidResponse("Response is not valid JSON. Error: \(decodingError.localizedDescription). Response preview: \(String(responsePreview.prefix(200)))")
            }
        }
        
        CodeMindLogger.shared.log(.success, "File delivery classification complete", category: .classification, metadata: [
            "isFileDelivery": "\(classification.isFileDelivery)",
            "confidence": String(format: "%.2f", classification.confidence),
            "fileLinksCount": "\(classification.fileLinks.count)",
            "services": classification.fileHostingServices.joined(separator: ", ")
        ])
        
        return (classification, response)
    }
    
    /// Provide feedback to CodeMind about a classification result
    /// - Parameters:
    ///   - response: The original CodeMind response
    ///   - rating: 1-5 rating (1 = very wrong, 5 = perfect)
    ///   - wasCorrect: Whether the classification was correct
    ///   - correction: Optional correction text explaining what was wrong
    ///   - comment: Optional additional feedback
    func provideFeedback(
        for response: CodeMindResponse,
        rating: Int,
        wasCorrect: Bool,
        correction: String? = nil,
        comment: String? = nil
    ) async throws {
        guard let codeMind = codeMind else {
            throw CodeMindError.notInitialized
        }
        
        let feedback = Feedback(
            rating: rating,
            comment: comment,
            correction: correction,
            wasHelpful: wasCorrect,
            categories: [.accuracy, .relevance]
        )
        
        CodeMindLogger.shared.log(.info, "Providing feedback to CodeMind", category: .feedback, metadata: [
            "rating": "\(rating)",
            "wasCorrect": "\(wasCorrect)",
            "hasCorrection": correction != nil,
            "hasComment": comment != nil
        ])
        
        try await codeMind.provideFeedback(feedback, for: response)
        CodeMindLogger.shared.log(.success, "Feedback recorded", category: .feedback, metadata: ["rating": "\(rating)"])
        
        // Save to shared cache so other users benefit from this learning
        CodeMindLogger.shared.log(.info, "Saving feedback to shared cache", category: .cache)
        await CodeMindSharedCacheManager.shared.saveToSharedCache()
        CodeMindLogger.shared.log(.success, "Feedback saved to shared cache", category: .cache)
    }
    
    /// Build a formatted email context string for CodeMind
    private func buildEmailContext(
        subject: String?,
        body: String?,
        from: String?,
        recipients: [String] = []
    ) -> String {
        var context = ""
        
        if let from = from {
            context += "From: \(from)\n"
        }
        
        if !recipients.isEmpty {
            context += "To: \(recipients.joined(separator: ", "))\n"
        }
        
        if let subject = subject, !subject.isEmpty {
            context += "Subject: \(subject)\n"
        }
        
        context += "\n"
        
        if let body = body, !body.isEmpty {
            // Clean up HTML if present (basic cleanup)
            let cleanedBody = body
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Limit body length to avoid token limits (keep first 2000 chars)
            let bodyPreview = cleanedBody.count > 2000 
                ? String(cleanedBody.prefix(2000)) + "\n... (truncated)"
                : cleanedBody
            
            context += "Body:\n\(bodyPreview)\n"
        } else {
            context += "Body: (empty)\n"
        }
        
        return context
    }
    
    /// Extract JSON from a response that may have extra text before/after
    /// This finds the first complete JSON object by matching braces properly
    private func extractJSONFromResponse(_ response: String) -> Range<String.Index>? {
        // Find the first opening brace
        guard let firstBrace = response.firstIndex(of: "{") else {
            return nil
        }
        
        // For very large responses, limit search to first 500KB to avoid performance issues
        let maxSearchLength = min(response.count, 500_000)
        let searchEndIndex = response.index(firstBrace, offsetBy: maxSearchLength, limitedBy: response.endIndex) ?? response.endIndex
        let searchRange = firstBrace..<searchEndIndex
        
        // Use bracket matching to find the closing brace for the first complete JSON object
        var braceCount = 0
        var currentIndex = firstBrace
        
        while currentIndex < searchEndIndex {
            let char = response[currentIndex]
            
            if char == "{" {
                braceCount += 1
            } else if char == "}" {
                braceCount -= 1
                if braceCount == 0 {
                    // Found the matching closing brace
                    let endIndex = response.index(after: currentIndex)
                    return firstBrace..<endIndex
                }
            }
            
            currentIndex = response.index(after: currentIndex)
        }
        
        // If we didn't find a complete JSON object, fall back to finding last brace in search range
        if let lastBrace = response[searchRange].lastIndex(of: "}"), firstBrace < lastBrace {
            let endIndex = response.index(after: lastBrace)
            return firstBrace..<endIndex
        }
        
        return nil
    }
}

// MARK: - Classification Results

/// Result of classifying an email as a new docket email
struct DocketEmailClassification: Codable {
    let isNewDocket: Bool
    let confidence: Double
    let docketNumber: String?
    let jobName: String?
    let reasoning: String
    let extractedMetadata: ExtractedMetadata?
    
    struct ExtractedMetadata: Codable {
        let agency: String?
        let client: String?
        let projectManager: String?
    }
}

/// Result of classifying an email as a file delivery email
struct FileDeliveryClassification: Codable {
    let isFileDelivery: Bool
    let confidence: Double
    let fileLinks: [String]
    let fileHostingServices: [String]
    let reasoning: String
    let hasAttachments: Bool
}

// MARK: - Errors

enum CodeMindError: LocalizedError {
    case notInitialized
    case notConfigured(String)
    case invalidResponse(String)
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "CodeMind is not initialized. Call initialize() first."
        case .notConfigured(let message):
            return "CodeMind not configured: \(message)"
        case .invalidResponse(let message):
            return "Invalid response from CodeMind: \(message)"
        case .apiError(let message):
            return "CodeMind API error: \(message)"
        }
    }
}

