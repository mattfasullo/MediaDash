//
//  SimianLooseFileFolderNamingTests.swift
//  MediaDashTests
//

import XCTest
@testable import MediaDash

final class SimianLooseFileFolderNamingTests: XCTestCase {

    func testNumberedPrefixValues_extractsIndices() {
        let names = ["01_Foo", "02_Bar", "99_x", "no_prefix", "123_abc"]
        let values = SimianFolderNaming.numberedPrefixValues(from: names)
        XCTAssertEqual(values, Set([1, 2, 99, 123]))
    }

    func testNextDateStampedLooseFileFolderName_emptySiblings_startsAt01() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 12))!
        let name = SimianFolderNaming.nextDateStampedLooseFileFolderName(existingFolderNames: [], date: date, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(name, "01_Apr01.26")
    }

    func testNextDateStampedLooseFileFolderName_incrementsFromExisting() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 12))!
        let existing = ["01_Jan15.26", "02_Feb01.26", "03_Mar10.26"]
        let name = SimianFolderNaming.nextDateStampedLooseFileFolderName(existingFolderNames: existing, date: date, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(name, "04_Apr01.26")
    }

    func testShouldAutoNestLooseFiles_caseInsensitive() {
        XCTAssertTrue(SimianFolderNaming.shouldAutoNestLooseFiles(inDestinationFolderNamed: "POSTINGS"))
        XCTAssertTrue(SimianFolderNaming.shouldAutoNestLooseFiles(inDestinationFolderNamed: "postings"))
        XCTAssertTrue(SimianFolderNaming.shouldAutoNestLooseFiles(inDestinationFolderNamed: " Picture "))
        XCTAssertFalse(SimianFolderNaming.shouldAutoNestLooseFiles(inDestinationFolderNamed: "OTHER"))
        XCTAssertFalse(SimianFolderNaming.shouldAutoNestLooseFiles(inDestinationFolderNamed: nil))
        XCTAssertFalse(SimianFolderNaming.shouldAutoNestLooseFiles(inDestinationFolderNamed: ""))
    }

    func testStemHasSimianDateSuffix_recognizesOneOrTwoDigitDay() {
        XCTAssertTrue(SimianFolderNaming.stemHasSimianDateSuffix("Cue_Apr8.26"))
        XCTAssertTrue(SimianFolderNaming.stemHasSimianDateSuffix("Cue_Apr08.26"))
        XCTAssertFalse(SimianFolderNaming.stemHasSimianDateSuffix("Cue_NoDateHere"))
    }

    func testFullLabelByAppendingDateStamp_beforeExtension() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 12))!
        let out = SimianFolderNaming.fullLabelByAppendingDateStamp("Mix.mov", date: date, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(out, "Mix_Apr08.26.mov")
    }

    func testFullLabelByAppendingDateStamp_skipsWhenStemAlreadyDated() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 12))!
        XCTAssertNil(SimianFolderNaming.fullLabelByAppendingDateStamp("Mix_Apr08.26.mov", date: date, timeZone: TimeZone(secondsFromGMT: 0)))
    }

    /// Regression: `pathExtension` used to treat `.26` as `26`, hiding `_Apr08.26` and producing `_Apr08.26.26`.
    func testFullLabelByAppendingDateStamp_skipsWhenFolderNameEndsWithUnderscoreDateDotYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 12))!
        XCTAssertNil(
            SimianFolderNaming.fullLabelByAppendingDateStamp(
                "06_Safeway_Apr7_Apr08.26",
                date: date,
                timeZone: TimeZone(secondsFromGMT: 0)
            )
        )
    }
}
