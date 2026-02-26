import Foundation

// MARK: - Contact Entry (one row from Contacts CSV)

/// One row from the contacts CSV: a person at a company with role, location, etc.
struct ContactEntry: Identifiable, Equatable {
    var id: String { "\(normalizedPersonKey)_\(normalizedCompany)" }
    let company: String
    let name: String
    let email: String
    let role: String
    let city: String
    let country: String

    /// Stable key for deduplicating people (prefer email, else name)
    var normalizedPersonKey: String {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !e.isEmpty { return e }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedCompany: String {
        company.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Contacts CSV Parser

/// Parses CSV or TSV with columns: Company, Name, Email, Role, City, Country (and optional Bounced columns).
enum ContactsCSVParser {
    static let defaultColumnNames = ["Company", "Name", "Email", "Role", "City", "Country"]

    /// Parse file content into contact entries. Auto-detects TSV (tabs) vs CSV (commas). Uses first row as header.
    nonisolated static func parse(content: String, fileExtension: String? = nil) -> [ContactEntry] {
        var raw = content
        if raw.hasPrefix("\u{FEFF}") { raw = String(raw.dropFirst()) }
        let useTSV: Bool
        if let ext = fileExtension?.lowercased(), ext == "tsv" || ext == "txt" {
            useTSV = true
        } else {
            let firstLine = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            useTSV = firstLine.contains("\t")
        }
        if useTSV {
            return parseTSV(content: raw)
        }
        return parse(csvContent: raw)
    }

    /// Parse CSV content string into contact entries. Uses first row as header.
    nonisolated static func parse(csvContent: String) -> [ContactEntry] {
        var content = csvContent
        if content.hasPrefix("\u{FEFF}") { content = String(content.dropFirst()) }
        let rows = parseCSVRows(content)
        guard let headerRow = rows.first else { return [] }
        let columnMap = buildColumnMap(headerRow)
        let entries = entriesFromRows(Array(rows.dropFirst()), columnMap: columnMap)
        if entries.isEmpty && rows.count > 1 {
            return parseSemicolonFallback(csvContent: content)
        }
        return entries
    }

    /// Parse TSV (tab-separated) content. More reliable than CSV when data contains commas.
    private nonisolated static func parseTSV(content: String) -> [ContactEntry] {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.isEmpty }
        guard let firstLine = lines.first else { return [] }
        let headerRow = firstLine.split(separator: "\t", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let columnMap = buildColumnMap(headerRow)
        let dataRows = lines.dropFirst().map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return entriesFromRows(Array(dataRows), columnMap: columnMap)
    }

    private nonisolated static func entriesFromRows(_ rows: [[String]], columnMap: [String: Int]) -> [ContactEntry] {
        let nameIdx = columnMap["Name"] ?? columnMap["name"] ?? 1
        let companyIdx = columnMap["Company"] ?? columnMap["company"] ?? 0
        let emailIdx = columnMap["Email"] ?? columnMap["email"] ?? 2
        let roleIdx = columnMap["Role"] ?? columnMap["role"] ?? 3
        let cityIdx = columnMap["City"] ?? columnMap["city"] ?? 4
        let countryIdx = columnMap["Country"] ?? columnMap["country"] ?? 5
        var entries: [ContactEntry] = []
        for row in rows {
            let company = row.count > companyIdx ? row[companyIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let name = row.count > nameIdx ? row[nameIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let email = row.count > emailIdx ? row[emailIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let role = row.count > roleIdx ? row[roleIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let city = row.count > cityIdx ? row[cityIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let country = row.count > countryIdx ? row[countryIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !company.isEmpty || !name.isEmpty else { continue }
            entries.append(ContactEntry(
                company: company.isEmpty ? "—" : company,
                name: name.isEmpty ? "—" : name,
                email: email,
                role: role,
                city: city,
                country: country
            ))
        }
        return entries
    }

    /// Fallback for semicolon-separated CSV (e.g. Excel in some locales).
    private nonisolated static func parseSemicolonFallback(csvContent: String) -> [ContactEntry] {
        let lines = csvContent.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return [] }
        let headerCells = lines[0].split(separator: ";", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        var nameIdx = 1, companyIdx = 0, emailIdx = 2, roleIdx = 3, cityIdx = 4, countryIdx = 5
        for (idx, cell) in headerCells.enumerated() {
            let key = cell.hasPrefix("\u{FEFF}") ? String(cell.dropFirst()) : cell
            switch key.lowercased() {
            case "company": companyIdx = idx
            case "name": nameIdx = idx
            case "email": emailIdx = idx
            case "role": roleIdx = idx
            case "city": cityIdx = idx
            case "country": countryIdx = idx
            default: break
            }
        }
        var entries: [ContactEntry] = []
        for line in lines.dropFirst() {
            let row = line.split(separator: ";", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            let company = row.count > companyIdx ? row[companyIdx] : ""
            let name = row.count > nameIdx ? row[nameIdx] : ""
            let email = row.count > emailIdx ? row[emailIdx] : ""
            let role = row.count > roleIdx ? row[roleIdx] : ""
            let city = row.count > cityIdx ? row[cityIdx] : ""
            let country = row.count > countryIdx ? row[countryIdx] : ""
            guard !company.isEmpty || !name.isEmpty else { continue }
            entries.append(ContactEntry(
                company: company.isEmpty ? "—" : company,
                name: name.isEmpty ? "—" : name,
                email: email,
                role: role,
                city: city,
                country: country
            ))
        }
        return entries
    }

    private nonisolated static func buildColumnMap(_ headerRow: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (idx, cell) in headerRow.enumerated() {
            var key = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("\u{FEFF}") { key = String(key.dropFirst()) }
            key = key.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            if !key.isEmpty && !key.lowercased().hasPrefix("bounced") {
                map[key] = idx
                map[key.lowercased()] = idx
            }
        }
        return map
    }

    private nonisolated static func parseCSVRows(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false
        var i = content.startIndex

        while i < content.endIndex {
            let char = content[i]

            if char == "\"" {
                insideQuotes.toggle()
                i = content.index(after: i)
                continue
            }

            if !insideQuotes {
                if char == "," {
                    currentRow.append(currentField)
                    currentField = ""
                    i = content.index(after: i)
                    continue
                }
                if char == "\n" || char == "\r" || char == "\u{2028}" || char == "\u{2029}" {
                    currentRow.append(currentField)
                    currentField = ""
                    if !currentRow.isEmpty {
                        rows.append(currentRow)
                        currentRow = []
                    }
                    if char == "\r" && content.index(after: i) < content.endIndex && content[content.index(after: i)] == "\n" {
                        i = content.index(after: i)
                    }
                    i = content.index(after: i)
                    continue
                }
            }

            currentField.append(char)
            i = content.index(after: i)
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            if !currentRow.isEmpty { rows.append(currentRow) }
        }
        return rows
    }
}

// MARK: - Contacts Tree (family-tree style: people ↔ companies)

/// One node in the tree: either a company or a person.
enum ContactsTreeNode: Equatable {
    case company(name: String)
    case person(name: String, email: String, role: String, company: String)

    var displayTitle: String {
        switch self {
        case .company(let name): return name
        case .person(let name, _, _, _): return name
        }
    }
}

/// Builds a navigable "family tree" from contact entries: companies → people, people → companies.
struct ContactsTree {
    /// All entries (one per person-company pair)
    let entries: [ContactEntry]

    /// Unique companies (sorted)
    var companies: [String] {
        Set(entries.map { $0.normalizedCompany }).sorted()
    }

    /// People at a given company (with role)
    func people(atCompany company: String) -> [ContactEntry] {
        let norm = company.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { $0.normalizedCompany == norm }
    }

    /// Companies a given person has worked at (by person key: email or name)
    func companies(forPersonKey personKey: String) -> [ContactEntry] {
        let key = personKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { $0.normalizedPersonKey == key }
    }

    /// Unique person keys (for "by person" list)
    var personKeys: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for e in entries {
            let k = e.normalizedPersonKey
            if !seen.contains(k) {
                seen.insert(k)
                result.append(k)
            }
        }
        return result.sorted { displayName(forPersonKey: $0) < displayName(forPersonKey: $1) }
    }

    /// Display name for a person key (best available: name or email)
    func displayName(forPersonKey key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let first = entries.first(where: { $0.normalizedPersonKey == k }) {
            let name = first.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name != "—", !name.isEmpty { return name }
            if !first.email.isEmpty { return first.email }
        }
        return key
    }
}
