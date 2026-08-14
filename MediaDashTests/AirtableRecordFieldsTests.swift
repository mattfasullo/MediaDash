import XCTest
@testable import MediaDash

final class AirtableRecordFieldsTests: XCTestCase {

    func testReadsDocketDespiteLeadingBOMOnKey() {
        let fields: [String: Any] = ["\u{FEFF}Docket": "26317"]
        XCTAssertEqual(
            AirtableRecordFields.string(in: fields, names: ["Docket"]),
            "26317"
        )
        XCTAssertTrue(AirtableRecordFields.hasField(in: fields, names: ["Docket"]))
    }

    func testReadsJobTitleDespiteCaseMismatch() {
        let fields: [String: Any] = ["licensor/project title": "Acme June Retail"]
        XCTAssertEqual(
            AirtableRecordFields.string(in: fields, names: ["Licensor/Project Title"]),
            "Acme June Retail"
        )
    }

    func testPrefersFieldIDWhenPresent() {
        let fields: [String: Any] = [
            "fldSWLZ9ONL1UzNx7": "26124",
            "\u{FEFF}Docket": "99999"
        ]
        XCTAssertEqual(
            AirtableRecordFields.string(
                in: fields,
                fieldID: "fldSWLZ9ONL1UzNx7",
                names: ["Docket"]
            ),
            "26124"
        )
    }

    func testCoercesNumericDocketToString() {
        let fields: [String: Any] = ["Docket": 26207]
        XCTAssertEqual(AirtableRecordFields.string(in: fields, names: ["Docket"]), "26207")
    }

    func testTrimsDocketWhitespace() {
        let fields: [String: Any] = ["Docket": "26091-US "]
        XCTAssertEqual(AirtableRecordFields.string(in: fields, names: ["Docket"]), "26091-US")
    }

    func testMissingDocketIsNotHasField() {
        let fields: [String: Any] = ["licensor/project title": "Job"]
        XCTAssertNil(AirtableRecordFields.string(in: fields, names: ["Docket"]))
        XCTAssertFalse(AirtableRecordFields.hasField(in: fields, names: ["Docket"]))
    }

    func testExactDocketKeyStillWorks() {
        let fields: [String: Any] = ["Docket": "26150"]
        XCTAssertEqual(AirtableRecordFields.string(in: fields, names: ["Docket"]), "26150")
    }
}

final class AirtableDocketScanFilterTests: XCTestCase {

    func testFormulaUsesWholeRecordLastModifiedTime() {
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000)
        let formula = AirtableDocketScanFilter.recentlyModifiedNonemptyJobFormula(
            jobFieldReference: "fldkfsB2Ny0Zza1AK",
            cutoff: cutoff
        )
        XCTAssertTrue(formula.contains("LAST_MODIFIED_TIME()"), formula)
        XCTAssertFalse(formula.contains("LAST_MODIFIED_TIME({"), formula)
        XCTAssertTrue(formula.contains("{fldkfsB2Ny0Zza1AK}"), formula)
        XCTAssertTrue(formula.contains("IS_AFTER"), formula)
    }

    func testCutoffIsUTCWithMillisecondsAndZ() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let s = AirtableDocketScanFilter.iso8601CutoffString(from: date)
        let regex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#)
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        XCTAssertEqual(regex.numberOfMatches(in: s, range: range), 1, s)
        XCTAssertTrue(s.hasSuffix("Z"))
        XCTAssertFalse(s.contains("+"))
    }
}
