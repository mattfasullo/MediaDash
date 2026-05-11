//
//  NormalizerView.swift
//  MediaDash
//
//  Stage media files, pick -14 or -24 LUFS integrated target, normalize with FFmpeg loudnorm.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NormalizerView: View {
    private struct StagedRow: Identifiable, Hashable {
        let path: String
        /// `true` when the row came from File Importer and `startAccessingSecurityScopedResource` succeeded.
        var securityScopedBookmarkActive: Bool
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
    }

    private static let dropTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .data]

    @State private var stagedRows: [StagedRow] = []
    @State private var selection: Set<String> = []
    @State private var targetLUFS: Int = -14
    @State private var isNormalizing = false
    @State private var statusMessage = ""
    @State private var showFFmpegInstall = false
    @State private var ffmpegAvailable = false
    @State private var showImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !ffmpegAvailable {
                ffmpegBanner
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Add files with audio (standalone audio or muxed video). Outputs are WAV (24-bit PCM, 48 kHz) beside each source, e.g. MyTrack_-14LUFS.wav.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Target integrated loudness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Target loudness", selection: $targetLUFS) {
                    Text("-14 LUFS").tag(-14)
                    Text("-24 LUFS").tag(-24)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                HStack(spacing: 10) {
                    Button("Add Files…") {
                        showImporter = true
                    }
                    .disabled(isNormalizing)

                    Button("Remove selected") {
                        let removed = stagedRows.filter { selection.contains($0.path) }
                        revokeSecurityScopedURLs(in: removed)
                        stagedRows.removeAll { selection.contains($0.path) }
                        selection.removeAll()
                    }
                    .disabled(stagedRows.isEmpty || selection.isEmpty || isNormalizing)

                    Button("Clear list") {
                        revokeSecurityScopedURLs(in: stagedRows)
                        stagedRows.removeAll()
                        selection.removeAll()
                    }
                    .disabled(stagedRows.isEmpty || isNormalizing)

                    Spacer()

                    Button("Normalize") {
                        runNormalization()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(stagedRows.isEmpty || isNormalizing || !ffmpegAvailable)
                }

                Table(stagedRows, selection: $selection) {
                    TableColumn("Filename") { row in
                        Text(row.url.lastPathComponent)
                            .lineLimit(2)
                    }
                    TableColumn("Folder", content: { row in
                        Text(row.url.deletingLastPathComponent().path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    })
                }
                .frame(minHeight: 200)
                .onDrop(of: Self.dropTypes, isTargeted: nil, perform: addFromProviders)

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()
                    Text("\(stagedRows.count) file(s)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { checkFFmpeg() }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    addImportedURL(url)
                }
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showFFmpegInstall) {
            FFmpegInstallSheet { checkFFmpeg() }
        }
    }

    private var ffmpegBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("FFmpeg not found")
                    .font(.headline)
                Text("Normalization requires FFmpeg (e.g. brew install ffmpeg).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("How to install") {
                    showFFmpegInstall = true
                }
                .buttonStyle(.link)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func checkFFmpeg() {
        ffmpegAvailable = RestripeService.resolveFFmpegPath() != nil
    }

    private func appendPathIfRegularFile(_ path: String, scoped: Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return }
        guard FileManager.default.isReadableFile(atPath: path) else { return }
        guard stagedRows.contains(where: { $0.path == path }) == false else { return }
        stagedRows.append(StagedRow(path: path, securityScopedBookmarkActive: scoped))
    }

    private func revokeSecurityScopedURLs(in rows: [StagedRow]) {
        for row in rows where row.securityScopedBookmarkActive {
            row.url.stopAccessingSecurityScopedResource()
        }
    }

    private func addImportedURL(_ url: URL) {
        let began = url.startAccessingSecurityScopedResource()
        let countBefore = stagedRows.count
        appendPathIfRegularFile(url.path, scoped: began)
        let added = stagedRows.count > countBefore
        if began, !added {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func addFromProviders(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier("public.file-url") {
                p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { obj, _ in
                    DispatchQueue.main.async {
                        guard let ns = obj as? NSString else { return }
                        self.appendPathIfRegularFile(ns as String, scoped: false)
                    }
                }
            }
        }
        return true
    }

    private func runNormalization() {
        guard let ffmpegPath = RestripeService.resolveFFmpegPath(), !stagedRows.isEmpty else { return }
        let inputs = stagedRows.map(\.url)
        let tgt = targetLUFS
        isNormalizing = true
        statusMessage = ""
        let total = inputs.count

        Task {
            await MainActor.run {
                FloatingProgressManager.shared.startOperation(
                    .converting(filename: "LUFS normalization"),
                    totalFiles: total
                )
            }

            let result = await AudioLoudnessNormalizerService.normalizeBatch(
                inputURLs: inputs,
                targetLUFS: tgt,
                ffmpegPath: ffmpegPath,
                progress: { index, filename, phase in
                    await MainActor.run {
                        FloatingProgressManager.shared.updateProgress(
                            Double(index) / Double(max(1, total)),
                            message: phase,
                            currentFile: filename
                        )
                    }
                }
            )

            await MainActor.run {
                for _ in inputs {
                    FloatingProgressManager.shared.incrementFile()
                }

                let ok = result.successURLs.count
                let bad = result.failures.count

                let msgBody: String
                if ok == total && bad == 0 {
                    msgBody = total == 1 ? "Wrote 1 WAV file beside the original." : "Wrote \(ok) WAV files beside the originals."
                } else if ok > 0 {
                    msgBody = "Wrote \(ok) of \(total); \(bad) failed. See summary."
                } else {
                    msgBody = "None completed. See details."
                }

                FloatingProgressManager.shared.complete(message: msgBody)

                if !result.failures.isEmpty {
                    let detail = result.failures.prefix(8).map { "\($0.url.lastPathComponent): \($0.message)" }.joined(separator: "\n")
                    let more = result.failures.count > 8 ? "\n…" : ""
                    let alert = NSAlert()
                    alert.messageText = bad == total ? "Normalization failed" : "Some files failed"
                    alert.informativeText = detail + more
                    alert.alertStyle = bad == total ? .warning : .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    statusMessage = bad == total ? "All failed." : "\(bad) failure(s)."
                } else {
                    statusMessage = "Done."
                }

                isNormalizing = false
            }
        }
    }
}

#Preview {
    NormalizerView()
        .frame(width: 520, height: 480)
}
