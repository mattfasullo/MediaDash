import Foundation

/// Result of a file job operation
struct JobResult {
    let success: Bool
    let failedFiles: [String]
    let prepFolderPath: String?
}

/// Use case for executing file jobs (Work Picture, Prep, Both)
struct FileJobUseCase {
    nonisolated(unsafe) let fileSystem: FileSystem
    let config: AppConfig
    
    nonisolated init(fileSystem: FileSystem = DefaultFileSystem(), config: AppConfig) {
        self.fileSystem = fileSystem
        self.config = config
    }
    
    /// Execute a file job
    func execute(
        type: JobType,
        docket: String,
        files: [FileItem],
        wpDate: Date,
        prepDate: Date,
        metadataProvider: MetadataProviding
    ) async throws -> JobResult {
        let fm = fileSystem
        let paths = config.getPaths()
        var failedFiles: [String] = []
        var prepFolderPath: String? = nil
        
        // Work Picture operation
        if type == .workPicture || type == .both {
            let dateStr = formatDate(wpDate)
            let base = paths.workPic.appendingPathComponent(docket)
            
            // Verify base path exists
            guard fm.fileExists(atPath: base.path) else {
                throw AppError.configuration(.pathNotConfigured(base.path))
            }
            
            let destFolder = getNextFolder(base: base, date: dateStr, fileSystem: fm)
            
            // Create folder if needed
            if !fm.fileExists(atPath: destFolder.path) {
                try fm.createDirectory(at: destFolder, withIntermediateDirectories: false, attributes: nil)
            }
            
            // Copy files
            for file in files {
                let dest = destFolder.appendingPathComponent(file.name)
                if !fm.fileExists(atPath: dest.path) {
                    do {
                        try fm.copyItem(from: file.url, to: dest)
                    } catch {
                        failedFiles.append(file.name)
                    }
                }
            }
        }
        
        // Prep operation
        if type == .prep || type == .both {
            let dateStr = formatDate(prepDate)
            let folderFormat = config.settings.prepFolderFormat
            let folder = folderFormat
                .replacingOccurrences(of: "{docket}", with: docket)
                .replacingOccurrences(of: "{date}", with: dateStr)
            let root = paths.prep.appendingPathComponent(folder)
            prepFolderPath = root.path
            
            // Create prep folder if needed
            if !fm.fileExists(atPath: root.path) {
                try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: nil)
            }
            
            // Get all flat files
            var flats: [(url: URL, sourceId: UUID)] = []
            for file in files {
                let flatFiles = getAllFiles(at: file.url, fileSystem: fm)
                for flatFile in flatFiles {
                    flats.append((flatFile, file.id))
                }
            }
            
            // Process each file
            for (flatFile, _) in flats {
                let category = getCategory(flatFile, config: config)
                let dir = root.appendingPathComponent(category)
                
                // Create category directory if needed
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: nil)
                }
                
                let destFile = dir.appendingPathComponent(flatFile.lastPathComponent)
                
                // Copy file if it doesn't exist
                if !fm.fileExists(atPath: destFile.path) {
                    do {
                        try fm.copyItem(from: flatFile, to: destFile)
                    } catch {
                        failedFiles.append(flatFile.lastPathComponent)
                    }
                }
            }
            
            // Organize stems
            organizeStems(in: root, config: config, fileSystem: fm)
        }
        
        return JobResult(
            success: failedFiles.isEmpty,
            failedFiles: failedFiles,
            prepFolderPath: prepFolderPath
        )
    }
    
    // MARK: - Helper Methods
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMdd.yy"
        return formatter.string(from: date)
    }
    
    private func getNextFolder(base: URL, date: String, fileSystem: FileSystem) -> URL {
        var p = 1
        var isDir: ObjCBool = false
        
        guard fileSystem.fileExists(atPath: base.path, isDirectory: &isDir),
              let items = try? fileSystem.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return base.appendingPathComponent(String(format: "%02d_%@", p, date))
        }
        
        // Filter for directories matching date pattern
        let matchingFolders = items.filter { item in
            var itemIsDir: ObjCBool = false
            guard fileSystem.fileExists(atPath: item.path, isDirectory: &itemIsDir),
                  itemIsDir.boolValue else {
                return false
            }
            let name = item.lastPathComponent
            // Must end with the date (format: "01_date" or "1_date")
            // Also handle old date formats that might not have zero-padded days
            if name.hasSuffix("_\(date)") {
                return true
            }
            // Check if it matches when normalized (handles "Dec2.25" vs "Dec02.25")
            if let underscoreIndex = name.firstIndex(of: "_") {
                let datePart = String(name[name.index(after: underscoreIndex)...])
                if normalizeDateString(datePart) == normalizeDateString(date) {
                    return true
                }
            }
            return false
        }
        
        // Extract numbers and find max
        let nums = matchingFolders.compactMap { item -> Int? in
            let name = item.lastPathComponent
            if let underscoreIndex = name.firstIndex(of: "_") {
                let prefix = String(name[..<underscoreIndex])
                return Int(prefix)
            }
            return nil
        }
        
        if let max = nums.max(), max >= 1 {
            p = max + 1
        }
        
        return base.appendingPathComponent(String(format: "%02d_%@", p, date))
    }
    
    // Helper to normalize date strings for comparison (handles both old and new formats)
    private func normalizeDateString(_ dateStr: String) -> String {
        // Convert "Dec02.25" to "Dec2.25" for comparison
        // This handles matching old folders with new format
        if let dotIndex = dateStr.firstIndex(of: ".") {
            let monthDay = String(dateStr[..<dotIndex])
            let year = String(dateStr[dateStr.index(after: dotIndex)...])
            
            // Extract month (first 3 letters) and day (rest)
            if monthDay.count > 3 {
                let month = String(monthDay.prefix(3))
                let dayStr = String(monthDay.dropFirst(3))
                // Remove leading zero from day if present
                let day = dayStr.hasPrefix("0") && dayStr.count > 1 ? String(dayStr.dropFirst()) : dayStr
                return "\(month)\(day).\(year)"
            }
        }
        return dateStr
    }
    
    private func getCategory(_ url: URL, config: AppConfig) -> String {
        let ext = url.pathExtension.lowercased()
        if config.settings.pictureExtensions.contains(ext) { return config.settings.pictureFolderName }
        if config.settings.musicExtensions.contains(ext) { return config.settings.musicFolderName }
        if config.settings.aafOmfExtensions.contains(ext) { return config.settings.aafOmfFolderName }
        return config.settings.otherFolderName
    }
    
    private func getAllFiles(at url: URL, fileSystem: FileSystem) -> [URL] {
        var results: [URL] = []
        var isDir: ObjCBool = false
        
        guard fileSystem.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return results
        }
        
        if isDir.boolValue {
            if let contents = try? fileSystem.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                for item in contents {
                    results.append(contentsOf: getAllFiles(at: item, fileSystem: fileSystem))
                }
            }
        } else {
            results.append(url)
        }
        
        return results
    }
    
    private func organizeStems(in prepFolder: URL, config: AppConfig, fileSystem: FileSystem) {
        let musicFolder = prepFolder.appendingPathComponent(config.settings.musicFolderName)
        var isDir: ObjCBool = false
        
        guard fileSystem.fileExists(atPath: musicFolder.path, isDirectory: &isDir) else { return }
        
        guard let musicFiles = try? fileSystem.contentsOfDirectory(at: musicFolder, includingPropertiesForKeys: nil, options: []) else { return }
        
        let audioFiles = musicFiles.filter {
            var isDir: ObjCBool = false
            guard fileSystem.fileExists(atPath: $0.path, isDirectory: &isDir) else { return false }
            return !isDir.boolValue && config.settings.musicExtensions.contains($0.pathExtension.lowercased())
        }
        
        // Group stems by track name
        var stemGroups: [String: [URL]] = [:]
        
        for file in audioFiles {
            if isStemFile(file.lastPathComponent) {
                let trackName = extractTrackName(file.lastPathComponent)
                stemGroups[trackName, default: []].append(file)
            }
        }
        
        // Move each stem group into its own folder
        for (trackName, stems) in stemGroups where stems.count > 1 {
            let stemFolder = musicFolder.appendingPathComponent("\(trackName) STEMS")
            try? fileSystem.createDirectory(at: stemFolder, withIntermediateDirectories: true, attributes: nil)
            
            for stem in stems {
                let destination = stemFolder.appendingPathComponent(stem.lastPathComponent)
                try? fileSystem.moveItem(at: stem, to: destination)
            }
        }
    }
    
    private func isStemFile(_ filename: String) -> Bool {
        let stemKeywords = ["vocal", "instrumental", "drum", "percussion", "bass", "guitar",
                           "piano", "strings", "brass", "synth", "pad", "lead", "stem"]
        return stemKeywords.contains { filename.lowercased().contains($0) }
    }
    
    private func extractTrackName(_ filename: String) -> String {
        let stemKeywords = ["vocal", "instrumental", "drum", "percussion", "bass", "guitar",
                           "piano", "strings", "brass", "synth", "pad", "lead", "stem"]
        var name = (filename as NSString).deletingPathExtension
        let lowercased = name.lowercased()
        
        for keyword in stemKeywords {
            if lowercased.hasSuffix(keyword) {
                name = String(name.dropLast(keyword.count)).trimmingCharacters(in: .whitespaces)
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
                break
            }
        }
        return name
    }
}

