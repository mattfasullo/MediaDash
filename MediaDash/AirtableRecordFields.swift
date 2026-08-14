import Foundation

/// Pure helpers for Airtable list-records JSON and new-docket filter formulas.
enum AirtableRecordFields {
    /// Match Airtable keys that differ by case or a leading UTF-8 BOM (CSV import artifact).
    static func normalizedFieldKey(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "\u{FEFF}" {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.lowercased()
    }

    /// Coerce an Airtable cell to a trimmed string. Empty after trim is `nil`.
    static func stringValue(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = raw as? Bool {
            return n ? "true" : "false"
        }
        if let n = raw as? Int {
            return String(n)
        }
        if let n = raw as? Int64 {
            return String(n)
        }
        if let n = raw as? Double {
            if n.rounded() == n, n >= Double(Int.min), n <= Double(Int.max) {
                return String(Int(n))
            }
            return String(n)
        }
        if let n = raw as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return stringValue(n.doubleValue)
        }
        return nil
    }

    /// Look up a cell by field ID (when `returnFieldsByFieldId=true`) then by display names.
    static func string(in fields: [String: Any], fieldID: String? = nil, names: [String]) -> String? {
        if let fieldID, let value = stringValue(fields[fieldID]) {
            return value
        }
        let wanted = Set(names.map(normalizedFieldKey))
        for (key, value) in fields {
            if wanted.contains(normalizedFieldKey(key)) {
                return stringValue(value)
            }
        }
        return nil
    }

    /// True if the JSON payload contains the field (ID or name), even when the value is empty.
    static func hasField(in fields: [String: Any], fieldID: String? = nil, names: [String]) -> Bool {
        if let fieldID, fields[fieldID] != nil { return true }
        let wanted = Set(names.map(normalizedFieldKey))
        return fields.keys.contains { wanted.contains(normalizedFieldKey($0)) }
    }
}

enum AirtableDocketScanFilter {
    /// `filterByFormula` for titled rows whose **record** (not a single column) changed after `cutoff`.
    static func recentlyModifiedNonemptyJobFormula(jobFieldReference: String, cutoff: Date) -> String {
        let jobRef = airtableFieldReference(jobFieldReference)
        let cutoffString = iso8601CutoffString(from: cutoff)
        return "AND(NOT(\(jobRef)=\"\"), IS_AFTER(LAST_MODIFIED_TIME(), '\(cutoffString)'))"
    }

    static func airtableFieldReference(_ nameOrID: String) -> String {
        let escaped = nameOrID
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "}", with: "\\}")
        return "{\(escaped)}"
    }

    static func iso8601CutoffString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
