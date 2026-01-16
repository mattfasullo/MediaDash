import Foundation
import Combine

private actor DownloadLogWriter {
    private let logURL: URL
    
    init(logURL: URL) {
        self.logURL = logURL
    }
    
    func appendLine(_ line: String) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let data = (line + "\n").data(using: .utf8) ?? Data()
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}

final class SimianArchiveManager: ObservableObject {
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var statusMessage: String = ""
    @Published var currentProjectName: String?
    @Published var currentFileName: String?
    @Published var completedProjects: Int = 0
    @Published var totalProjects: Int = 0
    @Published var completedFiles: Int = 0
    @Published var totalFiles: Int = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var scannedFolders: Int = 0
    @Published var currentFolderPath: String?
    
    private var archiveTask: Task<Void, Never>?
    
    func startArchive(projects: [SimianProject], destinationURL: URL, simianService: SimianService) {
        cancel()
        
        archiveTask = Task {
            await MainActor.run {
                isRunning = true
                errorMessage = nil
                statusMessage = "Preparing archive..."
                completedProjects = 0
                totalProjects = projects.count
                completedFiles = 0
                totalFiles = 0
                downloadedBytes = 0
                totalBytes = 0
                scannedFolders = 0
                currentFolderPath = nil
            }
            
            do {
                try await archiveProjects(projects, destinationURL: destinationURL, simianService: simianService)
                await MainActor.run {
                    statusMessage = "Archive complete."
                    isRunning = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    statusMessage = "Archive cancelled."
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    statusMessage = "Archive failed."
                    isRunning = false
                }
            }
        }
    }
    
    func cancel() {
        archiveTask?.cancel()
        archiveTask = nil
    }
    
    private func archiveProjects(_ projects: [SimianProject], destinationURL: URL, simianService: SimianService) async throws {
        let logURL = destinationURL.appendingPathComponent("SimianArchiver_Downloads.txt")
        let logWriter = DownloadLogWriter(logURL: logURL)
        let maxConcurrentDownloads = 3
        var index = 0
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            func enqueueNext() {
                guard index < projects.count else { return }
                let project = projects[index]
                index += 1
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.archiveProject(
                        project,
                        destinationURL: destinationURL,
                        simianService: simianService,
                        logWriter: logWriter
                    )
                }
            }
            
            let initialCount = min(maxConcurrentDownloads, projects.count)
            for _ in 0..<initialCount {
                enqueueNext()
            }
            
            while let _ = try await group.next() {
                enqueueNext()
            }
        }
    }

    private func archiveProject(
        _ project: SimianProject,
        destinationURL: URL,
        simianService: SimianService,
        logWriter: DownloadLogWriter
    ) async throws {
        try Task.checkCancellation()
        await MainActor.run {
            currentProjectName = project.name
            statusMessage = "Fetching project contents..."
            completedFiles = 0
            totalFiles = 0
            downloadedBytes = 0
            totalBytes = 0
            scannedFolders = 0
            currentFolderPath = nil
        }
        
        // #region agent log
        do {
            let logData: [String: Any] = [
                "sessionId": "debug-session",
                "runId": "run1",
                "hypothesisId": "H4",
                "location": "SimianArchiveManager.swift:archiveProject",
                "message": "archive project start",
                "data": [
                    "projectId": project.id,
                    "projectName": project.name
                ],
                "timestamp": Int(Date().timeIntervalSince1970 * 1000)
            ]
            if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                logFile.seekToEndOfFile()
                logFile.write(line)
                logFile.write("\n".data(using: .utf8)!)
                logFile.closeFile()
            }
        }
        // #endregion

        // Prefer server-side ZIP archive (no per-file fallback)
        let zipName = "\(Self.sanitizeFileName(project.name))_\(project.id).zip"
        let zipURL = destinationURL.appendingPathComponent(zipName)
        do {
            await MainActor.run {
                currentProjectName = project.name
                statusMessage = "Downloading project archive..."
            }
            
            // #region agent log
            do {
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "H7",
                    "location": "SimianArchiveManager.swift:archiveProject",
                    "message": "archive download start",
                    "data": [
                        "projectId": project.id,
                        "zipPath": zipURL.path
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                    let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                    logFile.seekToEndOfFile()
                    logFile.write(line)
                    logFile.write("\n".data(using: .utf8)!)
                    logFile.closeFile()
                }
            }
            // #endregion
            
            try await simianService.downloadProjectArchive(
                projectId: project.id,
                to: zipURL
            ) { [weak self] downloaded, total in
                Task { @MainActor in
                    guard let self else { return }
                    self.currentProjectName = project.name
                    self.downloadedBytes = downloaded
                    if let total, total > 0 {
                        self.totalBytes = total
                    }
                }
            }
            
            // #region agent log
            do {
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "H7",
                    "location": "SimianArchiveManager.swift:archiveProject",
                    "message": "archive download success",
                    "data": [
                        "projectId": project.id,
                        "zipPath": zipURL.path
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                    let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                    logFile.seekToEndOfFile()
                    logFile.write(line)
                    logFile.write("\n".data(using: .utf8)!)
                    logFile.closeFile()
                }
            }
            // #endregion
            
            let fileSizeBytes: Int64? = {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: zipURL.path),
                   let size = attributes[.size] as? NSNumber {
                    return size.int64Value
                }
                return nil
            }()
            let logLine = Self.buildDownloadLogLine(
                projectName: project.name,
                projectId: project.id,
                fileName: zipURL.lastPathComponent,
                sizeBytes: fileSizeBytes
            )
            try await logWriter.appendLine(logLine)
            
            await MainActor.run {
                completedProjects += 1
            }
        } catch {
            // #region agent log
            do {
                let logData: [String: Any] = [
                    "sessionId": "debug-session",
                    "runId": "run1",
                    "hypothesisId": "H7",
                    "location": "SimianArchiveManager.swift:archiveProject",
                    "message": "archive download failed",
                    "data": [
                        "projectId": project.id,
                        "error": error.localizedDescription
                    ],
                    "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                ]
                if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                    let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                    logFile.seekToEndOfFile()
                    logFile.write(line)
                    logFile.write("\n".data(using: .utf8)!)
                    logFile.closeFile()
                }
            }
            // #endregion
            
            await MainActor.run {
                statusMessage = "Failed to download zip."
            }
            throw error
        }
    }

    private static let logDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func buildDownloadLogLine(
        projectName: String,
        projectId: String,
        fileName: String,
        sizeBytes: Int64?
    ) -> String {
        let timestamp = logDateFormatter.string(from: Date())
        let safeProjectName = sanitizeLogValue(projectName)
        let safeFileName = sanitizeLogValue(fileName)
        let sizeValue = sizeBytes.map(String.init) ?? ""
        return "\(timestamp)\t\(safeProjectName)\t\(projectId)\t\(safeFileName)\t\(sizeValue)"
    }

    private static func sanitizeLogValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
    
    private func downloadFiles(_ files: [SimianFile], to directoryURL: URL, simianService: SimianService) async throws {
        let fileManager = FileManager.default
        let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let maxConcurrentDownloads = max(4, min(16, cpuCount * 2))
        var index = 0
        
        struct DownloadResult {
            let fileName: String
            let bytes: Int64
        }
        
        try await withThrowingTaskGroup(of: DownloadResult?.self) { group in
            func enqueueNext() {
                guard index < files.count else { return }
                let file = files[index]
                index += 1
                group.addTask {
                    try Task.checkCancellation()
                    guard let mediaURL = file.mediaURL else {
                        return nil
                    }
                    
                    // #region agent log
                    do {
                        let logData: [String: Any] = [
                            "sessionId": "debug-session",
                            "runId": "run1",
                            "hypothesisId": "H3",
                            "location": "SimianArchiveManager.swift:downloadFiles",
                            "message": "enqueue download",
                            "data": [
                                "fileId": file.id,
                                "projectId": file.projectId ?? "nil",
                                "host": mediaURL.host ?? "nil"
                            ],
                            "timestamp": Int(Date().timeIntervalSince1970 * 1000)
                        ]
                        if let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") {
                            let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
                            logFile.seekToEndOfFile()
                            logFile.write(line)
                            logFile.write("\n".data(using: .utf8)!)
                            logFile.closeFile()
                        }
                    }
                    // #endregion
                    
                    let fileName = await SimianArchiveManager.buildFileName(for: file, mediaURL: mediaURL)
                    var destinationURL = directoryURL.appendingPathComponent(fileName)
                    
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        let fileExtension = mediaURL.pathExtension
                        let baseName = fileExtension.isEmpty ? fileName : String(fileName.dropLast(fileExtension.count + 1))
                        let dedupedName = fileExtension.isEmpty
                            ? "\(baseName)_\(file.id)"
                            : "\(baseName)_\(file.id).\(fileExtension)"
                        destinationURL = directoryURL.appendingPathComponent(dedupedName)
                    }
                    
                    await MainActor.run {
                        self.currentFileName = fileName
                        let nextCount = self.completedFiles + 1
                        self.statusMessage = "Downloading \(fileName) (\(nextCount)/\(max(self.totalFiles, 1)))"
                    }
                    
                    try await simianService.downloadFile(from: mediaURL, to: destinationURL)
                    
                    let bytes: Int64
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
                       let sizeNumber = attributes[.size] as? NSNumber {
                        bytes = sizeNumber.int64Value
                    } else {
                        bytes = 0
                    }
                    
                    return DownloadResult(fileName: fileName, bytes: bytes)
                }
            }
            
            let initialCount = min(maxConcurrentDownloads, files.count)
            for _ in 0..<initialCount {
                enqueueNext()
            }
            
            while let result = try await group.next() {
                if let result = result {
                    await MainActor.run {
                        self.completedFiles += 1
                        self.downloadedBytes += result.bytes
                    }
                }
                enqueueNext()
            }
        }
    }

    private func fetchFileSizeBytes(projectId: String?, fileId: String, simianService: SimianService) async throws -> Int64? {
        guard let projectId = projectId else { return nil }
        let fileInfo = try await simianService.getFileInfo(projectId: projectId, fileId: fileId)
        return fileInfo.mediaSizeBytes
    }
    
    private func fetchFolderTree(
        projectId: String,
        parentFolderId: String?,
        parentPath: String,
        simianService: SimianService,
        visitedFolderIds: Set<String>
    ) async throws -> [SimianFolderNode] {
        var nodes: [SimianFolderNode] = []
        
        await MainActor.run {
            let parentLabel = parentFolderId ?? "root"
            statusMessage = "Listing folders (\(parentLabel))..."
            currentFolderPath = parentPath.isEmpty ? "/" : parentPath
        }
        
        let folders = try await fetchFolders(
            projectId: projectId,
            parentFolderId: parentFolderId,
            simianService: simianService
        )
        
        for folder in folders {
            if visitedFolderIds.contains(folder.id) {
                continue
            }
            let folderName = Self.sanitizeFileName(folder.name)
            let relativePath = parentPath.isEmpty ? folderName : "\(parentPath)/\(folderName)"
            let childNodes = try await fetchFolderTree(
                projectId: projectId,
                parentFolderId: folder.id,
                parentPath: relativePath,
                simianService: simianService,
                visitedFolderIds: visitedFolderIds.union([folder.id])
            )
            
            nodes.append(
                SimianFolderNode(
                    folder: folder,
                    relativePath: relativePath
                )
            )
            
            await MainActor.run {
                scannedFolders += 1
                statusMessage = "Scanning folders (\(scannedFolders))..."
            }
            nodes.append(contentsOf: childNodes)
        }
        
        return nodes
    }

    private func fetchFolders(projectId: String, parentFolderId: String?, simianService: SimianService) async throws -> [SimianFolder] {
        let start = Date()
        logEvent("fetch_folders_start", data: [
            "projectId": projectId,
            "parentFolderId": parentFolderId ?? "root"
        ])
        let folders = try await withTimeout(seconds: 90) {
            try await simianService.getProjectFolders(projectId: projectId, parentFolderId: parentFolderId)
        }
        let elapsed = Date().timeIntervalSince(start)
        logEvent("fetch_folders_success", data: [
            "projectId": projectId,
            "parentFolderId": parentFolderId ?? "root",
            "count": folders.count,
            "elapsedSeconds": elapsed
        ])
        await MainActor.run {
            statusMessage = "Found \(folders.count) folders (\(String(format: "%.1f", elapsed))s)"
        }
        return folders
    }

    private func fetchFiles(projectId: String, folderId: String?, simianService: SimianService) async throws -> [SimianFile] {
        let start = Date()
        logEvent("fetch_files_start", data: [
            "projectId": projectId,
            "folderId": folderId ?? "root"
        ])
        let files = try await withTimeout(seconds: 90) {
            try await simianService.getProjectFiles(projectId: projectId, folderId: folderId)
        }
        let elapsed = Date().timeIntervalSince(start)
        logEvent("fetch_files_success", data: [
            "projectId": projectId,
            "folderId": folderId ?? "root",
            "count": files.count,
            "elapsedSeconds": elapsed
        ])
        await MainActor.run {
            statusMessage = "Found \(files.count) files (\(String(format: "%.1f", elapsed))s)"
        }
        return files
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SimianError.apiError("Request timed out after \(Int(seconds))s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func logEvent(_ event: String, data: [String: Any]) {
        let logData: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "event": event,
            "data": data
        ]
        
        guard let logFile = FileHandle(forWritingAtPath: "/Users/mattfasullo/Projects/MediaDash/.cursor/debug.log") else {
            return
        }
        
        let line = (try? JSONSerialization.data(withJSONObject: logData)) ?? Data()
        logFile.seekToEndOfFile()
        logFile.write(line)
        logFile.write("\n".data(using: .utf8)!)
        logFile.closeFile()
    }
    
    private static func buildFileName(for file: SimianFile, mediaURL: URL) -> String {
        let sanitizedTitle = Self.sanitizeFileName(file.title.isEmpty ? "file_\(file.id)" : file.title)
        let fileExtension = mediaURL.pathExtension
        
        if fileExtension.isEmpty {
            return sanitizedTitle
        }
        
        if sanitizedTitle.lowercased().hasSuffix(".\(fileExtension.lowercased())") {
            return sanitizedTitle
        }
        
        return "\(sanitizedTitle).\(fileExtension)"
    }
    
    private static func sanitizeFileName(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value.components(separatedBy: invalidCharacters).joined(separator: "_")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func zipDirectory(_ sourceURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = sourceURL
        process.arguments = ["-r", destinationURL.path, "."]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw SimianError.apiError("Zip failed: \(errorOutput)")
        }
    }
}

private struct SimianFolderNode {
    let folder: SimianFolder
    let relativePath: String
}

