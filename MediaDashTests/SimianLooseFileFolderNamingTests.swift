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

    func testEffectiveDestinationFolderName_prefersProvidedName() {
        let out = SimianFolderNaming.effectiveDestinationFolderName(
            providedName: " FINALS ",
            folderId: "f1",
            currentFolderId: "f1",
            currentFolderName: "POSTINGS",
            cachedFolderName: "MUSIC"
        )
        XCTAssertEqual(out, "FINALS")
    }

    func testEffectiveDestinationFolderName_fallsBackToCurrentFolderName() {
        let out = SimianFolderNaming.effectiveDestinationFolderName(
            providedName: nil,
            folderId: "f1",
            currentFolderId: "f1",
            currentFolderName: "POSTINGS",
            cachedFolderName: nil
        )
        XCTAssertEqual(out, "POSTINGS")
    }

    func testEffectiveDestinationFolderName_fallsBackToCachedFolderName() {
        let out = SimianFolderNaming.effectiveDestinationFolderName(
            providedName: nil,
            folderId: "f2",
            currentFolderId: "f1",
            currentFolderName: "POSTINGS",
            cachedFolderName: "FINALS"
        )
        XCTAssertEqual(out, "FINALS")
    }

    func testEffectiveDestinationFolderName_returnsNilWithoutFolderContext() {
        let out = SimianFolderNaming.effectiveDestinationFolderName(
            providedName: nil,
            folderId: nil,
            currentFolderId: "f1",
            currentFolderName: "POSTINGS",
            cachedFolderName: "FINALS"
        )
        XCTAssertNil(out)
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

    // MARK: - fullLabelByAddingOrNormalizingSimianDate

    func testFullLabelByAddingOrNormalizing_appendsBeforeExtension() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 12))!
        let out = SimianFolderNaming.fullLabelByAddingOrNormalizingSimianDate("Mix.mov", referenceDate: ref, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(out, "Mix_Apr08.26.mov")
    }

    func testFullLabelByAddingOrNormalizing_normalizesUndersizedDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: DateComponents(year: 2026, month: 4, day: 9, hour: 12))!
        let out = SimianFolderNaming.fullLabelByAddingOrNormalizingSimianDate("Cue_Apr9.26", referenceDate: ref, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(out, "Cue_Apr09.26")
    }

    func testFullLabelByAddingOrNormalizing_extraDotMonthDayYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12))!
        let out = SimianFolderNaming.fullLabelByAddingOrNormalizingSimianDate("Spot_NOV.13.26", referenceDate: ref, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(out, "Spot_Nov13.26")
    }

    func testFullLabelByAddingOrNormalizing_noYearUsesReferenceYear() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        let out = SimianFolderNaming.fullLabelByAddingOrNormalizingSimianDate("Cue_Sept22", referenceDate: ref, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(out, "Cue_Sep22.26")
    }

    func testFullLabelByAddingOrNormalizing_noopWhenAlreadyCanonical() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 12))!
        let label = "Mix_Apr08.26.mov"
        let out = SimianFolderNaming.fullLabelByAddingOrNormalizingSimianDate(label, referenceDate: ref, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(out, label)
    }

    func testFullLabelByAddingOrNormalizing_regressionMiddleDateUnchangedByAppend() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let ref = cal.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 12))!
        let label = "06_Safeway_Apr7_Apr08.26"
        let out = SimianFolderNaming.fullLabelByAddingOrNormalizingSimianDate(label, referenceDate: ref, timeZone: TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(out, label)
    }

    // MARK: - multipart upload filename

    func testMultipartUploadFilename_videoUnchanged_noAutoDate() {
        let url = URL(fileURLWithPath: "/tmp/PURPLE.mov", isDirectory: false)
        let out = SimianFolderNaming.multipartUploadFilename(forLocalFileURL: url)
        XCTAssertEqual(out, "PURPLE.mov")
    }

    func testMultipartUploadFilename_musicExtensionUnchanged_noAutoDate() {
        let url = URL(fileURLWithPath: "/tmp/PURPLE.wav", isDirectory: false)
        let out = SimianFolderNaming.multipartUploadFilename(forLocalFileURL: url)
        XCTAssertEqual(out, "PURPLE.wav")
    }

    func testMultipartUploadFilename_passthroughAlreadyDatedName() {
        let url = URL(fileURLWithPath: "/tmp/PURPLE_Apr01.26.mov", isDirectory: false)
        let out = SimianFolderNaming.multipartUploadFilename(forLocalFileURL: url)
        XCTAssertEqual(out, "PURPLE_Apr01.26.mov")
    }

    func testMultipartUploadFilename_nonMediaUnchanged() {
        let url = URL(fileURLWithPath: "/tmp/Notes.txt", isDirectory: false)
        let out = SimianFolderNaming.multipartUploadFilename(forLocalFileURL: url)
        XCTAssertEqual(out, "Notes.txt")
    }
}
