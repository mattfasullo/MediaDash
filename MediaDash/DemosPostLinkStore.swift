//
//  DemosPostLinkStore.swift
//  MediaDash
//
//  Shared logic for linking Demos and Post tasks (same job, same day).
//  Supports manual link/unlink overrides persisted in UserDefaults.
//

import Foundation

struct DemosPostLinkStore {
    private static let manualLinksKey = "mediaDash.demosPostManualLinks"
    private static let manualUnlinksKey = "mediaDash.demosPostManualUnlinks"

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
    static func resolveLinkedPost(demos: AsanaTask, sameDayPosts: [AsanaTask]) -> AsanaTask? {
        let demosId = docketIdentifierFromTaskName(demos.name)
        let postCandidates = sameDayPosts.filter { other in
            guard other.gid != demos.gid, other.name.lowercased().contains("post") else { return false }
            if isManuallyUnlinked(demosGid: demos.gid, postGid: other.gid) { return false }
            if isManuallyLinked(demosGid: demos.gid, postGid: other.gid) { return true }
            return isSameDocketOrProject(demos: demos, post: other)
        }
        if !demosId.isEmpty,
           let nameMatch = postCandidates.first(where: { docketIdentifierFromTaskName($0.name).lowercased() == demosId.lowercased() }) {
            return nameMatch
        }
        return postCandidates.first
    }

    /// Compute linked pairs for a day's media tasks. Returns [(demos, post)] and Set of post GIDs that are linked (so we don't show them standalone).
    static func linkedPairsForDay(_ mediaTasks: [AsanaTask]) -> (pairs: [(AsanaTask, AsanaTask)], linkedPostGids: Set<String>) {
        let demosTasks = mediaTasks.filter { isDemosTask($0) }
        let postTasks = mediaTasks.filter { isPostTask($0) }
        var pairs: [(AsanaTask, AsanaTask)] = []
        var linkedPostGids = Set<String>()

        for demos in demosTasks {
            if let post = resolveLinkedPost(demos: demos, sameDayPosts: postTasks) {
                pairs.append((demos, post))
                linkedPostGids.insert(post.gid)
            }
        }
        return (pairs, linkedPostGids)
    }

    static func isDemosTask(_ task: AsanaTask) -> Bool {
        let n = task.name.lowercased()
        return n.contains("demos") || n.contains("demo ") || n.contains("submit")
    }

    static func isPostTask(_ task: AsanaTask) -> Bool {
        task.name.lowercased().contains("post")
    }
}
