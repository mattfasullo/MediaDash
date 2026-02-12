//
//  FFmpegInstallSheet.swift
//  MediaDash
//
//  Sheet for installing FFmpeg via Homebrew.
//

import SwiftUI

struct FFmpegInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onInstalled: () -> Void

    @State private var isInstalling = false
    @State private var installComplete = false
    @State private var errorMessage: String?
    @State private var outputLines: [String] = []
    @State private var outputViewId = UUID()

    private var hasHomebrew: Bool { FFmpegInstallService.brewPath() != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if hasHomebrew {
                if installComplete {
                    successView
                } else if let err = errorMessage {
                    errorView(err)
                } else {
                    installView
                }
            } else {
                noHomebrewView
            }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "waveform.badge.plus")
                    .font(.title2)
                Text("Install FFmpeg")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            Text("Restriping needs FFmpeg to combine video and audio. Install it with one click.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var installView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isInstalling {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Installing… This may take a few minutes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(outputLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(height: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: outputLines.count) { _, _ in
                        if let last = outputLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .id(outputViewId)
            } else {
                Button {
                    startInstall()
                } label: {
                    Label("Install FFmpeg", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("FFmpeg installed successfully!", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Text("You can close this and start restriping.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Done") {
                onInstalled()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Installation failed", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Try Again") {
                errorMessage = nil
                outputLines = []
                startInstall()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var noHomebrewView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Homebrew is required to install FFmpeg. Install it first, then return here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Open Homebrew Website") {
                if let url = URL(string: "https://brew.sh") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)

            Text("After installing Homebrew, restart MediaDash and try again.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func startInstall() {
        isInstalling = true
        errorMessage = nil
        outputLines = []

        Task {
            do {
                try await FFmpegInstallService.installFFmpeg { line in
                    outputLines.append(line)
                }
                await MainActor.run {
                    isInstalling = false
                    installComplete = true
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    isInstalling = false
                    errorMessage = msg
                }
            }
        }
    }
}
