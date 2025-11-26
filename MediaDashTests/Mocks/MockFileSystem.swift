import Foundation
@testable import MediaDash

/// Mock file system for testing
class MockFileSystem: FileSystem {
    var files: [String: Bool] = [:] // path -> isDirectory
    var directoryContents: [String: [URL]] = [:]
    var copyOperations: [(from: URL, to: URL)] = []
    var moveOperations: [(from: URL, to: URL)] = []
    var createDirectoryOperations: [URL] = []
    
    init() {}
    
    nonisolated func fileExists(atPath path: String) -> Bool {
        files.keys.contains(path)
    }
    
    nonisolated func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if let isDir = files[path] {
            isDirectory?.pointee = ObjCBool(isDir)
            return true
        }
        isDirectory?.pointee = ObjCBool(false)
        return false
    }
    
    nonisolated func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        return directoryContents[url.path] ?? []
    }
    
    nonisolated func copyItem(from srcURL: URL, to dstURL: URL) throws {
        copyOperations.append((from: srcURL, to: dstURL))
        files[dstURL.path] = files[srcURL.path] ?? false
    }
    
    nonisolated func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveOperations.append((from: srcURL, to: dstURL))
        if let isDir = files.removeValue(forKey: srcURL.path) {
            files[dstURL.path] = isDir
        }
    }
    
    nonisolated func removeItem(at URL: URL) throws {
        files.removeValue(forKey: URL.path)
    }
    
    nonisolated func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        createDirectoryOperations.append(url)
        files[url.path] = true
    }
    
    nonisolated func createDirectory(atPath path: String, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        let url = URL(fileURLWithPath: path)
        try createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

