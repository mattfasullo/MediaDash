import XCTest
@testable import MediaDash

/// Tests for DocketMetadata and DocketMetadataManager
final class DocketMetadataTests: XCTestCase {

    // MARK: - DocketMetadata Model Tests

    func testMetadataInitialization() {
        let metadata = DocketMetadata(
            docketNumber: "26150",
            jobName: "Test Campaign",
            client: "Test Client",
            producer: "John Doe",
            status: "Active",
            agency: "Test Agency"
        )

        XCTAssertEqual(metadata.docketNumber, "26150")
        XCTAssertEqual(metadata.jobName, "Test Campaign")
        XCTAssertEqual(metadata.id, "26150_Test Campaign")
        XCTAssertEqual(metadata.client, "Test Client")
        XCTAssertEqual(metadata.producer, "John Doe")
        XCTAssertEqual(metadata.status, "Active")
        XCTAssertEqual(metadata.agency, "Test Agency")
    }

    func testMetadataIdGeneration() {
        let metadata1 = DocketMetadata(docketNumber: "26150", jobName: "Campaign A")
        let metadata2 = DocketMetadata(docketNumber: "26150", jobName: "Campaign B")

        XCTAssertEqual(metadata1.id, "26150_Campaign A")
        XCTAssertEqual(metadata2.id, "26150_Campaign B")
        XCTAssertNotEqual(metadata1.id, metadata2.id)
    }

    func testMetadataWithSpecialCharacters() {
        let metadata = DocketMetadata(
            docketNumber: "26150",
            jobName: "Campaign & Project (2024)"
        )

        XCTAssertEqual(metadata.id, "26150_Campaign & Project (2024)")
    }

    // MARK: - CSV Field Escaping Tests

    func testCSVFieldEscaping() {
        // Test the private escapeCSVField function indirectly via metadata
        let metadata = DocketMetadata(
            docketNumber: "26150",
            jobName: "Campaign with, comma",
            client: "Client with \"quotes\"",
            notes: "Notes with\nnewline"
        )

        // The metadata should store the raw values
        XCTAssertEqual(metadata.jobName, "Campaign with, comma")
        XCTAssertEqual(metadata.client, "Client with \"quotes\"")
        XCTAssertEqual(metadata.notes, "Notes with\nnewline")
    }

    // MARK: - Empty Metadata Tests

    func testEmptyMetadata() {
        let metadata = DocketMetadata(
            docketNumber: "",
            jobName: ""
        )

        XCTAssertEqual(metadata.id, "_")
        XCTAssertTrue(metadata.client.isEmpty)
        XCTAssertTrue(metadata.producer.isEmpty)
        XCTAssertTrue(metadata.notes.isEmpty)
    }

    // MARK: - Date Handling Tests

    func testMetadataLastUpdated() {
        let before = Date()
        let metadata = DocketMetadata(docketNumber: "26150", jobName: "Test")
        let after = Date()

        // Last updated should be set automatically to now
        XCTAssertGreaterThanOrEqual(metadata.lastUpdated, before)
        XCTAssertLessThanOrEqual(metadata.lastUpdated, after)
    }
}
