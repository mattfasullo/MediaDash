import Foundation

/// Use case for scanning dockets
struct DocketScanningUseCase {
    nonisolated(unsafe) let fileSystem: FileSystem
    let config: AppConfig
    
    nonisolated init(fileSystem: FileSystem = DefaultFileSystem(), config: AppConfig) {
        self.fileSystem = fileSystem
        self.config = config
    }
    
    /// Scan for dockets in the work picture or prep folders
    func scanDockets(jobType: JobType = .workPicture) async throws -> [String] {
        let paths = config.getPaths()
        let base = (jobType == .prep) ? paths.prep : paths.workPic
        var results: [String] = []
        
        // Check if base path exists
        var isDir: ObjCBool = false
        guard fileSystem.fileExists(atPath: base.path, isDirectory: &isDir) else {
            throw AppError.fileSystem(.directoryNotFound(base.path))
        }
        
        do {
            let items = try fileSystem.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )
            
            let sorted = items.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
            
            for item in sorted {
                var isDir: ObjCBool = false
                guard fileSystem.fileExists(atPath: item.path, isDirectory: &isDir),
                      isDir.boolValue,
                      !item.lastPathComponent.hasPrefix(".") else {
                    continue
                }
                
                // For prep mode, extract just the docket number from folder name
                if jobType == .prep {
                    // Prep folders are named like "12345_PREP_Dec4.24"
                    // Extract just "12345" part
                    let folderName = item.lastPathComponent
                    if let docketNumber = folderName.split(separator: "_").first {
                        let docketStr = String(docketNumber)
                        if !results.contains(docketStr) {
                            results.append(docketStr)
                        }
                    }
                } else {
                    // For work picture, just use the folder name (which is the docket number)
                    results.append(item.lastPathComponent)
                }
            }
        } catch {
            throw AppError.fileSystem(.accessDenied(base.path))
        }
        
        return results
    }
}

