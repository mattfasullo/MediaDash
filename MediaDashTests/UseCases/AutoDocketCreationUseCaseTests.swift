import XCTest
@testable import MediaDash

final class AutoDocketCreationUseCaseTests: XCTestCase {
    func testSlashInJobNameStaysOneFolder() async throws {
        let mockFileSystem = MockFileSystem()
        var settings = AppSettings.default
        settings.serverBasePath = "/test/server"
        let config = AppConfig(settings: settings)
        mockFileSystem.files[config.getPaths().workPic.path] = true

        let useCase = AutoDocketCreationUseCase(fileSystem: mockFileSystem, config: config)
        let result = try await useCase.createDocket(
            docketNumber: "26424",
            jobName: "The Keg Our Kind of Winter 2027 TV/OLV Campaign",
            existingDockets: []
        )

        XCTAssertEqual(result.docketName, "26424_The Keg Our Kind of Winter 2027")
        XCTAssertEqual(URL(fileURLWithPath: result.path).lastPathComponent, result.docketName)
        XCTAssertEqual(mockFileSystem.createDirectoryOperations.count, 1)
    }

    func testSpacedSlashDoesNotKeepALeadingSpaceOnTheLastPiece() async throws {
        let mockFileSystem = MockFileSystem()
        var settings = AppSettings.default
        settings.serverBasePath = "/test/server"
        let config = AppConfig(settings: settings)
        mockFileSystem.files[config.getPaths().workPic.path] = true

        let useCase = AutoDocketCreationUseCase(fileSystem: mockFileSystem, config: config)
        let result = try await useCase.createDocket(
            docketNumber: "26425",
            jobName: "TD Insurance Refresh / F27 Q2 Affinity - t Number",
            existingDockets: []
        )

        XCTAssertEqual(
            result.docketName,
            "26425_TD Insurance Refresh"
        )
        XCTAssertEqual(URL(fileURLWithPath: result.path).lastPathComponent, result.docketName)
    }
}
