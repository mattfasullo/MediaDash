import SwiftUI
import Combine

// MARK: - CodeMind Brain View

/// Interactive knowledge graph visualization of CodeMind intelligence
struct CodeMindBrainView: View {
    @StateObject private var dataProvider = CodeMindBrainDataProvider.shared
    @StateObject private var rulesManager = CodeMindRulesManager.shared
    @StateObject private var physics = NodePhysicsEngine()
    
    @State private var selectedNode: BrainNode?
    @State private var hoveredNode: BrainNode?
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var showFilters = false
    @State private var mouseLocation: CGPoint = .zero
    @State private var canvasSize: CGSize = .zero
    @State private var draggedNodeId: String?
    @State private var lastDragTranslation: CGSize = .zero
    @State private var isDraggingCanvas: Bool = false
    @State private var canvasDragStartLocation: CGPoint = .zero
    @State private var editingRuleId: UUID?
    @State private var showRuleEditor = false
    @State private var ruleToDelete: BrainNode?
    @State private var showDeleteRuleAlert = false
    
    var body: some View {
        ZStack {
            // Background with subtle gradient
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.95)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            // Main content
            VStack(spacing: 0) {
                // Top bar
                topBar
                
                // Graph area
                GeometryReader { geometry in
                    ZStack {
                        // Background layer for canvas gestures (panning, zooming)
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(canvasDragGesture)
                            .gesture(magnificationGesture)
                            .onTapGesture { location in
                                // Only handle canvas tap if we're clicking on empty space (not a node)
                                if nodeAt(location, in: geometry.size) == nil {
                                    handleCanvasClick(at: location, in: geometry.size)
                                }
                            }
                        
                        // Connections layer with curves (no hit testing)
                        connectionsLayer(in: geometry.size)
                            .allowsHitTesting(false)
                        
                        // Nodes layer with physics (each node handles its own gestures)
                        nodesLayer(in: geometry.size)
                    }
                    .scaleEffect(scale)
                    .offset(offset)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            mouseLocation = location
                            updateHoveredNode(at: location, in: geometry.size)
                        case .ended:
                            hoveredNode = nil
                        }
                    }
                    .onAppear {
                        canvasSize = geometry.size
                        physics.canvasSize = geometry.size
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        canvasSize = newSize
                        physics.canvasSize = newSize
                        // Re-center the CodeMind node when canvas size changes
                        physics.resetCenterNodePosition(canvasSize: newSize)
                    }
                }
                
                // Bottom status bar
                statusBar
            }
            
            // Detail panel (slide in from right)
            if let node = selectedNode {
                detailPanel(for: node)
            }
            
            // Floating tooltip near cursor
            if let node = hoveredNode, selectedNode == nil {
                tooltipView(for: node)
                    .position(tooltipPosition)
            }
        }
        .onAppear {
            Task {
                // Run data fusion first to ensure all data is up to date
                await CodeMindDataFusion.shared.runFusion()
                await dataProvider.refreshNodes()
                physics.initializeNodes(dataProvider.nodes)
                physics.start()
            }
        }
        .onDisappear {
            physics.stop()
        }
        .onChange(of: dataProvider.nodes) { _, newNodes in
            physics.updateNodes(newNodes)
        }
        .sheet(isPresented: $showRuleEditor) {
            RuleEditorView(
                rulesManager: rulesManager,
                ruleId: editingRuleId,
                isPresented: $showRuleEditor
            )
            .onDisappear {
                editingRuleId = nil
                // Refresh nodes after rule is edited
                Task {
                    await dataProvider.refreshNodes()
                }
            }
        }
        .alert("Delete Rule", isPresented: $showDeleteRuleAlert) {
            Button("Cancel", role: .cancel) {
                ruleToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let node = ruleToDelete, let ruleId = node.ruleId {
                    deleteRule(ruleId: ruleId)
                }
                ruleToDelete = nil
            }
        } message: {
            if let node = ruleToDelete {
                Text("Are you sure you want to delete the rule '\(node.title)'? This action cannot be undone.")
            }
        }
    }
    
    private var tooltipPosition: CGPoint {
        let offset: CGFloat = 20
        return CGPoint(
            x: min(max(mouseLocation.x + offset + 80, 100), canvasSize.width - 100),
            y: min(max(mouseLocation.y - offset, 50), canvasSize.height - 50)
        )
    }
    
    // MARK: - Top Bar
    
    private var topBar: some View {
        HStack(spacing: 12) {
            Text("CodeMind Intelligence")
                .font(.system(size: 14, weight: .semibold))
            
            Spacer()
            
            // Filter button
            Button(action: { showFilters.toggle() }) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFilters) {
                filterPopover
            }
            
            // Refresh button
            Button(action: {
                Task {
                    await CodeMindDataFusion.shared.runFusion()
                    await dataProvider.refreshNodes()
                }
            }) {
                Image(systemName: dataProvider.isLoading ? "arrow.clockwise" : "arrow.clockwise")
                    .font(.system(size: 14))
                    .rotationEffect(.degrees(dataProvider.isLoading ? 360 : 0))
                    .animation(dataProvider.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: dataProvider.isLoading)
            }
            .buttonStyle(.plain)
            .disabled(dataProvider.isLoading)
            
            // Reset zoom
            Button(action: resetView) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Filter Popover
    
    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show/Hide")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            
            Toggle("Dockets", isOn: $dataProvider.showDockets)
            Toggle("Email Threads", isOn: $dataProvider.showEmails)
            Toggle("Sessions", isOn: $dataProvider.showSessions)
            Toggle("Files", isOn: $dataProvider.showFiles)
            Toggle("File Deliveries", isOn: $dataProvider.showFileDeliveries)
            Toggle("Suggestions", isOn: $dataProvider.showSuggestions)
            Toggle("Conflicts", isOn: $dataProvider.showConflicts)
            Toggle("Rules", isOn: $dataProvider.showRules)
            Toggle("User Preferences", isOn: $dataProvider.showUserPreferences)
        }
        .font(.system(size: 12))
        .padding()
        .frame(width: 180)
        .onChange(of: dataProvider.showDockets) { _, _ in refreshAfterFilterChange() }
        .onChange(of: dataProvider.showEmails) { _, _ in refreshAfterFilterChange() }
        .onChange(of: dataProvider.showSessions) { _, _ in refreshAfterFilterChange() }
        .onChange(of: dataProvider.showFiles) { _, _ in refreshAfterFilterChange() }
        .onChange(of: dataProvider.showFileDeliveries) { _, _ in refreshAfterFilterChange() }
        .onChange(of: dataProvider.showSuggestions) { _, _ in refreshAfterFilterChange() }
        .onChange(of: dataProvider.showConflicts) { _, _ in refreshAfterFilterChange() }
        .onChange(of: dataProvider.showRules) { _, _ in refreshAfterFilterChange() }
        .onChange(of: dataProvider.showUserPreferences) { _, _ in refreshAfterFilterChange() }
    }
    
    private func refreshAfterFilterChange() {
        Task {
            await dataProvider.refreshNodes()
        }
    }
    
    // MARK: - Connections Layer
    
    private func connectionsLayer(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            for connection in dataProvider.connections {
                guard let fromPos = physics.nodePositions[connection.fromId],
                      let toPos = physics.nodePositions[connection.toId] else {
                    continue
                }
                
                let fromPoint = CGPoint(x: fromPos.x, y: fromPos.y)
                let toPoint = CGPoint(x: toPos.x, y: toPos.y)
                
                // Create curved path
                var path = Path()
                path.move(to: fromPoint)
                
                // Calculate control point for curve
                let midX = (fromPoint.x + toPoint.x) / 2
                let midY = (fromPoint.y + toPoint.y) / 2
                let dx = toPoint.x - fromPoint.x
                let dy = toPoint.y - fromPoint.y
                let distance = sqrt(dx * dx + dy * dy)
                let curveAmount = min(distance * 0.15, 30)
                
                // Perpendicular offset for curve
                let perpX = -dy / distance * curveAmount
                let perpY = dx / distance * curveAmount
                
                let controlPoint = CGPoint(x: midX + perpX, y: midY + perpY)
                path.addQuadCurve(to: toPoint, control: controlPoint)
                
                let isHighlighted = hoveredNode?.id == connection.fromId || hoveredNode?.id == connection.toId
                let opacity = isHighlighted ? 0.7 : (connection.isAnimated ? 0.5 : 0.2)
                let lineWidth: CGFloat = isHighlighted ? 2.5 : (connection.isAnimated ? 1.5 : 1)
                
                context.stroke(
                    path,
                    with: .color(connection.color.opacity(opacity)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }
        }
        .animation(.easeInOut(duration: 0.1), value: hoveredNode?.id)
    }
    
    // MARK: - Nodes Layer
    
    private func nodesLayer(in size: CGSize) -> some View {
        ForEach(dataProvider.nodes) { node in
            FloatingNodeView(
                node: node,
                position: physics.nodePositions[node.id] ?? CGPoint(x: size.width / 2, y: size.height / 2),
                isSelected: selectedNode?.id == node.id,
                isHovered: hoveredNode?.id == node.id,
                isDragging: draggedNodeId == node.id,
                canvasScale: scale,
                onDrag: { newPosition in
                    physics.setNodePosition(node.id, position: newPosition)
                    draggedNodeId = node.id
                    // Track if center node is being dragged
                    if node.id == "codemind_center" {
                        physics.isCenterNodeDragging = true
                    }
                },
                onDragEnd: {
                    draggedNodeId = nil
                    // Return node to its target position after drag
                    if node.id == "codemind_center" {
                        physics.isCenterNodeDragging = false
                        physics.resetCenterNodePosition(canvasSize: canvasSize)
                    } else {
                        // Stop dragging and let physics spring back to target with floating
                        physics.stopDragging(node.id)
                    }
                },
                onTap: {
                    // Select/deselect node on tap
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        if selectedNode?.id == node.id {
                            selectedNode = nil
                        } else {
                            selectedNode = node
                        }
                    }
                },
                onHover: { isHovered in
                    withAnimation(.easeOut(duration: 0.15)) {
                        hoveredNode = isHovered ? node : nil
                    }
                }
            )
        }
    }
    
    // MARK: - Detail Panel
    
    private func detailPanel(for node: BrainNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Image(systemName: node.category.icon)
                        .foregroundColor(node.category.color)
                    Text(node.title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button(action: { selectedNode = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
                
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Category badge
                HStack {
                    Text(node.category.displayName)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(node.category.color.opacity(0.2))
                        .foregroundColor(node.category.color)
                        .cornerRadius(4)
                    
                    if node.hasIssue {
                        Text("Has Issues")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(4)
                    }
                }
                
                // Detail data
                if let details = node.detailData {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(details.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                            HStack(alignment: .top) {
                                Text(key)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(value)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                
                // Confidence bar
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confidence")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 6)
                                .cornerRadius(3)
                            Rectangle()
                                .fill(confidenceColor(node.confidence))
                                .frame(width: geo.size.width * node.confidence, height: 6)
                                .cornerRadius(3)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.top, 8)
                
                Spacer()
                
                // Actions
                actionButtons(for: node)
            }
            .padding(16)
            .frame(width: 280)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.15), radius: 12, x: -4, y: 0)
            .padding(16)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }
    
    // MARK: - Action Buttons
    
    @ViewBuilder
    private func actionButtons(for node: BrainNode) -> some View {
        VStack(spacing: 8) {
            switch node.category {
            case .suggestion:
                if node.suggestionId != nil {
                    HStack(spacing: 8) {
                        Button("Approve") {
                            approveSuggestion(node)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        Button("Dismiss") {
                            dismissSuggestion(node)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                
            case .conflict:
                if node.conflictId != nil {
                    Button("Resolve Conflict...") {
                        // Would open conflict resolution dialog
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                
            case .rule:
                if let ruleId = node.ruleId {
                    HStack(spacing: 8) {
                        Button("Edit Rule") {
                            editingRuleId = ruleId
                            showRuleEditor = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        
                        Button("Delete") {
                            ruleToDelete = node
                            showDeleteRuleAlert = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(.red)
                    }
                }
                
            case .docket:
                if node.docketNumber != nil {
                    Button("View Docket") {
                        // Would navigate to docket
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
            default:
                EmptyView()
            }
        }
    }
    
    // MARK: - Tooltip
    
    private func tooltipView(for node: BrainNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(node.category.color)
                    .frame(width: 10, height: 10)
                Text(node.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
            }
            if let subtitle = node.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                Text(node.category.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(node.category.color)
                Text("•")
                    .foregroundColor(.secondary)
                Text("\(Int(node.confidence * 100))% confidence")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(node.category.color.opacity(0.3), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    
    // MARK: - Status Bar
    
    private var statusBar: some View {
        let docketCount = dataProvider.nodes.filter { $0.category == .docket }.count
        let emailCount = dataProvider.nodes.filter { $0.category == .emailThread }.count
        let sessionCount = dataProvider.nodes.filter { $0.category == .session }.count
        let fileCount = dataProvider.nodes.filter { $0.category == .file }.count
        
        return VStack(spacing: 4) {
            // Node counts by category
            HStack(spacing: 16) {
                ForEach([BrainNodeCategory.docket, .emailThread, .session, .file, .suggestion, .conflict, .rule, .pattern], id: \.self) { category in
                    let count = dataProvider.nodes.filter { $0.category == category }.count
                    if count > 0 {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(category.color)
                                .frame(width: 8, height: 8)
                            Text("\(count)")
                                .font(.system(size: 10, design: .monospaced))
                        }
                        .help("\(count) \(category.displayName)(s)")
                    }
                }
                
                Spacer()
                
                // Last refresh
                if let lastRefresh = dataProvider.lastRefresh {
                    Text("Updated \(lastRefresh.formatted(.relative(presentation: .numeric)))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            
            // Total counts (may be filtered)
            HStack(spacing: 12) {
                if dataProvider.totalDocketsCount > docketCount {
                    Text("Dockets: \(docketCount) of \(dataProvider.totalDocketsCount)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                if dataProvider.totalEmailThreadsCount > emailCount {
                    Text("Emails: \(emailCount) of \(dataProvider.totalEmailThreadsCount)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                if dataProvider.totalSessionsCount > sessionCount {
                    Text("Sessions: \(sessionCount) of \(dataProvider.totalSessionsCount)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                if dataProvider.totalFilesCount > fileCount {
                    Text("Files: \(fileCount) of \(dataProvider.totalFilesCount)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Total nodes count
                Text("\(dataProvider.nodes.count) nodes")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Gestures
    
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                withAnimation(.interactiveSpring()) {
                    scale = max(0.3, min(3.0, value))
                }
            }
    }
    
    private var canvasDragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                // Only pan canvas if not dragging a node
                if draggedNodeId == nil {
                    if !isDraggingCanvas {
                        // Check if we're starting over a node - if so, don't pan
                        if let _ = nodeAt(value.startLocation, in: canvasSize) {
                            return
                        }
                        isDraggingCanvas = true
                        canvasDragStartLocation = value.startLocation
                        lastDragTranslation = .zero
                    }
                    // Calculate delta from last position
                    let delta = CGSize(
                        width: value.translation.width - lastDragTranslation.width,
                        height: value.translation.height - lastDragTranslation.height
                    )
                    offset = CGSize(
                        width: offset.width + delta.width,
                        height: offset.height + delta.height
                    )
                    lastDragTranslation = value.translation
                }
            }
            .onEnded { _ in
                isDraggingCanvas = false
                lastDragTranslation = .zero
                canvasDragStartLocation = .zero
            }
    }
    
    // MARK: - Node Selection Helpers
    
    /// Converts a screen coordinate to canvas coordinate accounting for scale and offset
    private func screenToCanvas(_ screenPoint: CGPoint, canvasSize: CGSize) -> CGPoint {
        // Account for scale and offset transformations
        let canvasPoint = CGPoint(
            x: (screenPoint.x - offset.width) / scale,
            y: (screenPoint.y - offset.height) / scale
        )
        return canvasPoint
    }
    
    /// Finds the node at the given screen coordinate
    private func nodeAt(_ screenPoint: CGPoint, in canvasSize: CGSize) -> BrainNode? {
        let canvasPoint = screenToCanvas(screenPoint, canvasSize: canvasSize)
        
        // Check each node to see if the point is within its bounds
        for node in dataProvider.nodes {
            guard let nodePos = physics.nodePositions[node.id] else { continue }
            
            // Calculate node size
            let nodeSize: CGFloat = switch node.category {
            case .core: 60
            case .docket: 48
            case .rule: 44
            case .emailThread, .session: 40
            case .suggestion, .conflict: 36
            default: 40
            }
            
            // Check if point is within node bounds (with some padding for easier clicking)
            let padding: CGFloat = 10
            let distance = sqrt(
                pow(canvasPoint.x - nodePos.x, 2) + 
                pow(canvasPoint.y - nodePos.y, 2)
            )
            
            if distance <= (nodeSize / 2) + padding {
                return node
            }
        }
        
        return nil
    }
    
    /// Updates the hovered node based on cursor position
    private func updateHoveredNode(at screenPoint: CGPoint, in canvasSize: CGSize) {
        if let node = nodeAt(screenPoint, in: canvasSize) {
            if hoveredNode?.id != node.id {
                withAnimation(.easeOut(duration: 0.15)) {
                    hoveredNode = node
                }
            }
        } else {
            if hoveredNode != nil {
                withAnimation(.easeOut(duration: 0.15)) {
                    hoveredNode = nil
                }
            }
        }
    }
    
    /// Handles canvas click to select node at cursor position
    private func handleCanvasClick(at screenPoint: CGPoint, in canvasSize: CGSize) {
        // Don't select if we just finished dragging canvas or a node
        guard !isDraggingCanvas && draggedNodeId == nil else { return }
        
        if let node = nodeAt(screenPoint, in: canvasSize) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if selectedNode?.id == node.id {
                    selectedNode = nil
                } else {
                    selectedNode = node
                }
            }
        } else {
            // Click on empty space deselects
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedNode = nil
            }
        }
    }
    
    private func resetView() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            scale = 1.0
            offset = .zero
        }
        physics.resetPositions(dataProvider.nodes)
    }
    
    // MARK: - Helpers
    
    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.8 { return .green }
        if confidence >= 0.6 { return .yellow }
        if confidence >= 0.4 { return .orange }
        return .red
    }
    
    private func approveSuggestion(_ node: BrainNode) {
        guard let suggestionId = node.suggestionId else { return }
        
        // Check if it's a session link suggestion
        if node.id.contains("link") {
            CodeMindSessionAnalyzer.shared.approveLinkSuggestion(suggestionId: suggestionId)
        } else {
            // Metadata enrichment
            CodeMindMetadataIntelligence.shared.applyEnrichment(enrichmentId: suggestionId)
        }
        
        selectedNode = nil
        Task {
            await dataProvider.refreshNodes()
        }
    }
    
    private func dismissSuggestion(_ node: BrainNode) {
        guard let suggestionId = node.suggestionId else { return }
        
        if node.id.contains("link") {
            CodeMindSessionAnalyzer.shared.rejectLinkSuggestion(suggestionId: suggestionId)
        } else {
            CodeMindMetadataIntelligence.shared.dismissEnrichment(enrichmentId: suggestionId)
        }
        
        selectedNode = nil
        Task {
            await dataProvider.refreshNodes()
        }
    }
    
    private func deleteRule(ruleId: UUID) {
        // Find the rule and delete it
        if let rule = rulesManager.rules.first(where: { $0.id == ruleId }) {
            rulesManager.deleteRule(rule)
            
            // Close detail panel if this rule was selected
            if selectedNode?.ruleId == ruleId {
                selectedNode = nil
            }
            
            // Refresh nodes to remove the deleted rule
            Task {
                await dataProvider.refreshNodes()
            }
        }
    }
}

// MARK: - Floating Node View (Interactive & Draggable)

struct FloatingNodeView: View {
    let node: BrainNode
    let position: CGPoint
    let isSelected: Bool
    let isHovered: Bool
    let isDragging: Bool
    let canvasScale: CGFloat
    let onDrag: (CGPoint) -> Void
    let onDragEnd: () -> Void
    let onTap: () -> Void
    let onHover: (Bool) -> Void
    
    @State private var breathePhase: Double = 0
    @State private var dragStartPosition: CGPoint = .zero
    
    private var nodeSize: CGFloat {
        let base: CGFloat = switch node.category {
        case .core: 60
        case .docket: 48
        case .rule: 44
        case .emailThread, .session: 40
        case .suggestion, .conflict: 36
        default: 40
        }
        // Slightly larger when hovered or selected
        let modifier: CGFloat = isSelected ? 1.15 : (isHovered ? 1.08 : 1.0)
        return base * modifier
    }
    
    var body: some View {
        ZStack {
            // Outer glow (breathing animation)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            node.category.color.opacity(0.4 + breathePhase * 0.2),
                            node.category.color.opacity(0)
                        ],
                        center: .center,
                        startRadius: nodeSize * 0.3,
                        endRadius: nodeSize * (0.8 + breathePhase * 0.1)
                    )
                )
                .frame(width: nodeSize * 1.8, height: nodeSize * 1.8)
                .opacity(isSelected ? 1 : (isHovered ? 0.8 : 0.4))
            
            // Selection ring
            if isSelected {
                Circle()
                    .stroke(node.category.color, lineWidth: 3)
                    .frame(width: nodeSize + 8, height: nodeSize + 8)
                    .scaleEffect(1.0 + breathePhase * 0.05)
            }
            
            // Main node body
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            node.category.color.opacity(isHovered ? 0.5 : 0.35),
                            node.category.color.opacity(isHovered ? 0.35 : 0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: nodeSize, height: nodeSize)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    node.category.color.opacity(0.8),
                                    node.category.color.opacity(0.4)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isSelected ? 2.5 : (isHovered ? 2 : 1.5)
                        )
                )
                .shadow(color: node.category.color.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 8 : 4)
            
            // Icon
            Image(systemName: node.category.icon)
                .font(.system(size: nodeSize * 0.38, weight: .medium))
                .foregroundColor(node.category.color)
                .shadow(color: .black.opacity(0.2), radius: 1)
            
            // Issue indicator with pulse
            if node.hasIssue {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                    )
                    .scaleEffect(1.0 + breathePhase * 0.2)
                    .offset(x: nodeSize * 0.38, y: -nodeSize * 0.38)
            }
        }
        // CRITICAL: Define hit-testing area for gestures - must cover the entire node
        .contentShape(Circle())
        .frame(width: nodeSize * 1.8, height: nodeSize * 1.8)
        .position(x: position.x, y: position.y)  // Position is now handled entirely by physics with floating
        .scaleEffect(isDragging ? 1.1 : 1.0)
        .opacity(isDragging ? 0.9 : 1.0)
        .highPriorityGesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    if dragStartPosition == .zero {
                        dragStartPosition = position
                    }
                    // Calculate new position based on start position and translation
                    // The translation is in view coordinates (scaled space), so divide by scale
                    // to convert to canvas coordinates (unscaled space)
                    let newPosition = CGPoint(
                        x: dragStartPosition.x + value.translation.width / canvasScale,
                        y: dragStartPosition.y + value.translation.height / canvasScale
                    )
                    onDrag(newPosition)
                }
                .onEnded { _ in
                    dragStartPosition = .zero
                    onDragEnd()
                }
        )
        .simultaneousGesture(
            TapGesture()
                .onEnded { _ in
                    onTap()
                }
        )
        .onHover { isHovering in
            onHover(isHovering)
        }
        .onAppear {
            startAnimations()
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isDragging)
    }
    
    private func startAnimations() {
        // Breathing animation (glow effect)
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
            breathePhase = 1.0
        }
        
        // Floating motion is now handled by physics engine for natural water-like movement
        // This allows nodes to continuously drift in a small area around their target position
    }
}

// MARK: - Node Physics Engine

@MainActor
class NodePhysicsEngine: ObservableObject {
    @Published var nodePositions: [String: CGPoint] = [:]
    
    var canvasSize: CGSize = CGSize(width: 800, height: 600)
    var isCenterNodeDragging: Bool = false
    
    private var velocities: [String: CGPoint] = [:]
    private var targetPositions: [String: CGPoint] = [:]
    private var timer: Timer?
    private var nodes: [BrainNode] = []
    
    // Floating animation state (water-like gentle drift)
    private var floatOffsets: [String: CGPoint] = [:]
    private var floatPhases: [String: Double] = [:]
    private var isDragging: Set<String> = []
    
    // Physics parameters
    private let friction: CGFloat = 0.95  // Higher friction for slower movement
    private let springStrength: CGFloat = 0.008  // Reduced spring strength for slower bounce back
    private let repulsionStrength: CGFloat = 3000  // Increased repulsion strength for better separation
    private let minDistance: CGFloat = 100  // Increased base minimum distance
    
    // Get node size for a given node ID
    private func getNodeSize(for nodeId: String) -> CGFloat {
        guard let node = nodes.first(where: { $0.id == nodeId }) else {
            return 40  // Default size
        }
        
        switch node.category {
        case .core: return 60
        case .docket: return 48
        case .rule: return 44
        case .emailThread, .session, .file: return 40
        case .suggestion, .conflict: return 36
        case .pattern: return 40
        default: return 40
        }
    }
    
    // Calculate minimum distance between two nodes based on their sizes
    private func getMinDistanceBetween(nodeId1: String, nodeId2: String) -> CGFloat {
        let size1 = getNodeSize(for: nodeId1)
        let size2 = getNodeSize(for: nodeId2)
        // Minimum distance is sum of radii plus padding (20% extra for breathing room)
        return (size1 / 2 + size2 / 2) * 1.2
    }
    
    func initializeNodes(_ nodes: [BrainNode]) {
        self.nodes = nodes
        
        for node in nodes {
            let position: CGPoint
            // Always keep CodeMind center node at center
            if node.id == "codemind_center" {
                position = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            } else {
                position = CGPoint(
                    x: node.position.x * canvasSize.width,
                    y: node.position.y * canvasSize.height
                )
            }
            nodePositions[node.id] = position
            targetPositions[node.id] = position
            velocities[node.id] = .zero
            
            // Initialize floating animation state
            floatOffsets[node.id] = .zero
            floatPhases[node.id] = Double(node.id.hashValue % 1000) / 1000.0 * 2.0 * .pi
        }
    }
    
    func updateNodes(_ newNodes: [BrainNode]) {
        // Add new nodes
        for node in newNodes {
            if nodePositions[node.id] == nil {
                let position: CGPoint
                // Always keep CodeMind center node at center
                if node.id == "codemind_center" {
                    position = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                } else {
                    position = CGPoint(
                        x: node.position.x * canvasSize.width,
                        y: node.position.y * canvasSize.height
                    )
                }
                nodePositions[node.id] = position
                targetPositions[node.id] = position
                velocities[node.id] = .zero
                
                // Initialize floating animation state for new nodes
                if floatOffsets[node.id] == nil {
                    floatOffsets[node.id] = .zero
                    floatPhases[node.id] = Double(node.id.hashValue % 1000) / 1000.0 * 2.0 * .pi
                }
            } else if node.id == "codemind_center" {
                // Ensure center node stays centered even if it already exists
                let centerPosition = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                targetPositions[node.id] = centerPosition
                nodePositions[node.id] = centerPosition
            }
        }
        
        // Remove old nodes
        let newIds = Set(newNodes.map { $0.id })
        for id in nodePositions.keys {
            if !newIds.contains(id) {
                nodePositions.removeValue(forKey: id)
                targetPositions.removeValue(forKey: id)
                velocities.removeValue(forKey: id)
                floatOffsets.removeValue(forKey: id)
                floatPhases.removeValue(forKey: id)
                isDragging.remove(id)
            }
        }
        
        self.nodes = newNodes
    }
    
    func setNodePosition(_ id: String, position: CGPoint) {
        nodePositions[id] = position
        // Don't update target position when dragging - let it return after drag ends
        // targetPositions[id] = position
        velocities[id] = .zero
        isDragging.insert(id)
    }
    
    func stopDragging(_ id: String) {
        isDragging.remove(id)
        // Velocity will naturally spring back to target
        velocities[id] = .zero
    }
    
    func resetPositions(_ nodes: [BrainNode]) {
        for node in nodes {
            let position = CGPoint(
                x: node.position.x * canvasSize.width,
                y: node.position.y * canvasSize.height
            )
            targetPositions[node.id] = position
        }
    }
    
    func resetCenterNodePosition(canvasSize: CGSize) {
        let centerId = "codemind_center"
        let centerPosition = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        targetPositions[centerId] = centerPosition
        nodePositions[centerId] = centerPosition
        velocities[centerId] = .zero
    }
    
    /// Return a node to its target position after dragging (with spring animation)
    func returnToTargetPosition(nodeId: String) {
        guard let targetPos = targetPositions[nodeId] else { return }
        // Set target position and let physics spring it back smoothly
        targetPositions[nodeId] = targetPos
        // Clear velocity to allow smooth spring return
        velocities[nodeId] = .zero
    }
    
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.step()
            }
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    private func step() {
        var newPositions = nodePositions
        var newVelocities = velocities
        
        // Always keep CodeMind center node at center (unless being dragged)
        let centerId = "codemind_center"
        if nodePositions[centerId] != nil && !isCenterNodeDragging {
            let centerPosition = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            targetPositions[centerId] = centerPosition
            
            // Use strong spring force to pull back to center smoothly
            if let currentPos = nodePositions[centerId] {
                var velocity = velocities[centerId] ?? .zero
                let dx = centerPosition.x - currentPos.x
                let dy = centerPosition.y - currentPos.y
                
                // Moderate spring force to ensure smooth return to center
                velocity.x += dx * springStrength * 2.5  // Reduced from 5x to 2.5x for slower return
                velocity.y += dy * springStrength * 2.5
                
                // Apply friction
                velocity.x *= friction
                velocity.y *= friction
                
                // Update position
                let newX = currentPos.x + velocity.x
                let newY = currentPos.y + velocity.y
                newPositions[centerId] = CGPoint(x: newX, y: newY)
                newVelocities[centerId] = velocity
            }
        }
        
        // Update floating phases for continuous animation (water-like gentle drift)
        let timeStep: Double = 1.0 / 60.0  // 60 FPS
        for id in nodePositions.keys {
            if floatPhases[id] == nil {
                // Each node gets a unique starting phase based on its ID for organic motion
                floatPhases[id] = Double(id.hashValue % 1000) / 1000.0 * 2.0 * .pi
            }
            if !isDragging.contains(id) && id != centerId {
                // Continuous floating motion - each node moves at slightly different speed
                let speed = 0.3 + Double(id.hashValue % 50) / 500.0  // Varies between 0.3-0.4
                floatPhases[id] = (floatPhases[id] ?? 0) + timeStep * speed
                if floatPhases[id]! > 2.0 * .pi {
                    floatPhases[id] = floatPhases[id]! - 2.0 * .pi
                }
            }
        }
        
        for (id, currentPos) in nodePositions {
            // Skip center node - it's handled above
            if id == centerId { continue }
            
            guard var velocity = velocities[id],
                  let targetPos = targetPositions[id] else { continue }
            
            // Spring force toward target (with floating motion when not dragging)
            if isDragging.contains(id) {
                // While dragging, just apply repulsion - don't pull toward target
            } else {
                // Add gentle floating drift (water-like motion)
                let phase = floatPhases[id] ?? 0
                let floatRadius: CGFloat = 5.0  // Maximum drift distance (small area - like floating in water)
                
                // Create organic floating pattern with varying frequencies for natural movement
                // Each node uses a different hash-based offset for unique motion
                let nodeHash = abs(id.hashValue % 100)
                let speedX = 0.4 + Double(nodeHash % 20) / 100.0  // Varies 0.4-0.6
                let speedY = 0.5 + Double((nodeHash / 20) % 20) / 100.0  // Different Y speed for organic movement
                
                // Elliptical floating pattern (more natural than circular)
                let offsetX = cos(phase * speedX) * floatRadius
                let offsetY = sin(phase * speedY) * floatRadius * 0.8  // Slightly flattened ellipse
                
                // Floating target position (small area around base target)
                let floatingTargetX = targetPos.x + offsetX
                let floatingTargetY = targetPos.y + offsetY
                
                // Calculate distance from base target to ensure nodes never float off
                let dxFromBase = currentPos.x - targetPos.x
                let dyFromBase = currentPos.y - targetPos.y
                let distanceFromBase = sqrt(dxFromBase * dxFromBase + dyFromBase * dyFromBase)
                let maxFloatDistance: CGFloat = floatRadius * 1.5  // Max 1.5x radius from target
                
                // Spring force toward floating target (gentle, water-like)
                let dx = floatingTargetX - currentPos.x
                let dy = floatingTargetY - currentPos.y
                
                // If too far from base target, apply stronger spring to pull back
                // This ensures nodes never float away from their home position
                let springMultiplier: CGFloat = distanceFromBase > maxFloatDistance ? 2.0 : 0.4  // Reduced multipliers for slower movement
                velocity.x += dx * springStrength * springMultiplier
                velocity.y += dy * springStrength * springMultiplier
            }
            
            // Repulsion from other nodes (prevent overlaps)
            for (otherId, otherPos) in nodePositions where otherId != id {
                let repDx = currentPos.x - otherPos.x
                let repDy = currentPos.y - otherPos.y
                let distance = sqrt(repDx * repDx + repDy * repDy)
                
                // Get minimum distance required between these two nodes
                let requiredMinDistance = getMinDistanceBetween(nodeId1: id, nodeId2: otherId)
                
                // Apply repulsion if nodes are too close
                if distance < requiredMinDistance && distance > 0 {
                    // Stronger repulsion the closer they are
                    let overlap = requiredMinDistance - distance
                    let normalizedDx = repDx / distance
                    let normalizedDy = repDy / distance
                    
                    // Scale force based on overlap amount (more overlap = stronger force)
                    let force = (repulsionStrength * overlap) / (distance + 1.0)
                    velocity.x += normalizedDx * force * 0.02
                    velocity.y += normalizedDy * force * 0.02
                } else if distance < requiredMinDistance * 1.5 && distance > requiredMinDistance {
                    // Soft repulsion even when not overlapping (preventive)
                    let normalizedDx = repDx / distance
                    let normalizedDy = repDy / distance
                    let proximityFactor = (requiredMinDistance * 1.5 - distance) / (requiredMinDistance * 0.5)
                    let force = repulsionStrength * 0.5 * proximityFactor / (distance * distance + 1.0)
                    velocity.x += normalizedDx * force * 0.01
                    velocity.y += normalizedDy * force * 0.01
                }
            }
            
            // Apply friction
            velocity.x *= friction
            velocity.y *= friction
            
            // Update position
            var newX = currentPos.x + velocity.x
            var newY = currentPos.y + velocity.y
            
            // Boundary constraints with soft bounce
            let margin: CGFloat = 40
            if newX < margin { newX = margin; velocity.x *= -0.5 }
            if newX > canvasSize.width - margin { newX = canvasSize.width - margin; velocity.x *= -0.5 }
            if newY < margin { newY = margin; velocity.y *= -0.5 }
            if newY > canvasSize.height - margin { newY = canvasSize.height - margin; velocity.y *= -0.5 }
            
            newPositions[id] = CGPoint(x: newX, y: newY)
            newVelocities[id] = velocity
        }
        
        // Final collision resolution pass - ensure no overlaps
        resolveOverlaps(&newPositions)
        
        nodePositions = newPositions
        velocities = newVelocities
    }
    
    /// Resolve any remaining overlaps by pushing nodes apart
    private func resolveOverlaps(_ positions: inout [String: CGPoint]) {
        let centerId = "codemind_center"
        var resolvedIds = Set<String>()
        
        // Process nodes in order, ensuring each doesn't overlap with previously resolved ones
        for (id, currentPos) in positions {
            if id == centerId || resolvedIds.contains(id) { continue }
            
            var adjustedPos = currentPos
            
            // Check against all other nodes (including center)
            for (otherId, otherPos) in positions where otherId != id {
                let repDx = adjustedPos.x - otherPos.x
                let repDy = adjustedPos.y - otherPos.y
                let distance = sqrt(repDx * repDx + repDy * repDy)
                
                let requiredMinDistance = getMinDistanceBetween(nodeId1: id, nodeId2: otherId)
                
                // If overlapping, push apart
                if distance < requiredMinDistance && distance > 0 {
                    let overlap = requiredMinDistance - distance
                    let normalizedDx = repDx / distance
                    let normalizedDy = repDy / distance
                    
                    // Push this node away (but don't move center node)
                    if otherId != centerId {
                        adjustedPos.x += normalizedDx * overlap * 0.5
                        adjustedPos.y += normalizedDy * overlap * 0.5
                    } else {
                        // If colliding with center, push this node away more strongly
                        adjustedPos.x += normalizedDx * overlap
                        adjustedPos.y += normalizedDy * overlap
                    }
                    
                    // Keep within bounds
                    let margin: CGFloat = 50
                    adjustedPos.x = max(margin, min(canvasSize.width - margin, adjustedPos.x))
                    adjustedPos.y = max(margin, min(canvasSize.height - margin, adjustedPos.y))
                }
            }
            
            positions[id] = adjustedPos
            resolvedIds.insert(id)
        }
    }
}

// MARK: - Legacy Node View (kept for compatibility)

struct NodeView: View {
    let node: BrainNode
    let isSelected: Bool
    let isHovered: Bool
    
    private var nodeSize: CGFloat {
        switch node.category {
        case .core: return 56
        case .docket: return 44
        case .rule: return 40
        case .emailThread, .session: return 36
        case .suggestion, .conflict: return 32
        default: return 36
        }
    }
    
    var body: some View {
        ZStack {
            if node.isHighlighted || isSelected {
                Circle()
                    .fill(node.category.color.opacity(0.3))
                    .frame(width: nodeSize + 12, height: nodeSize + 12)
                    .blur(radius: 6)
            }
            
            Circle()
                .fill(node.category.color.opacity(isHovered ? 0.3 : 0.15))
                .frame(width: nodeSize, height: nodeSize)
                .overlay(
                    Circle()
                        .stroke(
                            node.category.color,
                            lineWidth: isSelected ? 3 : (isHovered ? 2 : 1.5)
                        )
                )
            
            Image(systemName: node.category.icon)
                .font(.system(size: nodeSize * 0.35))
                .foregroundColor(node.category.color)
            
            if node.hasIssue {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .offset(x: nodeSize * 0.35, y: -nodeSize * 0.35)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Preview

#Preview {
    CodeMindBrainView()
        .frame(width: 800, height: 600)
}
