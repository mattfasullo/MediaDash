import Foundation

struct PrepChecklistItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var assignedFileIds: Set<UUID>

    init(id: UUID = UUID(), title: String, assignedFileIds: Set<UUID> = []) {
        self.id = id
        self.title = title
        self.assignedFileIds = assignedFileIds
    }
}

struct PrepChecklistSession: Identifiable, Hashable {
    let id: UUID
    let docket: String
    let createdAt: Date
    var items: [PrepChecklistItem]
    var rawChecklistText: String

    init(
        id: UUID = UUID(),
        docket: String,
        createdAt: Date = Date(),
        items: [PrepChecklistItem],
        rawChecklistText: String
    ) {
        self.id = id
        self.docket = docket
        self.createdAt = createdAt
        self.items = items
        self.rawChecklistText = rawChecklistText
    }

    /// All file IDs that are assigned to any checklist item (used to skip format-based copy for those files).
    var allAssignedFileIds: Set<UUID> {
        Set(items.flatMap { $0.assignedFileIds })
    }
}

enum PrepChecklistParser {
    /// Parse pasted checklist text (e.g. from manual paste)
    static func parseItems(from text: String) -> [PrepChecklistItem] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleaned = lines.compactMap { line -> String? in
            let trimmed = trimLeadingBullet(line)
            return trimmed.isEmpty ? nil : trimmed
        }

        return cleaned.map { PrepChecklistItem(title: $0) }
    }
    
    /// Parse checklist from Asana task notes (session description).
    /// Keeps section headers (e.g. "ENGINEER:"), numbered items ("1. Deliverables:"), and content lines.
    /// Skips separator lines (e.g. "___________________").
    static func parseItemsFromAsanaNotes(_ notes: String?) -> [PrepChecklistItem] {
        guard let notes = notes, !notes.isEmpty else { return [] }
        
        let lines = notes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        var items: [PrepChecklistItem] = []
        for line in lines {
            guard !line.isEmpty else { continue }
            // Skip separator lines (only underscores, dashes, spaces)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.allSatisfy({ $0 == "_" || $0 == "-" || $0 == " " }) {
                continue
            }
            let title = trimLeadingBullet(line)
            if title.isEmpty { continue }
            items.append(PrepChecklistItem(title: title))
        }
        return items
    }

    private static func trimLeadingBullet(_ line: String) -> String {
        var text = line

        // Remove common bullet prefixes
        let bulletPrefixes = ["•", "-", "*", "–", "—"]
        for bullet in bulletPrefixes {
            if text.hasPrefix(bullet) {
                text = text.dropFirst(bullet.count).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Remove numeric prefixes like "1." or "1)"
        if let range = text.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
