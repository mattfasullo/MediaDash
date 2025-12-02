import SwiftUI

/// Editor view for classification rules, usable from BrainView or Settings
struct RuleEditorView: View {
    @ObservedObject var rulesManager: CodeMindRulesManager
    @Binding var isPresented: Bool
    
    let ruleId: UUID?
    @State private var editedRule: ClassificationRule
    
    init(rulesManager: CodeMindRulesManager, ruleId: UUID?, isPresented: Binding<Bool>) {
        self.rulesManager = rulesManager
        self.ruleId = ruleId
        self._isPresented = isPresented
        
        // Initialize with existing rule or create new one
        if let ruleId = ruleId,
           let existingRule = rulesManager.rules.first(where: { $0.id == ruleId }) {
            self._editedRule = State(initialValue: existingRule)
        } else {
            self._editedRule = State(initialValue: ClassificationRule())
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ruleId == nil ? "New Classification Rule" : "Edit Classification Rule")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    if let subtitle = editedRule.name.isEmpty ? nil : editedRule.name {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    saveRule()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic Information
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Basic Information")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rule Name")
                                .font(.system(size: 12, weight: .medium))
                            
                            TextField("e.g., Ignore Grayson Emails", text: $editedRule.name)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description")
                                .font(.system(size: 12, weight: .medium))
                            
                            TextField("Optional description", text: $editedRule.description, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(3...6)
                        }
                    }
                    
                    Divider()
                    
                    // Rule Configuration
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Rule Configuration")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rule Type")
                                .font(.system(size: 12, weight: .medium))
                            
                            Picker("", selection: $editedRule.type) {
                                ForEach(ClassificationRule.RuleType.allCases, id: \.self) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pattern")
                                .font(.system(size: 12, weight: .medium))
                            
                            TextField("Pattern to match", text: $editedRule.pattern)
                                .textFieldStyle(.roundedBorder)
                            
                            Text(patternHelpText)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Action")
                                .font(.system(size: 12, weight: .medium))
                            
                            Picker("", selection: $editedRule.action) {
                                ForEach(ClassificationRule.RuleAction.allCases, id: \.self) { action in
                                    Text(action.rawValue).tag(action)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Weight")
                                .font(.system(size: 12, weight: .medium))
                            
                            HStack {
                                Slider(value: $editedRule.weight, in: 0.0...1.0, step: 0.05)
                                Text(String(format: "%.2f", editedRule.weight))
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 40)
                            }
                        }
                        
                        Toggle("Enabled", isOn: $editedRule.isEnabled)
                            .font(.system(size: 12))
                    }
                    
                    Divider()
                    
                    // Preview
                    if !editedRule.pattern.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Preview")
                                .font(.headline)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("When an email matches:")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                
                                Text("Pattern: \"\(editedRule.pattern)\"")
                                    .font(.system(size: 11, design: .monospaced))
                                
                                Text("Type: \(editedRule.type.rawValue)")
                                    .font(.system(size: 11))
                                
                                Text("Action: \(editedRule.action.rawValue)")
                                    .font(.system(size: 11))
                                
                                if editedRule.action == .boostConfidence || editedRule.action == .reduceConfidence {
                                    Text("Confidence modifier: \(String(format: "%.1f", editedRule.weight * 20))%")
                                        .font(.system(size: 11))
                                }
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 600)
    }
    
    private var patternHelpText: String {
        switch editedRule.type {
        case .subjectContains, .bodyContains:
            return "Case-insensitive text to search for in the email"
        case .subjectRegex, .bodyRegex:
            return "Regular expression pattern (e.g., '\\d{5}' for 5-digit numbers)"
        case .senderDomain:
            return "Domain name (e.g., 'graysonmusicgroup.com')"
        case .senderEmail:
            return "Email address or partial match (e.g., 'media@' or 'noreply@')"
        case .docketFormat:
            return "Regex pattern for docket number format (e.g., '\\b\\d{5}\\b' for 5-digit docket)"
        }
    }
    
    private func saveRule() {
        if ruleId != nil {
            // Update existing rule
            rulesManager.updateRule(editedRule)
        } else {
            // Add new rule
            rulesManager.addRule(editedRule)
        }
        isPresented = false
    }
}

