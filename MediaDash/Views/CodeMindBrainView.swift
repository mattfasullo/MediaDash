import SwiftUI
import Combine

// MARK: - Brain View - Simple Knowledge Graph (Obsidian-style)

struct CodeMindBrainView: View {
    @StateObject private var history = CodeMindClassificationHistory.shared
    @StateObject private var patternSuggester = CodeMindPatternSuggester.shared
    @StateObject private var anomalyDetector = CodeMindAnomalyDetector.shared
    @StateObject private var rulesManager = CodeMindRulesManager.shared
    @AppStorage("codemind_advanced_mode") private var advancedMode = false
    
    @State private var selectedNode: ThoughtNode?
    @State private var thoughtNodes: [ThoughtNode] = []
    @State private var connections: [SynapseConnection] = []
    @State private var isAnalyzing = false
    
    var body: some View {
        ZStack {
            // Simple flat background
            Color(red: 0.95, green: 0.95, blue: 0.97)
                .ignoresSafeArea()
            
            // Connections (simple lines)
            connectionsLayer
            
            // Nodes (simple bubbles)
            nodesLayer
            
            // Edit panel (only when node selected)
            if let node = selectedNode, node.category == .rule, let ruleId = node.ruleId {
                editPanel(node: node, ruleId: ruleId)
            }
            
            // Top bar
            VStack {
                topBar
                Spacer()
            }
        }
        .onAppear {
            Task {
                await refreshBrain()
                handlePendingNavigation()
            }
        }
        .onChange(of: rulesManager.rules) { _, _ in
            Task { await refreshBrain() }
        }
        .onReceive(CodeMindBrainNavigator.shared.$pendingNavigation) { target in
            if target != nil {
                Task {
                    await refreshBrain()
                    handlePendingNavigation()
                }
            }
        }
    }
    
    // MARK: - Simple Top Bar
    
    private var topBar: some View {
        HStack {
            Text("CodeMind Knowledge Graph")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            
            Spacer()
            
            if advancedMode {
                Button(action: { Task { await refreshBrain() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Connections (Simple Lines)
    
    private var connectionsLayer: some View {
        Canvas { context, size in
            for connection in connections {
                guard let from = thoughtNodes.first(where: { $0.id == connection.from }),
                      let to = thoughtNodes.first(where: { $0.id == connection.to }) else { continue }
                
                let fromPoint = CGPoint(
                    x: from.position.x * size.width,
                    y: from.position.y * size.height
                )
                let toPoint = CGPoint(
                    x: to.position.x * size.width,
                    y: to.position.y * size.height
                )
                
                var path = Path()
                path.move(to: fromPoint)
                path.addLine(to: toPoint)
                
                context.stroke(
                    path,
                    with: .color(connection.color.opacity(0.2)),
                    lineWidth: 1
                )
            }
        }
    }
    
    // MARK: - Nodes (Simple Bubbles)
    
    private var nodesLayer: some View {
        GeometryReader { geo in
            ForEach(thoughtNodes) { node in
                SimpleNodeView(
                    node: node,
                    isSelected: selectedNode?.id == node.id
                )
                .position(
                    x: node.position.x * geo.size.width,
                    y: node.position.y * geo.size.height
                )
                .onTapGesture {
                    if node.category == .rule {
                        selectedNode = node
                    } else if advancedMode {
                        selectedNode = node
                    }
                }
            }
        }
    }
    
    // MARK: - Edit Panel (Simple Inline Editor)
    
    private func editPanel(node: ThoughtNode, ruleId: UUID) -> some View {
        let rule = rulesManager.rules.first { $0.id == ruleId }
        
        return SimpleEditPanel(
            rule: rule,
            node: node,
            onSave: { updatedRule in
                rulesManager.updateRule(updatedRule)
                selectedNode = nil
                Task { await refreshBrain() }
            },
            onCancel: {
                selectedNode = nil
            },
            onDelete: {
                if let rule = rule {
                    rulesManager.deleteRule(rule)
                }
                selectedNode = nil
                Task { await refreshBrain() }
            }
        )
    }
    
    // MARK: - Navigation Handling
    
    private func handlePendingNavigation() {
        guard let target = CodeMindBrainNavigator.shared.pendingNavigation else { return }
        CodeMindBrainNavigator.shared.clearPendingNavigation()
        
        switch target {
        case .classificationById(let id):
            if let node = thoughtNodes.first(where: { $0.classificationId == id }) {
                selectedNode = node
            }
        case .classificationBySubject(let subject):
            if let node = thoughtNodes.first(where: { $0.emailSubject == subject }) {
                selectedNode = node
            }
        case .ruleById(let id):
            if let node = thoughtNodes.first(where: { $0.ruleId == id }) {
                selectedNode = node
            }
        case .createRuleForEmail(let subject, let from, let classificationType):
            let action: ClassificationRule.RuleAction = classificationType == "newDocket" ? .classifyAsNewDocket : .classifyAsFileDelivery
            let pattern = from ?? subject.components(separatedBy: " ").filter { $0.count > 3 }.prefix(3).joined(separator: " ")
            
            let rule = ClassificationRule(
                name: "Rule: \(subject.prefix(20))",
                description: "",
                type: from != nil ? .senderEmail : .subjectContains,
                pattern: pattern,
                weight: 0.85,
                isEnabled: true,
                action: action
            )
            rulesManager.addRule(rule)
            
            Task {
                await refreshBrain()
                if let newNode = thoughtNodes.first(where: { $0.ruleId == rule.id }) {
                    selectedNode = newNode
                }
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func refreshBrain() async {
        isAnalyzing = true
        
        if advancedMode {
            _ = await patternSuggester.extractPatternsFromClassifications()
            await anomalyDetector.runAllChecks()
        }
        
        var nodes: [ThoughtNode] = []
        var conns: [SynapseConnection] = []
        
        // Center node
        let center = ThoughtNode(
            id: "center",
            title: "CodeMind",
            description: "",
            category: .core,
            confidence: 1.0,
            position: CGPoint(x: 0.5, y: 0.5)
        )
        nodes.append(center)
        
        // Rules (knowledge points)
        for (index, rule) in rulesManager.rules.enumerated() {
            let angle = (Double(index) / max(Double(rulesManager.rules.count), 1)) * 2 * .pi
            let radius = 0.35
            let position = CGPoint(
                x: 0.5 + cos(angle) * radius,
                y: 0.5 + sin(angle) * radius
            )
            
            var node = ThoughtNode(
                id: "rule_\(rule.id)",
                title: rule.name.isEmpty ? rule.pattern : rule.name,
                description: rule.description,
                category: .rule,
                confidence: rule.isEnabled ? rule.weight : 0.3,
                position: position
            )
            node.ruleId = rule.id
            nodes.append(node)
            
            conns.append(SynapseConnection(
                from: "center",
                to: "rule_\(rule.id)",
                strength: rule.weight,
                color: rule.isEnabled ? .blue : .gray
            ))
        }
        
        // Recent classifications (if advanced mode)
        if advancedMode {
            for (index, record) in history.getRecentClassifications(limit: 8).enumerated() {
                let angle = (Double(index) / 8.0) * 2 * .pi + .pi / 4
                let radius = 0.25
                let position = CGPoint(
                    x: 0.5 + cos(angle) * radius,
                    y: 0.5 + sin(angle) * radius
                )
                
                var node = ThoughtNode(
                    id: record.id.uuidString,
                    title: String(record.subject.prefix(25)),
                    description: "",
                    category: .memory,
                    confidence: record.confidence,
                    position: position
                )
                node.classificationId = record.id
                node.emailSubject = record.subject
                nodes.append(node)
                
                conns.append(SynapseConnection(
                    from: "center",
                    to: record.id.uuidString,
                    strength: record.confidence,
                    color: .cyan
                ))
            }
        }
        
        await MainActor.run {
            thoughtNodes = nodes
            connections = conns
            isAnalyzing = false
        }
    }
}

// MARK: - Simple Node View (Flat Bubble)

struct SimpleNodeView: View {
    let node: ThoughtNode
    let isSelected: Bool
    
    private var nodeSize: CGFloat {
        switch node.category {
        case .core: return 60
        case .rule: return 50
        case .memory: return 35
        case .pattern, .anomaly: return 40
        }
    }
    
    private var nodeColor: Color {
        switch node.category {
        case .core: return .blue
        case .rule: 
            // Check if rule is enabled via rulesManager
            if let ruleId = node.ruleId,
               let rule = CodeMindRulesManager.shared.rules.first(where: { $0.id == ruleId }),
               !rule.isEnabled {
                return .gray
            }
            return .green
        case .memory: return .cyan
        case .pattern: return .purple
        case .anomaly: return .orange
        }
    }
    
    var body: some View {
        ZStack {
            // Simple circle
            Circle()
                .fill(nodeColor.opacity(0.15))
                .frame(width: nodeSize, height: nodeSize)
                .overlay(
                    Circle()
                        .stroke(nodeColor, lineWidth: isSelected ? 3 : 1.5)
                )
            
            // Label
            Text(node.title)
                .font(.system(size: nodeSize > 40 ? 11 : 9, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: nodeSize * 1.5)
                .padding(.top, nodeSize * 0.6)
        }
    }
}

// MARK: - Simple Edit Panel

struct SimpleEditPanel: View {
    let rule: ClassificationRule?
    let node: ThoughtNode
    let onSave: (ClassificationRule) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    
    @State private var name: String = ""
    @State private var pattern: String = ""
    @State private var ruleType: ClassificationRule.RuleType = .subjectContains
    @State private var action: ClassificationRule.RuleAction = .boostConfidence
    @State private var weight: Double = 0.8
    @State private var isEnabled: Bool = true
    
    init(rule: ClassificationRule?, node: ThoughtNode, onSave: @escaping (ClassificationRule) -> Void, onCancel: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.rule = rule
        self.node = node
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        
        if let rule = rule {
            _name = State(initialValue: rule.name)
            _pattern = State(initialValue: rule.pattern)
            _ruleType = State(initialValue: rule.type)
            _action = State(initialValue: rule.action)
            _weight = State(initialValue: rule.weight)
            _isEnabled = State(initialValue: rule.isEnabled)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Edit Rule")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("Rule name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Pattern")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("Pattern to match", text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Type")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $ruleType) {
                    ForEach(ClassificationRule.RuleType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.menu)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Action")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $action) {
                    ForEach(ClassificationRule.RuleAction.allCases, id: \.self) { act in
                        Text(act.rawValue).tag(act)
                    }
                }
                .pickerStyle(.menu)
            }
            
            if action == .boostConfidence || action == .reduceConfidence {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weight")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(weight * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Slider(value: $weight, in: 0.1...1, step: 0.1)
                }
            }
            
            Toggle("Enabled", isOn: $isEnabled)
            
            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                
                Button("Delete", action: onDelete)
                    .buttonStyle(.bordered)
                    .tint(.red)
                
                Spacer()
                
                Button("Save", action: saveRule)
                    .buttonStyle(.borderedProminent)
                    .disabled(pattern.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding()
    }
    
    private func saveRule() {
        guard let existingRule = rule else { return }
        let updatedRule = ClassificationRule(
            id: existingRule.id,
            name: name,
            description: "",
            type: ruleType,
            pattern: pattern,
            weight: weight,
            isEnabled: isEnabled,
            action: action,
            createdAt: existingRule.createdAt,
            lastModified: Date()
        )
        onSave(updatedRule)
    }
}

// MARK: - Thought Node Model

enum ThoughtCategory: String, Codable {
    case core = "Core"
    case pattern = "Pattern"
    case memory = "Memory"
    case anomaly = "Anomaly"
    case rule = "Rule"
    
    var color: Color {
        switch self {
        case .core: return .blue
        case .pattern: return .purple
        case .memory: return .cyan
        case .anomaly: return .orange
        case .rule: return .green
        }
    }
}

struct ThoughtNode: Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    let category: ThoughtCategory
    let confidence: Double
    var position: CGPoint
    var ruleId: UUID? = nil
    var classificationId: UUID? = nil
    var emailSubject: String? = nil
    
    static func == (lhs: ThoughtNode, rhs: ThoughtNode) -> Bool {
        lhs.id == rhs.id
    }
}

struct SynapseConnection: Identifiable {
    let id = UUID()
    let from: String
    let to: String
    let strength: Double
    var color: Color = .blue
}
