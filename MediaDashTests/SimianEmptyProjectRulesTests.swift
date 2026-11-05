//
//  SimianEmptyProjectRulesTests.swift
//  MediaDashTests
//

import XCTest
@testable import MediaDash

final class SimianEmptyProjectRulesTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 15))
    }

    func testReportedSizeAtOrUnder64KBIsEmpty() {
        XCTAssertTrue(SimianEmptyProjectRules.isEmpty(reportedSizeBytes: 0))
        XCTAssertTrue(SimianEmptyProjectRules.isEmpty(reportedSizeBytes: 33 * 1024))
        XCTAssertTrue(SimianEmptyProjectRules.isEmpty(reportedSizeBytes: 64 * 1024))
        XCTAssertFalse(SimianEmptyProjectRules.isEmpty(reportedSizeBytes: 64 * 1024 + 1))
        XCTAssertFalse(SimianEmptyProjectRules.isEmpty(reportedSizeBytes: nil))
    }

    func testSimian33KBShellCountsAsEmpty() {
        let info = SimianProjectInfo(
            id: "1",
            name: "26120_Lazer Sonic Branding",
            projectNumber: nil,
            uploadDate: nil,
            startDate: nil,
            completeDate: nil,
            lastAccess: "2026-01-01",
            projectSize: "33 KB"
        )
        XCTAssertTrue(SimianEmptyProjectRules.isEmpty(reportedSizeBytes: info.projectSizeBytes))
    }

    func testEmptyAndLastAccessOlderThanThreeMonthsIsDeletable() {
        let cutoff = calendar.date(byAdding: .month, value: -3, to: now)!
        XCTAssertTrue(isDeletable(archived: false, size: 33 * 1024, lastAccess: cutoff.addingTimeInterval(-1)))
        XCTAssertFalse(isDeletable(archived: false, size: 33 * 1024, lastAccess: cutoff))
        XCTAssertFalse(isDeletable(archived: false, size: 33 * 1024, lastAccess: cutoff.addingTimeInterval(1)))
        XCTAssertFalse(isDeletable(archived: false, size: 33 * 1024, lastAccess: nil))
    }

    func testPopulatedUnarchivedJobIsNotDeletable() {
        let old = calendar.date(byAdding: .year, value: -1, to: now)!
        XCTAssertFalse(isDeletable(archived: false, size: 5 * 1024 * 1024, lastAccess: old))
        XCTAssertFalse(isDeletable(archived: false, size: nil, lastAccess: old))
    }

    func testArchivedJobIsDeletableRegardlessOfSizeOrAge() {
        XCTAssertTrue(isDeletable(archived: true, size: 80 * 1024 * 1024, lastAccess: now))
        XCTAssertTrue(isDeletable(archived: true, size: nil, lastAccess: nil))
    }

    func testPartitionKeepsPopulatedJobsAndSkipsEmptyOnes() {
        let empty = project("e", "Empty")
        let full = project("f", "Full")
        let unknown = project("u", "Unknown")
        let sizes: [String: Int64] = ["e": 33 * 1024, "f": 8 * 1024 * 1024]
        let split = SimianEmptyProjectRules.partitionForArchive([empty, full, unknown], reportedSizeBytesById: sizes)
        XCTAssertEqual(split.toArchive.map(\.id), ["f", "u"])
        XCTAssertEqual(split.skippedEmpty.map(\.id), ["e"])
    }

    func testDeletionTargetsIncludeArchivedAndOldEmptyFromTheSelection() {
        let archived = project("a", "Archived")
        let oldEmpty = project("e", "Old empty")
        let recentEmpty = project("r", "Recent empty")
        let populated = project("p", "Populated")
        let displayed = [archived, oldEmpty, recentEmpty, populated]
        let targets = SimianEmptyProjectRules.deletionTargets(
            clicked: recentEmpty,
            isClickedSelected: true,
            displayedProjects: displayed,
            selectedIds: Set(displayed.map(\.id)),
            deletableIds: ["a", "e"]
        )
        XCTAssertEqual(targets.map(\.id), ["a", "e"])
    }

    func testUnselectedClickDeletesOnlyThatJobWhenItQualifies() {
        let archived = project("a", "Archived")
        let other = project("b", "Other")
        let alone = SimianEmptyProjectRules.deletionTargets(
            clicked: archived,
            isClickedSelected: false,
            displayedProjects: [archived, other],
            selectedIds: ["b"],
            deletableIds: ["a"]
        )
        XCTAssertEqual(alone.map(\.id), ["a"])

        let recent = project("r", "Recent")
        let none = SimianEmptyProjectRules.deletionTargets(
            clicked: recent,
            isClickedSelected: false,
            displayedProjects: [recent],
            selectedIds: [],
            deletableIds: []
        )
        XCTAssertTrue(none.isEmpty)
    }

    func testStatusMentionsSkippedEmptyProjects() {
        XCTAssertEqual(
            SimianEmptyProjectRules.nothingToDownloadMessage(skippedEmptyCount: 1),
            "Skipped 1 empty project. Nothing to download."
        )
        XCTAssertEqual(
            SimianEmptyProjectRules.nothingToDownloadMessage(skippedEmptyCount: 15),
            "Skipped 15 empty projects. Nothing to download."
        )
        XCTAssertEqual(
            SimianEmptyProjectRules.appendingSkippedEmpty("Archive complete.", count: 0),
            "Archive complete."
        )
        XCTAssertEqual(
            SimianEmptyProjectRules.appendingSkippedEmpty("Archive complete with 1 failure(s).", count: 2),
            "Archive complete with 1 failure(s). Skipped 2 empty projects."
        )
    }

    private func isDeletable(archived: Bool, size: Int64?, lastAccess: Date?) -> Bool {
        SimianEmptyProjectRules.isDeletable(
            isArchived: archived,
            reportedSizeBytes: size,
            lastAccess: lastAccess,
            now: now,
            calendar: calendar
        )
    }

    private func project(_ id: String, _ name: String) -> SimianProject {
        SimianProject(id: id, name: name, accessAreas: nil)
    }
}

final class SimianArchiverExclusionsTests: XCTestCase {

    func testPermanentProjectsStayOutOfTheArchiver() {
        XCTAssertTrue(SimianArchiverExclusions.isHidden(project("91", "Whatever")))
        XCTAssertTrue(SimianArchiverExclusions.isHidden(project("459", "Whatever")))
        XCTAssertTrue(SimianArchiverExclusions.isHidden(project("1", "Misc/UNARCHIVE_Delete Every 3 Months")))
        XCTAssertTrue(SimianArchiverExclusions.isHidden(project("332", "2xxxx_Tom Westin_Jazz_VN_Do Not Delete")))
        XCTAssertTrue(SimianArchiverExclusions.isHidden(project("348", "24xxx_SizzleReel")))
        XCTAssertTrue(SimianArchiverExclusions.isHidden(project("999", "2xxxx_Tom Westin_Jazz_VN_Do Not Delete")))
        XCTAssertTrue(SimianArchiverExclusions.isHidden(project("999", "24xxx_SizzleReel")))
    }

    func testOrdinaryProjectIsListed() {
        XCTAssertFalse(SimianArchiverExclusions.isHidden(project("26020", "26020_Sephora x Tempo")))
    }

    private func project(_ id: String, _ name: String) -> SimianProject {
        SimianProject(id: id, name: name, accessAreas: nil)
    }
}

final class SimianUnarchiveCleanupTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!
    private var cutoff: Date!

    override func setUp() {
        super.setUp()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 15))
        cutoff = calendar.date(byAdding: .month, value: -3, to: now)
    }

    func testOnlyTopLevelUploadDateDecidesRemoval() {
        let old = folder("old", "Old drop", cutoff.addingTimeInterval(-1))
        let recent = folder("recent", "Recent", cutoff.addingTimeInterval(1))
        let undated = folder("undated", "No date", nil)
        let plan = SimianUnarchiveCleanup.removalPlan([old, recent, undated], now: now, calendar: calendar)
        XCTAssertEqual(plan.due.map(\.id), ["old"])
        XCTAssertEqual(plan.undatedCount, 1)
    }

    func testCreatedAtUsesTheEarliestFileUpload() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 500)
        XCTAssertEqual(SimianUnarchiveCleanup.createdAt(fromFileUploadDates: [newer, older]), older)
        XCTAssertNil(SimianUnarchiveCleanup.createdAt(fromFileUploadDates: []))
    }

    func testFolderUploadedExactlyThreeMonthsAgoStays() {
        let exact = folder("exact", "Exact", cutoff)
        let plan = SimianUnarchiveCleanup.removalPlan([exact], now: now, calendar: calendar)
        XCTAssertTrue(plan.due.isEmpty)
    }

    private func folder(_ id: String, _ name: String, _ uploadedAt: Date?) -> SimianUnarchiveCleanup.Folder {
        SimianUnarchiveCleanup.Folder(id: id, name: name, uploadedAt: uploadedAt)
    }
}
