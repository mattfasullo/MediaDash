import Foundation

/// Use case for searching sessions
struct SearchUseCase {
    nonisolated(unsafe) let fileSystem: FileSystem
    let config: AppConfig
    
    nonisolated init(fileSystem: FileSystem = DefaultFileSystem(), config: AppConfig) {
        self.fileSystem = fileSystem
        self.config = config
    }
    
    /// Build search index for a folder
    func buildIndex(folder: SearchFolder) async throws -> [String] {
        var index: [String] = []
        var isDir: ObjCBool = false
        
        switch folder {
        case .sessions:
            let base = URL(fileURLWithPath: config.sessionsBasePath)
            guard fileSystem.fileExists(atPath: base.path, isDirectory: &isDir) else {
                return index
            }
            
            do {
                let contents = try fileSystem.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: [])
                let years = contents.filter {
                    $0.lastPathComponent.uppercased().contains("_PROTOOLS SESSIONS") ||
                    $0.lastPathComponent.uppercased().contains("PROTOOLS")
                }
                
                for year in years {
                    if let sessions = try? fileSystem.contentsOfDirectory(at: year, includingPropertiesForKeys: nil, options: []) {
                        for sess in sessions {
                            var isDir: ObjCBool = false
                            guard fileSystem.fileExists(atPath: sess.path, isDirectory: &isDir),
                                  isDir.boolValue,
                                  !sess.lastPathComponent.hasPrefix(".") else {
                                continue
                            }
                            index.append(sess.path)
                        }
                    }
                }
            } catch {
                throw AppError.fileSystem(.accessDenied(base.path))
            }
            
        case .workPicture:
            // Dynamically find all Work Picture folders across years
            let serverBase = URL(fileURLWithPath: config.settings.serverBasePath)
            let yearPrefix = config.settings.yearPrefix
            let workPictureFolderName = config.settings.workPictureFolderName
            
            var isDir: ObjCBool = false
            guard fileSystem.fileExists(atPath: serverBase.path, isDirectory: &isDir) else {
                return index
            }
            
            if let yearFolders = try? fileSystem.contentsOfDirectory(at: serverBase, includingPropertiesForKeys: nil, options: []) {
                for yearFolder in yearFolders where yearFolder.lastPathComponent.hasPrefix(yearPrefix) {
                    let yearString = yearFolder.lastPathComponent.replacingOccurrences(of: yearPrefix, with: "")
                    let workPicPath = yearFolder.appendingPathComponent("\(yearString)_\(workPictureFolderName)")
                    
                    var isDir: ObjCBool = false
                    guard fileSystem.fileExists(atPath: workPicPath.path, isDirectory: &isDir) else {
                        continue
                    }
                    
                    if let sessions = try? fileSystem.contentsOfDirectory(at: workPicPath, includingPropertiesForKeys: nil, options: []) {
                        for sess in sessions {
                            var isDir: ObjCBool = false
                            guard fileSystem.fileExists(atPath: sess.path, isDirectory: &isDir),
                                  isDir.boolValue,
                                  !sess.lastPathComponent.hasPrefix(".") else {
                                continue
                            }
                            index.append(sess.path)
                        }
                    }
                }
            }
            
        case .mediaPostings:
            let baseMedia = URL(fileURLWithPath: "/Volumes/Grayson Assets/MEDIA/MEDIA POSTINGS")
            var isDir: ObjCBool = false
            
            guard fileSystem.fileExists(atPath: baseMedia.path, isDirectory: &isDir) else {
                return index
            }
            
            if let yearFolders = try? fileSystem.contentsOfDirectory(at: baseMedia, includingPropertiesForKeys: nil, options: []) {
                for yearFolder in yearFolders {
                    var isDir: ObjCBool = false
                    guard fileSystem.fileExists(atPath: yearFolder.path, isDirectory: &isDir),
                          isDir.boolValue,
                          !yearFolder.lastPathComponent.hasPrefix(".") else {
                        continue
                    }
                    
                    if let sessions = try? fileSystem.contentsOfDirectory(at: yearFolder, includingPropertiesForKeys: nil, options: []) {
                        for sess in sessions {
                            var isDir: ObjCBool = false
                            guard fileSystem.fileExists(atPath: sess.path, isDirectory: &isDir),
                                  isDir.boolValue,
                                  !sess.lastPathComponent.hasPrefix(".") else {
                                continue
                            }
                            index.append(sess.path)
                        }
                    }
                }
            }
        }
        
        return index
    }
    
    /// Search sessions with fuzzy matching
    func searchSessions(
        term: String,
        folder: SearchFolder,
        index: [String],
        enableFuzzy: Bool
    ) async -> SearchResults {
        if term.isEmpty {
            return SearchResults(exactMatches: [], fuzzyMatches: [])
        }
        
        let lower = term.localizedLowercase
        let searchWords = lower.split(separator: " ").map(String.init)
        
        // Exact matches - check if all words are present (in any order)
        let exactMatches = index.filter { path in
            let pathLower = path.lowercased()
            if searchWords.count == 1 || pathLower.contains(lower) {
                return pathLower.contains(lower)
            }
            return searchWords.allSatisfy { word in
                pathLower.contains(word)
            }
        }
        
        // Fuzzy matches
        let fuzzyMatches: [String]
        if enableFuzzy {
            fuzzyMatches = index.filter { path in
                if exactMatches.contains(path) { return false }
                return MediaLogic.fuzzyMatch(searchTerm: term, target: path)
            }
        } else {
            fuzzyMatches = []
        }
        
        // Sort both lists
        let sortedExact = exactMatches.prefix(150).sorted { pathA, pathB in
            let nsPathA = pathA as NSString
            let nsPathB = pathB as NSString
            
            let parentA = nsPathA.deletingLastPathComponent as NSString
            let parentB = nsPathB.deletingLastPathComponent as NSString
            
            let folderA = parentA.lastPathComponent
            let folderB = parentB.lastPathComponent
            
            if folderA != folderB {
                return folderA > folderB
            }
            return nsPathA.lastPathComponent < nsPathB.lastPathComponent
        }
        
        let sortedFuzzy = fuzzyMatches.prefix(50).sorted { pathA, pathB in
            let nsPathA = pathA as NSString
            let nsPathB = pathB as NSString
            
            let parentA = nsPathA.deletingLastPathComponent as NSString
            let parentB = nsPathB.deletingLastPathComponent as NSString
            
            let folderA = parentA.lastPathComponent
            let folderB = parentB.lastPathComponent
            
            if folderA != folderB {
                return folderA > folderB
            }
            return nsPathA.lastPathComponent < nsPathB.lastPathComponent
        }
        
        return SearchResults(
            exactMatches: Array(sortedExact),
            fuzzyMatches: Array(sortedFuzzy)
        )
    }
}

