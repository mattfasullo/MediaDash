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
                }
            }
            
            // If no key found, provide clear error message
            guard let key = finalApiKey else {
                let providerName = selectedProvider.capitalized
                let envVarName: String
                switch selectedProvider {
                case "grok":
                    envVarName = "GROK_API_KEY"
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
            default:
                let errorMsg = "Unsupported provider: \(selectedProvider). Supported providers: Gemini, Grok"
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
                codebasePath: nil,  // Don't include codebase context for email classification
                customSystemPrompt: """
                You are an email classification assistant for MediaDash.
                
                IMPORTANT: You must ONLY respond with valid JSON. Do NOT use any tools. Do NOT call any functions.
                
                Your task is to analyze emails and return a JSON classification:
                1. Identify "new docket" emails - emails announcing new docket/job for media production
                2. Identify "file delivery" emails - emails with file sharing links or attachments
                3. Extract docket numbers, job names, and other metadata
                4. Provide confidence scores (0.0 to 1.0)
                
                ALWAYS respond with ONLY the JSON object requested. No tool calls, no function calls, no additional text.
                Start your response with { and end with }. Nothing else.
                """
            )
            
            CodeMindLogger.shared.log(.info, "Creating CodeMind instance (without codebase context)", category: .initialization)
            
            // Try to create CodeMind instance - catch DecodingError specifically as it indicates API response issues
            do {
            // NOTE: Do NOT register tools for the classifier - it should only return JSON
            self.codeMind = try await CodeMind.create(config: config)
            CodeMindLogger.shared.log(.success, "CodeMind instance created (no tools registered for classifier)", category: .initialization)
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
    
    /// Process a prompt with automatic retry for rate limit errors
    /// - Parameters:
    ///   - prompt: The prompt to send
    ///   - maxRetries: Maximum number of retries (default: 1)
    /// - Returns: The CodeMind response
    private func processWithRetry(prompt: String, maxRetries: Int = 1) async throws -> CodeMindResponse {
        guard let codeMind = codeMind else {
            throw CodeMindError.notInitialized
        }
        
        var lastError: Error?
        
        for attempt in 0...maxRetries {
            do {
                return try await codeMind.process(prompt)
            } catch let error {
                lastError = error
                let errorString = "\(error)"
                let errorDesc = error.localizedDescription
                
                // Check if this is a rate limit error
                let isRateLimit = errorString.contains("429") ||
                                 errorDesc.contains("429") ||
                                 errorDesc.contains("RESOURCE_EXHAUSTED") ||
                                 errorDesc.contains("quota") ||
                                 errorDesc.contains("Quota") ||
                                 errorString.contains("rateLimited") ||
                                 errorDesc.contains("rate limit") ||
                                 errorDesc.contains("Rate limit")
                
                // Only retry for rate limit errors and if we have retries left
                if isRateLimit && attempt < maxRetries {
                    // Extract retry delay from error message
                    var retryDelay: TimeInterval = 35.0 // Default to 35 seconds
                    
                    if let regex = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)s", options: []),
                       let match = regex.firstMatch(in: errorDesc, range: NSRange(errorDesc.startIndex..., in: errorDesc)),
                       let secondsRange = Range(match.range(at: 1), in: errorDesc) {
                        let seconds = String(errorDesc[secondsRange])
                        if let secondsDouble = Double(seconds) {
                            retryDelay = secondsDouble
                            // Add a small buffer (2 seconds) to ensure quota resets
                            retryDelay += 2.0
                        }
                    }
                    
                    CodeMindLogger.shared.log(.warning, "⏳ Rate limit hit, waiting \(Int(retryDelay))s before retry", category: .llm, metadata: [
                        "attempt": "\(attempt + 1)/\(maxRetries + 1)",
                        "retryDelay": "\(retryDelay)"
                    ])
                    
                    // Wait for the retry delay
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    
                    // Retry
                    continue
                } else {
                    // Not a rate limit error, or no retries left - throw the error
                    throw error
                }
            }
        }
        
        // Should never reach here, but just in case
        if let error = lastError {
            throw error
        }
        throw CodeMindError.apiError("Unknown error during retry")
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
        from: String?,
        threadId: String? = nil,
        gmailService: GmailService? = nil
    ) async throws -> (classification: DocketEmailClassification, response: CodeMindResponse) {
        // Log at the VERY START to confirm function is called - use print for immediate visibility
        print("🚀 classifyNewDocketEmail START - Function called")
        CodeMindLogger.shared.log(.info, "🚀 classifyNewDocketEmail START", category: .classification)
        
        // Check custom rules first for overrides
        let rulesResult = CodeMindRulesManager.shared.getClassificationOverride(
            subject: subject,
            body: body,
            from: from
        )
        
        // If rules say to ignore this email, return a non-docket classification
        if rulesResult.shouldIgnore {
            CodeMindLogger.shared.log(.warning, "Email BLOCKED by custom rule (new docket check)", category: .classification, metadata: [
                "subject": subject ?? "nil",
                "from": from ?? "unknown",
                "action": "Email will not be processed"
            ])
            print("⚠️ EmailScanningService: Email BLOCKED by classification rule - Subject: \(subject ?? "nil"), From: \(from ?? "unknown")")
            let emptyResponse = CodeMindResponse(content: "{}", toolResults: [])
            let ignoredClassification = DocketEmailClassification(
                isNewDocket: false,
                confidence: 1.0,
                docketNumber: nil,
                jobName: nil,
                reasoning: "Ignored by custom classification rule",
                extractedMetadata: nil
            )
            return (ignoredClassification, emptyResponse)
        }
        
        // If rules explicitly classify as new docket, boost that classification
        let forceNewDocket = rulesResult.shouldClassifyAs == "newDocket"
        let confidenceModifier = rulesResult.confidenceModifier
        
        guard codeMind != nil else {
            print("❌ CodeMind not initialized")
            CodeMindLogger.shared.log(.error, "❌ CodeMind not initialized", category: .classification)
            throw CodeMindError.notInitialized
        }
        
        print("✅ CodeMind instance exists, proceeding with classification")
        
        // Report activity to overlay
        Task { @MainActor in
            CodeMindActivityManager.shared.startClassifying(subject: subject ?? "Unknown")
        }
        
        let emailContent = buildEmailContext(subject: subject, body: body, from: from)
        
        // Fetch thread context if available
        var threadContext = ""
        if let threadId = threadId, let gmailService = gmailService {
            if let context = await fetchThreadContext(threadId: threadId, gmailService: gmailService) {
                threadContext = context
            }
        }
        
        // Build learning context from feedback history
        let learningContext = buildLearningContext(
            currentSubject: subject,
            currentFrom: from,
            currentBody: body,
            classificationType: "newDocket"
        )
        
        CodeMindLogger.shared.log(.info, "Classifying new docket email", category: .classification, metadata: [
            "hasSubject": subject != nil,
            "hasBody": body != nil,
            "hasFrom": from != nil,
            "subjectPreview": subject?.prefix(50) ?? "nil",
            "bodyLength": body?.count ?? 0,
            "fromEmail": from ?? "nil",
            "hasThreadId": threadId != nil
        ])
        
        let prompt = """
        You must respond with ONLY valid JSON. Do not include any text, explanation, or content before or after the JSON object.
        
        Analyze this email to determine if it's a "new docket" email - an email that announces or creates a new docket/job for a media production project.
        
        \(learningContext)
        
        \(threadContext)
        
        Current email to classify:
        \(emailContent)
        
        CRITICAL THREAD-BASED REASONING:
        - Check thread context to understand if this is the FIRST message in a conversation (more likely new docket)
        - If this is a REPLY in a thread, it's likely NOT a new docket announcement
        - Company/internal emails (including @graysonmusicgroup.com) can be new docket announcements - do NOT filter them out
        
        Instructions:
        1. Determine if this email is announcing a new docket/job (not a reply, not a file delivery, not a status update)
           - Check thread context: Is this the first message or a reply?
           - First messages are more likely to be new docket announcements
           - Replies are typically follow-ups, not new announcements
        2. If it IS a new docket email, extract:
           - Docket number: MUST be exactly 5 digits (e.g., "25493"), optionally with "-US" suffix (e.g., "25493-US")
             Numbers with fewer or more than 5 digits are NOT valid docket numbers - return null for those
           - If multiple docket numbers are mentioned, include ALL of them separated by comma (e.g., "25493, 25495")
           - Job name/Client name (the project or client name)
           - Any other relevant metadata
        3. Respond with ONLY this JSON object, nothing else:
        {
          "isNewDocket": true/false,
          "confidence": 0.0-1.0,
          "docketNumber": "12345" or null,
          "jobName": "Client Name" or null,
          "reasoning": "Brief explanation - MUST mention thread analysis if thread context available",
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
            // Try with automatic retry for rate limit errors
            response = try await processWithRetry(prompt: prompt, maxRetries: 1)
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
            
            // Check for quota/rate limit errors first (429, RESOURCE_EXHAUSTED, quota exceeded)
            if errorString.contains("429") || 
               errorDesc.contains("429") ||
               errorDesc.contains("RESOURCE_EXHAUSTED") ||
               errorDesc.contains("quota") ||
               errorDesc.contains("Quota") ||
               errorString.contains("rateLimited") || 
               errorDesc.contains("rate limit") ||
               errorDesc.contains("Rate limit") {
                // Extract quota details if available
                var message = "API quota/rate limit exceeded."
                
                // Try to extract retry delay from error message (look for patterns like "33s" or "33.72s")
                if let regex = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)s", options: []),
                   let match = regex.firstMatch(in: errorDesc, range: NSRange(errorDesc.startIndex..., in: errorDesc)),
                   let secondsRange = Range(match.range(at: 1), in: errorDesc) {
                    let seconds = String(errorDesc[secondsRange])
                    if let secondsDouble = Double(seconds) {
                        let roundedSeconds = Int(secondsDouble.rounded())
                        message += " Please wait \(roundedSeconds) seconds and try again."
                    } else {
                        message += " Please wait a moment and try again."
                    }
                } else {
                    message += " Please wait a moment and try again."
                }
                
                // Add helpful context about free tier limits
                if errorDesc.contains("free_tier") || errorDesc.contains("FreeTier") {
                    message += "\n\nNote: You're using the free tier which has limited requests per minute. Consider upgrading your API plan for higher limits."
                }
                
                throw CodeMindError.apiError(message)
            }
            // Check for API errors (most common - invalid API key, service errors, etc.)
            else if errorString.contains("apiError") || errorDesc.contains("API error:") || errorDesc.contains("API key") {
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
        
        // Strip markdown code fences if present (e.g., ```json ... ```)
        let cleanedContent = stripMarkdownCodeFences(from: contentToParse)
        
        // Parse JSON response
        guard let jsonData = cleanedContent.data(using: .utf8) else {
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
            
            // Try to strip markdown code fences and extract JSON from response if it has extra text
            let cleanedResponse = stripMarkdownCodeFences(from: response.content)
            
            if let jsonRange = extractJSONFromResponse(cleanedResponse) {
                let jsonString = String(cleanedResponse[jsonRange])
                CodeMindLogger.shared.log(.debug, "Attempting to parse extracted JSON", category: .classification, metadata: [
                    "extractedJSONLength": "\(jsonString.count)",
                    "extractedJSONPreview": jsonString.count > 500 ? String(jsonString.prefix(500)) + "..." : jsonString
                ])
                if let extractedData = jsonString.data(using: .utf8),
                   let extracted = try? JSONDecoder().decode(DocketEmailClassification.self, from: extractedData) {
                    classification = extracted
                    CodeMindLogger.shared.log(.success, "Successfully parsed extracted JSON after stripping markdown", category: .classification)
                } else {
                    throw CodeMindError.invalidResponse("Response is not valid JSON. Error: \(decodingError.localizedDescription). Response preview: \(String(responsePreview.prefix(200)))")
                }
            } else {
                // Last resort: try parsing the cleaned response directly
                if let cleanedData = cleanedResponse.data(using: .utf8),
                   let extracted = try? JSONDecoder().decode(DocketEmailClassification.self, from: cleanedData) {
                    classification = extracted
                    CodeMindLogger.shared.log(.success, "Successfully parsed JSON after stripping markdown code fences", category: .classification)
                } else {
                    throw CodeMindError.invalidResponse("Response is not valid JSON. Error: \(decodingError.localizedDescription). Response preview: \(String(responsePreview.prefix(200)))")
                }
            }
        }
        
        // Apply custom rule modifiers to classification
        var finalClassification = classification
        
        // Apply confidence modifier from custom rules
        if confidenceModifier != 0 {
            let newConfidence = max(0, min(1.0, classification.confidence + confidenceModifier))
            finalClassification = DocketEmailClassification(
                isNewDocket: classification.isNewDocket,
                confidence: newConfidence,
                docketNumber: classification.docketNumber,
                jobName: classification.jobName,
                reasoning: classification.reasoning + (confidenceModifier > 0 ? " (boosted by custom rule)" : " (reduced by custom rule)"),
                extractedMetadata: classification.extractedMetadata
            )
            CodeMindLogger.shared.log(.info, "Applied custom rule confidence modifier", category: .classification, metadata: [
                "originalConfidence": String(format: "%.2f", classification.confidence),
                "modifier": String(format: "%.2f", confidenceModifier),
                "newConfidence": String(format: "%.2f", newConfidence)
            ])
        }
        
        // If custom rules force new docket classification
        if forceNewDocket && !finalClassification.isNewDocket {
            finalClassification = DocketEmailClassification(
                isNewDocket: true,
                confidence: max(finalClassification.confidence, 0.85),
                docketNumber: finalClassification.docketNumber,
                jobName: finalClassification.jobName,
                reasoning: "Classified as new docket by custom rule",
                extractedMetadata: finalClassification.extractedMetadata
            )
            CodeMindLogger.shared.log(.info, "Custom rule forced new docket classification", category: .classification)
        }
        
        CodeMindLogger.shared.log(.success, "Classification complete", category: .classification, metadata: [
            "isNewDocket": "\(finalClassification.isNewDocket)",
            "confidence": String(format: "%.2f", finalClassification.confidence),
            "hasDocketNumber": finalClassification.docketNumber != nil,
            "hasJobName": finalClassification.jobName != nil,
            "rulesApplied": confidenceModifier != 0 || forceNewDocket
        ])
        
        // Verify docket number if extracted and determine if it exists
        var wasVerified = false
        var verificationSource = ""
        if let docketNumber = finalClassification.docketNumber {
            // Report verification activity
            Task { @MainActor in
                CodeMindActivityManager.shared.startVerifying(docket: docketNumber)
            }
            
            // Check if docket exists in metadata/Asana/filesystem
            if let metadataManager = CodeMindServiceRegistry.shared.metadataManager {
                let matches = metadataManager.metadata.values.filter { $0.docketNumber == docketNumber }
                if !matches.isEmpty {
                    wasVerified = true
                    verificationSource = "metadata"
                }
            }
            if !wasVerified, let asanaCache = CodeMindServiceRegistry.shared.asanaCacheManager {
                let dockets = asanaCache.loadCachedDockets()
                if dockets.contains(where: { $0.number == docketNumber }) {
                    wasVerified = true
                    verificationSource = "Asana"
                }
            }
            
            // Report verification result
            let finalSource = verificationSource
            let finalVerified = wasVerified
            Task { @MainActor in
                CodeMindActivityManager.shared.finishVerifying(
                    docket: docketNumber,
                    source: finalSource,
                    found: finalVerified
                )
            }
        }
        
        // Report classification complete to overlay
        let classType = finalClassification.isNewDocket ? "New Docket" : "Not Docket"
        let finalWasVerified = wasVerified
        Task { @MainActor in
            CodeMindActivityManager.shared.finishClassifying(
                subject: subject ?? "Unknown",
                type: classType,
                confidence: finalClassification.confidence,
                verified: finalWasVerified
            )
        }
        
        // Record classification to history for learning and analysis
        // Generate a unique email ID from the content hash
        let emailId = "\(subject?.hashValue ?? 0)_\(from?.hashValue ?? 0)_\(Date().timeIntervalSince1970)"
        CodeMindClassificationHistory.shared.recordNewDocketClassification(
            emailId: emailId,
            threadId: threadId,
            subject: subject ?? "",
            fromEmail: from ?? "",
            confidence: finalClassification.confidence,
            docketNumber: finalClassification.docketNumber,
            jobName: finalClassification.jobName,
            wasVerified: wasVerified,
            rawResponse: response.content
        )
        
        // Feed to intelligence engines for unified tracking
        await feedToIntelligenceEngines(
            emailId: emailId,
            threadId: threadId,
            subject: subject,
            from: from,
            classificationType: finalClassification.isNewDocket ? "newDocket" : nil,
            docketNumber: finalClassification.docketNumber,
            jobName: finalClassification.jobName,
            metadata: finalClassification.extractedMetadata
        )
        
        // Log detailed classification debug information
        CodeMindLogger.shared.logDetailedClassification(
            emailId: emailId,
            subject: subject,
            from: from,
            threadId: threadId,
            classificationType: "newDocket",
            isFileDelivery: nil, // Not applicable for new docket
            confidence: finalClassification.confidence,
            reasoning: finalClassification.reasoning,
            threadContext: threadContext.isEmpty ? nil : threadContext,
            prompt: prompt,
            llmResponse: response.content,
            recipients: nil, // Not passed for new docket classification
            emailBody: body
        )
        
        return (finalClassification, response)
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
        recipients: [String] = [],
        threadId: String? = nil,
        gmailService: GmailService? = nil
    ) async throws -> (classification: FileDeliveryClassification, response: CodeMindResponse) {
        // Check custom rules first for overrides
        let rulesResult = CodeMindRulesManager.shared.getClassificationOverride(
            subject: subject,
            body: body,
            from: from
        )
        
        // If rules say to ignore this email, return a non-file-delivery classification
        if rulesResult.shouldIgnore {
            CodeMindLogger.shared.log(.warning, "Email BLOCKED by custom rule (file delivery check)", category: .classification, metadata: [
                "subject": subject ?? "nil",
                "from": from ?? "unknown",
                "action": "Email will not be processed"
            ])
            print("⚠️ EmailScanningService: Email BLOCKED by classification rule - Subject: \(subject ?? "nil"), From: \(from ?? "unknown")")
            let emptyResponse = CodeMindResponse(content: "{}", toolResults: [])
            let ignoredClassification = FileDeliveryClassification(
                isFileDelivery: false,
                confidence: 1.0,
                fileLinks: [],
                fileHostingServices: [],
                reasoning: "Ignored by custom classification rule",
                hasAttachments: false
            )
            return (ignoredClassification, emptyResponse)
        }
        
        // If rules explicitly classify as file delivery, boost that classification
        let forceFileDelivery = rulesResult.shouldClassifyAs == "fileDelivery"
        let confidenceModifier = rulesResult.confidenceModifier
        
        guard codeMind != nil else {
            throw CodeMindError.notInitialized
        }
        
        // Report activity to overlay
        Task { @MainActor in
            CodeMindActivityManager.shared.startClassifying(subject: subject ?? "Unknown")
        }
        
        let emailContent = buildEmailContext(subject: subject, body: body, from: from, recipients: recipients)
        
        // Fetch thread context if available
        var threadContext = ""
        if let threadId = threadId, let gmailService = gmailService {
            if let context = await fetchThreadContext(threadId: threadId, gmailService: gmailService) {
                threadContext = context
            }
        }
        
        // Build learning context from feedback history
        let learningContext = buildLearningContext(
            currentSubject: subject,
            currentFrom: from,
            currentBody: body,
            classificationType: "fileDelivery"
        )
        
        CodeMindLogger.shared.log(.info, "Classifying file delivery email", category: .classification, metadata: [
            "hasSubject": subject != nil,
            "hasBody": body != nil,
            "hasFrom": from != nil,
            "recipientCount": "\(recipients.count)",
            "subjectPreview": subject?.prefix(50) ?? "nil",
            "bodyLength": body?.count ?? 0,
            "fromEmail": from ?? "nil",
            "hasThreadId": threadId != nil
        ])
        
        // Build prompt with thread-first approach
        let hasThreadContext = !threadContext.isEmpty
        let prompt: String
        
        if hasThreadContext {
            prompt = """
            YOUR PRIMARY TASK: Read through the ENTIRE email thread below and determine if the CURRENT email (the last one) is a file delivery that the media team should process.
            
            ============================================================================
            READ THE FULL EMAIL THREAD FIRST - This is the PRIMARY source of information
            ============================================================================
            
            \(threadContext)
            
            ============================================================================
            CURRENT EMAIL TO CLASSIFY (the last message in the thread above):
            ============================================================================
            
            \(emailContent)
            
            ============================================================================
            LEARNING FROM PAST CORRECTIONS:
            ============================================================================
            
            \(learningContext)
            
            ============================================================================
            YOUR ANALYSIS - READ THROUGH THE THREAD AND REASON:
            ============================================================================
            
            STEP 1: UNDERSTAND THE THREAD CONTEXT
            - Read through ALL messages in the thread chronologically
            - Who started this conversation? (first message sender)
            - What is the overall purpose of this thread?
            - Who are the participants? (internal team vs external clients)
            - Trace the conversation flow from start to finish
            
            STEP 2: ANALYZE THE CONVERSATION DIRECTION
            - Is this thread primarily:
              * An incoming conversation FROM external clients/producers TO your company?
              * An outgoing conversation FROM your company TO external clients?
              * An internal conversation between company employees?
            
            STEP 3: UNDERSTAND THE CURRENT EMAIL IN CONTEXT
            - Where does the current email fit in the conversation?
            - Is it part of an ongoing thread about file delivery?
            - Does the thread context indicate files are being delivered TO your company?
            - Or are files being sent FROM your company TO clients?
            
            STEP 4: KEY DISTINCTIONS TO CONSIDER
            - External sender in thread → Likely INCOMING file delivery
            - Company sending to external recipients in thread → OUTGOING (NOT file delivery)
            - Company internal conversation → Could be INTERNAL REQUEST (IS file delivery)
            - Note: Media team being CC'd doesn't change outgoing status if external clients are in the thread
            
            STEP 5: MAKE YOUR DECISION
            Based on your analysis of the FULL THREAD:
            - Is the current email part of a conversation where files are being DELIVERED TO your company?
            - Or is it part of a conversation where your company is SENDING files OUT?
            - Consider the entire thread context, not just the current email in isolation
            
            DECISION CRITERIA:
            - Files being delivered TO your company (incoming) → isFileDelivery=true
            - Files being sent FROM your company TO clients (outgoing) → isFileDelivery=false
            - Internal company requests for media processing → isFileDelivery=true
            
            CONFIDENCE GUIDELINES:
            - Strong thread context clearly showing direction → confidence 0.85-0.95
            - Thread shows some ambiguity → confidence 0.6-0.8
            - Contradictory signals in thread → confidence 0.4-0.6
            
            IMPORTANT: Base your decision on understanding the FULL THREAD. Don't just look at the current email - understand the entire conversation flow and context.
            
            INSTRUCTIONS:
            1. Read through the ENTIRE thread above to understand the conversation
            2. Determine if the current email is part of a file delivery TO your company
            3. Extract file links if this is a file delivery
            4. Respond with ONLY valid JSON:
            {
              "isFileDelivery": true/false,
              "confidence": 0.0-1.0,
              "fileLinks": ["https://...", "https://..."],
              "fileHostingServices": ["Dropbox", "WeTransfer"],
              "reasoning": "MUST include: 1) Your analysis of the FULL thread, 2) Conversation direction, 3) Why this is/isn't file delivery based on thread context, 4) Confidence reasoning",
              "hasAttachments": true/false
            }
            
            Only respond with valid JSON, no additional text.
            """
        } else {
            // Fallback for emails without thread context
            prompt = """
            Analyze this email to determine if it's a file delivery email - an email that contains files that need to be processed by the media team.
            
            \(learningContext)
            
            Current email to classify:
            \(emailContent)
            
            (No thread context available - analyzing single email)
            
            File deliveries can be:
            - FROM external clients/producers TO your company (incoming)
            - FROM company producers TO media team only (internal request)
            - NOT: FROM company TO external clients (outgoing, even if media is CC'd)
            
            REASONING STEPS:
            1. CHECK SENDER: External → isFileDelivery=true, Company → Continue
            2. CHECK RECIPIENTS: If ANY external recipients → isFileDelivery=false (outgoing)
            3. If ALL internal recipients → isFileDelivery=true (internal request)
            
            INSTRUCTIONS:
            1. Determine if this email is delivering files FROM external party TO your company (not outgoing, not a new docket, not a status update)
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
        }
        
        CodeMindLogger.shared.log(.debug, "Sending prompt to LLM", category: .llm, metadata: ["promptLength": "\(prompt.count)"])
        let response = try await processWithRetry(prompt: prompt, maxRetries: 1)
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
        
        // Strip markdown code fences if present (e.g., ```json ... ```)
        let cleanedContent = stripMarkdownCodeFences(from: contentToParse)
        
        // Parse JSON response
        guard let jsonData = cleanedContent.data(using: .utf8) else {
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
            
            // Try to strip markdown code fences and extract JSON from response if it has extra text
            let cleanedResponse = stripMarkdownCodeFences(from: response.content)
            
            if let jsonRange = extractJSONFromResponse(cleanedResponse) {
                let jsonString = String(cleanedResponse[jsonRange])
                CodeMindLogger.shared.log(.debug, "Attempting to parse extracted JSON", category: .classification, metadata: [
                    "extractedJSONLength": "\(jsonString.count)",
                    "extractedJSONPreview": jsonString.count > 500 ? String(jsonString.prefix(500)) + "..." : jsonString
                ])
                if let extractedData = jsonString.data(using: .utf8),
                   let extracted = try? JSONDecoder().decode(FileDeliveryClassification.self, from: extractedData) {
                    classification = extracted
                    CodeMindLogger.shared.log(.success, "Successfully parsed extracted JSON after stripping markdown", category: .classification)
                } else {
                    throw CodeMindError.invalidResponse("Response is not valid JSON. Error: \(decodingError.localizedDescription). Response preview: \(String(responsePreview.prefix(200)))")
                }
            } else {
                // Last resort: try parsing the cleaned response directly
                if let cleanedData = cleanedResponse.data(using: .utf8),
                   let extracted = try? JSONDecoder().decode(FileDeliveryClassification.self, from: cleanedData) {
                    classification = extracted
                    CodeMindLogger.shared.log(.success, "Successfully parsed JSON after stripping markdown code fences", category: .classification)
                } else {
                    throw CodeMindError.invalidResponse("Response is not valid JSON. Error: \(decodingError.localizedDescription). Response preview: \(String(responsePreview.prefix(200)))")
                }
            }
        }
        
        // Apply custom rule modifiers to classification
        var finalClassification = classification
        
        // Apply confidence modifier from custom rules
        if confidenceModifier != 0 {
            let newConfidence = max(0, min(1.0, classification.confidence + confidenceModifier))
            finalClassification = FileDeliveryClassification(
                isFileDelivery: classification.isFileDelivery,
                confidence: newConfidence,
                fileLinks: classification.fileLinks,
                fileHostingServices: classification.fileHostingServices,
                reasoning: classification.reasoning + (confidenceModifier > 0 ? " (boosted by custom rule)" : " (reduced by custom rule)"),
                hasAttachments: classification.hasAttachments
            )
            CodeMindLogger.shared.log(.info, "Applied custom rule confidence modifier to file delivery", category: .classification, metadata: [
                "originalConfidence": String(format: "%.2f", classification.confidence),
                "modifier": String(format: "%.2f", confidenceModifier),
                "newConfidence": String(format: "%.2f", newConfidence)
            ])
        }
        
        // If custom rules force file delivery classification
        if forceFileDelivery && !finalClassification.isFileDelivery {
            finalClassification = FileDeliveryClassification(
                isFileDelivery: true,
                confidence: max(finalClassification.confidence, 0.85),
                fileLinks: finalClassification.fileLinks,
                fileHostingServices: finalClassification.fileHostingServices,
                reasoning: "Classified as file delivery by custom rule",
                hasAttachments: finalClassification.hasAttachments
            )
            CodeMindLogger.shared.log(.info, "Custom rule forced file delivery classification", category: .classification)
        }
        
        CodeMindLogger.shared.log(.success, "File delivery classification complete", category: .classification, metadata: [
            "isFileDelivery": "\(finalClassification.isFileDelivery)",
            "confidence": String(format: "%.2f", finalClassification.confidence),
            "fileLinksCount": "\(finalClassification.fileLinks.count)",
            "services": finalClassification.fileHostingServices.joined(separator: ", "),
            "rulesApplied": confidenceModifier != 0 || forceFileDelivery
        ])
        
        // Report classification complete to overlay
        let classType = finalClassification.isFileDelivery ? "File Delivery" : "Not File"
        let subjectForOverlay = subject ?? "Unknown"
        let confidenceForOverlay = finalClassification.confidence
        Task { @MainActor in
            CodeMindActivityManager.shared.finishClassifying(
                subject: subjectForOverlay,
                type: classType,
                confidence: confidenceForOverlay,
                verified: false
            )
        }
        
        // Record file delivery classification to history
        let emailId = "\(subject?.hashValue ?? 0)_\(from?.hashValue ?? 0)_\(Date().timeIntervalSince1970)"
        CodeMindClassificationHistory.shared.recordFileDeliveryClassification(
            emailId: emailId,
            threadId: threadId,
            subject: subject ?? "",
            fromEmail: from ?? "",
            confidence: finalClassification.confidence,
            isFileDelivery: finalClassification.isFileDelivery,
            fileLinks: finalClassification.fileLinks,
            rawResponse: response.content
        )
        
        // Feed to intelligence engines for unified tracking
        await feedToIntelligenceEngines(
            emailId: emailId,
            threadId: threadId,
            subject: subject,
            from: from,
            classificationType: finalClassification.isFileDelivery ? "fileDelivery" : nil,
            docketNumber: nil,
            jobName: nil,
            metadata: nil
        )
        
        // Log detailed classification debug information
        CodeMindLogger.shared.logDetailedClassification(
            emailId: emailId,
            subject: subject,
            from: from,
            threadId: threadId,
            classificationType: "fileDelivery",
            isFileDelivery: finalClassification.isFileDelivery,
            confidence: finalClassification.confidence,
            reasoning: finalClassification.reasoning,
            threadContext: threadContext.isEmpty ? nil : threadContext,
            prompt: prompt,
            llmResponse: response.content,
            recipients: recipients.isEmpty ? nil : recipients,
            emailBody: body
        )
        
        return (finalClassification, response)
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
    
    /// Strip markdown code fences from a response (e.g., ```json ... ```)
    /// - Parameter response: The response string that may contain markdown code fences
    /// - Returns: The response with markdown code fences removed
    private func stripMarkdownCodeFences(from response: String) -> String {
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove markdown code fence at the start (```json, ```JSON, ```, etc.)
        if cleaned.hasPrefix("```") {
            // Find the first newline after ```
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            } else {
                // No newline, just remove the ```
                cleaned = cleaned.replacingOccurrences(of: "^```[a-zA-Z]*", with: "", options: .regularExpression)
            }
        }
        
        // Remove markdown code fence at the end (```)
        if cleaned.hasSuffix("```") {
            // Find the last newline before ```
            if let lastNewline = cleaned.lastIndex(of: "\n") {
                cleaned = String(cleaned[..<lastNewline])
            } else {
                // No newline, just remove the ```
                cleaned = cleaned.replacingOccurrences(of: "```$", with: "", options: .regularExpression)
            }
        }
        
        // Also handle cases where ``` might be on its own line
        cleaned = cleaned.replacingOccurrences(of: "^```[a-zA-Z]*\n", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\n```$", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "```$", with: "", options: .regularExpression)
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
    
    // MARK: - Thread Context & Learning
    
    /// Fetch and format thread context for classification
    private func fetchThreadContext(threadId: String, gmailService: GmailService) async -> String? {
        do {
            let thread = try await gmailService.getThread(threadId: threadId)
            
            guard let messages = thread.messages, messages.count > 1 else {
                return nil // Single message, no thread
            }
            
            // Sort chronologically
            let sortedMessages = messages.sorted { msg1, msg2 in
                let date1 = msg1.date ?? Date.distantPast
                let date2 = msg2.date ?? Date.distantPast
                return date1 < date2
            }
            
            var context = "\n"
            context += String(repeating: "=", count: 80) + "\n"
            context += "EMAIL THREAD CONTEXT - READ THROUGH ALL \(sortedMessages.count) MESSAGES BELOW\n"
            context += String(repeating: "=", count: 80) + "\n"
            context += "This thread contains \(sortedMessages.count) messages. Read them in chronological order to understand the full conversation.\n\n"
            
            // Determine company domains (could come from settings)
            let companyDomains = ["graysonmusicgroup.com", "graysonmusic.com"]
            
            var threadDirection = "Unknown"
            
            // Get media team emails from settings (will need to be passed or accessed differently)
            // For now, use common patterns - these should ideally come from settings
            let mediaTeamEmailPatterns = ["media@", "mediadash", "@graysonmusicgroup.com", "@graysonmusic.com"]
            
            // Track conversation flow
            var allParticipants: Set<String> = []
            var externalParticipants: Set<String> = []
            var internalParticipants: Set<String> = []
            
            for (index, message) in sortedMessages.enumerated() {
                let from = message.from ?? "Unknown"
                let fromDomain = from.split(separator: "@").last.map(String.init) ?? ""
                let isCompany = companyDomains.contains(where: { fromDomain.lowercased().contains($0.lowercased()) })
                
                // Check recipients
                let recipients = message.allRecipients
                let recipientDomains = recipients.map { $0.split(separator: "@").last.map(String.init) ?? "" }
                let hasCompanyRecipients = recipientDomains.contains(where: { domain in
                    companyDomains.contains(where: { domain.lowercased().contains($0.lowercased()) })
                })
                
                // Check if there are ANY external recipients (not company domain)
                let hasExternalRecipients = !recipients.isEmpty && !recipientDomains.allSatisfy { domain in
                    companyDomains.contains(where: { domain.lowercased().contains($0.lowercased()) }) ||
                    mediaTeamEmailPatterns.contains(where: { domain.lowercased().contains($0.lowercased()) })
                }
                
                // Determine recipient type
                var recipientType = ""
                if isCompany && hasExternalRecipients {
                    recipientType = " [OUTGOING - TO EXTERNAL CLIENTS]"
                } else if isCompany && !hasExternalRecipients && hasCompanyRecipients {
                    recipientType = " [INTERNAL - TO COMPANY/MEDIA TEAM ONLY]"
                } else if !isCompany {
                    recipientType = " [INCOMING - FROM EXTERNAL]"
                }
                
                if index == 0 {
                    if isCompany && hasExternalRecipients {
                        threadDirection = "OUTGOING (company → external clients)"
                    } else if isCompany && !hasExternalRecipients {
                        threadDirection = "INTERNAL (company → company/media team)"
                    } else {
                        threadDirection = "INCOMING (external → company)"
                    }
                }
                
                let subject = message.subject ?? "No subject"
                let dateStr: String
                if let date = message.date {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .short
                    dateStr = formatter.string(from: date)
                } else {
                    dateStr = "Unknown date"
                }
                let snippet = message.snippet?.prefix(150) ?? ""
                
                // Track participants
                allParticipants.insert(from.lowercased())
                recipients.forEach { allParticipants.insert($0.lowercased()) }
                if isCompany {
                    internalParticipants.insert(from.lowercased())
                } else {
                    externalParticipants.insert(from.lowercased())
                }
                
                context += "\n"
                context += String(repeating: "-", count: 80) + "\n"
                context += "MESSAGE \(index + 1) of \(sortedMessages.count) - \(dateStr)\n"
                context += String(repeating: "-", count: 80) + "\n"
                context += "FROM: \(from)\(isCompany ? " [YOUR COMPANY]" : " [EXTERNAL]")\n"
                if !recipients.isEmpty {
                    context += "TO: \(recipients.joined(separator: ", "))\(recipientType)\n"
                }
                context += "SUBJECT: \(subject)\n"
                if index > 0 {
                    let prevMessage = sortedMessages[index - 1]
                    context += "→ This is a REPLY to message \(index) \"\(prevMessage.subject ?? "previous message")\"\n"
                } else {
                    context += "→ This is the FIRST message in the thread\n"
                }
                context += "\nCONTENT PREVIEW:\n\(snippet)\n"
                
                // Get body content if available for more context
                if let body = message.plainTextBody, !body.isEmpty {
                    let bodyPreview = body.count > 300 ? String(body.prefix(300)) + "..." : body
                    context += "\nFULL MESSAGE CONTENT:\n\(bodyPreview)\n"
                }
            }
            
            context += "\n"
            context += String(repeating: "=", count: 80) + "\n"
            context += "THREAD ANALYSIS SUMMARY\n"
            context += String(repeating: "=", count: 80) + "\n"
            context += "Total messages: \(sortedMessages.count)\n"
            context += "Conversation type: \(threadDirection)\n"
            context += "\nParticipants in this thread:\n"
            context += "- Internal (company): \(internalParticipants.count) participant(s)\n"
            context += "- External: \(externalParticipants.count) participant(s)\n"
            if !externalParticipants.isEmpty {
                context += "- External participants: \(Array(externalParticipants).joined(separator: ", "))\n"
            }
            
            // Analyze first message recipients for better context
            if let firstMessage = sortedMessages.first {
                let firstFrom = firstMessage.from ?? "Unknown"
                let firstFromDomain = firstFrom.split(separator: "@").last.map(String.init) ?? ""
                let firstIsCompany = companyDomains.contains(where: { firstFromDomain.lowercased().contains($0.lowercased()) })
                let firstRecipients = firstMessage.allRecipients
                let firstRecipientDomains = firstRecipients.map { $0.split(separator: "@").last.map(String.init) ?? "" }
                
                // Check if ANY recipients are external (not company domain)
                let hasExternalRecipients = !firstRecipients.isEmpty && !firstRecipientDomains.allSatisfy { domain in
                    companyDomains.contains(where: { domain.lowercased().contains($0.lowercased()) }) ||
                    mediaTeamEmailPatterns.contains(where: { domain.lowercased().contains($0.lowercased()) })
                }
                
                context += "\nFIRST MESSAGE ANALYSIS:\n"
                if !firstIsCompany {
                    context += "✓ External sender started this conversation → This thread is INCOMING\n"
                    context += "✓ Files in this thread ARE file deliveries TO your company\n"
                    context += "  (Media team being CC'd doesn't change that this is incoming from external)\n"
                } else if firstIsCompany && hasExternalRecipients {
                    context += "⚠️ Company started this conversation TO external clients → This thread is OUTGOING\n"
                    context += "⚠️ Files in this thread are being SENT TO clients, NOT file deliveries TO process\n"
                    context += "  (Even if media team is CC'd, this is outgoing to clients - not file delivery)\n"
                } else if firstIsCompany && !hasExternalRecipients {
                    context += "✓ Company started this conversation internally → This thread is INTERNAL REQUEST\n"
                    context += "✓ Files in this thread ARE file deliveries that media team should process\n"
                }
            }
            
            context += "\n"
            context += String(repeating: "=", count: 80) + "\n"
            context += "END OF THREAD CONTEXT - Now analyze the conversation above\n"
            context += String(repeating: "=", count: 80) + "\n\n"
            
            return context
        } catch {
            CodeMindLogger.shared.log(.warning, "Failed to fetch thread context", category: .classification, metadata: [
                "threadId": threadId,
                "error": error.localizedDescription
            ])
            return nil
        }
    }
    
    /// Build comprehensive learning context from feedback history and similar emails
    private func buildLearningContext(
        currentSubject: String?,
        currentFrom: String?,
        currentBody: String?,
        classificationType: String // "newDocket" or "fileDelivery"
    ) -> String {
        let history = CodeMindClassificationHistory.shared
        
        var context = "\n\n=== LEARNING CONTEXT (Learn from these examples) ===\n"
        
        // 1. Find similar emails from history
        let similarEmails = history.getSimilarClassifications(
            subject: currentSubject,
            fromEmail: currentFrom,
            limit: 5
        )
        
        if !similarEmails.isEmpty {
            context += "\n📚 SIMILAR EMAILS FROM HISTORY:\n"
            for record in similarEmails {
                if let feedback = record.feedback, !feedback.wasCorrect, let correction = feedback.correction {
                    context += "\n❌ MISTAKE EXAMPLE:\n"
                    context += "  Email: \"\(record.subject)\" from \(record.fromEmail)\n"
                    context += "  Original: Classified as \(record.classificationType.rawValue) with \(Int(record.confidence * 100))% confidence\n"
                    context += "  User correction: \"\(correction)\"\n"
                    context += "  Lesson: \(extractLessonFromCorrection(correction, type: classificationType))\n"
                }
            }
        }
        
        // 2. Recent corrections specifically about company-sent emails
        let recentCorrections = history.getRecentClassifications(limit: 20)
            .filter { record in
                record.feedback?.wasCorrect == false &&
                record.feedback?.correction != nil &&
                !record.feedback!.correction!.isEmpty
            }
            .prefix(10)
        
        let companySentCorrections = recentCorrections.filter { record in
            let correction = record.feedback?.correction?.lowercased() ?? ""
            return correction.contains("company") ||
                   correction.contains("we sent") ||
                   correction.contains("sent to clients") ||
                   correction.contains("outgoing") ||
                   correction.contains("client")
        }
        
        if !companySentCorrections.isEmpty {
            context += "\n\n⚠️ CRITICAL LESSONS ABOUT COMPANY-SENT EMAILS:\n"
            context += "The user has repeatedly corrected these classifications:\n\n"
            
            for record in companySentCorrections.prefix(5) {
                if let correction = record.feedback?.correction {
                    context += "❌ MISTAKE: Email \"\(record.subject)\"\n"
                    context += "   From: \(record.fromEmail)\n"
                    context += "   User said: \"\(correction)\"\n"
                    context += "   Pattern to avoid: \(extractPatternFromRecord(record))\n\n"
                }
            }
            
            context += "CRITICAL RULE - EMAIL DIRECTION DISTINCTION:\n"
            context += "  - External sender = INCOMING (IS file delivery)\n"
            context += "  - Company sender + ANY external recipients = OUTGOING (NOT file delivery)\n"
            context += "  - Company sender + ONLY internal recipients = INTERNAL REQUEST (IS file delivery)\n"
            context += "  - KEY: Check if ANY recipients are external - media team being CC'd doesn't change outgoing status!\n"
        }
        
        // 3. Pattern extraction from successful classifications
        let successfulClassifications = history.getRecentClassifications(limit: 30)
            .filter { record in
                (record.feedback?.wasCorrect == true || record.feedback == nil) &&
                record.confidence > 0.8
            }
            .prefix(5)
        
        if !successfulClassifications.isEmpty {
            context += "\n\n✅ SUCCESSFUL PATTERNS:\n"
            for record in successfulClassifications {
                context += "- \"\(record.subject)\" from \(record.fromEmail.split(separator: "@").last ?? "unknown")\n"
                context += "  → Correctly classified as \(record.classificationType.rawValue) (\(Int(record.confidence * 100))%)\n"
            }
        }
        
        context += "\n=== END LEARNING CONTEXT ===\n\n"
        
        return context
    }
    
    /// Extract a lesson from a correction
    private func extractLessonFromCorrection(_ correction: String, type: String) -> String {
        let lower = correction.lowercased()
        
        if lower.contains("company") || lower.contains("we sent") || lower.contains("sent to clients") {
            return "This was sent FROM the company TO clients (outgoing), not incoming file delivery. Check sender domain."
        }
        
        if lower.contains("client") && !lower.contains("from") {
            return "This appears to be communication TO clients, not FROM clients. Verify email direction."
        }
        
        if lower.contains("not a") || lower.contains("isn't") || lower.contains("wrong") {
            return "User explicitly says this is NOT \(type). Look for distinguishing context."
        }
        
        return correction
    }
    
    /// Extract pattern from a classification record for learning
    private func extractPatternFromRecord(_ record: ClassificationRecord) -> String {
        var patterns: [String] = []
        
        // Sender domain pattern
        if let domain = record.fromEmail.split(separator: "@").last.map(String.init) {
            patterns.append("sender domain: \(domain)")
        }
        
        // Subject keywords
        let subjectWords = record.subject.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 4 }
        
        if let firstKeyword = subjectWords.first {
            patterns.append("subject keyword: \(firstKeyword)")
        }
        
        return patterns.joined(separator: ", ")
    }
    
    /// Check if email domain matches company domain
    private func isCompanyEmailDomain(_ domain: String) -> Bool {
        let companyDomains = ["graysonmusicgroup.com", "graysonmusic.com"]
        return companyDomains.contains(domain.lowercased())
    }
    
    // MARK: - Intelligence Engine Integration
    
    /// Feed classification data to intelligence engines for unified tracking
    private func feedToIntelligenceEngines(
        emailId: String,
        threadId: String?,
        subject: String?,
        from: String?,
        classificationType: String?,
        docketNumber: String?,
        jobName: String?,
        metadata: DocketEmailClassification.ExtractedMetadata?
    ) async {
        // Track email in context engine
        CodeMindContextEngine.shared.trackEmail(
            emailId: emailId,
            threadId: threadId,
            subject: subject ?? "",
            from: from ?? "",
            date: Date(),
            snippet: nil,
            classificationResult: classificationType,
            docketNumber: docketNumber
        )
        
        // If we have a docket, update lifecycle and add metadata
        if let docket = docketNumber {
            // Update docket lifecycle
            let trigger = classificationType == "newDocket" ? "new_docket_email" : 
                         (classificationType == "fileDelivery" ? "file_delivery" : "email_received")
            CodeMindContextEngine.shared.updateDocketLifecycle(
                docketNumber: docket,
                jobName: jobName,
                trigger: trigger,
                emailId: emailId
            )
            
            // Add metadata from email
            CodeMindMetadataIntelligence.shared.addEmailMetadata(
                docketNumber: docket,
                jobName: jobName,
                client: metadata?.client,
                agency: metadata?.agency,
                producer: metadata?.projectManager,
                extractedFrom: subject ?? ""
            )
        }
        
        // Run data fusion in background (debounced by the provider)
        Task {
            await CodeMindDataFusion.shared.runFusion()
        }
        
        CodeMindLogger.shared.log(.debug, "Fed classification to intelligence engines", category: .general, metadata: [
            "emailId": emailId,
            "type": classificationType ?? "unknown",
            "docket": docketNumber ?? "none"
        ])
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

