//
//  FolderNamingService.swift
//  MediaDash
//
//  Centralized service for folder naming and date formatting across the app.
//  Ensures consistency and makes it easy to change formats in the future.
//

import Foundation

struct FolderNamingService: Sendable {
    let settings: AppSettings
    
    /// App-wide standard date format: MmmDD.YY (e.g., "Feb09.26")
    nonisolated static let standardDateFormat = "MMMdd.yy"
    
    /// Format a date using the app-wide standard format
    nonisolated func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Self.standardDateFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
    
    /// Sanitize a string for use in folder names (remove invalid characters)
    nonisolated func sanitizeFolderName(_ name: String) -> String {
        var t = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        // Strip trailing date-like suffix (e.g. " - Feb 9", " - Feb 9.26", " - Feb.5.26")
        if let range = t.range(of: "\\s*[-–]\\s*(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[.\\s\\d]*$", options: .regularExpression) {
            t = String(t[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
    
    /// Extract docket number and job name from a docket string
    /// Returns: (docketNumber: String, jobName: String)
    nonisolated func parseDocket(_ docket: String) -> (docketNumber: String, jobName: String) {
        // Already "number_jobName" (e.g. 25464_TD Insurance or 26029_Volkswagen Radio)
        if let underscoreIdx = docket.firstIndex(of: "_") {
            let prefix = String(docket[..<underscoreIdx])
            let numRegex = try? NSRegularExpression(pattern: #"^\d{5}(?:-[A-Z]{1,3})?$"#)
            if let numRegex = numRegex,
               numRegex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil {
                let num = prefix
                let job = sanitizeFolderName(String(docket[docket.index(after: underscoreIdx)...]))
                return (num, job.isEmpty ? "Job" : job)
            }
        }
        // Extract 5-digit (optional -XXX) number and use rest as job name (e.g. Asana session name)
        let docketNumPattern = #"\d{5}(?:-[A-Z]{1,3})?"#
        guard let regex = try? NSRegularExpression(pattern: docketNumPattern),
              let match = regex.firstMatch(in: docket, range: NSRange(docket.startIndex..., in: docket)),
              let matchRange = Range(match.range, in: docket) else {
            let safe = sanitizeFolderName(docket)
            return (safe.isEmpty ? "Prep" : safe, "")
        }
        let number = String(docket[matchRange])
        var jobPart = String(docket[matchRange.upperBound...])
        if let range = jobPart.range(of: "^(?:\\s*[-–]?\\s*)?", options: .regularExpression) {
            jobPart = String(jobPart[range.upperBound...])
        }
        let jobName = sanitizeFolderName(jobPart)
        return (number, jobName.isEmpty ? "Job" : jobName)
    }
    
    /// Build prep folder name using format string
    /// Format string supports placeholders: {docket}, {jobName}, {date}
    nonisolated func prepFolderName(docket: String, date: Date) -> String {
        let format = settings.prepFolderFormat // e.g., "{docket}_{jobName}_PREP_{date}"
        let (docketNumber, jobName) = parseDocket(docket)
        let dateStr = formatDate(date)
        
        return format
            .replacingOccurrences(of: "{docket}", with: docketNumber)
            .replacingOccurrences(of: "{jobName}", with: jobName)
            .replacingOccurrences(of: "{date}", with: dateStr)
    }
    
    /// Build work picture folder name: {number}_{date}
    /// Example: "01_Feb09.26"
    nonisolated func workPictureFolderName(sequenceNumber: Int, date: Date) -> String {
        let dateStr = formatDate(date)
        let format = settings.workPicNumberFormat // "%02d"
        let numberStr = String(format: format, sequenceNumber)
        return "\(numberStr)_\(dateStr)"
    }
    
    /// Build demos date folder name: {number}_{date}
    /// Example: "01_Feb09.26"
    nonisolated func demosDateFolderName(sequenceNumber: Int, date: Date) -> String {
        let dateStr = formatDate(date)
        let format = settings.workPicNumberFormat // "%02d"
        let numberStr = String(format: format, sequenceNumber)
        return "\(numberStr)_\(dateStr)"
    }
    
    /// Get the date part only from a demos folder name (for parsing existing folders)
    /// This extracts just the date portion after the sequence number
    nonisolated func demosDatePartFormat() -> String {
        // Since we're standardizing on MmmDD.YY format, this is just the standard format
        return Self.standardDateFormat
    }
}
