import SwiftUI

// MARK: - Recent Dockets Section

/// A collapsible section showing recently used dockets
struct RecentDocketsSection: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @State private var isExpanded = true
    @State private var isHovered = false
    
    let onDocketSelected: (String) -> Void
    
    private var recentDockets: [String] {
        settingsManager.currentSettings.recentDockets
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Text("Recent")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    if !recentDockets.isEmpty {
                        Text("\(recentDockets.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.5))
                            .cornerRadius(8)
                    }
                    
                    Spacer()
                    
                    if isHovered && !recentDockets.isEmpty {
                        Button(action: {
                            settingsManager.clearRecentDockets()
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear recent dockets")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
            
            // Docket list
            if isExpanded && !recentDockets.isEmpty {
                VStack(spacing: 2) {
                    ForEach(recentDockets.prefix(5), id: \.self) { docket in
                        RecentDocketRow(
                            docketName: docket,
                            onSelect: { onDocketSelected(docket) }
                        )
                    }
                    
                    // Show more button if there are more than 5
                    if recentDockets.count > 5 {
                        MoreRecentsButton(
                            remainingCount: recentDockets.count - 5,
                            allDockets: recentDockets,
                            onDocketSelected: onDocketSelected
                        )
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
            
            // Empty state
            if isExpanded && recentDockets.isEmpty {
                Text("No recent dockets")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
        }
        .background(Color.clear)
    }
}

// MARK: - Recent Docket Row

struct RecentDocketRow: View {
    let docketName: String
    let onSelect: () -> Void
    
    @State private var isHovered = false
    
    private var docketNumber: String {
        let parts = docketName.split(separator: "_", maxSplits: 1)
        return parts.first.map(String.init) ?? docketName
    }
    
    private var jobName: String {
        let parts = docketName.split(separator: "_", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(isHovered ? .blue : .secondary)
                
                Text(docketNumber)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(isHovered ? .blue : .primary)
                
                if !jobName.isEmpty {
                    Text(jobName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - More Recents Button

struct MoreRecentsButton: View {
    let remainingCount: Int
    let allDockets: [String]
    let onDocketSelected: (String) -> Void
    
    @State private var isHovered = false
    @State private var showPopover = false
    
    var body: some View {
        Button(action: {
            showPopover.toggle()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                
                Text("\(remainingCount) more")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? Color.gray.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(isPresented: $showPopover, arrowEdge: .trailing) {
            RecentDocketsPopover(
                dockets: allDockets,
                onDocketSelected: { docket in
                    showPopover = false
                    onDocketSelected(docket)
                }
            )
        }
    }
}

// MARK: - Recent Dockets Popover

struct RecentDocketsPopover: View {
    let dockets: [String]
    let onDocketSelected: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Dockets")
                .font(.system(size: 13, weight: .semibold))
                .padding()
            
            Divider()
            
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(dockets, id: \.self) { docket in
                        RecentDocketRow(
                            docketName: docket,
                            onSelect: { onDocketSelected(docket) }
                        )
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 280, height: min(CGFloat(dockets.count) * 32 + 60, 350))
    }
}

// MARK: - Preview

#Preview {
    RecentDocketsSection(onDocketSelected: { _ in })
        .frame(width: 280)
        .environmentObject(SettingsManager())
}

