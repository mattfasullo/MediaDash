//
//  AsanaCalendarView.swift
//  MediaDash
//
//  Asana calendar: 2-day lookback plus today through the next 5 business days (data from 4-week session sync).
//

import SwiftUI
import AppKit

// MARK: - Asana Calendar View

struct AsanaCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var cacheManager: AsanaCacheManager
    /// When set (e.g. in a separate window), the header close button calls this instead of dismiss.
    var onClose: (() -> Void)?
    /// Callback when user taps "Prep Elements" on a session
    var onPrepElements: ((DocketInfo) -> Void)?
    
    @State private var isLoadingSessions = false
    /// When false, previous two days are hidden; arrow to the left of today expands them.
    @State private var showLookbackDays = false
    
    private static let lookbackDays = 2
    private static let upcomingBusinessDays = 6 // today + 5 business days
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()
    
    private static let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        f.timeZone = TimeZone.current
        return f
    }()
    
    private var calendarSections: [CalendarDaySection] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let sessions = cacheManager.cachedSessionsTwoWeeks

        func section(for dayDate: Date) -> CalendarDaySection {
            let dateKey = Self.dateOnlyFormatter.string(from: dayDate)
            let dayLabel = Self.dayHeaderFormatter.string(from: dayDate)
            let isToday = calendar.isDate(dayDate, inSameDayAs: startOfToday)
            
            // Filter sessions for this date and convert to DocketInfo for display
            let sessionsForDate = sessions.filter { session in
                guard let due = session.effectiveDueDate ?? session.due_on, !due.isEmpty else { return false }
                let normalized = String(due.prefix(10))
                return normalized == dateKey
            }
            
            let dockets = sessionsForDate.map { cacheManager.docketInfoFromSession($0) }
            
            return CalendarDaySection(
                date: dayDate,
                dayLabel: dayLabel,
                isToday: isToday,
                dockets: dockets
            )
        }

        var sections: [CalendarDaySection] = []

        // Explicit lookback section: always include the previous two calendar days.
        for daysBack in stride(from: Self.lookbackDays, through: 1, by: -1) {
            guard let dayDate = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) else { continue }
            sections.append(section(for: dayDate))
        }
        
        // Existing forward window: today + next business days (skip weekends).
        var dayOffset = 0
        var businessDaysAdded = 0
        while businessDaysAdded < Self.upcomingBusinessDays {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else {
                dayOffset += 1
                continue
            }
            let weekday = calendar.component(.weekday, from: dayDate)
            if weekday == 7 || weekday == 1 {
                dayOffset += 1
                continue
            }
            sections.append(section(for: dayDate))
            businessDaysAdded += 1
            dayOffset += 1
        }
        return sections
    }
    
    private var lookbackSections: [CalendarDaySection] {
        Array(calendarSections.prefix(Self.lookbackDays))
    }
    
    private var forwardSections: [CalendarDaySection] {
        Array(calendarSections.dropFirst(Self.lookbackDays))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 18, weight: .medium))
                Text("Session Prep")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: {
                    if let onClose = onClose {
                        onClose()
                    } else {
                        dismiss()
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))
            
            Divider()
            
            if isLoadingSessions && cacheManager.cachedSessionsTwoWeeks.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading sessions...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        // Small arrow to expand/collapse previous 2 days (to the left of today)
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showLookbackDays.toggle()
                            }
                        }) {
                            Image(systemName: showLookbackDays ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        
                        if showLookbackDays {
                            ForEach(lookbackSections) { section in
                                daySectionView(section)
                            }
                        }
                        ForEach(forwardSections) { section in
                            daySectionView(section)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 400)
        .onAppear {
            syncSessions()
        }
    }
    
    private func syncSessions() {
        isLoadingSessions = true
        
        Task {
            do {
                try await cacheManager.syncSessionsTwoWeeks(workspaceID: settingsManager.currentSettings.asanaWorkspaceID)
            } catch {
                print("⚠️ [Calendar] Failed to sync sessions: \(error.localizedDescription)")
            }
            
            await MainActor.run {
                isLoadingSessions = false
            }
        }
    }
    
    private func daySectionView(_ section: CalendarDaySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(section.dayLabel)
                    .font(.system(size: 13, weight: .semibold))
                if section.isToday {
                    Text("Today")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
                Spacer()
                Text("\(section.dockets.count) session\(section.dockets.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            if section.dockets.isEmpty {
                Text("No sessions")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
            } else {
                VStack(spacing: 4) {
                    // Use stable id (taskGid or fullName) so row @State survives parent re-renders.
                    // DocketInfo.id is UUID and is recreated when calendarSections recomputes, which
                    // would recreate rows and reset isExpanded.
                    ForEach(section.dockets, id: \.fullName) { docket in
                        AsanaCalendarRow(
                            docket: docket,
                            asanaService: cacheManager.service,
                            onPrepElements: { selectedDocket in
                                onPrepElements?(selectedDocket)
                            }
                        )
                    }
                }
            }
        }
    }
    
    private func emptyState(message: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.6))
            Text(message)
                .font(.system(size: 14, weight: .medium))
            Text(detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Calendar Row

struct AsanaCalendarRow: View {
    let docket: DocketInfo
    let asanaService: AsanaService
    let onPrepElements: (DocketInfo) -> Void
    
    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var assignees: [String] = []
    @State private var isLoadingAssignees = false
    
    private var projectColor: Color {
        if let colorName = docket.projectMetadata?.color {
            return asanaColorToSwiftUI(colorName)
        }
        return .blue
    }
    
    private func asanaColorToSwiftUI(_ colorName: String) -> Color {
        switch colorName.lowercased() {
        case "dark-pink", "hot-pink", "light-pink": return .pink
        case "dark-red", "red", "light-red": return .red
        case "dark-orange", "orange", "light-orange": return .orange
        case "dark-warm-gray", "warm-gray", "light-warm-gray": return Color(red: 0.6, green: 0.5, blue: 0.4)
        case "yellow", "light-yellow": return .yellow
        case "dark-green", "green", "light-green": return .green
        case "lime": return Color(red: 0.5, green: 0.8, blue: 0.3)
        case "dark-teal", "teal", "light-teal", "aqua": return .teal
        case "dark-blue", "blue", "light-blue": return .blue
        case "dark-purple", "purple", "light-purple", "fuchsia": return .purple
        case "dark-brown", "light-brown": return Color.brown
        case "cool-gray", "light-gray": return .gray
        default: return .blue
        }
    }
    
    private var isCompleted: Bool { docket.completed == true }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row (clickable)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
                if isExpanded && assignees.isEmpty && !isLoadingAssignees {
                    fetchAssignees()
                }
            }) {
                HStack(spacing: 10) {
                    // Completed check (still interactive)
                    if isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    // Expand/collapse indicator
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    
                    // Docket number badge - always visible
                    if docket.number != "—" && !docket.number.isEmpty {
                        Text(docket.displayNumber)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(projectColor)
                            .cornerRadius(4)
                    } else {
                        // Show a placeholder when docket number is not found
                        Text("No #")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(docket.jobName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let projectName = docket.projectMetadata?.projectName, !projectName.isEmpty {
                            Text(projectName)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    if let studio = docket.studio, !studio.isEmpty {
                        let badgeColor: Color = {
                            if let colorName = docket.studioColor {
                                return asanaColorToSwiftUI(colorName)
                            }
                            return Color.secondary
                        }()
                        Text(studio)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(badgeColor.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(badgeColor.opacity(0.2)))
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                        .padding(.horizontal, 12)
                    
                    // Involved parties
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Involved:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            if isLoadingAssignees {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                    Text("Loading...")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            } else if assignees.isEmpty {
                                Text("No assignees found")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            } else {
                                Text(assignees.joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    // Prep Elements button
                    Button(action: {
                        onPrepElements(docket)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "checklist")
                                .font(.system(size: 11))
                            Text("Prep Elements")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .opacity(isCompleted ? 0.65 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered || isExpanded ? Color.gray.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .onHover { isHovered = $0 }
    }
    
    private func fetchAssignees() {
        guard let taskGid = docket.taskGid else { return }
        
        isLoadingAssignees = true
        Task {
            do {
                let names = try await asanaService.fetchSubtaskAssignees(taskGid: taskGid)
                await MainActor.run {
                    assignees = names
                    isLoadingAssignees = false
                }
            } catch {
                await MainActor.run {
                    isLoadingAssignees = false
                }
            }
        }
    }
}

// Preview requires a real AsanaCacheManager instance
// #Preview {
//     AsanaCalendarView(cacheManager: AsanaCacheManager(asanaService: AsanaService()))
//         .environmentObject(SettingsManager())
//         .frame(width: 460, height: 500)
// }
