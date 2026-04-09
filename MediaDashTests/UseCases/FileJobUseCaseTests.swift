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
        
        let year = Calendar.current.component(.year, from: Date())
        let docketFolder = URL(fileURLWithPath: "/test/server/GM_\(year)/\(year)_WORK PICTURE/12345")
        let dateFolder = docketFolder.appendingPathComponent("01_Jan1.24")
        mockFileSystem.files[docketFolder.path] = true
        mockFileSystem.directoryContents[docketFolder.path] = []
        
        let testFileURL = URL(fileURLWithPath: "/test/source/file.txt")
        let testFile = FileItem(url: testFileURL)
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
        
        let year = Calendar.current.component(.year, from: Date())
        let prepRoot = URL(fileURLWithPath: "/test/server/GM_\(year)/\(year)_SESSION PREP")
        mockFileSystem.files[prepRoot.path] = true
        mockFileSystem.directoryContents[prepRoot.path] = []
        
        let testFileURL = URL(fileURLWithPath: "/test/source/file.wav")
        let testFile = FileItem(url: testFileURL)
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

    func testCopyDroppedSourcesIntoExistingPrepFolderOrganizesByType() throws {
        let useCase = FileJobUseCase(fileSystem: mockFileSystem, config: config)
        let year = Calendar.current.component(.year, from: Date())
        let prepRoot = URL(fileURLWithPath: "/test/server/GM_\(year)/\(year)_SESSION PREP/12345_PREP")
        mockFileSystem.files[prepRoot.path] = true
        mockFileSystem.directoryContents[prepRoot.path] = []

        let musicFile = URL(fileURLWithPath: "/tmp/incoming/track.wav")
        mockFileSystem.files[musicFile.path] = false

        let result = try useCase.copyDroppedSourcesIntoExistingPrepFolder(sourceURLs: [musicFile], prepRoot: prepRoot)

        XCTAssertTrue(result.success)
        let musicFolderName = config.settings.musicFolderName
        let expectedDest = prepRoot.appendingPathComponent(musicFolderName).appendingPathComponent("track.wav")
        XCTAssertTrue(mockFileSystem.copyOperations.contains { $0.from == musicFile && $0.to == expectedDest })
    }

    func testCopyDroppedSourcesIntoWorkPictureDatedFolderUsesNextDatedSubfolder() throws {
        let useCase = FileJobUseCase(fileSystem: mockFileSystem, config: config)
        let base = URL(fileURLWithPath: "/test/wp/26044_Job")
        mockFileSystem.files[base.path] = true
        mockFileSystem.directoryContents[base.path] = []

        let src = URL(fileURLWithPath: "/incoming/spot.mov")
        mockFileSystem.files[src.path] = false

        let wpDate = Date()
        let dateStr = config.namingService.formatDate(wpDate)
        let expectedFolder = base.appendingPathComponent(String(format: "01_%@", dateStr))
        let expectedDest = expectedFolder.appendingPathComponent("spot.mov")

        let result = try useCase.copyDroppedSourcesIntoWorkPictureDatedFolder(
            workPictureBaseURL: base,
            sourceURLs: [src],
            wpDate: wpDate
        )

        XCTAssertTrue(result.success)
        XCTAssertTrue(mockFileSystem.createDirectoryOperations.contains(expectedFolder))
        XCTAssertTrue(mockFileSystem.copyOperations.contains { $0.from == src && $0.to == expectedDest })
    }
}

