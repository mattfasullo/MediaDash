import Foundation
import Combine

/// Scans an Airtable base for docket rows where the job name field was **recently assigned**
/// (non-empty + `LAST_MODIFIED_TIME` on that field after the scan cutoff). Rows often exist
/// early with only a docket number prefilled; the signal for a "new" docket is filling
/// **Licensor/Project Title** (or whatever `airtableJobNameField` is set to).
@MainActor
class AirtableDocketScanningService: ObservableObject {
    @Published var isScanning = false
    @Published var isEnabled = false
    @Published var lastScanTime: Date?
    @Published var lastError: String?
    @Published var totalDocketsDetected = 0

    weak var settingsManager: SettingsManager?
    weak var notificationCenter: NotificationCenter?
    weak var mediaManager: MediaManager?
    var simianService: SimianService?

    private var scanningTask: Task<Void, Never>?

    // Record IDs that have already been handled (produce a notification or were skipped as duplicates).
    private var seenRecordIds: Set<String> = []
    // Maps record id → date we first processed it; used to prune old entries.
    private var seenRecordDates: [String: Date] = [:]

    private let seenRecordIdsKey   = "airtable_seen_docket_record_ids"
    private let seenRecordDatesKey = "airtable_seen_docket_record_dates"
    private let lastScanTimeKey    = "airtable_docket_last_scan_time"

    private let baseURL = "https://api.airtable.com/v0"

    // MARK: - Lifecycle

    init() {
        loadSeenRecords()
    }

    func startScanning() {
        guard !isEnabled else { return }
        isEnabled = true
        lastError = nil
        Task { await scanNow() }
        startPeriodicScanning()
    }

    func stopScanning() {
        isEnabled = false
        isScanning = false
        scanningTask?.cancel()
        scanningTask = nil
    }

    // MARK: - Scan

    func scanNow() async {
        // Fix 4: cooperative cancellation so a cancelled periodic task doesn't start a new scan.
        guard !Task.isCancelled else { return }
        guard !isScanning else { return }

        guard let settings = settingsManager?.currentSettings,
              let apiKey = SharedKeychainService.getAirtableAPIKey(), !apiKey.isEmpty else {
            lastError = "Airtable API key is not configured"
            return
        }

        let baseID  = settings.airtableBaseID?.nilIfEmpty  ?? AirtableConfig.docketBaseID
        let tableID = settings.airtableTableID?.nilIfEmpty ?? AirtableConfig.docketTableID

        guard !baseID.isEmpty, !tableID.isEmpty else {
            lastError = "Airtable base ID or table ID is missing"
            return
        }

        isScanning = true
        lastError  = nil

        // Fix 1: defer only resets the scanning flag; lastScanTimeKey is written only on success.
        defer { isScanning = false }

        let cutoff: Date = (UserDefaults.standard.object(forKey: lastScanTimeKey) as? Date)
            ?? Date().addingTimeInterval(-7 * 24 * 3600)

        let docketField = settings.airtableDocketNumberField.nilIfEmpty ?? AirtableConfig.docketNumberField
        let jobField    = settings.airtableJobNameField.nilIfEmpty      ?? AirtableConfig.jobNameField

        do {
            let records = try await fetchRecordsJobFieldAssignedAfter(
                cutoff:      cutoff,
                baseID:      baseID,
                tableID:     tableID,
                jobField:    jobField,
                docketField: docketField,
                apiKey:      apiKey
            )

            for record in records {
                guard !seenRecordIds.contains(record.id) else { continue }

                guard let rawDocket = record.fields[docketField] as? String,
                      isValidDocketNumber(rawDocket) else {
                    // Mark unseen/invalid records so we don't keep re-evaluating them.
                    markSeen(record.id)
                    continue
                }

                let docketNumber = rawDocket.trimmingCharacters(in: .whitespacesAndNewlines)
                let jobName      = (record.fields[jobField] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                // Don't markSeen here — an empty job name is transient (not yet filled in).
                // The LAST_MODIFIED_TIME filter will re-surface this record once it's filled.
                guard !jobName.isEmpty else { continue }

                if shouldSkipAlreadyProvisioned(docketNumber: docketNumber) {
                    markSeen(record.id)
                    continue
                }

                let created = createNotification(docketNumber: docketNumber, jobName: jobName, recordId: record.id)
                if created {
                    totalDocketsDetected += 1
                }
                markSeen(record.id)
            }

            // Fix 1: only advance the cutoff after a fully successful scan.
            lastScanTime = Date()
            UserDefaults.standard.set(lastScanTime, forKey: lastScanTimeKey)

            // Fix 2: prune old entries so the set doesn't grow forever.
            pruneOldSeenRecords()
            saveSeenRecords()

        } catch {
            lastError = "Airtable scan failed: \(error.localizedDescription)"
            // Do NOT update lastScanTimeKey — next poll will retry the same window.
        }
    }

    // MARK: - API

    private struct AirtableRecord {
        let id: String
        let createdTime: Date
        let fields: [String: Any]
    }

    /// Fetch records where `jobField` is non-empty and was last modified after `cutoff`.
    /// Paginates fully; both `docketField` and `jobField` are requested so a single API
    /// call returns everything needed.
    private func fetchRecordsJobFieldAssignedAfter(
        cutoff:      Date,
        baseID:      String,
        tableID:     String,
        jobField:    String,
        docketField: String,
        apiKey:      String
    ) async throws -> [AirtableRecord] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cutoffString = formatter.string(from: cutoff)

        let jobRef = Self.airtableFieldReference(jobField)
        let filterFormula = "AND(NOT(\(jobRef)=\"\"), IS_AFTER(LAST_MODIFIED_TIME(\(jobRef)), '\(cutoffString)'))"

        let urlString = "\(baseURL)/\(baseID)/\(tableID)"
        var results: [AirtableRecord] = []
        var offset: String? = nil

        repeat {
            var components = URLComponents(string: urlString)
            var items: [URLQueryItem] = [
                URLQueryItem(name: "filterByFormula", value: filterFormula),
                URLQueryItem(name: "pageSize", value: "100")
            ]
            if let offset {
                items.append(URLQueryItem(name: "offset", value: offset))
            }
            components?.queryItems = items

            guard let url = components?.url else { throw AirtableError.invalidURL }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw AirtableError.invalidResponse
            }
            guard http.statusCode == 200 else {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let err  = json["error"] as? [String: Any],
                   let msg  = err["message"] as? String {
                    throw AirtableError.apiError(msg)
                }
                throw AirtableError.apiError("HTTP \(http.statusCode)")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AirtableError.invalidResponse
            }

            let rawRecords = json["records"] as? [[String: Any]] ?? []
            for raw in rawRecords {
                guard let id     = raw["id"]          as? String,
                      let ctStr  = raw["createdTime"] as? String,
                      let fields = raw["fields"]      as? [String: Any] else { continue }
                let ct = formatter.date(from: ctStr) ?? Date.distantPast
                results.append(AirtableRecord(id: id, createdTime: ct, fields: fields))
            }

            offset = json["offset"] as? String

            // Fix 6: persist progress after each page so a mid-pagination quit doesn't lose work.
            saveSeenRecords()

        } while offset != nil

        return results
    }

    /// Wraps an Airtable field name for use inside `filterByFormula` (curly-brace syntax).
    /// Fix 5: escapes backslashes and `}` so custom field names can't break the formula.
    private static func airtableFieldReference(_ name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "}", with: "\\}")
        return "{\(escaped)}"
    }

    // MARK: - Notification

    /// - Returns: `true` if a new notification was added; `false` if skipped (duplicate already listed).
    @discardableResult
    private func createNotification(docketNumber: String, jobName: String, recordId: String) -> Bool {
        guard let nc = notificationCenter else { return false }

        let alreadyExists = nc.notifications.contains {
            $0.type == .newDocket && $0.docketNumber == docketNumber
        }
        guard !alreadyExists else { return false }

        let message = jobName.isEmpty
            ? "Docket \(docketNumber)"
            : "Docket \(docketNumber): \(jobName)"

        let notification = Notification(
            type: .newDocket,
            title: "New Docket Detected",
            message: message,
            docketNumber: docketNumber,
            jobName: jobName.isEmpty ? nil : jobName
        )

        nc.add(notification)

        NotificationService.shared.showNewDocketNotification(
            docketNumber: docketNumber,
            jobName: jobName
        )

        #if DEBUG
        print("AirtableDocketScanningService: ✅ Created notification for docket \(docketNumber) — \(jobName)")
        #endif
        return true
    }

    // MARK: - Validation

    private func isValidDocketNumber(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let base: String
        if let dash  = trimmed.firstIndex(of: "-"),
           dash > trimmed.startIndex,
           let suf   = trimmed.index(dash, offsetBy: 1, limitedBy: trimmed.endIndex),
           (2...3).contains(trimmed.distance(from: suf, to: trimmed.endIndex)),
           trimmed[suf...].allSatisfy({ $0.isLetter }) {
            base = String(trimmed[..<dash])
        } else {
            base = trimmed
        }

        guard base.count == 5, base.allSatisfy(\.isNumber) else { return false }

        let cal              = Calendar.current
        let currentYearLast2 = cal.component(.year, from: Date()) % 100
        let nextYearLast2    = (currentYearLast2 + 1) % 100
        guard let prefix     = Int(String(base.prefix(2))) else { return false }
        return prefix == currentYearLast2 || prefix == nextYearLast2
    }

    /// Fix 3: skip only when the docket is confirmed to exist in Work Picture.
    /// Simian check is removed — we have no pre-fetched Simian list at scan time and
    /// the previous implementation unconditionally returned false anyway.
    private func shouldSkipAlreadyProvisioned(docketNumber: String) -> Bool {
        guard let mm = mediaManager else { return false }
        return DocketDuplicateDetection.workPictureContainsDocketNumber(docketNumber, dockets: mm.dockets)
    }

    // MARK: - Periodic scanning

    private func startPeriodicScanning() {
        let interval: TimeInterval = 3 * 60

        scanningTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, self.isEnabled else { break }
                await self.scanNow()
            }
        }
    }

    // MARK: - Seen-record helpers

    private func markSeen(_ id: String) {
        seenRecordIds.insert(id)
        if seenRecordDates[id] == nil {
            seenRecordDates[id] = Date()
        }
    }

    /// Fix 2: remove entries older than 60 days to bound storage growth.
    private func pruneOldSeenRecords() {
        let cutoff = Date().addingTimeInterval(-60 * 24 * 3600)
        let stale  = seenRecordDates.filter { $0.value < cutoff }.map(\.key)
        for id in stale {
            seenRecordIds.remove(id)
            seenRecordDates.removeValue(forKey: id)
        }
        if !stale.isEmpty {
            print("AirtableDocketScanningService: pruned \(stale.count) old seen record(s)")
        }
    }

    // MARK: - Persistence

    private func loadSeenRecords() {
        if let data = UserDefaults.standard.data(forKey: seenRecordIdsKey),
           let ids  = try? JSONDecoder().decode(Set<String>.self, from: data) {
            seenRecordIds = ids
        }
        if let data  = UserDefaults.standard.data(forKey: seenRecordDatesKey),
           let dates = try? JSONDecoder().decode([String: Date].self, from: data) {
            seenRecordDates = dates
        }
        // Back-fill dates for legacy ids that have no date entry.
        let now = Date()
        for id in seenRecordIds where seenRecordDates[id] == nil {
            seenRecordDates[id] = now
        }
    }

    private func saveSeenRecords() {
        if let data = try? JSONEncoder().encode(seenRecordIds) {
            UserDefaults.standard.set(data, forKey: seenRecordIdsKey)
        }
        if let data = try? JSONEncoder().encode(seenRecordDates) {
            UserDefaults.standard.set(data, forKey: seenRecordDatesKey)
        }
    }

    func clearSeenRecords() {
        seenRecordIds.removeAll()
        seenRecordDates.removeAll()
        saveSeenRecords()
        UserDefaults.standard.removeObject(forKey: lastScanTimeKey)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
