import Foundation
import Combine

/// Protocol for media management operations
protocol MediaManaging: ObservableObject {
    var selectedFiles: [FileItem] { get set }
    var dockets: [String] { get set }
    var statusMessage: String { get set }
    var isProcessing: Bool { get set }
    var progress: Double { get set }
    
    func refreshDockets()
    func buildSessionIndex(folder: SearchFolder)
    func searchSessions(term: String, folder: SearchFolder) async -> SearchResults
    func runJob(type: JobType, docket: String, wpDate: Date, prepDate: Date, existingPrepFolderName: String?)
    func pickFiles()
    func clearFiles()
}

