import SwiftUI

/// Flat circle CodeMind activity overlay
struct CodeMindActivityOverlay: View {
    @ObservedObject var activityManager = CodeMindActivityManager.shared

    var body: some View {
        if activityManager.isEnabled {
            CodeMindActivityTab()
        }
    }
}

// MARK: - Activity Tab

struct CodeMindActivityTab: View {
    @ObservedObject var activityManager = CodeMindActivityManager.shared

    @State private var isExpanded = false

    private let bubbleSize: CGFloat = 48
    private let expandedWidth: CGFloat = 300
    private let expandedHeight: CGFloat = 350
    private let edgePadding: CGFloat = 15
    private let cornerRadius: CGFloat = 16

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()

                if isExpanded {
                    expandedTabView
                        .frame(width: expandedWidth, height: expandedHeight)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    collapsedBubbleView
                        .frame(width: bubbleSize, height: bubbleSize)
                }
            }
            .padding(.trailing, edgePadding)
            .padding(.bottom, edgePadding)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isExpanded)
        .keyboardShortcut("l", modifiers: .command)
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "l" {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        isExpanded.toggle()
                    }
                    return nil
                }
                return event
            }
        }
    }

    // MARK: - Collapsed Bubble (circle)

    private var collapsedBubbleView: some View {
        Button(action: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isExpanded = true
            }
        }) {
            ZStack {
                // Flat circle background
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))

                // Subtle border
                Circle()
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)

                // Icon
                Image(systemName: activityManager.currentActivity.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(activityManager.currentActivity.color)
            }
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Expanded Tab

    private var expandedTabView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.8))

                Text("CodeMind Activity")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.9))

                Spacer()

                // Live indicator
                if activityManager.isActive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.green)
                    }
                }

                // Minimize button
                Button(action: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        isExpanded = false
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Stats bar
                    if activityManager.totalClassifications > 0 {
                        HStack(spacing: 16) {
                            StatBadge(
                                label: "Classified",
                                value: "\(activityManager.totalClassifications)"
                            )
                            StatBadge(
                                label: "Confidence",
                                value: String(format: "%.0f%%", activityManager.averageConfidence * 100),
                                color: confidenceColor(activityManager.averageConfidence)
                            )
                        }
                        .padding(.top, 8)
                    }

                    // Current activity
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CURRENT")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)

                        ExpandedActivityRow(
                            activity: activityManager.currentActivity,
                            isCurrentActivity: true
                        )
                    }

                    // Recent activities
                    if !activityManager.recentActivities.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("RECENT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.secondary)

                            let limit = activityManager.detailLevel == .detailed ? 10 : 5
                            ForEach(activityManager.recentActivities.prefix(limit)) { record in
                                ExpandedActivityRow(
                                    activity: record.activity,
                                    timestamp: record.timestamp
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.8 { return .green }
        if confidence >= 0.6 { return .yellow }
        return .orange
    }
}

// MARK: - Expanded Activity Row

struct ExpandedActivityRow: View {
    let activity: CodeMindActivity
    var timestamp: Date? = nil
    var isCurrentActivity: Bool = false

    @State private var isExpanded = false

    private var hasReasoning: Bool {
        activity.reasoning != nil && !activity.reasoning!.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - clickable if has reasoning
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    Circle()
                        .fill(activity.color.opacity(0.2))
                        .frame(width: 28, height: 28)

                    Image(systemName: activity.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(activity.color)
                }

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(activity.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.9))

                        if isCurrentActivity && activity.isActive {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        }
                    }

                    Text(activity.detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(activity.detail.contains("server") || activity.detail.contains("Server") || activity.detail.contains("cannot access") || activity.detail.contains("not connected") ? 3 : 1)
                }

                Spacer()

                // Expand indicator for items with reasoning
                if hasReasoning {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.6))
                }

                // Timestamp
                if let time = timestamp {
                    Text(timeAgo(time))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasReasoning {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Reasoning detail (when expanded)
            if isExpanded, let reasoning = activity.reasoning, !reasoning.isEmpty {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(activity.color.opacity(0.3))
                        .frame(width: 2)

                    Text(reasoning)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 38)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}

// MARK: - Stat Badge

struct StatBadge: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        LinearGradient(
            colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        CodeMindActivityOverlay()
    }
    .frame(width: 650, height: 550)
    .onAppear {
        CodeMindActivityManager.shared.setEnabled(true)
        CodeMindActivityManager.shared.setDetailLevel(.medium)
        CodeMindActivityManager.shared.recordActivity(.classified(
            emailSubject: "New Docket 25484 - Nike Campaign",
            type: "New Docket",
            confidence: 0.92,
            verified: true,
            reasoning: "Email contains docket number 25484 in subject line. Sender is from agency domain. Body mentions new project kickoff and budget approval."
        ))
        CodeMindActivityManager.shared.recordActivity(.classified(
            emailSubject: "RE: Final Assets Delivery",
            type: "Not Docket",
            confidence: 0.85,
            verified: false,
            reasoning: "This is a reply in an existing thread (RE: prefix). No new docket number found. Content discusses existing project deliverables."
        ))
    }
}
