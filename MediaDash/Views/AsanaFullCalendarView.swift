//
//  AsanaFullCalendarView.swift
//  MediaDash
//
//  Full 2-week Asana calendar: grid view. Click a day to expand; collapsible Sessions, Media Tasks, Tasks. Filter and tag colors.
//

import SwiftUI
import AppKit

private let fullCalendarDays = 14
private let gridColumns = 7

struct TaskDetailSheetItem: Identifiable {
    let id: String
    let taskGid: String
    let taskName: String?
}

struct AsanaFullCalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsManager: SettingsManager
    @ObservedObject var cacheManager: AsanaCacheManager
    var onClose: (() -> Void)?
    var onPrepElements: ((DocketInfo) -> Void)?

    @State private var isLoading = false
    @State private var selectedDay: Date?
    @State private var sessionsSectionExpanded = true
    @State private var mediaTasksSectionExpanded = true
    @State private var otherTasksSectionExpanded = true
    @State private var filterSessions = true
    @State private var filterMediaTasks = true
    @State private var filterOtherTasks = true

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

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        f.timeZone = TimeZone.current
        return f
    }()

    private var calendarDays: [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0..<fullCalendarDays).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func tasks(for date: Date) -> [AsanaTask] {
        let key = Self.dateOnlyFormatter.string(from: date)
        return cacheManager.cachedTasksTwoWeeks.filter { task in
            guard let due = task.effectiveDueDate, !due.isEmpty else { return false }
            return String(due.prefix(10)) == key
        }
    }

    private func sessions(for date: Date) -> [AsanaTask] {
        tasks(for: date).filter { $0.name.uppercased().contains("SESSION") }
    }

    private func isMediaTask(_ task: AsanaTask) -> Bool {
        let name = task.assignee?.name?.lowercased() ?? ""
        if name.contains("media") { return true }
        let tagNames = task.tags?.compactMap { $0.name?.lowercased() } ?? []
        if tagNames.contains(where: { $0.contains("media") }) { return true }
        return false
    }

    private func mediaTasks(for date: Date) -> [AsanaTask] {
        otherTasks(for: date).filter { isMediaTask($0) }
    }

    private func otherTasks(for date: Date) -> [AsanaTask] {
        tasks(for: date).filter { !$0.name.uppercased().contains("SESSION") }
    }

    private func otherTasksExcludingMedia(for date: Date) -> [AsanaTask] {
        otherTasks(for: date).filter { !isMediaTask($0) }
    }

    private func filteredCount(for date: Date) -> Int {
        var n = 0
        if filterSessions { n += sessions(for: date).count }
        if filterMediaTasks { n += mediaTasks(for: date).count }
        if filterOtherTasks { n += otherTasksExcludingMedia(for: date).count }
        return n
    }

    private static func asanaColorToSwiftUI(_ colorName: String?) -> Color {
        guard let name = colorName?.lowercased() else { return .blue }
        switch name {
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
        case "dark-brown", "light-brown": return .brown
        case "cool-gray", "light-gray": return .gray
        default: return .blue
        }
    }

    private func taskColor(_ task: AsanaTask) -> Color {
        Self.asanaColorToSwiftUI(task.tags?.first?.color)
    }

    private func taskKindBadge(_ task: AsanaTask) -> String? {
        let name = task.name.lowercased()
        // DEMOS and SUBMIT are synonymous
        if name.contains("demos") || name.contains("demo") || name.contains("submit") { return "Demos" }
        if name.contains("post") { return "Post" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading && cacheManager.cachedTasksTwoWeeks.isEmpty {
                loadingView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        calendarGridView
                        if let day = selectedDay {
                            dayDetailView(day)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            syncAll()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "calendar")
                .font(.system(size: 18, weight: .medium))
            Text("Asana Calendar — 2 weeks")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button(action: {
                if let onClose = onClose { onClose() } else { dismiss() }
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
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(0.8)
            Text("Loading calendar...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var calendarGridView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Calendar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                filterControls
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: gridColumns), spacing: 6) {
                ForEach(Array(calendarDays.enumerated()), id: \.offset) { index, date in
                    dayCell(date: date, isSelected: selectedDay.map { Calendar.current.isDate($0, inSameDayAs: date) } ?? false)
                }
            }
        }
    }

    private var filterControls: some View {
        HStack(spacing: 12) {
            Text("Show:")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Toggle("Sessions", isOn: $filterSessions)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Toggle("Media Tasks", isOn: $filterMediaTasks)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Toggle("Other Tasks", isOn: $filterOtherTasks)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
    }

    private func dayCell(date: Date, isSelected: Bool) -> some View {
        let count = filteredCount(for: date)
        let isToday = Calendar.current.isDateInToday(date)
        return Button(action: {
            selectedDay = date
        }) {
            VStack(spacing: 4) {
                Text(Self.shortDayFormatter.string(from: date))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 16, weight: isToday ? .bold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : (isToday ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.5)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func dayDetailView(_ date: Date) -> some View {
        let sessionList = sessions(for: date)
        let mediaList = mediaTasks(for: date)
        let otherList = otherTasksExcludingMedia(for: date)
        let dateLabel = Self.dayHeaderFormatter.string(from: date)
        let isToday = Calendar.current.isDateInToday(date)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(dateLabel)
                    .font(.system(size: 15, weight: .semibold))
                if isToday {
                    Text("Today")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
                Spacer()
                Button("Close") {
                    selectedDay = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom, 4)

            if sessionList.isEmpty && mediaList.isEmpty && otherList.isEmpty {
                Text("Nothing scheduled this day.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                if filterSessions && !sessionList.isEmpty {
                    collapsibleSection(
                        title: "Sessions",
                        count: sessionList.count,
                        isExpanded: $sessionsSectionExpanded
                    ) {
                        VStack(spacing: 4) {
                            ForEach(sessionList, id: \.gid) { task in
                                sessionRow(task)
                            }
                        }
                    }
                }
                if filterMediaTasks && !mediaList.isEmpty {
                    collapsibleSection(
                        title: "Media Tasks",
                        count: mediaList.count,
                        isExpanded: $mediaTasksSectionExpanded
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(mediaList, id: \.gid) { task in
                                taskRow(task)
                            }
                        }
                    }
                }
                if filterOtherTasks && !otherList.isEmpty {
                    collapsibleSection(
                        title: "Tasks",
                        count: otherList.count,
                        isExpanded: $otherTasksSectionExpanded
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(otherList, id: \.gid) { task in
                                taskRow(task)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private func collapsibleSection<Content: View>(
        title: String,
        count: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("(\(count))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded.wrappedValue {
                content()
            }
        }
    }

    private func sessionRow(_ task: AsanaTask) -> some View {
        let docket = cacheManager.docketInfoFromSession(task)
        let color = taskColor(task)
        let completed = task.completed == true
        return HStack {
            Button(action: {
                let item = TaskDetailSheetItem(id: task.gid, taskGid: task.gid, taskName: task.name)
                AsanaTaskDetailWindowManager.shared.show(
                    item: item,
                    asanaService: cacheManager.service,
                    config: AppConfig(settings: settingsManager.currentSettings),
                    settingsManager: settingsManager,
                    cacheManager: cacheManager,
                    onDismiss: {}
                )
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if completed {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Text(task.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .foregroundColor(.primary)
                        if let badge = taskKindBadge(task) {
                            Text(badge)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                        }
                    }
                    if let assignee = task.assignee?.name, !assignee.isEmpty {
                        Text(assignee)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button("Prep") {
                onPrepElements?(docket)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(8)
        .background(color.opacity(0.15))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(completed ? 0.65 : 1)
    }

    private func taskRow(_ task: AsanaTask) -> some View {
        let color = taskColor(task)
        let completed = task.completed == true
        return Button(action: {
            let item = TaskDetailSheetItem(id: task.gid, taskGid: task.gid, taskName: task.name)
            AsanaTaskDetailWindowManager.shared.show(
                item: item,
                asanaService: cacheManager.service,
                config: AppConfig(settings: settingsManager.currentSettings),
                settingsManager: settingsManager,
                cacheManager: cacheManager,
                onDismiss: {}
            )
        }) {
            HStack {
                HStack(spacing: 6) {
                    if completed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Text(task.name)
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    if let badge = taskKindBadge(task) {
                        Text(badge)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                    }
                }
                Spacer()
                if let assignee = task.assignee?.name, !assignee.isEmpty {
                    Text(assignee)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(color.opacity(0.15))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(completed ? 0.65 : 1)
    }

    private func syncAll() {
        isLoading = true
        Task {
            do {
                try await cacheManager.syncSessionsTwoWeeks(workspaceID: settingsManager.currentSettings.asanaWorkspaceID)
                try await cacheManager.syncTasksTwoWeeks(workspaceID: settingsManager.currentSettings.asanaWorkspaceID)
            } catch {
                print("⚠️ [FullCalendar] Sync failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                isLoading = false
            }
        }
    }
}
