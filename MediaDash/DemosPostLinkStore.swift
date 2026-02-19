//
//  DemosPostLinkStore.swift
//  MediaDash
//
//  Shared logic for linking Demos and Post tasks (same job, can span days).
//  Supports manual link/unlink overrides persisted in UserDefaults.
//

import Foundation

struct DemosPostLinkStore {
    private static let manualLinksKey = "mediaDash.demosPostManualLinks"
    private static let manualUnlinksKey = "mediaDash.demosPostManualUnlinks"
    private static let dueDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// Canonical pair key for storing (demosGid, postGid) — order-independent
    private static func pairKey(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "|")
    }

    /// Manual links: user explicitly linked these pairs
    static var manualLinks: Set<String> {
        get {
            (UserDefaults.standard.array(forKey: manualLinksKey) as? [String])?.reduce(into: Set()) { $0.insert($1) } ?? []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: manualLinksKey)
        }
    }

    /// Manual unlinks: user explicitly unlinked these pairs
    static var manualUnlinks: Set<String> {
        get {
            (UserDefaults.standard.array(forKey: manualUnlinksKey) as? [String])?.reduce(into: Set()) { $0.insert($1) } ?? []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: manualUnlinksKey)
        }
    }

    static func addManualLink(demosGid: String, postGid: String) {
        var u = manualUnlinks
        u.remove(pairKey(demosGid, postGid))
        manualUnlinks = u
        var l = manualLinks
        l.insert(pairKey(demosGid, postGid))
        manualLinks = l
    }

    static func addManualUnlink(demosGid: String, postGid: String) {
        var l = manualLinks
        l.remove(pairKey(demosGid, postGid))
        manualLinks = l
        var u = manualUnlinks
        u.insert(pairKey(demosGid, postGid))
        manualUnlinks = u
    }

    static func removeManualOverride(demosGid: String, postGid: String) {
        let key = pairKey(demosGid, postGid)
        var l = manualLinks
        var u = manualUnlinks
        l.remove(key)
        u.remove(key)
        manualLinks = l
        manualUnlinks = u
    }

    /// Whether a pair is manually unlinked
    static func isManuallyUnlinked(demosGid: String, postGid: String) -> Bool {
        manualUnlinks.contains(pairKey(demosGid, postGid))
    }

    /// Whether a pair is manually linked
    static func isManuallyLinked(demosGid: String, postGid: String) -> Bool {
        manualLinks.contains(pairKey(demosGid, postGid))
    }

    /// Date-only due key (`yyyy-MM-dd`) used for calendar matching/sorting.
    static func dueDateKey(_ task: AsanaTask) -> String {
        String((task.effectiveDueDate ?? "").prefix(10))
    }

    private static func dueDate(_ task: AsanaTask) -> Date? {
        let key = dueDateKey(task)
        guard !key.isEmpty else { return nil }
        return dueDateFormatter.date(from: key)
    }

    private static func dayDistance(demos: AsanaTask, post: AsanaTask) -> Int? {
        guard let demosDate = dueDate(demos), let postDate = dueDate(post) else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: demosDate)
        let end = calendar.startOfDay(for: postDate)
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    // MARK: - Linking logic (shared with AsanaTaskDetailView)

    /// Extract docket/job identifier from task name, e.g. "Bet365" from "DEMOS - Bet365 @12pm ME"
    static func docketIdentifierFromTaskName(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let dash = n.firstIndex(of: "–") ?? n.firstIndex(of: "-") else { return "" }
        let after = n[n.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if let at = after.firstIndex(of: "@") {
            return String(after[..<at]).trimmingCharacters(in: .whitespaces)
        }
        return after
    }

    /// Whether Demos and Post represent the same job (parent, project, or name identifier).
    /// When both have extractable identifiers, requires them to match.
    static func isSameDocketOrProject(demos: AsanaTask, post: AsanaTask) -> Bool {
        let id1 = docketIdentifierFromTaskName(demos.name)
        let id2 = docketIdentifierFromTaskName(post.name)
        if !id1.isEmpty && !id2.isEmpty {
            if id1.lowercased() != id2.lowercased() { return false }
        }
        if let p1 = demos.parent?.gid, let p2 = post.parent?.gid, p1 == p2 { return true }
        let proj1 = Set(demos.memberships?.compactMap { $0.project?.gid } ?? [])
        let proj2 = Set(post.memberships?.compactMap { $0.project?.gid } ?? [])
        if !proj1.isDisjoint(with: proj2) { return true }
        return !id1.isEmpty && !id2.isEmpty && id1.lowercased() == id2.lowercased()
    }

    /// Find the linked Post task for a Demos task. Respects manual overrides.
    /// - Parameters:
    ///   - demos: The Demos/Submit task to match.
    ///   - postCandidates: Candidate Post tasks (can include other days).
    ///   - maxDayDistance: Optional absolute day-distance cap for automatic matches.
    ///                     Manual links are always honored even beyond this range.
    static func resolveLinkedPost(demos: AsanaTask, postCandidates: [AsanaTask], maxDayDistance: Int? = nil) -> AsanaTask? {
        let demosId = docketIdentifierFromTaskName(demos.name).lowercased()
        let filteredCandidates = postCandidates.filter { other in
            guard other.gid != demos.gid, other.name.lowercased().contains("post") else { return false }
            if isManuallyUnlinked(demosGid: demos.gid, postGid: other.gid) { return false }
            if isManuallyLinked(demosGid: demos.gid, postGid: other.gid) { return true }
            guard isSameDocketOrProject(demos: demos, post: other) else { return false }
            if let maxDayDistance,
               let distance = dayDistance(demos: demos, post: other),
               abs(distance) > maxDayDistance {
                return false
            }
            return true
        }

        return filteredCandidates.sorted { lhs, rhs in
            let lhsManual = isManuallyLinked(demosGid: demos.gid, postGid: lhs.gid)
            let rhsManual = isManuallyLinked(demosGid: demos.gid, postGid: rhs.gid)
            if lhsManual != rhsManual { return lhsManual && !rhsManual }

            let lhsIdMatch = !demosId.isEmpty && docketIdentifierFromTaskName(lhs.name).lowercased() == demosId
            let rhsIdMatch = !demosId.isEmpty && docketIdentifierFromTaskName(rhs.name).lowercased() == demosId
            if lhsIdMatch != rhsIdMatch { return lhsIdMatch && !rhsIdMatch }

            let lhsDistance = abs(dayDistance(demos: demos, post: lhs) ?? Int.max)
            let rhsDistance = abs(dayDistance(demos: demos, post: rhs) ?? Int.max)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }

            let lhsDate = dueDate(lhs) ?? .distantFuture
            let rhsDate = dueDate(rhs) ?? .distantFuture
            if lhsDate != rhsDate { return lhsDate < rhsDate }

            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.gid < rhs.gid
        }.first
    }

    /// Compute linked pairs for Demos and Post task sets.
    /// A Post can only be linked once in a given pass to avoid duplicate pair rows.
    static func linkedPairs(demosTasks: [AsanaTask], postTasks: [AsanaTask], maxDayDistance: Int? = nil) -> (pairs: [(AsanaTask, AsanaTask)], linkedPostGids: Set<String>) {
        var pairs: [(AsanaTask, AsanaTask)] = []
        var linkedPostGids = Set<String>()

        for demos in demosTasks {
            let availablePosts = postTasks.filter { !linkedPostGids.contains($0.gid) }
            if let post = resolveLinkedPost(demos: demos, postCandidates: availablePosts, maxDayDistance: maxDayDistance) {
                pairs.append((demos, post))
                linkedPostGids.insert(post.gid)
            }
        }
        return (pairs, linkedPostGids)
    }

    /// Convenience for same-day media lists.
    static func linkedPairsForDay(_ mediaTasks: [AsanaTask]) -> (pairs: [(AsanaTask, AsanaTask)], linkedPostGids: Set<String>) {
        let demosTasks = mediaTasks.filter { isDemosTask($0) }
        let postTasks = mediaTasks.filter { isPostTask($0) }
        return linkedPairs(demosTasks: demosTasks, postTasks: postTasks)
    }

    static func isDemosTask(_ task: AsanaTask) -> Bool {
        let n = task.name.lowercased()
        return n.contains("demos") || n.contains("demo ") || n.contains("submit")
    }

    static func isPostTask(_ task: AsanaTask) -> Bool {
        task.name.lowercased().contains("post")
    }
}
