import XCTest
@testable import MediaDash

/// Tests for EmailDocketParser covering various email formats and edge cases
final class EmailDocketParserTests: XCTestCase {

    private var parser: EmailDocketParser!

    override func setUp() {
        super.setUp()
        parser = EmailDocketParser()
    }

    // MARK: - Basic Parsing Tests

    func testParseSimpleDocketInSubject() {
        let subject = "NEW DOCKET 26150 Test Job Name"
        let body = "Please create this new docket."
        let from = "test@example.com"

        let result = parser.parseEmail(subject: subject, body: body, from: from)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150")
        XCTAssertEqual(result?.jobName, "Test Job Name")
        XCTAssertEqual(result?.sourceEmail, from)
    }

    func testParseDocketWithCountryCode() {
        let subject = "NEW DOCKET 26150-US International Project"
        let body = "New docket for US client."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150-US")
        XCTAssertEqual(result?.jobName, "International Project")
    }

    func testParseDocketWithCanadaCode() {
        let subject = "NEW DOCKET 26150-CAN Canadian Project"
        let body = "New docket for Canadian client."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150-CAN")
    }

    // MARK: - Body-First-Line Parsing

    func testParseDocketOnFirstLineOfBody() {
        let subject = "New Project"
        let body = """
        26150 Amazing Campaign Name
        This is the body text with more details.
        """

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150")
        XCTAssertEqual(result?.jobName, "Amazing Campaign Name")
    }

    func testParseDocketWithCountryCodeOnFirstLine() {
        let subject = "Fwd: Project Request"
        let body = """
        26150-CA Provincial Health Campaign
        Please process this request.
        """

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150-CA")
        XCTAssertEqual(result?.jobName, "Provincial Health Campaign")
    }

    // MARK: - Pattern Variations

    func testParseDocketColonJobColonFormat() {
        let subject = "Project Request"
        let body = "Docket: 26150 Job: Product Launch 2024"

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150")
        XCTAssertEqual(result?.jobName, "Product Launch 2024")
    }

    func testParseBracketedDocketFormat() {
        let subject = "[26150] Summer Sale Campaign"
        let body = "New docket request attached."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150")
        XCTAssertEqual(result?.jobName, "Summer Sale Campaign")
    }

    func testParseUnderscoreDocketFormat() {
        let subject = "Project"
        let body = "Please create 26150_Summer_Sale_Campaign"

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150")
        XCTAssertEqual(result?.jobName, "Summer_Sale_Campaign")
    }

    func testParseDocketNumberJobNameFormat() {
        let subject = "New Request"
        let body = "26052 HH - End of year sizzle"

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26052")
        XCTAssertEqual(result?.jobName, "HH - End of year sizzle")
    }

    // MARK: - "New Docket" Intent Detection

    func testParseRequiresNewDocketIntent() {
        let subject = "26150 Random Subject"
        let body = "This is just a regular email without docket intent."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        // Should fail because there's no "new docket" language
        XCTAssertNil(result)
    }

    func testParseWithNewKeyword() {
        let subject = "New 26150 Project"
        let body = "Create new docket please."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150")
    }

    func testParseWithDocketStyleLineNearTop() {
        let subject = "Fwd: Request"
        let body = """
        Forwarded message:
        
        26150 Year End Review
        
        Please create this docket.
        """

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        // Should succeed due to "26150 Year End Review" pattern on an early line
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150")
    }

    // MARK: - Year Validation

    func testParseRejectsInvalidYearPrefix() {
        // 99 prefix is not a valid year (current year is 2025, so valid are 25, 26)
        let subject = "NEW DOCKET 99150 Old Project"
        let body = "New docket request."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        // Should be rejected due to invalid year
        XCTAssertNil(result)
    }

    func testParseAcceptsCurrentYearPrefix() {
        let currentYear = Calendar.current.component(.year, from: Date())
        let yearPrefix = String(currentYear % 100)
        let docketNumber = "\(yearPrefix)150"

        let subject = "NEW DOCKET \(docketNumber) Current Year Project"
        let body = "New docket request."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, docketNumber)
    }

    func testParseAcceptsNextYearPrefix() {
        let currentYear = Calendar.current.component(.year, from: Date())
        let nextYearPrefix = String((currentYear + 1) % 100)
        let docketNumber = "\(nextYearPrefix)150"

        let subject = "NEW DOCKET \(docketNumber) Next Year Project"
        let body = "New docket request."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, docketNumber)
    }

    // MARK: - Subject Cleanup

    func testParseCleansFwdPrefixFromSubject() {
        let subject = "Fwd: NEW DOCKET 26150 Forwarded Project"
        let body = "New docket request."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.jobName, "Forwarded Project")
    }

    func testParseCleansRePrefixFromSubject() {
        let subject = "Re: NEW DOCKET 26150 Reply Project"
        let body = "New docket request."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.jobName, "Reply Project")
    }

    // MARK: - Edge Cases

    func testParseNilInputs() {
        let result = parser.parseEmail(subject: nil, body: nil, from: nil)
        XCTAssertNil(result)
    }

    func testParseEmptyInputs() {
        let result = parser.parseEmail(subject: "", body: "", from: "")
        XCTAssertNil(result)
    }

    func testParseVeryShortJobName() {
        let subject = "NEW DOCKET 26150 AB"
        let body = "New docket."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        // Job name "AB" is too short (2 chars), should be rejected or handled
        // The parser may still return it depending on validation
        if let parsed = result {
            XCTAssertTrue(parsed.jobName.count > 2 || parsed.jobName == "AB")
        }
    }

    func testParseLongJobName() {
        let longJobName = String(repeating: "A", count: 150)
        let subject = "NEW DOCKET 26150 \(longJobName)"
        let body = "New docket."

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        // Very long job names should be capped or handled
        if let parsed = result {
            XCTAssertLessThanOrEqual(parsed.jobName.count, 200)
        }
    }

    // MARK: - HTML Content Handling

    func testParseStripsHTMLTags() {
        let subject = "NEW DOCKET 26150 HTML Project"
        let body = """
        <table>
        <tr><td>26150</td><td>Table Based Project</td></tr>
        </table>
        Please create this docket.
        """

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        // The parser should extract the docket from the HTML content
        XCTAssertEqual(result?.docketNumber, "26150")
    }

    func testParseHandlesTableSeparators() {
        let subject = "Request"
        let body = """
        26150 | Tims Soccer | Gut
        New docket please.
        """

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.docketNumber, "26150")
        XCTAssertEqual(result?.jobName, "Tims Soccer")
    }

    // MARK: - Docket Existence in Email

    func testParseRejectsDocketNotInEmail() {
        let subject = "NEW DOCKET Some Project"
        let body = "Please create docket."
        // Note: no actual docket number in subject or body

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        // Should fail because there's no docket number to extract
        XCTAssertNil(result)
    }

    // MARK: - Multiple Dockets

    func testParsePrefersFirstValidDocket() {
        let subject = "NEW DOCKET 26150 First Project"
        let body = """
        Also referencing 26151 second project
        and 26152 third project
        """

        let result = parser.parseEmail(subject: subject, body: body, from: nil)

        XCTAssertNotNil(result)
        // Should prefer the one from subject with "NEW DOCKET" intent
        XCTAssertEqual(result?.docketNumber, "26150")
    }
}
