//
//  AsanaCalendarView.swift
//  MediaDash
//
//  Asana calendar: sessions from today through the next 5 business days.
//

import SwiftUI
import AppKit

// MARK: - Calendar Day + Dockets

struct CalendarDaySection: Identifiable {
    let date: Date
    let dayLabel: String
    let isToday: Bool
    var dockets: [DocketInfo]
    var id: Date { date }
}

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
    
    private static let calendarDays = 6 // today + 5 business days
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
        var sections: [CalendarDaySection] = []
        
        // Get sessions from cache
        let sessions = cacheManager.cachedSessions
        
        // Build calendar days, skipping weekends (Saturday = 7, Sunday = 1 in weekday)
        var dayOffset = 0
        var businessDaysAdded = 0
        
        while businessDaysAdded < Self.calendarDays {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else {
                dayOffset += 1
                continue
            }
            
            let weekday = calendar.component(.weekday, from: dayDate)
            // Skip Saturday (7) and Sunday (1)
            if weekday == 7 || weekday == 1 {
                dayOffset += 1
                continue
            }
            
            let dateKey = Self.dateOnlyFormatter.string(from: dayDate)
            let dayLabel = Self.dayHeaderFormatter.string(from: dayDate)
            let isToday = dayOffset == 0
            
            // Filter sessions for this date and convert to DocketInfo for display
            let sessionsForDate = sessions.filter { session in
                guard let dueOn = session.due_on, !dueOn.isEmpty else { return false }
                let normalized = String(dueOn.prefix(10))
                return normalized == dateKey
            }
            
            // Convert AsanaTask sessions to DocketInfo for display
            let dockets = sessionsForDate.map { session -> DocketInfo in
                // Extract docket number from session name (e.g., "SESSION - 21419 Client Name")
                let docketNumber = extractDocketNumber(from: session.name) ?? "SESSION"
                let jobName = cleanSessionName(session.name)
                // Studio from task tags (e.g. "A - Blue", "B - Green", "C - Red", "M4 - Fuchsia")
                let firstTag = session.tags?.first
                let studio = firstTag?.name
                let studioColor = firstTag?.color
                
                return DocketInfo(
                    number: docketNumber,
                    jobName: jobName,
                    fullName: session.name,
                    updatedAt: session.modified_at,
                    createdAt: session.created_at,
                    metadataType: "SESSION",
                    subtasks: nil,
                    projectMetadata: nil,
                    dueDate: session.due_on,
                    taskGid: session.gid,
                    studio: studio,
                    studioColor: studioColor,
                    completed: session.completed
                )
            }
            
            sections.append(CalendarDaySection(
                date: dayDate,
                dayLabel: dayLabel,
                isToday: isToday,
                dockets: dockets
            ))
            
            businessDaysAdded += 1
            dayOffset += 1
        }
        return sections
    }
    
    /// Extract docket number from session name (e.g., "SESSION - 21419 Client" -> "21419")
    private func extractDocketNumber(from name: String) -> String? {
        // Pattern: 5 digits, optionally followed by -XX suffix (like -US, -CA)
        let pattern = #"\d{5}(?:-[A-Z]{1,3})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: name, options: [], range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range, in: name) else {
            return nil
        }
        return String(name[range])
    }
    
    /// Clean session name for display (remove "SESSION - " prefix, docket number, etc.)
    private func cleanSessionName(_ name: String) -> String {
        var cleaned = name
        // Remove "SESSION" prefix (case insensitive)
        if let range = cleaned.range(of: "SESSION\\s*[-–]?\\s*", options: [.regularExpression, .caseInsensitive]) {
            cleaned = String(cleaned[range.upperBound...])
        }
        // Remove docket number if at the start
        if let range = cleaned.range(of: "^\\d{5}(?:-[A-Z]{1,3})?\\s*[-–]?\\s*", options: .regularExpression) {
            cleaned = String(cleaned[range.upperBound...])
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "calendar")
                    .font(.system(size: 18, weight: .medium))
                Text("Asana Calendar")
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
            
            if isLoadingSessions && cacheManager.cachedSessions.isEmpty {
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
                        ForEach(calendarSections) { section in
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
                try await cacheManager.syncUpcomingSessions(workspaceID: settingsManager.currentSettings.asanaWorkspaceID)
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
                    
                    Text(docket.number)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(projectColor)
                        .cornerRadius(3)
                    
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
