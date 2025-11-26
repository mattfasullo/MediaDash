import XCTest
@testable import MediaDash

final class FileJobUseCaseTests: XCTestCase {
    
    var mockFileSystem: MockFileSystem!
    var config: AppConfig!
    
    override func setUp() {
        super.setUp()
        mockFileSystem = MockFileSystem()
        var settings = AppSettings.default
        settings.serverBasePath = "/test/server"
        settings.sessionsBasePath = "/test/sessions"
        config = AppConfig(settings: settings)
    }
    
    func testExecuteWorkPictureJob() async throws {
        let useCase = FileJobUseCase(fileSystem: mockFileSystem, config: config)
        let mockMetadata = MockMetadataManager()
        
        // Setup mock file system
        let docketFolder = URL(fileURLWithPath: "/test/server/GM_2024/2024_WORK PICTURE/12345")
        let dateFolder = docketFolder.appendingPathComponent("01_Jan1.24")
        mockFileSystem.files[docketFolder.path] = true
        mockFileSystem.directoryContents[docketFolder.path] = []
        
        let testFileURL = URL(fileURLWithPath: "/test/source/file.txt")
        let testFile = FileItem(url: testFileURL, name: "file.txt", fileCount: 1)
        mockFileSystem.files[testFileURL.path] = false
        
        let result = try await useCase.execute(
            type: .workPicture,
            docket: "12345",
            files: [testFile],
            wpDate: Date(),
            prepDate: Date(),
            metadataProvider: mockMetadata
        )
        
        XCTAssertTrue(result.success)
        XCTAssertTrue(mockFileSystem.copyOperations.contains { $0.from == testFileURL })
    }
    
    func testExecutePrepJob() async throws {
        let useCase = FileJobUseCase(fileSystem: mockFileSystem, config: config)
        let mockMetadata = MockMetadataManager()
        
        // Setup mock file system
        let prepRoot = URL(fileURLWithPath: "/test/server/GM_2024/2024_SESSION PREP")
        mockFileSystem.files[prepRoot.path] = true
        mockFileSystem.directoryContents[prepRoot.path] = []
        
        let testFileURL = URL(fileURLWithPath: "/test/source/file.wav")
        let testFile = FileItem(url: testFileURL, name: "file.wav", fileCount: 1)
        mockFileSystem.files[testFileURL.path] = false
        
        let result = try await useCase.execute(
            type: .prep,
            docket: "12345",
            files: [testFile],
            wpDate: Date(),
            prepDate: Date(),
            metadataProvider: mockMetadata
        )
        
        XCTAssertTrue(result.success)
        XCTAssertNotNil(result.prepFolderPath)
    }
}

