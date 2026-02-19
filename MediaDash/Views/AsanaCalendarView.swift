//
//  AsanaCalendarView.swift
//  MediaDash
//
//  Asana calendar: 2-day lookback plus today through the next 5 business days.
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
        let sessions = cacheManager.cachedSessions

        func section(for dayDate: Date) -> CalendarDaySection {
            let dateKey = Self.dateOnlyFormatter.string(from: dayDate)
            let dayLabel = Self.dayHeaderFormatter.string(from: dayDate)
            let isToday = calendar.isDate(dayDate, inSameDayAs: startOfToday)
            
            // Filter sessions for this date and convert to DocketInfo for display
            let sessionsForDate = sessions.filter { session in
                guard let dueOn = session.due_on, !dueOn.isEmpty else { return false }
                let normalized = String(dueOn.prefix(10))
                return normalized == dateKey
            }
            
            // Convert AsanaTask sessions to DocketInfo for display
            let dockets = sessionsForDate.map { session -> DocketInfo in
                // Extract docket number with priority:
                // 1. From session name (e.g., "SESSION - 21419 Client Name")
                // 2. From custom fields
                // 3. From project name (e.g., "25464_TD Insurance Golden Ticket")
                // 4. Fallback to "—"
                var docketNumber = extractDocketNumber(from: session.name) ?? extractDocketFromCustomFields(session)
                
                // Try to extract from project name if not found
                if docketNumber == nil, let memberships = session.memberships {
                    for membership in memberships {
                        if let projectName = membership.project?.name, !projectName.isEmpty {
                            if let projectDocket = extractDocketNumber(from: projectName) {
                                docketNumber = projectDocket
                                break
                            }
                        }
                    }
                }
                
                let finalDocketNumber = docketNumber ?? "—"
                let jobName = cleanSessionName(session.name)
                
                // Studio from task tags (e.g. "A - Blue", "B - Green", "C - Red", "M4 - Fuchsia")
                let firstTag = session.tags?.first
                let studio = firstTag?.name
                let studioColor = firstTag?.color
                
                return DocketInfo(
                    number: finalDocketNumber,
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
    
    /// Extract docket number from session name (e.g., "SESSION - 21419 Client" -> "21419")
    private func extractDocketNumber(from name: String) -> String? {
        // First try: Pattern for 5 digits (standard), optionally followed by -XX suffix (like -US, -CA)
        let standardPattern = #"\d{5}(?:-[A-Z]{1,3})?"#
        if let regex = try? NSRegularExpression(pattern: standardPattern, options: []) {
            let nsString = name as NSString
            let range = NSRange(location: 0, length: nsString.length)
            if let match = regex.firstMatch(in: name, options: [], range: range),
               let swiftRange = Range(match.range, in: name) {
                return String(name[swiftRange])
            }
        }
        
        // Fallback: Try 4-6 digits (more flexible for edge cases)
        let flexiblePattern = #"\d{4,6}(?:-[A-Z]{1,3})?"#
        if let regex = try? NSRegularExpression(pattern: flexiblePattern, options: []) {
            let nsString = name as NSString
            let range = NSRange(location: 0, length: nsString.length)
            if let match = regex.firstMatch(in: name, options: [], range: range),
               let swiftRange = Range(match.range, in: name) {
                let found = String(name[swiftRange])
                // Prefer 5-digit matches, but accept 4-6 if that's all we find
                return found
            }
        }
        
        return nil
    }
    
    /// Try to extract docket number from custom fields if not found in name
    private func extractDocketFromCustomFields(_ session: AsanaTask) -> String? {
        // First, check common custom field names for docket number
        let docketFieldNames = ["Docket", "Docket Number", "Docket #", "Docket#", "Job Number", "Job #"]
        for fieldName in docketFieldNames {
            if let value = session.getCustomFieldValue(name: fieldName), !value.isEmpty {
                // Extract just the number part if it contains other text
                if let number = extractDocketNumber(from: value) {
                    return number
                }
                // If it's already just a number (5 digits with optional suffix), return it
                if value.range(of: #"^\d{5}(?:-[A-Z]{1,3})?$"#, options: .regularExpression) != nil {
                    return value
                }
                // Also check for any sequence of 4-6 digits (more flexible)
                if let flexibleMatch = value.range(of: #"\d{4,6}(?:-[A-Z]{1,3})?"#, options: .regularExpression) {
                    return String(value[flexibleMatch])
                }
                // If the value looks like it might be a docket number (starts with digits), try to extract it
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if trimmed.range(of: #"^\d"#, options: .regularExpression) != nil {
                    // Extract first sequence of digits
                    if let digitMatch = trimmed.range(of: #"\d+"#, options: .regularExpression) {
                        let digits = String(trimmed[digitMatch])
                        // If it's 4-6 digits, use it
                        if digits.count >= 4 && digits.count <= 6 {
                            return digits
                        }
                    }
                }
            }
        }
        
        // If not found in named fields, check ALL custom fields for values that look like docket numbers
        if let customFields = session.custom_fields {
            for field in customFields {
                guard let value = field.display_value, !value.isEmpty else { continue }
                // Skip if this field name contains "name" or "description" (likely not a docket number)
                let fieldNameLower = field.name.lowercased()
                if fieldNameLower.contains("name") || fieldNameLower.contains("description") || fieldNameLower.contains("note") {
                    continue
                }
                // Check if value looks like a docket number
                if let number = extractDocketNumber(from: value) {
                    return number
                }
                // Check for 4-6 digit sequences
                if let flexibleMatch = value.range(of: #"\d{4,6}(?:-[A-Z]{1,3})?"#, options: .regularExpression) {
                    return String(value[flexibleMatch])
                }
            }
        }
        
        return nil
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
