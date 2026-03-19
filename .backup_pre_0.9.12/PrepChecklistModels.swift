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
}

enum PrepChecklistParser {
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
