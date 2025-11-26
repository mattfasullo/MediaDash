import Foundation
@testable import MediaDash

/// Mock implementation of MetadataProviding for testing
class MockMetadataManager: MetadataProviding {
    private var metadata: [String: DocketMetadata] = [:]
    
    init(metadata: [String: DocketMetadata] = [:]) {
        self.metadata = metadata
    }
    
    func getMetadata(for docketNumber: String, jobName: String) -> DocketMetadata {
        let key = "\(docketNumber)_\(jobName)"
        return metadata[key] ?? DocketMetadata(docketNumber: docketNumber, jobName: jobName)
    }
    
    func getJobName(for docket: String) -> String {
        for (_, meta) in metadata {
            if meta.docketNumber == docket && !meta.jobName.isEmpty {
                return meta.jobName
            }
        }
        return docket
    }
    
    func addMetadata(_ meta: DocketMetadata) {
        metadata[meta.id] = meta
    }
}

