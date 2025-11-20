import Foundation
import SwiftUI
import Combine

// MARK: - Docket Metadata Model

struct DocketMetadata: Codable, Identifiable {
    var id: String { "\(docketNumber)_\(jobName)" } // Computed ID
    var docketNumber: String
    var jobName: String
    var client: String
    var producer: String
    var status: String
    var licenseTotal: String
    var currency: String
    var agency: String
    var agencyProducer: String
    var musicType: String
    var track: String
    var media: String
    var notes: String
    var lastUpdated: Date

    init(docketNumber: String, jobName: String = "") {
        self.docketNumber = docketNumber
        self.jobName = jobName
        self.client = ""
        self.producer = ""
        self.status = ""
        self.licenseTotal = ""
        self.currency = ""
        self.agency = ""
        self.agencyProducer = ""
        self.musicType = ""
        self.track = ""
        self.media = ""
        self.notes = ""
        self.lastUpdated = Date()
    }

    enum CodingKeys: String, CodingKey {
        case docketNumber = "docket_number"
        case jobName = "job_name"
        case client
        case producer
        case status
        case licenseTotal = "license_total"
        case currency
        case agency
        case agencyProducer = "agency_producer"
        case musicType = "music_type"
        case track
        case media
        case notes
        case lastUpdated = "last_updated"
    }
}

// MARK: - Metadata Manager

@MainActor
class DocketMetadataManager: ObservableObject {
    @Published var metadata: [String: DocketMetadata] = [:]
    private var settings: AppSettings?

    private var csvFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let mediaDashFolder = documentsPath.appendingPathComponent("MediaDash")

        // Create MediaDash folder if it doesn't exist
        try? FileManager.default.createDirectory(at: mediaDashFolder, withIntermediateDirectories: true)

        return mediaDashFolder.appendingPathComponent("docket_metadata.csv")
    }

    init(settings: AppSettings? = nil) {
        self.settings = settings
        loadMetadata()
    }

    func updateSettings(_ newSettings: AppSettings) {
        self.settings = newSettings
        loadMetadata() // Reload with new column mappings
    }

    func getMetadata(for docketNumber: String, jobName: String) -> DocketMetadata {
        let key = "\(docketNumber)_\(jobName)"
        return metadata[key] ?? DocketMetadata(docketNumber: docketNumber, jobName: jobName)
    }

    func getMetadata(forId id: String) -> DocketMetadata {
        if let meta = metadata[id] {
            return meta
        }
        // Parse the ID if not found
        let components = id.split(separator: "_", maxSplits: 1)
        if components.count >= 2 {
            return DocketMetadata(docketNumber: String(components[0]), jobName: String(components[1]))
        }
        return DocketMetadata(docketNumber: id, jobName: "")
    }

    func saveMetadata(_ meta: DocketMetadata) {
        var updated = meta
        updated.lastUpdated = Date()
        metadata[meta.id] = updated
        persistMetadata()
    }

    func hasMetadata(for docketName: String) -> Bool {
        guard let meta = metadata[docketName] else { return false }
        return !meta.producer.isEmpty || !meta.agencyProducer.isEmpty ||
               !meta.agency.isEmpty || !meta.client.isEmpty ||
               !meta.status.isEmpty || !meta.notes.isEmpty
    }

    func reloadMetadata() {
        loadMetadata()
    }

    private func loadMetadata() {
        print("DocketMetadataManager: Attempting to load CSV from: \(csvFileURL.path)")

        guard FileManager.default.fileExists(atPath: csvFileURL.path) else {
            print("DocketMetadataManager: CSV file does not exist at path")
            return
        }

        do {
            let csvContent = try String(contentsOf: csvFileURL, encoding: .utf8)
            var rows = csvContent.components(separatedBy: .newlines).filter { !$0.isEmpty }

            print("DocketMetadataManager: CSV file loaded, found \(rows.count) rows")

            // Skip title row if it exists (e.g., "docket_metadata" on first line)
            if rows.count > 0 && !rows[0].contains(",") {
                print("DocketMetadataManager: Skipping title row: \(rows[0])")
                rows.removeFirst()
            }

            // Skip header row
            guard rows.count > 1 else {
                print("DocketMetadataManager: CSV file is empty or only has header row")
                return
            }

            var loadedMetadata: [String: DocketMetadata] = [:]

            // Parse header to create column map
            let headerFields = parseCSVRow(rows[0])
            var columnMap: [String: Int] = [:]
            for (index, header) in headerFields.enumerated() {
                // Strip BOM (Byte Order Mark) and whitespace
                var cleanedHeader = header.trimmingCharacters(in: .whitespaces)
                if index == 0 && cleanedHeader.hasPrefix("\u{FEFF}") {
                    cleanedHeader = String(cleanedHeader.dropFirst())
                }
                columnMap[cleanedHeader] = index
            }

            print("CSV Headers: \(headerFields)")
            print("Column map: \(columnMap)")

            // Get column names from settings or use defaults
            let docketCol = settings?.csvDocketColumn ?? "Docket"
            let projectCol = settings?.csvProjectTitleColumn ?? "Licensor/Project Title"

            print("Looking for columns: '\(docketCol)' and '\(projectCol)'")
            if let numIdx = columnMap[docketCol] {
                print("Found '\(docketCol)' at index \(numIdx)")
            } else {
                print("WARNING: Column '\(docketCol)' not found in CSV!")
            }
            if let nameIdx = columnMap[projectCol] {
                print("Found '\(projectCol)' at index \(nameIdx)")
            } else {
                print("WARNING: Column '\(projectCol)' not found in CSV!")
            }

            for row in rows.dropFirst() {
                let fields = parseCSVRow(row)

                // Get docket number and project title using configured column names
                guard let numIdx = columnMap[docketCol],
                      let nameIdx = columnMap[projectCol],
                      fields.count > numIdx,
                      fields.count > nameIdx else {
                    print("Skipping row: missing required columns '\(docketCol)' or '\(projectCol)'")
                    continue
                }

                let docketNumber = fields[numIdx].trimmingCharacters(in: .whitespaces)
                let jobName = fields[nameIdx].trimmingCharacters(in: .whitespaces)

                // Skip if either is empty
                guard !docketNumber.isEmpty && !jobName.isEmpty else {
                    print("Skipping row with empty docket number or job name")
                    continue
                }

                let key = "\(docketNumber)_\(jobName)"

                var meta = DocketMetadata(docketNumber: docketNumber, jobName: jobName)

                // Map other fields using configured column names
                if let col = settings?.csvClientColumn, let idx = columnMap[col], fields.count > idx {
                    meta.client = fields[idx]
                }
                if let col = settings?.csvProducerColumn, let idx = columnMap[col], fields.count > idx {
                    meta.producer = fields[idx]
                }
                if let col = settings?.csvStatusColumn, let idx = columnMap[col], fields.count > idx {
                    meta.status = fields[idx]
                }
                if let col = settings?.csvLicenseTotalColumn, let idx = columnMap[col], fields.count > idx {
                    meta.licenseTotal = fields[idx]
                }
                if let col = settings?.csvCurrencyColumn, let idx = columnMap[col], fields.count > idx {
                    meta.currency = fields[idx]
                }
                if let col = settings?.csvAgencyColumn, let idx = columnMap[col], fields.count > idx {
                    meta.agency = fields[idx]
                }
                if let col = settings?.csvAgencyProducerColumn, let idx = columnMap[col], fields.count > idx {
                    meta.agencyProducer = fields[idx]
                }
                if let col = settings?.csvMusicTypeColumn, let idx = columnMap[col], fields.count > idx {
                    meta.musicType = fields[idx]
                }
                if let col = settings?.csvTrackColumn, let idx = columnMap[col], fields.count > idx {
                    meta.track = fields[idx]
                }
                if let col = settings?.csvMediaColumn, let idx = columnMap[col], fields.count > idx {
                    meta.media = fields[idx]
                }

                loadedMetadata[key] = meta
                print("Loaded docket: \(docketNumber) - \(jobName)")
            }

            metadata = loadedMetadata
            print("DocketMetadataManager: Successfully loaded \(loadedMetadata.count) dockets from CSV")
            print("DocketMetadataManager: CSV location: \(csvFileURL.path)")

            if loadedMetadata.isEmpty {
                print("DocketMetadataManager: WARNING - No dockets were loaded. Check CSV format:")
                print("  - CSV must have 'docket_number' and 'job_name' columns")
                print("  - Column names are case-insensitive")
                print("  - Rows with empty docket_number or job_name are skipped")
            }
        } catch {
            print("DocketMetadataManager: Error loading metadata CSV: \(error)")
        }
    }

    private func persistMetadata() {
        var csvContent = "docket_number,job_name,client,producer,status,license_total,currency,agency,agency_producer,music_type,track,media,notes,last_updated\n"

        let dateFormatter = ISO8601DateFormatter()

        for (_, meta) in metadata.sorted(by: { $0.key < $1.key }) {
            let row = [
                escapeCSVField(meta.docketNumber),
                escapeCSVField(meta.jobName),
                escapeCSVField(meta.client),
                escapeCSVField(meta.producer),
                escapeCSVField(meta.status),
                escapeCSVField(meta.licenseTotal),
                escapeCSVField(meta.currency),
                escapeCSVField(meta.agency),
                escapeCSVField(meta.agencyProducer),
                escapeCSVField(meta.musicType),
                escapeCSVField(meta.track),
                escapeCSVField(meta.media),
                escapeCSVField(meta.notes),
                dateFormatter.string(from: meta.lastUpdated)
            ].joined(separator: ",")

            csvContent += row + "\n"
        }

        do {
            try csvContent.write(to: csvFileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Error saving metadata CSV: \(error)")
        }
    }

    // Helper to escape CSV fields (handle commas, quotes, newlines)
    private func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    // Helper to parse CSV row (handle quoted fields)
    private func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var currentField = ""
        var insideQuotes = false
        var i = row.startIndex

        while i < row.endIndex {
            let char = row[i]

            if char == "\"" {
                if insideQuotes {
                    // Check for escaped quote
                    let nextIndex = row.index(after: i)
                    if nextIndex < row.endIndex && row[nextIndex] == "\"" {
                        currentField.append("\"")
                        i = nextIndex
                    } else {
                        insideQuotes = false
                    }
                } else {
                    insideQuotes = true
                }
            } else if char == "," && !insideQuotes {
                fields.append(currentField)
                currentField = ""
            } else {
                currentField.append(char)
            }

            i = row.index(after: i)
        }

        fields.append(currentField)
        return fields
    }

    // Export metadata to CSV file
    func exportMetadata(to url: URL) throws {
        let content = try String(contentsOf: csvFileURL, encoding: .utf8)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // Import metadata from CSV file
    func importMetadata(from url: URL) throws {
        let csvContent = try String(contentsOf: url, encoding: .utf8)
        var rows = csvContent.components(separatedBy: .newlines).filter { !$0.isEmpty }

        // Skip title row if it exists (e.g., "docket_metadata" on first line)
        if rows.count > 0 && !rows[0].contains(",") {
            rows.removeFirst()
        }

        guard rows.count > 1 else { return }

        let dateFormatter = ISO8601DateFormatter()

        // Parse header to create column map
        let headerFields = parseCSVRow(rows[0])
        var columnMap: [String: Int] = [:]
        for (index, header) in headerFields.enumerated() {
            // Strip BOM (Byte Order Mark) and whitespace
            var cleanedHeader = header.trimmingCharacters(in: .whitespaces)
            if index == 0 && cleanedHeader.hasPrefix("\u{FEFF}") {
                cleanedHeader = String(cleanedHeader.dropFirst())
            }
            columnMap[cleanedHeader.lowercased()] = index
        }

        for row in rows.dropFirst() {
            let fields = parseCSVRow(row)

            // Get docket number and job name using column map
            guard let numIdx = columnMap["docket_number"],
                  let nameIdx = columnMap["job_name"],
                  fields.count > numIdx,
                  fields.count > nameIdx else {
                continue
            }

            let docketNumber = fields[numIdx].trimmingCharacters(in: .whitespaces)
            let jobName = fields[nameIdx].trimmingCharacters(in: .whitespaces)

            guard !docketNumber.isEmpty && !jobName.isEmpty else { continue }

            let key = "\(docketNumber)_\(jobName)"

            var meta = DocketMetadata(docketNumber: docketNumber, jobName: jobName)

            // Map other fields by column name
            if let idx = columnMap["client"], fields.count > idx {
                meta.client = fields[idx]
            }
            if let idx = columnMap["producer"], fields.count > idx {
                meta.producer = fields[idx]
            }
            if let idx = columnMap["status"], fields.count > idx {
                meta.status = fields[idx]
            }
            if let idx = columnMap["license_total"], fields.count > idx {
                meta.licenseTotal = fields[idx]
            }
            if let idx = columnMap["currency"], fields.count > idx {
                meta.currency = fields[idx]
            }
            if let idx = columnMap["agency"], fields.count > idx {
                meta.agency = fields[idx]
            }
            if let idx = columnMap["agency_producer"], fields.count > idx {
                meta.agencyProducer = fields[idx]
            }
            if let idx = columnMap["music_type"], fields.count > idx {
                meta.musicType = fields[idx]
            }
            if let idx = columnMap["track"], fields.count > idx {
                meta.track = fields[idx]
            }
            if let idx = columnMap["media"], fields.count > idx {
                meta.media = fields[idx]
            }
            if let idx = columnMap["notes"], fields.count > idx {
                meta.notes = fields[idx]
            }
            if let idx = columnMap["last_updated"], fields.count > idx {
                meta.lastUpdated = dateFormatter.date(from: fields[idx]) ?? Date()
            }

            metadata[key] = meta
        }

        persistMetadata()
    }
}
