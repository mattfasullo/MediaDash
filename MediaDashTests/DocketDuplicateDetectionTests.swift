import XCTest
@testable import MediaDash

final class DocketDuplicateDetectionTests: XCTestCase {

    func testBaseNumericStripsCountrySuffix() {
        XCTAssertEqual(DocketDuplicateDetection.baseNumericDocketString("26150-US"), "26150")
        XCTAssertEqual(DocketDuplicateDetection.baseNumericDocketString("26150-CAN"), "26150")
        XCTAssertEqual(DocketDuplicateDetection.baseNumericDocketString("26150"), "26150")
    }

    func testWorkPictureContainsDocketNumberByPrefixIgnoresJobNameMismatch() {
        let dockets = ["26150_Ford_June_Retail", "26149_Other_Job"]
        XCTAssertTrue(DocketDuplicateDetection.workPictureContainsDocketNumber("26150", dockets: dockets))
        XCTAssertTrue(DocketDuplicateDetection.workPictureContainsDocketNumber("26150-US", dockets: dockets))
        XCTAssertFalse(DocketDuplicateDetection.workPictureContainsDocketNumber("26151", dockets: dockets))
    }

    func testSimianProjectListContainsDocketNumberUsesPrefixOnly() {
        let names = ["26150_Ford_Retail", "99999_Other"]
        XCTAssertTrue(DocketDuplicateDetection.simianProjectListContainsDocketNumber("26150", projectNames: names))
        XCTAssertTrue(DocketDuplicateDetection.simianProjectListContainsDocketNumber("26150-US", projectNames: names))
        XCTAssertFalse(DocketDuplicateDetection.simianProjectListContainsDocketNumber("26151", projectNames: names))
    }

    // MARK: - Edge Cases

    func testEmptyDocketReturnsEmptyString() {
        XCTAssertEqual(DocketDuplicateDetection.baseNumericDocketString(""), "")
    }

    func testDocketWithMultipleDashes() {
        // Should only strip the last country code suffix
        XCTAssertEqual(DocketDuplicateDetection.baseNumericDocketString("26150-US-CA"), "26150-US")
    }

    func testEmptyDocketLists() {
        XCTAssertFalse(DocketDuplicateDetection.workPictureContainsDocketNumber("26150", dockets: []))
        XCTAssertFalse(DocketDuplicateDetection.simianProjectListContainsDocketNumber("26150", projectNames: []))
    }

    func testPartialMatchesDoNotCount() {
        // 2615 is a prefix of 26150 but should not match
        let dockets = ["26150_Ford_June_Retail"]
        XCTAssertFalse(DocketDuplicateDetection.workPictureContainsDocketNumber("2615", dockets: dockets))
        XCTAssertTrue(DocketDuplicateDetection.workPictureContainsDocketNumber("26150", dockets: dockets))
    }

    func testCaseInsensitiveMatching() {
        let dockets = ["26150_FORD_RETAIL", "26150_ford_retail"]
        XCTAssertTrue(DocketDuplicateDetection.workPictureContainsDocketNumber("26150", dockets: dockets))
    }
}
