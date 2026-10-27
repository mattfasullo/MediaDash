import XCTest
@testable import MediaDash

final class SimianRequestLogicTests: XCTestCase {

    func testFormEncodingReservesAmpersandEqualsPlusAndSpace() {
        let encoded = SimianService.formURLEncodedValue("AT&T=a+b c")
        XCTAssertEqual(encoded, "AT%26T%3Da%2Bb%20c")
        XCTAssertFalse(encoded.contains("&"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertEqual(encoded.removingPercentEncoding, "AT&T=a+b c")
    }

    func testFormEncodingLeavesUnreservedCharacters() {
        XCTAssertEqual(SimianService.formURLEncodedValue("job-name_01.mov"), "job-name_01.mov")
    }

    func testProjectNameMatchIsExactAndCaseInsensitive() {
        XCTAssertTrue(SimianService.projectNameMatches(
            docketNumber: "26001",
            jobName: "AD",
            projectName: "26001_AD"
        ))
        XCTAssertTrue(SimianService.projectNameMatches(
            docketNumber: "26001",
            jobName: "AD",
            projectName: "26001_ad"
        ))
        XCTAssertFalse(SimianService.projectNameMatches(
            docketNumber: "26001",
            jobName: "AD",
            projectName: "26001_ADIDAS"
        ))
        XCTAssertFalse(SimianService.projectNameMatches(
            docketNumber: "26001",
            jobName: "AD",
            projectName: "26001_AD_v2"
        ))
        XCTAssertFalse(SimianService.projectNameMatches(
            docketNumber: "26001",
            jobName: "AD",
            projectName: "26001_OTHER"
        ))
    }

    func testScalarStringCoercesNumbersAndTreatsEmptyArrayAsBlank() {
        XCTAssertEqual(SimianService.simianScalarString(" 12 "), "12")
        XCTAssertEqual(SimianService.simianScalarString(42), "42")
        XCTAssertEqual(SimianService.simianScalarString(NSNumber(value: 7)), "7")
        XCTAssertEqual(SimianService.simianScalarString("0"), "0")
        XCTAssertNil(SimianService.simianScalarString([] as [Any]))
        XCTAssertNil(SimianService.simianScalarString(""))
        XCTAssertNil(SimianService.simianScalarString("[]"))
        XCTAssertNil(SimianService.simianScalarString(NSNull()))
        XCTAssertNil(SimianService.simianScalarString(false))
    }

    func testAuthenticationFailureIsNotEveryAPIError() {
        let notFound = Data(#"{"root":{"status":"error","message":"Project not found"}}"#.utf8)
        XCTAssertFalse(SimianService.isSimianAuthenticationFailure(httpStatus: 200, body: notFound))

        let expired = Data(#"{"root":{"status":"error","message":"Invalid auth token"}}"#.utf8)
        XCTAssertTrue(SimianService.isSimianAuthenticationFailure(httpStatus: 200, body: expired))

        let success = Data(#"{"root":{"status":"success","message":"success","payload":[]}}"#.utf8)
        XCTAssertFalse(SimianService.isSimianAuthenticationFailure(httpStatus: 200, body: success))
        XCTAssertTrue(SimianService.isSimianAuthenticationFailure(httpStatus: 401, body: Data()))
        XCTAssertTrue(SimianService.isSimianAuthenticationFailure(httpStatus: 403, body: success))
    }
}
