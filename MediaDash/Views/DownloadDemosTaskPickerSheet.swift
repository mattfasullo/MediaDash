//
//  DownloadDemosTaskPickerSheet.swift
//  MediaDash
//
//  Picker for Demos tasks from the calendar when user chose "Demo" in the download prompt.
//  Files are already staged; user picks which task to associate them with.
//

import SwiftUI

private func isDemosTask(_ task: AsanaTask) -> Bool {
    let name = task.name.lowercased()
    return name.contains("demos") || name.contains("demo ") || name.contains("submit")
}

struct DownloadDemosTaskPickerSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var cacheManager: AsanaCacheManager
    @ObservedObject var settingsManager: SettingsManager

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        f.timeZone = TimeZone.current
        return f
    }()

    private var demosTasks: [AsanaTask] {
        cacheManager.cachedTasksTwoWeeks.filter { isDemosTask($0) }
            .sorted { t1, t2 in
                let d1 = t1.effectiveDueDate ?? ""
                let d2 = t2.effectiveDueDate ?? ""
                return d1 < d2
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if demosTasks.isEmpty {
                emptyState
            } else {
                List(demosTasks) { task in
                    demosTaskRow(task)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 400, minHeight: 300, idealHeight: 400)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Associate with Demos Task")
                    .font(.system(size: 16, weight: .semibold))
                Text("Select the task these files belong to. You can then drag from staging to the task’s \"Who's submitting\" section.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No Demos tasks in the next 2 weeks")
                .font(.system(size: 14, weight: .medium))
            Text("Open Calendar to sync or check back later.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func demosTaskRow(_ task: AsanaTask) -> some View {
        let dueLabel = task.effectiveDueDate.flatMap { due -> String? in
            let key = String(due.prefix(10))
            guard let date = Self.dateOnlyFormatter.date(from: key) else { return nil }
            return Self.dayFormatter.string(from: date)
        } ?? "No date"

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
            isPresented = false
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    if let assignee = task.assignee?.name, !assignee.isEmpty {
                        Text(assignee)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Text(dueLabel)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
