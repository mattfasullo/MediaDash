import Foundation

/// Default file system implementation using FileManager
nonisolated struct DefaultFileSystem: FileSystem {
    private let fileManager: FileManager
    
    nonisolated init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }
    
    nonisolated func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }
    
    nonisolated func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        fileManager.fileExists(atPath: path, isDirectory: isDirectory)
    }
    
    nonisolated func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
    }
    
    nonisolated func copyItem(from srcURL: URL, to dstURL: URL) throws {
        try fileManager.copyItem(at: srcURL, to: dstURL)
    }
    
    nonisolated func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try fileManager.moveItem(at: srcURL, to: dstURL)
    }
    
    nonisolated func removeItem(at URL: URL) throws {
        try fileManager.removeItem(at: URL)
    }
    
    nonisolated func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    
    nonisolated func createDirectory(atPath path: String, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

