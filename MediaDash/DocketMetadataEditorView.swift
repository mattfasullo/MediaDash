import SwiftUI

struct DocketMetadataEditorView: View {
    let docket: DocketInfo
    @Binding var isPresented: Bool
    @ObservedObject var metadataManager: DocketMetadataManager

    @State private var metadata: DocketMetadata

    init(docket: DocketInfo, isPresented: Binding<Bool>, metadataManager: DocketMetadataManager) {
        self.docket = docket
        self._isPresented = isPresented
        self.metadataManager = metadataManager
        
        // Initialize metadata from saved data or docket info
        var initialMetadata = metadataManager.getMetadata(forId: docket.fullName)
        
        // Auto-populate empty fields from custom fields (don't overwrite existing saved data)
        if let customFields = docket.projectMetadata?.customFields {
            initialMetadata = Self.populateMetadataFromCustomFields(initialMetadata, customFields: customFields)
        }
        
        self._metadata = State(initialValue: initialMetadata)
    }
    
    /// Populate metadata fields from Asana custom fields (only fills empty fields, doesn't overwrite existing data)
    static func populateMetadataFromCustomFields(_ metadata: DocketMetadata, customFields: [String: String]) -> DocketMetadata {
        var updated = metadata
        
        // Create mapping of common field name variations to metadata fields
        let fieldMappings: [String: WritableKeyPath<DocketMetadata, String>] = [
            // Client
            "client": \.client,
            "licensor": \.client,
            "licensor/client": \.client,
            "licensor / client": \.client,
            // Agency
            "agency": \.agency,
            // Producer
            "producer": \.producer,
            "grayson producer": \.producer,
            "internal producer": \.producer,
            // Agency Producer
            "agency producer": \.agencyProducer,
            "agency producer / supervisor": \.agencyProducer,
            "supervisor": \.agencyProducer,
            // Status
            "status": \.status,
            // License Total
            "license total": \.licenseTotal,
            "music license totals": \.licenseTotal,
            "license": \.licenseTotal,
            // Currency
            "currency": \.currency,
            // Music Type
            "music type": \.musicType,
            // Track
            "track": \.track,
            // Media
            "media": \.media
        ]
        
        // Map custom fields to metadata (only fill empty fields)
        for (key, value) in customFields {
            let normalizedKey = key.lowercased().trimmingCharacters(in: .whitespaces)
            if let path = fieldMappings[normalizedKey], !value.isEmpty {
                // Only populate if the field is currently empty
                if updated[keyPath: path].isEmpty {
                    updated[keyPath: path] = value
                }
            }
        }
        
        return updated
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Docket Information")
                        .font(.title2)
                        .fontWeight(.bold)

                    HStack(spacing: 8) {
                        Text(docket.number)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.blue)
                            .cornerRadius(4)

                        Text(docket.jobName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button("Done") {
                    metadataManager.saveMetadata(metadata)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic Information Section (always shown)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("Basic Information")
                                .font(.headline)
                        }
                        
                        HStack(spacing: 16) {
                            ReadOnlyMetadataField(label: "Docket Number", icon: "123.rectangle", value: docket.number)
                            if let metadataType = docket.metadataType, !metadataType.isEmpty {
                                ReadOnlyMetadataField(label: "Type", icon: "tag", value: metadataType)
                            }
                        }
                        
                        ReadOnlyMetadataField(label: "Job Name", icon: "briefcase.fill", value: docket.jobName)
                        
                        if let updatedAt = docket.updatedAt {
                            ReadOnlyMetadataField(label: "Last Updated", icon: "clock", value: formatDate(updatedAt))
                        }
                        
                        if let subtasks = docket.subtasks, !subtasks.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "list.bullet")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                        .frame(width: 16)
                                    Text("Subtasks (\(subtasks.count))")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                }
                                ForEach(subtasks.prefix(5)) { subtask in
                                    HStack(spacing: 8) {
                                        Text("•")
                                            .foregroundColor(.secondary)
                                        Text(subtask.name)
                                            .font(.system(size: 12))
                                            .foregroundColor(.primary)
                                        Spacer()
                                    }
                                    .padding(.leading, 24)
                                }
                                if subtasks.count > 5 {
                                    Text("... and \(subtasks.count - 5) more")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 24)
                                }
                            }
                            .padding(8)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                    }
                    .padding()
                    .background(Color.green.opacity(0.05))
                    .cornerRadius(8)
                    
                    Divider()
                    
                    // Asana Project Info Section (if available)
                    if let projectMeta = docket.projectMetadata {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .foregroundColor(.blue)
                                Text("Asana Project Information")
                                    .font(.headline)
                            }
                            
                            if let projectName = projectMeta.projectName, !projectName.isEmpty {
                                ReadOnlyMetadataField(label: "Project Name", icon: "folder", value: projectName)
                            }
                            
                            if let createdBy = projectMeta.createdBy, !createdBy.isEmpty {
                                ReadOnlyMetadataField(label: "Created By", icon: "person.crop.circle.badge.plus", value: createdBy)
                            }
                            
                            if let owner = projectMeta.owner, !owner.isEmpty {
                                ReadOnlyMetadataField(label: "Owner", icon: "person.crop.circle.badge.checkmark", value: owner)
                            }
                            
                            if let team = projectMeta.team, !team.isEmpty {
                                ReadOnlyMetadataField(label: "Team", icon: "person.3", value: team)
                            }
                            
                            if let dueDate = projectMeta.dueDate, !dueDate.isEmpty {
                                ReadOnlyMetadataField(label: "Due Date", icon: "calendar", value: dueDate)
                            }
                            
                            if let color = projectMeta.color, !color.isEmpty {
                                HStack {
                                    ReadOnlyMetadataField(label: "Color", icon: "paintpalette", value: color)
                                    if let colorValue = colorFromString(color) {
                                        Circle()
                                            .fill(colorValue)
                                            .frame(width: 20, height: 20)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                            )
                                    }
                                }
                            }
                            
                            if let notes = projectMeta.notes, !notes.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "note.text")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                            .frame(width: 16)
                                        Text("Project Notes")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(notes)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(nsColor: .textBackgroundColor))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                        )
                                }
                            }
                            
                            if !projectMeta.customFields.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "list.bullet.rectangle")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                            .frame(width: 16)
                                        Text("Custom Fields")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.secondary)
                                    }
                                    ForEach(Array(projectMeta.customFields.keys.sorted()), id: \.self) { key in
                                        if let value = projectMeta.customFields[key], !value.isEmpty {
                                            ReadOnlyMetadataField(label: key, icon: "tag", value: value)
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(8)
                        
                        Divider()
                    }
                    
                    // Job Details Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Job Details")
                            .font(.headline)

                        MetadataField(label: "Client", icon: "building.2", text: $metadata.client)
                        MetadataField(label: "Agency", icon: "briefcase", text: $metadata.agency)
                        MetadataField(label: "License Total", icon: "dollarsign.circle", text: $metadata.licenseTotal)
                        MetadataField(label: "Currency", icon: "banknote", text: $metadata.currency)
                    }

                    Divider()

                    // Production Team Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Production Info")
                            .font(.headline)

                        MetadataField(label: "Producer", icon: "person", text: $metadata.producer)
                        MetadataField(label: "Agency Producer", icon: "person.badge.key", text: $metadata.agencyProducer)
                        MetadataField(label: "Status", icon: "checkmark.circle", text: $metadata.status)
                        MetadataField(label: "Music Type", icon: "music.note", text: $metadata.musicType)
                        MetadataField(label: "Track", icon: "waveform", text: $metadata.track)
                        MetadataField(label: "Media", icon: "tv", text: $metadata.media)
                    }

                    Divider()

                    // Notes Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes")
                            .font(.headline)

                        TextEditor(text: $metadata.notes)
                            .frame(minHeight: 100)
                            .font(.system(size: 13))
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }

                    if metadata.lastUpdated > Date.distantPast {
                        HStack {
                            Image(systemName: "clock")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Last updated: \(metadata.lastUpdated, style: .relative)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Button("Clear All") {
                    metadata = DocketMetadata(docketNumber: docket.number, jobName: docket.jobName)
                }
                .foregroundColor(.red)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    metadataManager.saveMetadata(metadata)
                    isPresented = false
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 500, height: 650)
    }
}

struct MetadataField: View {
    let label: String
    let icon: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .frame(width: 16)
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

            TextField("Enter \(label.lowercased())", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct ReadOnlyMetadataField: View {
    let label: String
    let icon: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .frame(width: 16)
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
        }
    }
}

extension DocketMetadataEditorView {
    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    func colorFromString(_ colorString: String) -> Color? {
        // Asana colors are typically named like "blue", "green", "red", etc.
        // or hex codes. Try to map common names to SwiftUI colors.
        let lowercased = colorString.lowercased()
        switch lowercased {
        case "blue", "dark-blue":
            return .blue
        case "green", "dark-green":
            return .green
        case "red", "dark-red":
            return .red
        case "yellow", "dark-yellow":
            return .yellow
        case "orange", "dark-orange":
            return .orange
        case "purple", "dark-purple":
            return .purple
        case "pink", "dark-pink":
            return .pink
        case "brown", "dark-brown":
            return .brown
        case "gray", "grey", "dark-gray", "dark-grey":
            return .gray
        default:
            // Try to parse as hex color
            if colorString.hasPrefix("#") {
                let hex = String(colorString.dropFirst())
                if let rgb = Int(hex, radix: 16) {
                    let r = Double((rgb >> 16) & 0xFF) / 255.0
                    let g = Double((rgb >> 8) & 0xFF) / 255.0
                    let b = Double(rgb & 0xFF) / 255.0
                    return Color(red: r, green: g, blue: b)
                }
            }
            return nil
        }
    }
}

