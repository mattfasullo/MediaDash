import Foundation

/// Protocol for providing docket metadata
protocol MetadataProviding {
    func getMetadata(for docketNumber: String, jobName: String) -> DocketMetadata
    func getJobName(for docket: String) -> String
}

