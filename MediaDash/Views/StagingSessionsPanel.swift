//
//  StagingSessionsPanel.swift
//  MediaDash
//
//  Today + next day-with-sessions; work-picture / prep folder targets (Finder + drop to copy).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shared by compact, dashboard, and desktop staging headers.
enum StagingCenterContentMode: String, CaseIterable {
    case files = "Files"
    case sessions = "Sessions"
}

/// Hover callout: destination label + horizontally wiggling swap arrows.
private struct StagingHeaderHoverBubble: View {
    let destinationLabel: String

    var body: some View {
        HStack(spacing: 6) {
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let nudge = sin(t * 5.5) * 2.2
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .offset(x: nudge)
            }
            .frame(width: 14, height: 12)

            Text(destinationLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .offset(y: -36)
        .allowsHitTesting(false)
    }
}

/// Header control that switches between staged files and sessions; shows a small hover bubble with the view you’ll open on click.
struct StagingHeaderModeToggleButton: View {
    @Binding var selection: StagingCenterContentMode
    @State private var isHovered = false

    private var hoverHint: String {
        selection == .files ? "Sessions" : "Staging"
    }

    var body: some View {
        Button {
            selection = selection == .files ? .sessions : .files
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection == .files ? "tray.2.fill" : "calendar")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18)
                Text(selection == .files ? "Staging" : "Sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 36)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.09 : 0))
            )
        }
        .buttonStyle(.plain)
        .zIndex(isHovered ? 2 : 0)
        .background(alignment: .top) {
            if isHovered {
                StagingHeaderHoverBubble(destinationLabel: hoverHint)
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityLabel("Switch between staged files and sessions")
        .accessibilityHint("Switches to \(hoverHint)")
    }
}

struct StagingSessionsPanel: View {
    /// Avoid `@ObservedObject` here: `syncProgress` and other fields update constantly; this panel only needs
    /// session list changes (`cachedSessions` / `lastSessionSyncDate`).
    let cacheManager: AsanaCacheManager
    @EnvironmentObject var settingsManager: SettingsManager
    let prepDate: Date

    @State private var refreshToken = UUID()
    @State private var sessionsSections: [CalendarDaySection] = []
    @State private var isSyncingSessions = false
    @State private var createPrepError: String?
    @State private var creatingSessionKey: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if isSyncingSessions && cacheManager.cachedSessions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.65)
                        Text("Loading sessions…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(sessionsSections) { section in
                        StagingSessionsCollapsibleDay(
                            section: section,
                            prepDate: prepDate,
                            refreshToken: refreshToken,
                            creatingSessionKey: $creatingSessionKey,
                            onCreatedPrep: { refreshToken = UUID() },
                            onCreateError: { createPrepError = $0 }
                        )
                        .environmentObject(settingsManager)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            reloadDaySections()
            syncSessionsIfNeeded()
        }
        .onReceive(cacheManager.$cachedSessions) { _ in
            reloadDaySections()
        }
        .onReceive(cacheManager.$lastSessionSyncDate) { _ in
            reloadDaySections()
            refreshToken = UUID()
        }
        .onChange(of: settingsManager.currentSettings.serverBasePath) { _, _ in
            reloadDaySections()
            refreshToken = UUID()
        }
        .alert("Could not create prep folder", isPresented: Binding(
            get: { createPrepError != nil },
            set: { if !$0 { createPrepError = nil } }
        )) {
            Button("OK", role: .cancel) { createPrepError = nil }
        } message: {
            Text(createPrepError ?? "")
        }
    }

    private func syncSessionsIfNeeded() {
        guard !isSyncingSessions else { return }
        isSyncingSessions = true
        Task {
            try? await cacheManager.syncUpcomingSessions(workspaceID: settingsManager.currentSettings.asanaWorkspaceID)
            await MainActor.run {
                isSyncingSessions = false
                reloadDaySections()
                refreshToken = UUID()
            }
        }
    }

    private func reloadDaySections() {
        sessionsSections = cacheManager.sessionDaysTodayAndNextWithSessions()
    }

}

// MARK: - Day expand/collapse (saved per calendar day)

private enum PrepStagingDayExpansion {
    private static let keyPrefix = "prepStaging.dayExpanded."
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private static func storageKey(for date: Date) -> String {
        keyPrefix + dayKeyFormatter.string(from: Calendar.current.startOfDay(for: date))
    }

    /// Default is expanded when the user has never toggled this day.
    static func isExpanded(date: Date) -> Bool {
        let k = storageKey(for: date)
        if UserDefaults.standard.object(forKey: k) == nil { return true }
        return UserDefaults.standard.bool(forKey: k)
    }

    static func setExpanded(_ value: Bool, date: Date) {
        UserDefaults.standard.set(value, forKey: storageKey(for: date))
    }
}

// MARK: - Collapsible day block

private struct StagingSessionsCollapsibleDay: View {
    let section: CalendarDaySection
    let prepDate: Date
    let refreshToken: UUID
    @Binding var creatingSessionKey: String?
    let onCreatedPrep: () -> Void
    let onCreateError: (String) -> Void

    @State private var isExpanded = true
    @State private var didLoadExpansionPreference = false

    private var dayTint: Color {
        section.isToday ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.045)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isExpanded.toggle()
                }
                PrepStagingDayExpansion.setExpanded(isExpanded, date: section.date)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, alignment: .center)
                    Text(section.dayLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    if section.isToday {
                        Text("Today")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text("\(section.dockets.count) session\(section.dockets.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if section.dockets.isEmpty {
                        Text("No sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                            .cornerRadius(6)
                    } else {
                        ForEach(section.dockets, id: \.fullName) { docket in
                            StagingSessionFolderRow(
                                docket: docket,
                                prepDate: prepDate,
                                refreshToken: refreshToken,
                                creatingSessionKey: $creatingSessionKey,
                                onCreatedPrep: onCreatedPrep,
                                onCreateError: onCreateError
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .padding(.top, 2)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(dayTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(section.isToday ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .onAppear {
            guard !didLoadExpansionPreference else { return }
            isExpanded = PrepStagingDayExpansion.isExpanded(date: section.date)
            didLoadExpansionPreference = true
        }
    }
}

// MARK: - Session row

private struct StagingSessionFolderRow: View {
    let docket: DocketInfo
    let prepDate: Date
    let refreshToken: UUID
    @Binding var creatingSessionKey: String?
    let onCreatedPrep: () -> Void
    let onCreateError: (String) -> Void

    @EnvironmentObject var settingsManager: SettingsManager

    @State private var wpFolders: [(name: String, path: String)] = []
    @State private var prepFolders: [(name: String, path: String)] = []

    private var sessionKey: String {
        docket.taskGid ?? docket.fullName
    }

    /// Identity for rescanning server paths off the main thread (see `.task(id:)`).
    private var folderScanTaskID: String {
        "\(sessionKey)|\(refreshToken.uuidString)|\(settingsManager.currentSettings.serverBasePath)"
    }

    private var docketHasValidNumber: Bool {
        let d = docket.displayNumber
        guard d != "—", d.range(of: #"^\d{5}"#, options: .regularExpression) != nil else { return false }
        return true
    }

    private var isCreating: Bool {
        creatingSessionKey == sessionKey
    }

    private var sessionAccent: Color? {
        AsanaStudioColor.resolvedAccentColor(studio: docket.studio, apiColor: docket.studioColor)
    }

    /// Muted tints to separate “Work picture” vs “Prep” blocks without loud color.
    private var workPictureSectionTint: Color { Color(red: 0.72, green: 0.46, blue: 0.2) }
    private var prepSectionTint: Color { Color(red: 0.36, green: 0.4, blue: 0.72) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill((sessionAccent ?? Color.secondary).opacity(sessionAccent != nil ? 0.5 : 0.22))
                .frame(width: 3)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(docket.displayNumber)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(docket.jobName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(minWidth: 72, alignment: .leading)
                    if let studio = docket.studio, !studio.isEmpty {
                        let chip = AsanaStudioColor.studioChipColors(studio: studio, apiColor: docket.studioColor)
                        Text(studio)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(chip.foreground)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(chip.background))
                            .overlay(Capsule().strokeBorder(chip.foreground.opacity(0.22), lineWidth: 0.5))
                    }
                    Spacer(minLength: 0)
                }

                folderChipRow(
                    title: "Work picture",
                    folders: wpFolders,
                    emptyLabel: "No work picture folder",
                    sectionTint: workPictureSectionTint
                )

                prepRow
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.52))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .task(id: folderScanTaskID) {
            await scanFoldersFromServer()
        }
    }

    /// `MediaLogic.existing*` walks every year folder on the server; must not run during SwiftUI body recomputation
    /// (e.g. on every Asana sync progress tick).
    private func scanFoldersFromServer() async {
        let docketNum = docket.displayNumber
        let valid = docketHasValidNumber
        let config = AppConfig(settings: settingsManager.currentSettings)
        guard valid else {
            wpFolders = []
            prepFolders = []
            return
        }
        async let wp = Task.detached {
            MediaLogic.existingWorkPictureFolders(docketNumber: docketNum, config: config)
        }.value
        async let prep = Task.detached {
            MediaLogic.existingPrepFolders(docketNumber: docketNum, config: config)
        }.value
        let (w, p) = await (wp, prep)
        wpFolders = w
        prepFolders = p
    }

    @ViewBuilder
    private var prepRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading("Prep", tint: prepSectionTint)
            if !prepFolders.isEmpty {
                FlowFolderChips(folders: prepFolders)
            } else if docketHasValidNumber {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No prep folder yet")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Button(action: createPrep) {
                        if isCreating {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.55)
                                Text("Creating…")
                            }
                        } else {
                            Text("Create prep folder")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isCreating)
                }
            } else {
                Text("No docket — cannot match folders")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func createPrep() {
        creatingSessionKey = sessionKey
        Task { @MainActor in
            defer { creatingSessionKey = nil }
            do {
                let url = try MediaLogic.createPrepFolderForSession(
                    docket: docket,
                    prepDateFallback: prepDate,
                    config: AppConfig(settings: settingsManager.currentSettings)
                )
                if settingsManager.currentSettings.openPrepFolderWhenDone {
                    NSWorkspace.shared.open(url)
                }
                onCreatedPrep()
            } catch {
                onCreateError(error.localizedDescription)
            }
        }
    }

    private func sectionHeading(_ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint.opacity(0.75))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.92))
        }
    }

    private func folderChipRow(
        title: String,
        folders: [(name: String, path: String)],
        emptyLabel: String,
        sectionTint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading(title, tint: sectionTint)
            if folders.isEmpty {
                Text(emptyLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                FlowFolderChips(folders: folders)
            }
        }
    }
}

// MARK: - Chips + drop

private struct FlowFolderChips: View {
    let folders: [(name: String, path: String)]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(folders, id: \.path) { item in
                    FolderDropChip(label: item.name, path: item.path)
                }
            }
        }
    }
}

private struct FolderDropChip: View {
    let label: String
    let path: String

    @State private var isTargeted = false

    var body: some View {
        Button(action: openInFinder) {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isTargeted ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isTargeted ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("Open in Finder — drop files to copy here")
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            copyDroppedFiles(from: providers, toDirectory: URL(fileURLWithPath: path))
            return true
        }
    }

    private func openInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - File copy helpers

private func copyDroppedFiles(from providers: [NSItemProvider], toDirectory destDir: URL) {
    let fm = FileManager.default
    for provider in providers {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            DispatchQueue.main.async {
                if isDir.boolValue {
                    copyDirectoryContents(from: url, to: destDir, fm: fm)
                } else {
                    copyFileToPrepDir(from: url, destDir: destDir, fm: fm)
                }
            }
        }
    }
}

private func copyFileToPrepDir(from source: URL, destDir: URL, fm: FileManager) {
    let name = source.lastPathComponent
    var dest = destDir.appendingPathComponent(name)
    if fm.fileExists(atPath: dest.path) {
        dest = uniqueDestinationURL(in: destDir, fileName: name, fm: fm)
    }
    do {
        try fm.copyItem(at: source, to: dest)
    } catch {
        print("⚠️ [StagingSessions] copy failed: \(error.localizedDescription)")
    }
}

private func copyDirectoryContents(from sourceDir: URL, to destParent: URL, fm: FileManager) {
    guard let items = try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) else { return }
    for item in items {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            // Shallow: only copy files at top level of dropped folder
            copyDirectoryContents(from: item, to: destParent, fm: fm)
        } else {
            copyFileToPrepDir(from: item, destDir: destParent, fm: fm)
        }
    }
}

private func uniqueDestinationURL(in directory: URL, fileName: String, fm: FileManager) -> URL {
    let base = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    var n = 1
    var candidate = directory.appendingPathComponent(fileName)
    while fm.fileExists(atPath: candidate.path) {
        let stem = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        candidate = directory.appendingPathComponent(stem)
        n += 1
    }
    return candidate
}
