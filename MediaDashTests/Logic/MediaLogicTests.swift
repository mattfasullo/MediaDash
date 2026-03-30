import XCTest
@testable import MediaDash

final class MediaLogicTests: XCTestCase {

    func testLevenshteinDistance() {
        XCTAssertEqual(MediaLogic.levenshteinDistance("test", "test"), 0)
        XCTAssertEqual(MediaLogic.levenshteinDistance("test", "tets"), 2)
        XCTAssertEqual(MediaLogic.levenshteinDistance("kitten", "sitting"), 3)
    }
    
    func testGetAllFiles() {
        let mockFS = MockFileSystem()
        let testDir = URL(fileURLWithPath: "/test/dir")
        let file1 = testDir.appendingPathComponent("file1.txt")
        let file2 = testDir.appendingPathComponent("file2.txt")
        
        // Setup mock
        mockFS.files[testDir.path] = true
        mockFS.files[file1.path] = false
        mockFS.files[file2.path] = false
        mockFS.directoryContents[testDir.path] = [file1, file2]
        
        let files = MediaLogic.getAllFiles(at: testDir, fileSystem: mockFS)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains(file1))
        XCTAssertTrue(files.contains(file2))
    }
    
    func testGetAllFilesRecursive() {
        let mockFS = MockFileSystem()
        let rootDir = URL(fileURLWithPath: "/root")
        let subDir = rootDir.appendingPathComponent("sub")
        let file1 = rootDir.appendingPathComponent("file1.txt")
        let file2 = subDir.appendingPathComponent("file2.txt")
        
        // Setup mock
        mockFS.files[rootDir.path] = true
        mockFS.files[subDir.path] = true
        mockFS.files[file1.path] = false
        mockFS.files[file2.path] = false
        mockFS.directoryContents[rootDir.path] = [subDir, file1]
        mockFS.directoryContents[subDir.path] = [file2]
        
        let files = MediaLogic.getAllFiles(at: rootDir, fileSystem: mockFS)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains(file1))
        XCTAssertTrue(files.contains(file2))
    }
}

