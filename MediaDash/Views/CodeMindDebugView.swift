import SwiftUI

struct CodeMindDebugView: View {
    @StateObject private var logger = CodeMindLogger.shared
    @State private var selectedCategory: CodeMindLogCategory? = nil
    @State private var selectedLevel: CodeMindLogLevel? = nil
    @State private var searchText = ""
    @State private var autoScroll = true
    @State private var selectedTab: DebugTab = .brain
    @State private var copiedAll = false
    
    var filteredLogs: [CodeMindLogEntry] {
        var logs = logger.logs
        
        // Filter by category
        if let category = selectedCategory {
            logs = logs.filter { $0.category == category }
        }
        
        // Filter by level
        if let level = selectedLevel {
            logs = logs.filter { $0.level == level }
        }
        
        // Filter by search text
        if !searchText.isEmpty {
            logs = logs.filter { log in
                log.message.localizedCaseInsensitiveContains(searchText) ||
                log.category.rawValue.localizedCaseInsensitiveContains(searchText) ||
                (log.metadata?.values.joined(separator: " ").localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        
        return logs
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab selector
            Picker("View", selection: $selectedTab) {
                Text("🧠 Brain").tag(DebugTab.brain)
                Text("Logs").tag(DebugTab.logs)
                Text("Chat").tag(DebugTab.chat)
            }
            .pickerStyle(.segmented)
            .padding()
            
            Divider()
            
            // Content based on selected tab
            switch selectedTab {
            case .brain:
                CodeMindBrainView()
            case .logs:
                logsView
            case .chat:
                CodeMindChatView()
            }
        }
    }
    
    private var logsView: some View {
        HSplitView {
            // Sidebar with filters
            VStack(alignment: .leading, spacing: 12) {
                Text("Filters")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal)
                    .padding(.top, 8)
                
                // Search
                TextField("Search logs...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                
                Divider()
                
                // Category filter
                VStack(alignment: .leading, spacing: 8) {
                    Text("Category")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal)
                    
                    List(CodeMindLogCategory.allCases, id: \.self, selection: $selectedCategory) { category in
                        HStack {
                            Text(category.rawValue)
                            Spacer()
                            Text("\(logger.logs(for: category).count)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .tag(category as CodeMindLogCategory?)
                    }
                    .listStyle(.sidebar)
                }
                
                Divider()
                
                // Level filter
                VStack(alignment: .leading, spacing: 8) {
                    Text("Level")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal)
                    
                    List(CodeMindLogLevel.allCases, id: \.self, selection: $selectedLevel) { level in
                        HStack {
                            Text(level.emoji)
                            Text(level.rawValue)
                            Spacer()
                            Text("\(logger.logs(for: level).count)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .tag(level as CodeMindLogLevel?)
                    }
                    .listStyle(.sidebar)
                }
                
                Spacer()
                
                // Actions
                VStack(spacing: 8) {
                    Button("Clear Logs") {
                        logger.clear()
                    }
                    .buttonStyle(.bordered)
                    
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.checkbox)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .frame(width: 200)
            
            // Main log view
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("CodeMind Activity Log")
                        .font(.system(size: 16, weight: .semibold))
                    
                    Spacer()
                    
                    Text("\(filteredLogs.count) logs")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    
                    Button(action: {
                        let allText = logger.getAllLogsAsText(filtered: filteredLogs)
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(allText, forType: .string)
                        copiedAll = true
                        
                        // Reset copied state after 2 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedAll = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            if copiedAll {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Copied!")
                                    .foregroundColor(.green)
                            } else {
                                Image(systemName: "doc.on.doc")
                                Text("Copy All")
                            }
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy all logs as text (⌘⇧C)")
                }
                .padding()
                .background(Color(nsColor: .separatorColor).opacity(0.1))
                
                // Log list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(filteredLogs) { log in
                                LogRowView(log: log)
                                    .id(log.id)
                            }
                        }
                        .padding(8)
                        .onChange(of: filteredLogs.count) {
                            if autoScroll, let lastLog = filteredLogs.last {
                                withAnimation {
                                    proxy.scrollTo(lastLog.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

enum DebugTab {
    case brain
    case logs
    case chat
}

struct LogRowView: View {
    let log: CodeMindLogEntry
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(log.level.emoji)
                    .font(.system(size: 12))
                
                Text(log.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Text(log.category.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .separatorColor).opacity(0.2))
                    .cornerRadius(4)
                
                Spacer()
            }
            
            Text(log.message)
                .font(.system(size: 11))
                .textSelection(.enabled)
            
            if let metadata = log.metadata, !metadata.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(metadata.keys.sorted()), id: \.self) { key in
                        if let value = metadata[key] {
                            HStack(alignment: .top, spacing: 4) {
                                Text("\(key):")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(value)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.leading, 16)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(log.level == .error ? Color.red.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}

extension CodeMindLogLevel: CaseIterable {
    static var allCases: [CodeMindLogLevel] {
        [.debug, .info, .success, .warning, .error]
    }
}

