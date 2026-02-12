import Foundation
import SwiftUI
import Combine

/// Service for aggregating docket-related data from multiple sources
@MainActor
class DocketHubService: ObservableObject {
    @Published var isFetching = false
    @Published var lastError: String?
    
    private let asanaService: AsanaService
    private let asanaCacheManager: AsanaCacheManager
    private let simianService: SimianService
    private let metadataManager: DocketMetadataManager
    private let settingsManager: SettingsManager
    
    init(
        asanaService: AsanaService? = nil,
        asanaCacheManager: AsanaCacheManager? = nil,
        simianService: SimianService? = nil,
        metadataManager: DocketMetadataManager? = nil,
        settingsManager: SettingsManager? = nil
    ) {
        self.asanaService = asanaService ?? AsanaService()
        self.asanaCacheManager = asanaCacheManager ?? AsanaCacheManager()
        self.simianService = simianService ?? SimianService()
        self.metadataManager = metadataManager ?? DocketMetadataManager()
        self.settingsManager = settingsManager ?? SettingsManager()
    }
    
    /// Extract docket number from text (matches 5 digits optionally followed by -XX)
    nonisolated private func extractDocketNumber(from text: String) -> String? {
        let pattern = #"\d{5}(?:-[A-Z]{1,3})?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }
    
    /// Check if text contains the docket number (exact match or prefix)
    nonisolated private func matchesDocket(_ text: String, docketNumber: String) -> Bool {
        let normalizedDocket = docketNumber.trimmingCharacters(in: .whitespaces)
        let normalizedText = text.trimmingCharacters(in: .whitespaces)
        
        // Exact match
        if normalizedText.contains(normalizedDocket) {
            return true
        }
        
        // Extract docket from text and compare
        if let extractedDocket = extractDocketNumber(from: normalizedText) {
            // Exact match
            if extractedDocket == normalizedDocket {
                return true
            }
            // Prefix match (e.g., "254" matches "25464")
            if extractedDocket.hasPrefix(normalizedDocket) || normalizedDocket.hasPrefix(extractedDocket) {
                return true
            }
        }
        
        return false
    }
    
    /// Fetch all hub data for a docket number
    /// Optimized with timeouts and progressive loading
    func fetchHubData(for docketNumber: String, jobName: String?) async throws -> DocketHubData {
        isFetching = true
        lastError = nil
        
        defer {
            isFetching = false
        }
        
        let normalizedDocket = docketNumber.trimmingCharacters(in: .whitespaces)
        
        // Get fast data first (synchronous)
        let metadataKey = jobName.map { "\(normalizedDocket)_\($0)" } ?? normalizedDocket
        let metadata = metadataManager.metadata[metadataKey]
        
        // Fetch data from all sources concurrently with timeouts
        async let asanaTasks = withTimeout(seconds: 10) {
            try await self.searchAsanaTasks(docketNumber: normalizedDocket)
        }
        
        async let simianProjects = withTimeout(seconds: 15) {
            try await self.searchSimianProjects(docketNumber: normalizedDocket)
        }
        
        async let serverFolders = withTimeout(seconds: 30) {
            try await self.searchServerFolders(docketNumber: normalizedDocket)
        }
        
        // Wait for all async operations (with fallback to empty arrays on timeout)
        let (asanaResults, simianResults, serverResults) = try await (
            asanaTasks ?? [],
            simianProjects ?? [],
            serverFolders ?? []
        )
        
        return DocketHubData(
            docketNumber: normalizedDocket,
            jobName: jobName ?? "",
            asanaTasks: asanaResults,
            simianProjects: simianResults,
            serverFolders: serverResults,
            metadata: metadata
        )
    }
    
    /// Execute an async operation with a timeout, returning nil if timeout is exceeded
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T? {
        return try await withThrowingTaskGroup(of: T?.self) { group in
            // Add the actual operation
            group.addTask {
                return try await operation()
            }
            
            // Add a timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            
            // Return the first result (either the operation or timeout)
            if let result = try await group.next(), let value = result {
                group.cancelAll()
                return value
            }
            
            group.cancelAll()
            return nil
        }
    }
    
    /// Search Asana tasks matching the docket number
    func searchAsanaTasks(docketNumber: String) async throws -> [DocketHubAsanaTask] {
        let normalizedDocket = docketNumber.trimmingCharacters(in: .whitespaces)
        var results: [DocketHubAsanaTask] = []
        
        // Search in cached dockets
        let cachedDockets = asanaCacheManager.loadCachedDockets()
        let matchingDockets = cachedDockets.filter { docket in
            matchesDocket(docket.number, docketNumber: normalizedDocket)
        }
        
        // Convert matching dockets to hub tasks
        for docket in matchingDockets {
            var projectName: String? = nil
            var projectGid: String? = nil
            var customFields: [String: String] = [:]
            
            if let projectMeta = docket.projectMetadata {
                projectName = projectMeta.projectName
                projectGid = projectMeta.projectGid
                customFields = projectMeta.customFields
            }
            
            // Build Asana task URL
            let taskURL: URL?
            if let taskGid = docket.taskGid {
                taskURL = URL(string: "https://app.asana.com/0/0/\(taskGid)")
            } else {
                taskURL = nil
            }
            
            let hubTask = DocketHubAsanaTask(
                id: docket.taskGid ?? UUID().uuidString,
                taskGid: docket.taskGid ?? "",
                name: docket.fullName,
                projectName: projectName,
                projectGid: projectGid,
                dueDate: docket.dueDate,
                completed: docket.completed ?? false,
                customFields: customFields,
                assignee: nil, // Would need to fetch task details for this
                notes: nil,
                tags: docket.studio.map { [$0] },
                url: taskURL
            )
            results.append(hubTask)
        }
        
        // Also search in cached sessions (for calendar items)
        let cachedSessions = asanaCacheManager.cachedSessions
        for session in cachedSessions {
            if let sessionDocket = extractDocketNumber(from: session.name),
               matchesDocket(sessionDocket, docketNumber: normalizedDocket) {
                
                // Check if we already have this task
                if results.contains(where: { $0.taskGid == session.gid }) {
                    continue
                }
                
                var projectName: String? = nil
                var projectGid: String? = nil
                var customFields: [String: String] = [:]
                
                if let memberships = session.memberships, let firstProject = memberships.first?.project {
                    projectName = firstProject.name
                    projectGid = firstProject.gid
                }
                
                // Extract custom fields
                if let fields = session.custom_fields {
                    for field in fields {
                        if let value = field.display_value {
                            customFields[field.name] = value
                        }
                    }
                }
                
                let taskURL = URL(string: "https://app.asana.com/0/0/\(session.gid)")
                
                let hubTask = DocketHubAsanaTask(
                    id: session.gid,
                    taskGid: session.gid,
                    name: session.name,
                    projectName: projectName,
                    projectGid: projectGid,
                    dueDate: session.effectiveDueDate,
                    completed: session.completed ?? false,
                    customFields: customFields,
                    assignee: session.assignee?.name,
                    notes: session.notes ?? session.html_notes,
                    tags: session.tags?.compactMap { $0.name },
                    url: taskURL
                )
                results.append(hubTask)
            }
        }
        
        return results
    }
    
    /// Search Simian projects matching the docket number
    func searchSimianProjects(docketNumber: String) async throws -> [DocketHubSimianProject] {
        let normalizedDocket = docketNumber.trimmingCharacters(in: .whitespaces)
        var results: [DocketHubSimianProject] = []
        
        do {
            // Fetch all projects
            let projects = try await simianService.getProjectList()
            
            // Filter projects first before fetching details (optimization)
            let matchingProjects = projects.filter { project in
                matchesDocket(project.name, docketNumber: normalizedDocket)
            }
            
            // Fetch details for matching projects concurrently (but limit concurrency)
            await withTaskGroup(of: DocketHubSimianProject?.self) { group in
                for project in matchingProjects.prefix(10) { // Limit to first 10 matches for performance
                    group.addTask { [normalizedDocket] in
                        // Fetch project details
                        let projectInfo = try? await self.simianService.getProjectInfoDetails(projectId: project.id)
                        
                        // Check project_number field if available
                        let projectNumber = projectInfo?.projectNumber
                        let shouldInclude = projectNumber.map { self.matchesDocket($0, docketNumber: normalizedDocket) } ?? true
                        
                        guard shouldInclude else { return nil }
                        
                        // Don't fetch files immediately - just get basic info for performance
                        // Files can be loaded lazily when user clicks on the project
                        
                        return DocketHubSimianProject(
                            id: project.id,
                            projectId: project.id,
                            name: project.name,
                            projectNumber: projectNumber,
                            uploadDate: projectInfo?.uploadDate,
                            startDate: projectInfo?.startDate,
                            completeDate: projectInfo?.completeDate,
                            lastAccess: projectInfo?.lastAccess,
                            projectSize: projectInfo?.projectSize,
                            fileCount: 0, // Will be loaded lazily if needed
                            folderStructure: nil // Will be loaded lazily if needed
                        )
                    }
                }
                
                for await result in group {
                    if let project = result {
                        results.append(project)
                    }
                }
            }
        } catch {
            // If Simian is not configured or fails, return empty array
            print("DocketHubService: Error fetching Simian projects: \(error.localizedDescription)")
        }
        
        return results
    }
    
    /// Search server folders matching the docket number
    /// Searches comprehensively across the entire server structure including GM folder, year folders, and DATA BACKUPS
    func searchServerFolders(docketNumber: String) async throws -> [DocketHubServerFolder] {
        let normalizedDocket = docketNumber.trimmingCharacters(in: .whitespaces)
        var results: [DocketHubServerFolder] = []
        
        let settings = settingsManager.currentSettings
        let config = AppConfig(settings: settings)
        
        // Search in sessions base path
        let sessionsPath = URL(fileURLWithPath: config.settings.sessionsBasePath)
        if FileManager.default.fileExists(atPath: sessionsPath.path) {
            if let folders = try? await scanFolders(at: sessionsPath, matchingDocket: normalizedDocket, folderType: "SESSIONS") {
                results.append(contentsOf: folders)
            }
        }
        
        // Search in work picture path
        let workPicPath = URL(fileURLWithPath: config.getPaths().workPic.path)
        if FileManager.default.fileExists(atPath: workPicPath.path) {
            if let folders = try? await scanFolders(at: workPicPath, matchingDocket: normalizedDocket, folderType: "WORK PICTURE") {
                results.append(contentsOf: folders)
            }
        }
        
        // Search in prep path
        let prepPath = URL(fileURLWithPath: config.getPaths().prep.path)
        if FileManager.default.fileExists(atPath: prepPath.path) {
            if let folders = try? await scanFolders(at: prepPath, matchingDocket: normalizedDocket, folderType: "PREP") {
                results.append(contentsOf: folders)
            }
        }
        
        // Search entire GM folder structure (comprehensive search)
        let gmBasePath = URL(fileURLWithPath: config.settings.serverBasePath)
        if FileManager.default.fileExists(atPath: gmBasePath.path) {
            if let gmFolders = try? await scanGMStructure(at: gmBasePath, matchingDocket: normalizedDocket, yearPrefix: config.settings.yearPrefix) {
                results.append(contentsOf: gmFolders)
            }
        }
        
        return results
    }
    
    /// Scan the entire GM folder structure including all year folders and DATA BACKUPS
    /// Optimized to search most recent years first and limit depth for older years
    private func scanGMStructure(at gmBase: URL, matchingDocket: String, yearPrefix: String) async throws -> [DocketHubServerFolder] {
        var results: [DocketHubServerFolder] = []
        
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: gmBase,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }
        
        // Find all year folders (e.g., GM_2024, GM_2025, GM_2026)
        let yearFolders = items.filter { item in
            guard item.hasDirectoryPath else { return false }
            let name = item.lastPathComponent
            return name.hasPrefix(yearPrefix) && name.count >= yearPrefix.count + 4 // e.g., "GM_" + "2026"
        }
        
        // Sort by year (most recent first) - search recent years first for faster results
        let sortedYearFolders = yearFolders.sorted { folder1, folder2 in
            let name1 = folder1.lastPathComponent
            let name2 = folder2.lastPathComponent
            // Extract year number and compare
            if let year1 = extractYear(from: name1, prefix: yearPrefix),
               let year2 = extractYear(from: name2, prefix: yearPrefix) {
                return year1 > year2 // Most recent first
            }
            return name1 > name2
        }
        
        // Process year folders concurrently but limit to recent years for initial search
        let currentYear = Calendar.current.component(.year, from: Date())
        let yearsToSearch = sortedYearFolders.filter { folder in
            if let year = extractYear(from: folder.lastPathComponent, prefix: yearPrefix) {
                // Search current year and previous 2 years deeply, others shallow
                return year >= currentYear - 2
            }
            return true
        }
        
        // Search recent years concurrently (most likely to have active dockets)
        await withTaskGroup(of: [DocketHubServerFolder].self) { group in
            for yearFolder in yearsToSearch.prefix(3) { // Limit to 3 most recent years for initial load
                group.addTask { [yearFolder] in
                    var yearResults: [DocketHubServerFolder] = []
                    
                    // Search in all subfolders of the year folder
                    guard let subfolders = try? FileManager.default.contentsOfDirectory(
                        at: yearFolder,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) else {
                        return yearResults
                    }
                    
                    // Process subfolders concurrently
                    await withTaskGroup(of: [DocketHubServerFolder].self) { subGroup in
                        for subfolder in subfolders {
                            guard subfolder.hasDirectoryPath else { continue }
                            
                            subGroup.addTask { [subfolder] in
                                let folderName = subfolder.lastPathComponent
                                let folderType: String
                                
                                // Determine folder type
                                if folderName.contains("DATA BACKUPS") || folderName.contains("DATA BACKUP") {
                                    folderType = "DATA BACKUPS"
                                } else if folderName.contains("WORK PICTURE") {
                                    folderType = "WORK PICTURE"
                                } else if folderName.contains("SESSION PREP") || folderName.contains("PREP") {
                                    folderType = "PREP"
                                } else if folderName.contains("MUSIC DEMOS") {
                                    folderType = "MUSIC DEMOS"
                                } else if folderName.contains("MUSIC LAYUPS") {
                                    folderType = "MUSIC LAYUPS"
                                } else if folderName.contains("SFX") {
                                    folderType = "SFX"
                                } else {
                                    folderType = folderName
                                }
                                
                            // Search recursively in this subfolder (reduced depth for performance)
                            let maxDepth = folderType == "DATA BACKUPS" ? 3 : 2
                            return (try? await self.scanFolders(
                                at: subfolder,
                                matchingDocket: matchingDocket,
                                folderType: folderType,
                                depth: 0,
                                maxDepth: maxDepth
                            )) ?? []
                            }
                        }
                        
                        for await folderResults in subGroup {
                            yearResults.append(contentsOf: folderResults)
                        }
                    }
                    
                    return yearResults
                }
            }
            
            // Collect results from all year folders
            for await yearResults in group {
                results.append(contentsOf: yearResults)
            }
        }
        
        // Search older years with shallow search (if needed, can be done in background)
        if yearsToSearch.count > 3 {
            // Do a quick shallow search of older years
            for yearFolder in yearsToSearch.dropFirst(3) {
                await Task.yield()
                
                if let subfolders = try? FileManager.default.contentsOfDirectory(
                    at: yearFolder,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for subfolder in subfolders {
                        guard subfolder.hasDirectoryPath else { continue }
                        let folderName = subfolder.lastPathComponent
                        
                        // Quick check - only search if folder name itself contains docket
                        if let extractedDocket = extractDocketNumber(from: folderName),
                           matchesDocket(extractedDocket, docketNumber: matchingDocket) {
                            let folderType = folderName.contains("DATA BACKUPS") ? "DATA BACKUPS" : folderName
                            let lastModified = try? subfolder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                            
                            results.append(DocketHubServerFolder(
                                id: subfolder.path,
                                path: subfolder,
                                folderName: folderName,
                                fileCount: 0,
                                lastModified: lastModified,
                                folderType: folderType
                            ))
                        }
                    }
                }
            }
        }
        
        return results
    }
    
    /// Extract year from folder name (e.g., "GM_2026" -> 2026)
    nonisolated private func extractYear(from name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix) else { return nil }
        let yearString = String(name.dropFirst(prefix.count))
        return Int(yearString)
    }
    
    /// Scan folders recursively for docket matches (optimized with early exit and smart filtering)
    private func scanFolders(at url: URL, matchingDocket: String, folderType: String? = nil, depth: Int = 0, maxDepth: Int = 2) async throws -> [DocketHubServerFolder] {
        var results: [DocketHubServerFolder] = []
        
        guard depth < maxDepth else { return results }
        
        // Quick check: if folder name doesn't contain any digits, skip it entirely (except at root)
        let folderName = url.lastPathComponent
        if depth > 0 && !folderName.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
            // Skip folders without digits (except at root level where we need to explore)
            return results
        }
        
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }
        
        // Process items in batches to avoid blocking
        let batchSize = 100
        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, items.count)
            let batch = items[batchStart..<batchEnd]
            
            for item in batch {
                guard item.hasDirectoryPath else { continue }
                
                let itemName = item.lastPathComponent
                
                // Quick filter: skip if name doesn't contain any digits (much faster than regex)
                if !itemName.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
                    continue
                }
                
                // Check if folder name matches docket pattern
                if let extractedDocket = extractDocketNumber(from: itemName),
                   matchesDocket(extractedDocket, docketNumber: matchingDocket) {
                    
                    // Skip file counting (expensive) - can be lazy loaded if needed
                    // Get last modified date (lightweight)
                    let lastModified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    
                    let hubFolder = DocketHubServerFolder(
                        id: item.path,
                        path: item,
                        folderName: itemName,
                        fileCount: 0, // Skip counting for performance
                        lastModified: lastModified,
                        folderType: folderType
                    )
                    results.append(hubFolder)
                }
                
                // Recursively search subdirectories (but limit depth for performance)
                if depth < maxDepth - 1 {
                    let subResults = try await scanFolders(at: item, matchingDocket: matchingDocket, folderType: folderType, depth: depth + 1, maxDepth: maxDepth)
                    results.append(contentsOf: subResults)
                }
            }
            
            // Yield periodically for responsiveness
            if batchStart % (batchSize * 2) == 0 {
                await Task.yield()
            }
        }
        
        return results
    }
    
    /// Count files in a directory (non-recursive) - lazy loaded when needed
    nonisolated private func countFiles(in url: URL) -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        return items.filter { !$0.hasDirectoryPath }.count
    }
    
    /// Search notifications matching the docket number
}
