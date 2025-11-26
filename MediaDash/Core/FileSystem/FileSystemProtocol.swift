import Foundation

/// Protocol for file system operations
protocol FileSystem {
    nonisolated func fileExists(atPath path: String) -> Bool
    nonisolated func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    nonisolated func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    nonisolated func copyItem(from srcURL: URL, to dstURL: URL) throws
    nonisolated func moveItem(at srcURL: URL, to dstURL: URL) throws
    nonisolated func removeItem(at URL: URL) throws
    nonisolated func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws
    nonisolated func createDirectory(atPath path: String, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey : Any]?) throws
}

