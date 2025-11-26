import XCTest
@testable import MediaDash

final class DocketScanningUseCaseTests: XCTestCase {
    
    var mockFileSystem: MockFileSystem!
    var config: AppConfig!
    
    override func setUp() {
        super.setUp()
        mockFileSystem = MockFileSystem()
        var settings = AppSettings.default
        settings.serverBasePath = "/test/server"
        config = AppConfig(settings: settings)
    }
    
    func testScanDocketsWorkPicture() async throws {
        let useCase = DocketScanningUseCase(fileSystem: mockFileSystem, config: config)
        
        // Setup mock file system
        let workPicPath = URL(fileURLWithPath: "/test/server/GM_2024/2024_WORK PICTURE")
        let docket1 = workPicPath.appendingPathComponent("12345")
        let docket2 = workPicPath.appendingPathComponent("12346")
        
        mockFileSystem.files[workPicPath.path] = true
        mockFileSystem.files[docket1.path] = true
        mockFileSystem.files[docket2.path] = true
        mockFileSystem.directoryContents[workPicPath.path] = [docket1, docket2]
        
        let dockets = try await useCase.scanDockets(jobType: .workPicture)
        
        XCTAssertEqual(dockets.count, 2)
        XCTAssertTrue(dockets.contains("12345"))
        XCTAssertTrue(dockets.contains("12346"))
    }
    
    func testScanDocketsPrep() async throws {
        let useCase = DocketScanningUseCase(fileSystem: mockFileSystem, config: config)
        
        // Setup mock file system
        let prepPath = URL(fileURLWithPath: "/test/server/GM_2024/2024_SESSION PREP")
        let prepFolder1 = prepPath.appendingPathComponent("12345_PREP_Jan1.24")
        let prepFolder2 = prepPath.appendingPathComponent("12346_PREP_Jan2.24")
        
        mockFileSystem.files[prepPath.path] = true
        mockFileSystem.files[prepFolder1.path] = true
        mockFileSystem.files[prepFolder2.path] = true
        mockFileSystem.directoryContents[prepPath.path] = [prepFolder1, prepFolder2]
        
        let dockets = try await useCase.scanDockets(jobType: .prep)
        
        XCTAssertEqual(dockets.count, 2)
        XCTAssertTrue(dockets.contains("12345"))
        XCTAssertTrue(dockets.contains("12346"))
    }
    
    func testScanDocketsDirectoryNotFound() async {
        let useCase = DocketScanningUseCase(fileSystem: mockFileSystem, config: config)
        
        // Don't setup the directory - should throw error
        do {
            _ = try await useCase.scanDockets(jobType: .workPicture)
            XCTFail("Should have thrown an error")
        } catch {
            if case AppError.fileSystem(.directoryNotFound) = error {
                // Expected
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }
}

