import XCTest
@testable import MediaDash

final class DemoFilenameParserTests: XCTestCase {

    func testCrossRoundLavenderLineageMatches() {
        let a = DemoFilenameParser.parse(stem: "MF_LAVENDER_Safeway_Apr10.26", defaultYear: 2026)
        let b = DemoFilenameParser.parse(stem: "Safeway_Lavender_MF_rev1_Apr12.26", defaultYear: 2026)
        XCTAssertEqual(a.lineageKey, b.lineageKey)
        XCTAssertEqual(a.canonicalColorName?.uppercased(), "LAVENDER")
        XCTAssertEqual(b.canonicalColorName?.uppercased(), "LAVENDER")
        XCTAssertGreaterThan(b.versionScore.rev, a.versionScore.rev)
    }

    func testOrangeLineageDistinctFromLavender() {
        let lav = DemoFilenameParser.parse(stem: "MF_LAVENDER_Safeway_Apr10.26", defaultYear: 2026)
        let org = DemoFilenameParser.parse(stem: "MF_ORANGE_Safeway_Apr10.26", defaultYear: 2026)
        XCTAssertNotEqual(lav.lineageKey, org.lineageKey)
        XCTAssertEqual(org.canonicalColorName?.uppercased(), "ORANGE")
    }

    func testOrangeCrossRoundPair() {
        let a = DemoFilenameParser.parse(stem: "MF_ORANGE_Safeway_Apr10.26", defaultYear: 2026)
        let b = DemoFilenameParser.parse(stem: "Orange_MF_Safeway_rev_Apr12.26", defaultYear: 2026)
        XCTAssertEqual(a.lineageKey, b.lineageKey)
    }

    func testStingVariantsStaySeparate() {
        let a = DemoFilenameParser.parse(stem: "CLIENT_Option_MIX_15s_STINGA_v3", defaultYear: 2026)
        let b = DemoFilenameParser.parse(stem: "CLIENT_Option_MIX_15s_STINGB_v3", defaultYear: 2026)
        XCTAssertNotEqual(a.variantKey, b.variantKey)
        XCTAssertEqual(a.familyKey, b.familyKey)
    }

    func testRevisionOrderingWithinSameRoundAssumption() {
        let lower = DemoFilenameParser.parse(stem: "DEMO_Track_REV1", defaultYear: 2026)
        let higher = DemoFilenameParser.parse(stem: "DEMO_Track_REV3", defaultYear: 2026)
        XCTAssertTrue(higher.versionScore.isNewerThan(lower.versionScore))
    }

    func testNFCDoesNotCrash() {
        let s = "MF_LAVENDER_Safeway_Apr10.26" + "\u{0301}"
        _ = DemoFilenameParser.parse(stem: s, defaultYear: 2026)
    }

    /// Instrumental / acapella / full mix share lineage; mix type stays in variant only.
    func testMixDeliverableTokensShareLineage() {
        let full = DemoFilenameParser.parse(stem: "ANZUPGO-HANDTHEM_A_v4 I Never Miss", defaultYear: 2026)
        let inst = DemoFilenameParser.parse(stem: "ANZUPGO-HANDTHEM_A_v4 I Never Miss_INSTRUMENTAL", defaultYear: 2026)
        let acap = DemoFilenameParser.parse(stem: "ANZUPGO-HANDTHEM_A_v4 I never miss_ ACAPELLA", defaultYear: 2026)
        XCTAssertEqual(full.lineageKey, inst.lineageKey)
        XCTAssertEqual(full.lineageKey, acap.lineageKey)
        XCTAssertNotEqual(full.variantKey, inst.variantKey)
        XCTAssertNotEqual(full.variantKey, acap.variantKey)
    }
}
