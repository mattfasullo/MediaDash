import SwiftUI
import CodeMind

struct CodeMindChatView: View {
    @StateObject private var logger = CodeMindLogger.shared
    @State private var messages: [ChatMessage] = []
    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var codeMind: CodeMind?
    @State private var isInitialized = false
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("Chat with CodeMind")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("Ask questions, get help with email classification, or teach CodeMind new patterns.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        } else {
                            ForEach(messages) { message in
                                ChatMessageView(message: message)
                                    .id(message.id)
                            }
                        }
                        
                        if isProcessing {
                            HStack(alignment: .top, spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("CodeMind is thinking...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .id("processing")
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: messages.count) {
                        if let lastMessage = messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: isProcessing) {
                        if isProcessing {
                            withAnimation {
                                proxy.scrollTo("processing", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            
            Divider()
            
            // Input area
            HStack(spacing: 8) {
                TextField("Ask CodeMind a question...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .disabled(isProcessing || !isInitialized)
                    .onSubmit {
                        if !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sendMessage()
                        }
                    }
                
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(canSend ? .blue : .gray)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding()
            .background(Color(nsColor: .separatorColor).opacity(0.1))
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            initializeCodeMind()
        }
    }
    
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isProcessing &&
        isInitialized
    }
    
    private func initializeCodeMind() {
        guard !isInitialized else { return }
        
        Task {
            do {
                // Get provider from settings or default to Gemini
                let providerName = UserDefaults.standard.string(forKey: "codemind_provider") ?? CodeMindConfig.getDefaultProvider()
                
                // Ensure provider is supported
                let selectedProvider = CodeMindConfig.supportedProviders.contains(providerName.lowercased()) 
                    ? providerName.lowercased() 
                    : CodeMindConfig.getDefaultProvider()
                
                // Get API key for selected provider
                let apiKey = CodeMindConfig.getAPIKey(for: selectedProvider) ??
                             KeychainService.retrieve(key: selectedProvider == "grok" ? "codemind_grok_api_key" : "codemind_gemini_api_key") ??
                             (selectedProvider == "gemini" ? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] : nil) ??
                             (selectedProvider == "grok" ? ProcessInfo.processInfo.environment["GROK_API_KEY"] : nil)
                
                guard let key = apiKey else {
                    let providerDisplayName = selectedProvider.capitalized
                    await MainActor.run {
                        messages.append(ChatMessage(
                            role: .system,
                            content: "❌ CodeMind is not configured. Please add a \(providerDisplayName) API key in Settings > CodeMind AI.",
                            timestamp: Date()
                        ))
                    }
                    return
                }
                
                // Convert provider string to CloudProvider enum
                let provider: CloudProvider
                switch selectedProvider.lowercased() {
                case "gemini":
                    provider = .gemini
                case "grok":
                    provider = .grok
                default:
                    await MainActor.run {
                        messages.append(ChatMessage(
                            role: .system,
                            content: "❌ Unsupported provider: \(selectedProvider). Please select a supported provider in Settings.",
                            timestamp: Date()
                        ))
                    }
                    return
                }
                
                let projectPath = "/Users/mattfasullo/Projects/MediaDash"
                
                // Use a separate storage path for chat to avoid conflicts with email classifier
                // This prevents issues if the main CodeMind instance has corrupted data
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let chatStorageBase = appSupport.appendingPathComponent("CodeMindChat", isDirectory: true).path
                let chatKnowledgePath = (chatStorageBase as NSString).appendingPathComponent("knowledge")
                let chatLearningPath = (chatStorageBase as NSString).appendingPathComponent("learning")
                
                CodeMindLogger.shared.log(.info, "Initializing CodeMind for chat with isolated storage", category: .general)
                
                let config = Configuration(
                    llmMode: .cloud(provider),
                    apiKey: key,
                    codebasePath: projectPath,
                    knowledgeStoragePath: chatKnowledgePath,
                    learningStoragePath: chatLearningPath
                )
                
                CodeMindLogger.shared.log(.info, "Creating CodeMind instance for chat", category: .general)
                let codeMindInstance = try await CodeMind.create(config: config)
                
                await MainActor.run {
                    self.codeMind = codeMindInstance
                    self.isInitialized = true
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: "👋 Hello! I'm CodeMind, your AI assistant for email classification. I can help you understand how I classify emails, answer questions about the codebase, and learn from your feedback. What would you like to know?",
                        timestamp: Date()
                    ))
                }
                
                CodeMindLogger.shared.log(.success, "CodeMind initialized for chat", category: .general)
            } catch {
                let errorMessage: String
                var recoveryTip = ""
                
                // Check for specific error types
                if let decodingError = error as? DecodingError {
                    errorMessage = "Data format error: \(decodingError.localizedDescription)"
                    recoveryTip = "\n\n💡 This might be due to corrupted learning data. You can fix this by:\n1. Closing this window\n2. Deleting ~/Library/Application Support/CodeMind/patterns.json and feedback.json\n3. Reopening the chat window"
                } else if error.localizedDescription.contains("couldn't be read") || error.localizedDescription.contains("correct format") {
                    errorMessage = error.localizedDescription
                    recoveryTip = "\n\n💡 This usually means corrupted data. The chat uses isolated storage, but if this persists, try:\n1. Closing this window\n2. Deleting ~/Library/Application Support/CodeMindChat/\n3. Reopening the chat"
                } else {
                    errorMessage = error.localizedDescription
                }
                
                await MainActor.run {
                    messages.append(ChatMessage(
                        role: .system,
                        content: "❌ Failed to initialize CodeMind: \(errorMessage)\(recoveryTip)",
                        timestamp: Date()
                    ))
                }
                CodeMindLogger.shared.log(.error, "Failed to initialize CodeMind for chat", category: .general, metadata: [
                    "error": errorMessage,
                    "errorType": String(describing: type(of: error)),
                    "fullError": "\(error)"
                ])
            }
        }
    }
    
    private func handleProcessingError(_ error: Error, userMessage: String) {
        let errorString = "\(error)"
        var userFriendlyMessage = "❌ Failed to process your message: \(error.localizedDescription)"
        
        // Get provider from settings to customize error messages
        let providerName = UserDefaults.standard.string(forKey: "codemind_provider") ?? CodeMindConfig.getDefaultProvider()
        let providerDisplayName = providerName == "grok" ? "Grok" : "Gemini"
        let apiKeyURL = providerName == "grok" ? "https://console.x.ai/" : "https://aistudio.google.com/apikey"
        
        // Check for common API errors and provide helpful guidance
        if errorString.contains("insufficient_quota") || errorString.contains("quota") {
            if providerName == "grok" {
                userFriendlyMessage = """
                ❌ Grok API Quota Exceeded
                
                Your Grok API key has exceeded its usage quota. Here are your options:
                
                1. **Check your xAI billing**: Visit \(apiKeyURL)
                2. **Add credits**: Ensure you have sufficient credits in your xAI account
                3. **Check usage limits**: Review your API usage at the xAI console
                """
            } else {
                userFriendlyMessage = """
                ❌ Gemini API Quota Exceeded
                
                Your Gemini API key has exceeded its usage quota. Here are your options:
                
                1. **Check your Google AI billing**: Visit \(apiKeyURL)
                2. **Add payment method**: Ensure you have a valid payment method linked
                3. **Wait for quota reset**: If you're on a free tier, wait for the monthly reset
                """
            }
        } else if errorString.contains("model_not_found") || errorString.contains("does not exist") {
            userFriendlyMessage = """
            ❌ Model Not Available
            
            The \(providerDisplayName) model is not available with your API key. This could mean:
            
            1. **Model access**: Your account may not have access to this model
            2. **API key permissions**: Check your API key at \(apiKeyURL)
            3. **Verify key**: Ensure your \(providerDisplayName) API key is valid and active
            """
        } else if errorString.contains("invalid_api_key") || errorString.contains("authentication") {
            userFriendlyMessage = """
            ❌ \(providerDisplayName) API Key Error
            
            There's an issue with your \(providerDisplayName) API key:
            
            1. **Check your API key**: Go to Settings > CodeMind AI and verify your \(providerDisplayName) key
            2. **Test connection**: Use the "Test Connection" button in settings
            3. **Get a new key**: Visit \(apiKeyURL) to create a new \(providerDisplayName) API key
            """
        }
        
        Task { @MainActor in
            messages.append(ChatMessage(
                role: .system,
                content: userFriendlyMessage,
                timestamp: Date()
            ))
        }
        
        CodeMindLogger.shared.log(.error, "Failed to process message", category: .general, metadata: [
            "error": error.localizedDescription,
            "userMessage": userMessage,
            "errorType": String(describing: type(of: error))
        ])
    }
    
    private func sendMessage() {
        guard canSend else { return }
        
        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        isInputFocused = false
        
        // Add user message
        let userMsg = ChatMessage(role: .user, content: userMessage, timestamp: Date())
        messages.append(userMsg)
        
        CodeMindLogger.shared.log(.info, "User message sent", category: .general, metadata: ["message": userMessage])
        
        // Process with CodeMind
        isProcessing = true
        Task {
            do {
                guard let codeMind = codeMind else {
                    throw NSError(domain: "CodeMindChat", code: 1, userInfo: [NSLocalizedDescriptionKey: "CodeMind not initialized"])
                }
                
                let response = try await codeMind.process(userMessage)
                
                // Log detailed response information
                CodeMindLogger.shared.log(.success, "CodeMind response received", category: .general, metadata: [
                    "responseLength": "\(response.content.count)",
                    "toolCallsCount": "\(response.toolResults.count)"
                ])
                
                // Log tool results if any
                for toolResult in response.toolResults {
                    let outputString = String(describing: toolResult.output ?? "nil")
                    CodeMindLogger.shared.log(.info, "Tool executed", category: .general, metadata: [
                        "toolName": toolResult.toolName,
                        "success": "\(toolResult.success)",
                        "outputLength": "\(outputString.count)",
                        "outputPreview": outputString.count > 100 ? String(outputString.prefix(100)) + "..." : outputString
                    ])
                }
                
                await MainActor.run {
                    // Add assistant response
                    var assistantContent = response.content
                    
                    // Add tool results if any
                    if !response.toolResults.isEmpty {
                        assistantContent += "\n\n**Tools Used:**\n"
                        for toolResult in response.toolResults {
                            let status = toolResult.success ? "✅" : "❌"
                            assistantContent += "\n\(status) \(toolResult.toolName)"
                            let resultString = String(describing: toolResult.output)
                            if !resultString.isEmpty && resultString != "nil" {
                                let preview = resultString.count > 200 
                                    ? String(resultString.prefix(200)) + "..."
                                    : resultString
                                assistantContent += "\n   Result: \(preview)"
                            }
                        }
                    }
                    
                    messages.append(ChatMessage(
                        role: .assistant,
                        content: assistantContent,
                        timestamp: Date(),
                        toolResults: response.toolResults
                    ))
                    
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                }
                handleProcessingError(error, userMessage: userMessage)
            }
        }
    }
}

// MARK: - Chat Message

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let timestamp: Date
    var toolResults: [ToolResult] = []
}

enum MessageRole {
    case user
    case assistant
    case system
}

// MARK: - Chat Message View

struct ChatMessageView: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if message.role == .assistant {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 12))
                            .foregroundColor(.purple)
                    }
                    
                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                
                Text(message.content)
                    .font(.system(size: 12))
                    .padding(12)
                    .background(message.role == .user ? Color.blue.opacity(0.1) : Color(nsColor: .separatorColor).opacity(0.2))
                    .cornerRadius(8)
                    .textSelection(.enabled)
                
                // Show tool results if any
                if !message.toolResults.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(message.toolResults.enumerated()), id: \.offset) { index, result in
                            HStack(spacing: 4) {
                                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(result.success ? .green : .red)
                                Text(result.toolName)
                                    .font(.system(size: 10, weight: .medium))
                                let resultString = String(describing: result.output)
                                if !resultString.isEmpty && resultString != "nil" {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text(resultString.count > 100 ? String(resultString.prefix(100)) + "..." : resultString)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .separatorColor).opacity(0.1))
                            .cornerRadius(4)
                        }
                    }
                }
            }
            .frame(maxWidth: 600, alignment: message.role == .user ? .trailing : .leading)
            
            if message.role == .assistant || message.role == .system {
                Spacer()
            }
        }
    }
}

