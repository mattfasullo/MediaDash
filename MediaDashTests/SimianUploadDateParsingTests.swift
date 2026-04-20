import XCTest
@testable import MediaDash

final class SimianUploadDateParsingTests: XCTestCase {

    func testParsesNestedUploadedAtISOString() {
        let dict: [String: Any] = [
            "id": "1",
            "title": "x.mov",
            "file": ["uploadedAt": "2023-06-15T12:00:00Z"] as [String: Any]
        ]
        guard let date = SimianService.uploadDateFromPayload(dict) else {
            return XCTFail("expected date")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(cal.component(.year, from: date), 2023)
        XCTAssertEqual(cal.component(.month, from: date), 6)
        XCTAssertEqual(cal.component(.day, from: date), 15)
    }

    func testDoesNotUseAmbiguousDateKeyAlone() {
        let dict: [String: Any] = ["date": "01/10/2020", "title": "n/a"]
        XCTAssertNil(SimianService.uploadDateFromPayload(dict))
    }

    func testUnixSecondsInt() {
        let dict: [String: Any] = ["upload_date": 1_704_067_200]
        guard let date = SimianService.uploadDateFromPayload(dict) else {
            return XCTFail("expected date")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(cal.component(.year, from: date), 2024)
        XCTAssertEqual(cal.component(.month, from: date), 1)
        XCTAssertEqual(cal.component(.day, from: date), 1)
    }

    func testMillisecondsEpochNormalizesToSeconds() {
        let dict: [String: Any] = ["uploadedAt": 1_704_067_200_000]
        guard let date = SimianService.uploadDateFromPayload(dict) else {
            return XCTFail("expected date")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(cal.component(.year, from: date), 2024)
        XCTAssertEqual(cal.component(.month, from: date), 1)
        XCTAssertEqual(cal.component(.day, from: date), 1)
    }

    func testDateOnlyYYYY_MM_DD() {
        let dict: [String: Any] = ["upload_date": "2019-11-08"]
        guard let date = SimianService.uploadDateFromPayload(dict) else {
            return XCTFail("expected date")
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        XCTAssertEqual(cal.component(.year, from: date), 2019)
        XCTAssertEqual(cal.component(.month, from: date), 11)
        XCTAssertEqual(cal.component(.day, from: date), 8)
    }
}
