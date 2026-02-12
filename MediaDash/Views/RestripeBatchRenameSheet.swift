//
//  RestripeBatchRenameSheet.swift
//  MediaDash
//
//  Simple batch rename sheet for restriping output files.
//

import SwiftUI

struct RestripeBatchRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// Current output basenames (without extension) of selected items
    let selectedBasenames: [String]
    let outputFormat: RestripeConfig.OutputFormat
    /// New basenames in same order as selectedBasenames
    let onApply: ([String]) -> Void

    @State private var mode: RenameMode = .addPrefix
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var replace = ""

    enum RenameMode: String, CaseIterable {
        case addPrefix = "Add prefix"
        case addSuffix = "Add suffix"
        case replace = "Replace entirely"
    }

    private var previewNames: [String] {
        selectedBasenames.map { applyToBasename($0) + ".\(outputFormat.fileExtension)" }
    }

    private func applyToBasename(_ base: String) -> String {
        switch mode {
        case .addPrefix: return prefix + base
        case .addSuffix: return base + suffix
        case .replace: return replace.isEmpty ? base : replace
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Batch Rename (\(selectedBasenames.count) items)")
                .font(.title2)
                .fontWeight(.semibold)

            Picker("Mode", selection: $mode) {
                ForEach(RenameMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch mode {
                case .addPrefix:
                    TextField("Prefix", text: $prefix)
                        .textFieldStyle(.roundedBorder)
                case .addSuffix:
                    TextField("Suffix", text: $suffix)
                        .textFieldStyle(.roundedBorder)
                case .replace:
                    TextField("New name (replaces entirely)", text: $replace)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.subheadline)
                    .fontWeight(.medium)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(previewNames, id: \.self) { name in
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply") {
                    onApply(selectedBasenames.map { applyToBasename($0) })
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 380, minHeight: 320)
    }
}
