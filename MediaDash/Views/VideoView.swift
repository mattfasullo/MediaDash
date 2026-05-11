//
//  VideoView.swift
//  MediaDash
//
//  Tools hub: video conversion, restriping, LUFS normalizer, etc.
//

import SwiftUI

struct VideoView: View {
    @Binding var isPresented: Bool
    /// Dismiss popover and open Video Converter sheet.
    var onOpenVideoConverter: () -> Void
    /// Dismiss popover and open Restripe window (or no-op if not implemented).
    var onOpenRestripe: () -> Void
    /// Dismiss popover and open LUFS Normalizer window.
    var onOpenNormalizer: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            VideoOptionRow(
                title: "Video conversion",
                subtitle: "Convert to ProRes Proxy, adjust aspect ratio",
                icon: "film"
            ) {
                isPresented = false
                onOpenVideoConverter()
            }

            VideoOptionRow(
                title: "Restriping",
                subtitle: "Combine picture/video with multiple audio files",
                icon: "waveform"
            ) {
                isPresented = false
                onOpenRestripe()
            }

            VideoOptionRow(
                title: "Normalizer",
                subtitle: "Normalize staged audio or muxed clips to -14 or -24 LUFS (WAV out)",
                icon: "slider.horizontal.3"
            ) {
                isPresented = false
                onOpenNormalizer()
            }
        }
        .padding(20)
        .frame(minWidth: 380, maxWidth: 380)
    }
}

private struct VideoOptionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

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
            .background(hoverBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            isHovered = hovering && !disabled
        }
    }

    private var hoverBackgroundColor: Color {
        if disabled { return Color(nsColor: .controlBackgroundColor) }
        return isHovered
            ? Color.accentColor.opacity(0.2)
            : Color(nsColor: .controlBackgroundColor)
    }
}

#Preview {
    VideoView(
        isPresented: .constant(true),
        onOpenVideoConverter: {},
        onOpenRestripe: {},
        onOpenNormalizer: {}
    )
}
