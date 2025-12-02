import SwiftUI

/// iOS 26-style floating activity bubble for CodeMind
struct CodeMindActivityOverlay: View {
    @ObservedObject var activityManager = CodeMindActivityManager.shared
    
    var body: some View {
        if activityManager.isEnabled {
            FloatingActivityBubble()
        }
    }
}

// MARK: - Static Activity Bubble

struct FloatingActivityBubble: View {
    @ObservedObject var activityManager = CodeMindActivityManager.shared
    
    // Expansion state
    @State private var isExpanded = false
    
    // Pulse animation for active state
    @State private var pulseScale: CGFloat = 1.0
    
    private let bubbleSize: CGFloat = 56
    private let expandedWidth: CGFloat = 300
    private let expandedHeight: CGFloat = 350
    private let edgePadding: CGFloat = 15
    
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                
                if isExpanded {
                    expandedView
                        .frame(width: expandedWidth, height: expandedHeight)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5).combined(with: .opacity),
                            removal: .scale(scale: 0.8).combined(with: .opacity)
                        ))
                } else {
                    bubbleView
                        .frame(width: bubbleSize, height: bubbleSize)
                }
            }
            .padding(.trailing, edgePadding)
            .padding(.bottom, edgePadding)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isExpanded)
    }
    
    // MARK: - Bubble View (Collapsed)
    
    private var bubbleView: some View {
        ZStack {
            // Outer glow when active
            if activityManager.isActive {
                Circle()
                    .fill(activityManager.currentActivity.color.opacity(0.3))
                    .frame(width: bubbleSize + 20, height: bubbleSize + 20)
                    .blur(radius: 10)
                    .scaleEffect(pulseScale)
            }
            
            // Glass bubble
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.25),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.4),
                                    Color.white.opacity(0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: .black.opacity(0.25), radius: 15, x: 0, y: 8)
            
            // Inner content
            VStack(spacing: 2) {
                Image(systemName: activityManager.currentActivity.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(activityManager.currentActivity.color)
                
                if activityManager.isActive {
                    // Tiny activity indicator dots
                    HStack(spacing: 2) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(activityManager.currentActivity.color)
                                .frame(width: 3, height: 3)
                                .opacity(pulseScale > 1.0 + Double(i) * 0.03 ? 1 : 0.3)
                        }
                    }
                }
            }
        }
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isExpanded = true
            }
        }
        .onChange(of: activityManager.isActive) { _, isActive in
            if isActive {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseScale = 1.1
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    pulseScale = 1.0
                }
            }
        }
    }
    
    // MARK: - Expanded View
    
    private var expandedView: some View {
        VStack(spacing: 0) {
            // Header with minimize button
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                
                Text("CodeMind Activity")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
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
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            
            Divider()
                .background(Color.white.opacity(0.1))
            
            // Content based on detail level
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
                            .foregroundColor(.white.opacity(0.4))
                        
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
                                .foregroundColor(.white.opacity(0.4))
                            
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
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.black.opacity(0.4))
                
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.3),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .shadow(color: .black.opacity(0.4), radius: 25, x: 0, y: 15)
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
    
    var body: some View {
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
                        .foregroundColor(.white.opacity(0.9))
                    
                    if isCurrentActivity && activity.isActive {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
                
                Text(activity.detail)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Timestamp
            if let time = timestamp {
                Text(timeAgo(time))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.vertical, 4)
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
    var color: Color = .white
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
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
            verified: true
        ))
    }
}
