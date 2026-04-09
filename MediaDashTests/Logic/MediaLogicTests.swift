import XCTest
@testable import MediaDash

final class MediaLogicTests: XCTestCase {

    func testLevenshteinDistance() {
        XCTAssertEqual(MediaLogic.levenshteinDistance("test", "test"), 0)
        XCTAssertEqual(MediaLogic.levenshteinDistance("test", "tets"), 2)
        XCTAssertEqual(MediaLogic.levenshteinDistance("kitten", "sitting"), 3)
    }

    func testPrepEmbeddedDateFromFolderName_parsesStandardSuffix() {
        let name = "26036_Tangerine Summit_PREP_Mar31.26"
        let parsed = MediaLogic.prepEmbeddedDateFromFolderName(name)
        XCTAssertNotNil(parsed)
        var c = DateComponents()
        c.year = 2026
        c.month = 3
        c.day = 31
        let expected = Calendar.current.date(from: c)
        XCTAssertNotNil(expected)
        XCTAssertTrue(Calendar.current.isDate(parsed!, inSameDayAs: expected!))
    }

    func testCalendarDayForSessionPrepNaming_usesDueDate() {
        let docket = DocketInfo(
            number: "26036",
            jobName: "Tangerine",
            fullName: "Session 26036 Tangerine",
            dueDate: "2026-04-10"
        )
        let fallback = Date(timeIntervalSince1970: 0)
        let day = MediaLogic.calendarDayForSessionPrepNaming(docket: docket, prepDateFallback: fallback)
        var c = DateComponents()
        c.year = 2026
        c.month = 4
        c.day = 10
        let expected = Calendar.current.date(from: c)!
        XCTAssertTrue(Calendar.current.isDate(day, inSameDayAs: expected))
    }
    
}

