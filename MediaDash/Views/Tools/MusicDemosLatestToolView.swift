import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let musicDemosLineageOverridesDefaultsKey = "musicDemosLineageOverridesByStem"

private final class ScanCancellation: @unchecked Sendable {
    /// Set from main thread; read from scan `Task.detached`.
    nonisolated(unsafe) var requested = false
}

/// Project toolbar + three-column browser: writers (roster-deduped) | tracks by lineage | file versions.
struct MusicDemosLatestToolView: View {
    @EnvironmentObject private var mediaManager: MediaManager
    @EnvironmentObject private var settingsManager: SettingsManager

    @State private var selectedYear: Int
    @State private var projectFolderURL: URL?
    @State private var rows: [MusicDemosLatestVersionsIndexer.IndexedFile] = []
    @State private var scanErrors: [String] = []
    @State private var isScanning = false
    @State private var scanError: String?
    @State private var selectedWriterCanon: String?
    @State private var selectedRowID: String?
    @State private var writerRosterRevision = 0
    @State private var editWriterCanon: String?
    @State private var editWriterNameDraft = ""

    init() {
        let y = Calendar.current.component(.year, from: Date())
        _selectedYear = State(initialValue: y)
    }

    private var musicDemosRoot: URL {
        mediaManager.config.getMusicDemosRoot(for: selectedYear)
    }

    private var folderTokensLongestFirst: [String] {
        _ = writerRosterRevision
        return MusicDemosWriterResolver.knownFolderTokensLongestFirst(
            serverWriters: mediaManager.config.loadWritersFromServer(),
            composerInitials: settingsManager.currentSettings.composerInitials,
            displayNameForInitials: settingsManager.currentSettings.displayNameForInitials
        )
    }

    private func canonicalWriterKey(_ raw: String) -> String {
        MusicDemosWriterResolver.canonicalFolder(raw: raw, tokens: folderTokensLongestFirst)
    }

    private func writerDisplayLabel(_ canon: String) -> String {
        _ = writerRosterRevision
        return MusicDemosWriterResolver.displayName(
            canonicalFolder: canon,
            serverWriters: mediaManager.config.loadWritersFromServer(),
            settings: settingsManager.currentSettings
        )
    }

    private var canonicalWriterKeysSorted: [String] {
        Array(Set(rows.map { canonicalWriterKey($0.writerKey) })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func rowsForCanonicalWriter(_ canon: String) -> [MusicDemosLatestVersionsIndexer.IndexedFile] {
        rows.filter { canonicalWriterKey($0.writerKey) == canon }
    }

    private static let scoringHelpText =
        "Uses numbered round folders (higher number = newer wave), then parsed revision / option / embedded dates, then file date and format (WAV before MP3). Grouped by writer and family (palette colours help match renames across rounds)."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            projectToolbar

            if projectFolderURL == nil {
                ContentUnavailableView(
                    "Choose a project",
                    systemImage: "folder",
                    description: Text("Pick a folder inside Music Demos for the selected year, then scan.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
            } else {
                NavigationSplitView {
                    writerSidebarColumn
                } content: {
                    writerTracksMiddleColumn
                        .navigationSplitViewColumnWidth(min: 300, ideal: 440, max: 720)
                } detail: {
                    trackVersionsDetailColumn
                        .navigationSplitViewColumnWidth(min: 320, ideal: 480, max: 900)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selectedYear) { _, _ in
            projectFolderURL = nil
            rows = []
            scanError = nil
            scanErrors = []
            selectedWriterCanon = nil
            selectedRowID = nil
        }
        .onChange(of: projectFolderURL) { _, _ in
            selectedWriterCanon = nil
            selectedRowID = nil
        }
        .onChange(of: rows.count) { _, _ in
            pruneSelectionsAfterDataChange()
        }
        .onChange(of: selectedWriterCanon) { _, _ in
            selectedRowID = nil
        }
        .sheet(isPresented: Binding(
            get: { editWriterCanon != nil },
            set: { if !$0 { editWriterCanon = nil } }
        )) {
            editWriterNameSheet
        }
    }

    private func pruneSelectionsAfterDataChange() {
        if rows.isEmpty {
            selectedWriterCanon = nil
            selectedRowID = nil
            return
        }
        let keys = Set(rows.map { canonicalWriterKey($0.writerKey) })
        if let w = selectedWriterCanon, !keys.contains(w) {
            selectedWriterCanon = nil
            selectedRowID = nil
        }
        if let id = selectedRowID, !rows.contains(where: { $0.id == id }) {
            selectedRowID = nil
        }
    }

    @State private var activeCancel: ScanCancellation?

    // MARK: Toolbar + home

    private var projectToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Music demos")
                .font(.title3.weight(.semibold))

            Text("Newer round wins, then rev / opt / embedded dates, then modified date & format (WAV before MP3).")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(Self.scoringHelpText)
                .accessibilityHint(Self.scoringHelpText)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker("Year", selection: $selectedYear) {
                    ForEach(yearRange, id: \.self) { y in
                        Text(String(y)).tag(y)
                    }
                }
                .frame(width: 92)

                if let projectFolderURL {
                    HStack(spacing: 4) {
                        Text("Project")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(projectFolderURL.lastPathComponent)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(projectFolderURL.path)
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                }

                Spacer(minLength: 8)

                Button("Choose project folder…") {
                    presentFolderPicker()
                }
                .disabled(isScanning)
                .controlSize(.small)

                Button("Scan") {
                    runScan(cancellation: ScanCancellation())
                }
                .disabled(isScanning || projectFolderURL == nil)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)

                Button("Cancel scan") {
                    activeCancel?.requested = true
                }
                .disabled(!isScanning)
                .controlSize(.small)

                Button("Export CSV…") {
                    exportCSV()
                }
                .disabled(rows.isEmpty)
                .controlSize(.small)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Music Demos root")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize()
                Text(musicDemosRoot.path)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isScanning {
                ProgressView("Scanning…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let scanError {
                Text(scanError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }

            if !scanErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Partial scan issues")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                    ForEach(Array(scanErrors.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Writer name (roster)

    private var editWriterNameSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $editWriterNameDraft)
                        .frame(minWidth: 280)
                } header: {
                    Text("Writer")
                } footer: {
                    if editWriterCanon != nil {
                        Text("The folder token on disk is not renamed. Names are saved to the shared writers list when available, and to this profile display-name map.")
                            .font(.caption)
                    }
                }
                if let canon = editWriterCanon {
                    Section("Folder token") {
                        Text(canon)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit display name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        editWriterCanon = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let canon = editWriterCanon {
                            persistWriterDisplayName(canonicalFolder: canon, displayName: editWriterNameDraft)
                        }
                        editWriterCanon = nil
                    }
                    .disabled(editWriterNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 220)
    }

    private func persistWriterDisplayName(canonicalFolder: String, displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        mediaManager.config.updateWriterDisplayName(folderToken: canonicalFolder, displayName: trimmed)

        var s = settingsManager.currentSettings
        var map = s.displayNameForInitials ?? [:]
        map[canonicalFolder] = trimmed
        s.displayNameForInitials = map.isEmpty ? nil : map
        settingsManager.currentSettings = s
        settingsManager.saveCurrentProfile()

        mediaManager.updateConfig(settings: settingsManager.currentSettings)
        writerRosterRevision += 1
    }

    // MARK: - Split columns (tree: writers | tracks | versions)

    private var writerSidebarColumn: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No writers yet",
                    systemImage: "person.2",
                    description: Text("Run Scan in the toolbar after choosing a project folder.")
                )
            } else {
                List(canonicalWriterKeysSorted, id: \.self, selection: $selectedWriterCanon) { canon in
                    let writerRows = rowsForCanonicalWriter(canon)
                    let demoLines = Set(writerRows.map(\.lineageKey)).count
                    let label = writerDisplayLabel(canon)
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                            if label.caseInsensitiveCompare(canon) != .orderedSame {
                                Text(canon)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(writerRows.count) variant\(writerRows.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            if demoLines != writerRows.count {
                                Text("\(demoLines) line\(demoLines == 1 ? "" : "s")")
                                    .foregroundStyle(.tertiary)
                                    .font(.caption2)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Edit display name…") {
                            editWriterCanon = canon
                            editWriterNameDraft = writerDisplayLabel(canon)
                        }
                    }
                }
            }
        }
        .navigationTitle("Writers")
    }

    @ViewBuilder
    private var writerTracksMiddleColumn: some View {
        if rows.isEmpty {
            ContentUnavailableView("Scan first", systemImage: "waveform", description: Text("Indexing fills the writer list."))
        } else if selectedWriterCanon == nil {
            ContentUnavailableView(
                "Select a writer",
                systemImage: "arrow.left",
                description: Text("Pick a composer in the first column. Folders like “BG ~ Stems Only” merge with **BG** when both match your writer roster.")
            )
        } else if let canon = selectedWriterCanon {
            writerTracksListView(canonicalWriterKey: canon)
        }
    }

    @ViewBuilder
    private var trackVersionsDetailColumn: some View {
        if let id = selectedRowID, let row = rows.first(where: { $0.id == id }) {
            trackVersionsContent(for: row)
        } else {
            ContentUnavailableView(
                "Select a track",
                systemImage: "waveform",
                description: Text("Choose a variant in the middle column to see versions across rounds.")
            )
        }
    }

    /// One section per `lineageKey` (same demo line); rows are deliverable variants (DNU, ALT, REV, …).
    private func writerTracksListView(canonicalWriterKey canon: String) -> some View {
        let tracks = rowsForCanonicalWriter(canon)
        let byLineage = Dictionary(grouping: tracks, by: \.lineageKey)
        let sortedLineageKeys = byLineage.keys.sorted { lk1, lk2 in
            let a = byLineage[lk1]!.first!
            let b = byLineage[lk2]!.first!
            return lineageSectionSortKey(a).localizedCaseInsensitiveCompare(lineageSectionSortKey(b)) == .orderedAscending
        }

        return List(selection: $selectedRowID) {
            ForEach(sortedLineageKeys, id: \.self) { lineageKey in
                let group = byLineage[lineageKey]!.sorted { a, b in
                    a.displayVariant.localizedCaseInsensitiveCompare(b.displayVariant) == .orderedAscending
                }
                Section {
                    ForEach(group) { row in
                        trackVariantRowInLineageSection(row)
                            .tag(row.id)
                    }
                } header: {
                    lineageSectionHeaderView(for: group)
                }
            }
        }
        .navigationTitle(writerDisplayLabel(canon))
    }

    private func lineageSectionSortKey(_ row: MusicDemosLatestVersionsIndexer.IndexedFile) -> String {
        let color = row.canonicalColorName ?? ""
        return "\(row.displayFamily)|\(color)|\(row.lineageKey)"
    }

    private func lineageSectionHeader(for group: [MusicDemosLatestVersionsIndexer.IndexedFile]) -> String {
        guard let first = group.first else { return "Tracks" }
        let trimmedColor = first.canonicalColorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedColor.isEmpty {
            return trimmedColor.uppercased()
        }
        return first.displayFamily
    }

    @ViewBuilder
    private func lineageSectionHeaderView(for group: [MusicDemosLatestVersionsIndexer.IndexedFile]) -> some View {
        let title = lineageSectionHeader(for: group)
        if let first = group.first {
            let colorTrim = first.canonicalColorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !colorTrim.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(first.displayFamily)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
        } else {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func trackVariantRowInLineageSection(_ row: MusicDemosLatestVersionsIndexer.IndexedFile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let name = row.canonicalColorName {
                Circle()
                    .fill(DemoTrackColorPalette.swiftUIColor(forName: name))
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                let variantTitle = row.displayVariant.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(variantTitle.isEmpty || variantTitle == "—" ? row.fileURL.lastPathComponent : variantTitle)
                    .font(.body.weight(.medium))
                Text(row.fileURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func trackVersionsContent(for row: MusicDemosLatestVersionsIndexer.IndexedFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.fileURL.deletingPathExtension().lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(row.displayFamily) · \(row.displayVariant)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))

            List {
                Section {
                    Text(row.whyLatestSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text("Why the latest won")
                }

                Section {
                    ForEach(row.versionsNewestFirst) { ver in
                        versionRow(ver, row: row)
                    }
                } header: {
                    Text("Versions (newest first)")
                }
            }
        }
    }

    private func versionRow(
        _ ver: MusicDemosLatestVersionsIndexer.IndexedDemoVersion,
        row: MusicDemosLatestVersionsIndexer.IndexedFile
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(ver.fileURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(2)
                if ver.isLatestWinner {
                    Text("Latest")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            HStack(spacing: 8) {
                Text(ver.roundFolderName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(ver.formatLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Self.shortDate.string(from: ver.modificationDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Reveal") {
                    NSWorkspace.shared.selectFile(ver.fileURL.path, inFileViewerRootedAtPath: ver.fileURL.deletingLastPathComponent().path)
                }
                .buttonStyle(.borderless)

                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ver.fileURL.path, forType: .string)
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)

            if row.isLineageAmbiguous || row.hasContentHashConflict || row.parseConfidence != .high {
                HStack(spacing: 6) {
                    if row.parseConfidence != .high {
                        Text(row.parseConfidence.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if row.isLineageAmbiguous {
                        Text("Ambiguous lineage")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(Color.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if row.hasContentHashConflict {
                        Text("Different bytes at tie")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var yearRange: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...(current + 1)).reversed()
    }

    private func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = musicDemosRoot
        panel.prompt = "Choose"
        panel.message = "Select a project folder inside Music Demos."

        if panel.runModal() == .OK, let url = panel.url {
            projectFolderURL = url.standardizedFileURL
            rows = []
            scanError = nil
            scanErrors = []
        }
    }

    private func loadLineageOverrides() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: musicDemosLineageOverridesDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "MusicDemosLatest.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines: [String] = [
            "Writer (canonical),Writer folder (disk),Family display,Lineage key,Variant,Colour,Round,Confidence,Ambiguous lineage,Hash tie,Winning path,Why latest,All paths"
        ]
        for row in rows {
            let paths = row.contributingPaths.joined(separator: "; ")
            let esc: (String) -> String = { s in
                if s.contains(",") || s.contains("\"") {
                    return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return s
            }
            let line = [
                esc(canonicalWriterKey(row.writerKey)),
                esc(row.writerKey),
                esc(row.displayFamily),
                esc(row.lineageKey),
                esc(row.displayVariant),
                esc(row.canonicalColorName ?? ""),
                esc(row.roundFolderName),
                esc(row.parseConfidence.rawValue),
                esc(row.isLineageAmbiguous ? "yes" : "no"),
                esc(row.hasContentHashConflict ? "yes" : "no"),
                esc(row.fileURL.path),
                esc(row.whyLatestSummary),
                esc(paths)
            ].joined(separator: ",")
            lines.append(line)
        }
        let csv = lines.joined(separator: "\n") + "\n"
        guard let data = csv.data(using: .utf8) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func runScan(cancellation: ScanCancellation) {
        guard let folder = projectFolderURL else { return }
        scanError = nil
        scanErrors = []
        isScanning = true
        cancellation.requested = false
        activeCancel = cancellation
        let exts = settingsManager.currentSettings.musicExtensions
        let year = selectedYear
        let overrides = loadLineageOverrides()

        Task.detached(priority: .userInitiated) {
            do {
                let result = try MusicDemosLatestVersionsIndexer.indexProjectFolder(
                    folder,
                    musicExtensions: exts,
                    scanYear: year,
                    lineageKeyOverrides: overrides,
                    shouldCancel: { cancellation.requested }
                )
                await MainActor.run {
                    rows = result.rows
                    scanErrors = result.scanErrors
                    isScanning = false
                    activeCancel = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    scanError = "Scan cancelled."
                    isScanning = false
                    activeCancel = nil
                }
            } catch {
                await MainActor.run {
                    scanError = error.localizedDescription
                    rows = []
                    isScanning = false
                    activeCancel = nil
                }
            }
        }
    }
}
