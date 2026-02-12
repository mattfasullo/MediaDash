//
//  PortalView.swift
//  MediaDash
//
//  Media layups hub: Video conversion, Restriping, Post to Simian, etc.
//

import SwiftUI

struct PortalView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isPresented: Bool
    /// Dismiss portal and open Video Converter sheet.
    var onOpenVideoConverter: () -> Void
    /// Dismiss portal and open Restripe window (or no-op if not implemented).
    var onOpenRestripe: () -> Void
    /// Dismiss portal and open Simian posting (or no-op / coming soon).
    var onOpenSimian: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Portal")
                .font(.title)
                .fontWeight(.bold)
            Text("Media layups: convert video, restripe picture+audio, post to Simian.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                PortalOptionRow(
                    title: "Video conversion",
                    subtitle: "Convert to ProRes Proxy, adjust aspect ratio",
                    icon: "film"
                ) {
                    isPresented = false
                    onOpenVideoConverter()
                }

                PortalOptionRow(
                    title: "Restriping",
                    subtitle: "Combine picture/video with multiple audio files",
                    icon: "waveform"
                ) {
                    isPresented = false
                    onOpenRestripe()
                }

                if let onOpenSimian = onOpenSimian {
                    PortalOptionRow(
                        title: "Post to Simian",
                        subtitle: "Upload to Simian",
                        icon: "arrow.up.circle"
                    ) {
                        isPresented = false
                        onOpenSimian()
                    }
                } else {
                    PortalOptionRow(
                        title: "Post to Simian",
                        subtitle: "Coming soon",
                        icon: "arrow.up.circle",
                        disabled: true
                    ) {}
                }
            }

            Spacer()
        }
        .padding(28)
        .frame(minWidth: 380, minHeight: 320)
    }
}

private struct PortalOptionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
                    .frame(width: 32, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(disabled ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !disabled {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

#Preview {
    PortalView(
        isPresented: .constant(true),
        onOpenVideoConverter: {},
        onOpenRestripe: {},
        onOpenSimian: nil
    )
}
