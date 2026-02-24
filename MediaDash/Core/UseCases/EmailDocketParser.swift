import Foundation

// #region agent log
private func _parserLog(_ message: String, _ data: [String: Any], _ hypothesisId: String) {
    let payload: [String: Any] = ["timestamp": Int(Date().timeIntervalSince1970 * 1000), "location": "EmailDocketParser", "message": message, "data": data, "hypothesisId": hypothesisId]
    guard let d = try? JSONSerialization.data(withJSONObject: payload), let line = String(data: d, encoding: .utf8) else { return }
    let path = "/Users/mediamini1/Documents/Projects/MediaDash/.cursor/debug.log"
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
    guard let stream = OutputStream(url: url, append: true) else { return }
    stream.open()
    defer { stream.close() }
    let out = (line + "\n").data(using: .utf8)!
    _ = out.withUnsafeBytes { stream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: out.count) }
}
// #endregion

/// Result of parsing an email for docket information
struct ParsedDocket {
    let docketNumber: String
    let jobName: String
    let sourceEmail: String
    let rawData: [String: Any] // Store any additional extracted data
}

/// Use case for parsing emails to extract docket information
struct EmailDocketParser {
    private let patterns: [String]
    private let companyNameMatcher: CompanyNameMatcher?
    private let metadataManager: DocketMetadataManager?
    private weak var asanaCacheManager: AsanaCacheManager?
    
    init(patterns: [String] = [], companyNameMatcher: CompanyNameMatcher? = nil, metadataManager: DocketMetadataManager? = nil, asanaCacheManager: AsanaCacheManager? = nil) {
        self.patterns = patterns.isEmpty ? Self.defaultPatterns : patterns
        self.companyNameMatcher = companyNameMatcher
        self.metadataManager = metadataManager
        self.asanaCacheManager = asanaCacheManager
    }
    
    /// Default parsing patterns
    private static var defaultPatterns: [String] {
        [
            // Pattern 1: "25484-US" format (docket number with country code)
            #"(\d{5,}-[A-Z]{2,3})"#,
            // Pattern 2: "Docket: 12345 Job: JobName"
            #"Docket[:\s]+(\d+)\s+Job[:\s]+(.+?)(?:\s|$|,|\.)"#,
            // Pattern 3: "New Docket 12345 - JobName" or "NEW DOCKET 12345 - JobName"
            #"(?:New|NEW)\s+Docket\s+(\d+)\s*[-–]\s*(.+?)(?:\s|$|,|\.)"#,
            // Pattern 3b: "NEW DOCKET [text] 12345" (number at end)
            #"(?:New|NEW)\s+Docket\s+(.+?)\s+(\d{5,})(?:\s|$|,|\.)"#,
            // Pattern 4: "[12345] JobName"
            #"\[(\d+)\]\s*(.+?)(?:\s|$|,|\.)"#,
            // Pattern 5: "12345_JobName" (in subject or body)
            #"(\d+)_([^_\s]+(?:_[^_\s]+)*)"#,
            // Pattern 5b: "12345 JobName" (space-separated, like "25483 HH - End of year sizzle")
            // Matches docket number followed by space and job name anywhere in text
            // Made more restrictive: only match exactly 5 digits (not 5+) to prevent false positives
            #"(\d{5})\s+(.+?)(?:\n|$|\.)"#,
            // Pattern 6: "Docket #12345 - JobName"
            #"Docket\s*#?\s*(\d+)\s*[-–]\s*(.+?)(?:\s|$|,|\.)"#,
            // Pattern 7: Just numeric docket "12345" or "25484" anywhere
            // NOTE: This is a fallback pattern - should only match if other patterns failed
            // Made more restrictive: only match exactly 5 digits (not 5+), and only if followed by whitespace/punctuation
            // This prevents matching long numbers like order IDs, product codes, etc.
            #"\b(\d{5})\b(?:\s|$|,|\.)"#
        ]
    }
    
    
    /// Parse email to extract docket information
    /// - Parameters:
    ///   - subject: Email subject line
    ///   - body: Email body text
    ///   - from: Email sender
    /// - Returns: ParsedDocket if successful, nil otherwise
    func parseEmail(subject: String?, body: String?, from: String?) -> ParsedDocket? {
        let subjectText = subject ?? ""
        var bodyText = body ?? ""
        // #region agent log
        let preview = String(bodyText.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        _parserLog("parseEmail entry", ["subjectLen": subjectText.count, "bodyLen": bodyText.count, "bodyPreview": preview], "H5")
        // #endregion
        
        // If body is empty but subject contains "Fwd:" or "Re:", try to extract from subject
        // Forwarded emails might have the docket info in the subject line
        if bodyText.isEmpty && (subjectText.contains("Fwd:") || subjectText.contains("Re:")) {
            #if DEBUG
            print("EmailDocketParser: Body is empty, attempting to parse from subject only")
            #endif
        }
        
        // Clean up HTML/table formatting that might interfere with parsing
        // Remove HTML table tags but preserve cell content
        bodyText = bodyText.replacingOccurrences(of: #"<td[^>]*>"#, with: " | ", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"</td>"#, with: "", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"<tr[^>]*>"#, with: "\n", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"</tr>"#, with: "", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression) // Remove remaining HTML tags
        bodyText = bodyText.replacingOccurrences(of: #"&nbsp;"#, with: " ", options: .regularExpression)
        // Normalize horizontal whitespace but preserve newlines so "26052 Job Name" on line 2 is still matchable
        bodyText = bodyText.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"\n+"#, with: "\n", options: .regularExpression)
        
        let combinedText = "\(subjectText)\n\(bodyText)"
        
        // Accept explicit "new docket" language OR strong docket context near the top of the message.
        let searchText = combinedText.lowercased()
        let hasNewAndDocket = searchText.contains("new") && searchText.contains("docket")
        let hasEarlyDocketLine = hasDocketStyleLineNearTop(in: bodyText)
        let hasDocketKeywordWithNumber = hasDocketKeywordNumberPattern(in: searchText)
        let hasDocketIntent = hasNewAndDocket || hasEarlyDocketLine || hasDocketKeywordWithNumber
        // #region agent log
        _parserLog("docketIntentSignals", ["hasNewAndDocket": hasNewAndDocket, "hasEarlyDocketLine": hasEarlyDocketLine, "hasDocketKeywordWithNumber": hasDocketKeywordWithNumber, "hasDocketIntent": hasDocketIntent, "searchTextLen": searchText.count], "H1")
        // #endregion
        
        // First, try to extract docket number from body (like "25484-US")
        var extractedDocketNumber: String?
        var extractedJobName: String?
        
        // FIRST: Try to find docket number and job name on the first line of body (most common case)
        // Pattern: "25489 12 Days of Connection" or "25489 Job Name" or "26053-US Ferring - IVF"
        // Supports optional -XX country code (e.g. -US, -CA) between docket number and job name
        let firstLinePattern = #"^(\d{5}(?:-[A-Z]{2,3})?)\s+(.+?)(?:\s*$|\n|\.)"#
        if let regex = try? NSRegularExpression(pattern: firstLinePattern, options: [.anchorsMatchLines]),
           let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText)),
           match.numberOfRanges >= 3 {
            let docketRange = Range(match.range(at: 1), in: bodyText)!
            let jobRange = Range(match.range(at: 2), in: bodyText)!
            let docketNum = String(bodyText[docketRange])
            let jobName = String(bodyText[jobRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Validate year prefix immediately before accepting
            if isValidYearBasedDocket(docketNum) {
                // Take only first line of job name if multiple lines
                if let firstLine = jobName.components(separatedBy: .newlines).first {
                    let cleanedJobName = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanedJobName.isEmpty && cleanedJobName.count > 2 && cleanedJobName.count < 100 {
                        extractedDocketNumber = docketNum
                        extractedJobName = cleanedJobName
                    }
                }
            } else {
                #if DEBUG
                print("EmailDocketParser: ⚠️ First line match rejected - invalid year format: \(docketNum)")
                #endif
            }
        }
        
        // SECOND: If not found on first line, try other patterns on combined text
        if extractedDocketNumber == nil {
            for pattern in patterns {
                if let parsed = tryPattern(pattern, in: combinedText) {
                    // Validate year prefix before accepting
                    if isValidYearBasedDocket(parsed.docketNumber) {
                        extractedDocketNumber = parsed.docketNumber
                        // If we got a job name too, use it
                        if !parsed.jobName.isEmpty {
                            extractedJobName = parsed.jobName
                        }
                        break
                    } else {
                        #if DEBUG
                        print("EmailDocketParser: ⚠️ Pattern match rejected - invalid year format: \(parsed.docketNumber)")
                        #endif
                    }
                }
            }
        }

        // THIRD: If we found a docket number but no job name, try to extract from the same line in body
        if extractedDocketNumber != nil, extractedJobName == nil {
            // Try to find job name on the same line as the docket number
            let bodyLines = bodyText.components(separatedBy: .newlines)
            for line in bodyLines {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Check if this line contains the docket number
                if trimmedLine.contains(extractedDocketNumber!) {
                    // Extract everything after the docket number and spaces
                    if let docketRange = trimmedLine.range(of: extractedDocketNumber!) {
                        let afterDocket = String(trimmedLine[docketRange.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Remove common separators
                        var candidate = afterDocket
                        candidate = candidate.replacingOccurrences(of: #"^[-–:\s]+"#, with: "", options: .regularExpression)
                        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Take only first line if multiple
                        if let firstLine = candidate.components(separatedBy: .newlines).first {
                            candidate = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        
                        if !candidate.isEmpty && candidate.count > 2 && candidate.count < 100 {
                            extractedJobName = candidate
                            break
                        }
                    }
                }
            }
        }
        
        // If we still don't have a job name, extract from subject
        if extractedDocketNumber != nil, extractedJobName == nil {
            // Extract job name from subject (remove "NEW DOCKET" prefix and forwarding info)
            var jobName = subjectText
            // Remove "NEW DOCKET" or "New Docket" prefix
            jobName = jobName.replacingOccurrences(of: #"(?i)^(?:NEW\s+)?DOCKET\s*[-–]?\s*"#, with: "", options: .regularExpression)
            // Remove "Fwd:" or "Re:" prefixes
            jobName = jobName.replacingOccurrences(of: #"^(?:Fwd?|Re):\s*"#, with: "", options: .regularExpression)
            // Remove docket number if present
            jobName = jobName.replacingOccurrences(of: #"\d{5,}(?:-[A-Z]{2,3})?"#, with: "", options: .regularExpression)
            jobName = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !jobName.isEmpty {
                extractedJobName = jobName
            } else {
                // Fallback: use subject as job name
                extractedJobName = subjectText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // If we have both, try to improve job name with fuzzy matching and metadata lookup
        if let docketNumber = extractedDocketNumber, let jobName = extractedJobName {
            var finalJobName = jobName
            
            // Try metadata lookup first (most reliable)
            if let metadata = metadataManager?.getMetadata(for: docketNumber, jobName: jobName),
               !metadata.jobName.isEmpty {
                finalJobName = metadata.jobName
            }
            // Try fuzzy matching against company cache
            else if let matcher = companyNameMatcher {
                let combinedText = "\(subjectText)\n\(bodyText)"
                if let match = matcher.findBestMatch(in: combinedText) {
                    finalJobName = match.name
                }
            }
            
            // Validate: docket number must have valid year format
            guard isValidYearBasedDocket(docketNumber) else {
                #if DEBUG
                print("EmailDocketParser: ⚠️ Rejecting match - invalid year format: \(docketNumber)")
                #endif
                return nil
            }
            
            // #region agent log
            if !hasDocketIntent { _parserLog("rejected path", ["path": "body_subject_combination", "reason": "hasDocketIntent false", "docketNumber": docketNumber], "H2") }
            // #endregion
            guard hasDocketIntent else { return nil }
            _parserLog("parsed ok", ["method": "body_subject_combination", "docketNumber": docketNumber], "H2")
            return ParsedDocket(
                docketNumber: docketNumber,
                jobName: finalJobName,
                sourceEmail: from ?? "unknown",
                rawData: [
                    "method": "body_subject_combination",
                    "subject": subjectText,
                    "body": bodyText,
                    "original_job_name": jobName,
                    "final_job_name": finalJobName,
                    "year_valid": isValidYearBasedDocket(docketNumber),
                    "asana_exists": docketExistsInAsana(docketNumber)
                ]
            )
        }
        
        // Try each pattern on combined text
        for (index, pattern) in patterns.enumerated() {
            if let parsed = tryPattern(pattern, in: combinedText) {
                // Check if docket number was found in email (subject or body)
                let foundInEmail = subjectText.contains(parsed.docketNumber) || bodyText.contains(parsed.docketNumber)
                
                // CRITICAL: Pattern 7 is the most permissive (matches any 5-digit number)
                // For Pattern 7, we MUST validate the year to prevent false positives
                let isPattern7 = (index == patterns.count - 1) // Pattern 7 is the last pattern
                if isPattern7 {
                    // Pattern 7 is too broad - reject if year validation fails
                    if !isValidYearBasedDocket(parsed.docketNumber) {
                        #if DEBUG
                        print("EmailDocketParser: ⚠️ Rejecting Pattern 7 match - invalid year format: \(parsed.docketNumber)")
                        #endif
                        continue // Skip this match, try next pattern or return nil
                    }
                    // Also require that the docket number appears in the email content
                    if !foundInEmail {
                        #if DEBUG
                        print("EmailDocketParser: ⚠️ Rejecting Pattern 7 match - docket number not found in email: \(parsed.docketNumber)")
                        #endif
                        continue
                    }
                }
                
                // Validate: docket number must have valid year format
                guard isValidYearBasedDocket(parsed.docketNumber) else {
                    #if DEBUG
                    print("EmailDocketParser: ⚠️ Rejecting pattern match - invalid year format: \(parsed.docketNumber)")
                    #endif
                    continue
                }
                
                // Validate: docket number must be found in email
                guard foundInEmail else {
                    #if DEBUG
                    print("EmailDocketParser: ⚠️ Rejecting pattern match - docket number not found in email: \(parsed.docketNumber)")
                    #endif
                    continue
                }
                
                // #region agent log
                if !hasDocketIntent { _parserLog("rejected path", ["path": "pattern_match", "reason": "hasDocketIntent false", "docketNumber": parsed.docketNumber], "H2") }
                // #endregion
                guard hasDocketIntent else { continue }
                _parserLog("parsed ok", ["method": "pattern_match", "docketNumber": parsed.docketNumber], "H2")
                return ParsedDocket(
                    docketNumber: parsed.docketNumber,
                    jobName: parsed.jobName.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceEmail: from ?? "unknown",
                    rawData: [
                        "pattern": pattern,
                        "subject": subjectText,
                        "matchedText": parsed.matchedText,
                        "found_in_email": foundInEmail,
                        "year_valid": isValidYearBasedDocket(parsed.docketNumber),
                        "asana_exists": docketExistsInAsana(parsed.docketNumber)
                    ]
                )
            }
        }
        
        // If no pattern matches, try to extract from subject alone using common formats
        if let parsed = extractFromSubject(subjectText) {
            let foundInEmail = subjectText.contains(parsed.docketNumber) || bodyText.contains(parsed.docketNumber)
            
            // Validate: docket number must have valid year format and be found in email
            if isValidYearBasedDocket(parsed.docketNumber) && foundInEmail && hasDocketIntent {
                return ParsedDocket(
                    docketNumber: parsed.docketNumber,
                    jobName: parsed.jobName,
                    sourceEmail: from ?? "unknown",
                    rawData: [
                        "method": "subject_fallback",
                        "subject": subjectText,
                        "found_in_email": foundInEmail,
                        "year_valid": isValidYearBasedDocket(parsed.docketNumber),
                        "asana_exists": docketExistsInAsana(parsed.docketNumber)
                    ]
                )
            } else {
                #if DEBUG
                if !isValidYearBasedDocket(parsed.docketNumber) {
                    print("EmailDocketParser: ⚠️ Rejecting subject fallback - invalid year format: \(parsed.docketNumber)")
                }
                if !foundInEmail {
                    print("EmailDocketParser: ⚠️ Rejecting subject fallback - docket number not found in email: \(parsed.docketNumber)")
                }
                #endif
            }
        }

        // Final fallback: only when we have intent signals, search for a docket number.
        if hasDocketIntent {
            // #region agent log
            _parserLog("fallback enter", ["searchTextLen": searchText.count], "H3")
            // #endregion
            // Search for docket numbers (5+ digits, optionally with country code) anywhere in subject or body
            // Also match 4+ digit numbers at word boundaries (some dockets might be 4 digits)
            let docketPattern = #"\b(\d{4,}(?:-[A-Z]{2,3})?)\b"#
            var foundDocketNumber: String?
            var jobName: String? // Declare jobName early so we can use it in the first-line check
            
            // Try to find docket number in subject first
            if let regex = try? NSRegularExpression(pattern: docketPattern, options: []),
               let match = regex.firstMatch(in: subjectText, range: NSRange(subjectText.startIndex..., in: subjectText)),
               match.numberOfRanges >= 2 {
                let docketRange = Range(match.range(at: 1), in: subjectText)!
                foundDocketNumber = String(subjectText[docketRange])
            }
            
            // If not found in subject, try body (search all matches, prefer 5+ digit numbers)
            // FIRST: Check first line of body for "25489 Job Name" or "26053-US Ferring - IVF" pattern
            if foundDocketNumber == nil {
                let firstLinePattern = #"^(\d{5}(?:-[A-Z]{2,3})?)\s+(.+?)(?:\s*$|\n|\.)"#
                if let regex = try? NSRegularExpression(pattern: firstLinePattern, options: [.anchorsMatchLines]),
                   let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText)),
                   match.numberOfRanges >= 3 {
                    let docketRange = Range(match.range(at: 1), in: bodyText)!
                    let jobRange = Range(match.range(at: 2), in: bodyText)!
                    let docketNum = String(bodyText[docketRange])
                    let extractedJobName = String(bodyText[jobRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    // Take only first line of job name if multiple lines
                    if let firstLine = extractedJobName.components(separatedBy: .newlines).first {
                        let cleanedJobName = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleanedJobName.isEmpty && cleanedJobName.count > 2 && cleanedJobName.count < 100 {
                            foundDocketNumber = docketNum
                            // Set job name here too if we don't have one yet
                            if jobName == nil {
                                jobName = cleanedJobName
                            }
                        }
                    }
                }
            }
            
            // SECOND: If still not found, search all matches in body
            // Also check for table-like formats (pipe-separated or tab-separated)
            if foundDocketNumber == nil {
                // First, try to find docket numbers in table-like formats
                // Look for patterns like "25461 | Tims Soccer | Gut" or "25461\tTims Soccer"
                let tablePattern = #"(\d{5,})\s*[|\t]\s*([^|\t\n]+?)(?:\s*[|\t]|$|\n)"#
                if let regex = try? NSRegularExpression(pattern: tablePattern, options: []),
                   let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText)),
                   match.numberOfRanges >= 3 {
                    let docketRange = Range(match.range(at: 1), in: bodyText)!
                    let jobRange = Range(match.range(at: 2), in: bodyText)!
                    let docketNum = String(bodyText[docketRange])
                    let extractedJobName = String(bodyText[jobRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !extractedJobName.isEmpty && extractedJobName.count > 2 && extractedJobName.count < 100 {
                        foundDocketNumber = docketNum
                        if jobName == nil {
                            jobName = extractedJobName
                        }
                    }
                }
                
                // If not found in table format, search all matches in body
                // Prefer 5-digit numbers that pass year validation (real dockets); skip 6+ digit numbers (often URLs/IDs)
                if foundDocketNumber == nil {
                    if let regex = try? NSRegularExpression(pattern: docketPattern, options: []) {
                        let matches = regex.matches(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText))
                        
                        for match in matches {
                            guard match.numberOfRanges >= 2 else { continue }
                            let docketRange = Range(match.range(at: 1), in: bodyText)!
                            let candidate = String(bodyText[docketRange])
                            
                            // Accept 5-digit dockets (e.g. 26053) or 5 digits + country code (e.g. 26053-US)
                            // Reject 6+ digit numbers (often IDs/URLs) unless they have -XX suffix
                            let numericPart = candidate.components(separatedBy: "-").first ?? candidate
                            let isValidFormat = (numericPart.count == 5 && numericPart.allSatisfy { $0.isNumber })
                            if isValidFormat && isValidYearBasedDocket(candidate) {
                                foundDocketNumber = candidate
                                break
                            }
                        }
                    }
                }
            }
            
            // PRIORITY 1: Try to extract job name from subject first (most reliable, single line)
            // (jobName already declared above)
            var subjectJobName = subjectText
            // Remove "NEW DOCKET" or "New Docket" prefix
            subjectJobName = subjectJobName.replacingOccurrences(of: #"(?i)^(?:NEW\s+)?DOCKET\s*[-–]?\s*"#, with: "", options: .regularExpression)
            // Remove "Fwd:" or "Re:" prefixes
            subjectJobName = subjectJobName.replacingOccurrences(of: #"^(?:Fwd?|Re):\s*"#, with: "", options: .regularExpression)
            // Remove any remaining "Fwd:" or "Re:" in the middle
            subjectJobName = subjectJobName.replacingOccurrences(of: #"\s*(?:Fwd?|Re):\s*"#, with: " ", options: .regularExpression)
            // Remove docket number patterns (5+ digits, optionally with country code)
            subjectJobName = subjectJobName.replacingOccurrences(of: #"\b\d{5,}(?:-[A-Z]{2,3})?\b"#, with: "", options: .regularExpression)
            subjectJobName = subjectJobName.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Take only the first line if there are multiple lines
            if let firstLine = subjectJobName.components(separatedBy: .newlines).first {
                let cleaned = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty && cleaned.count > 2 {
                    jobName = cleaned
                }
            }
            
            // PRIORITY 2: If docket number was found, try to extract job name from the same line in body
            if jobName == nil, let docketNum = foundDocketNumber {
                let bodyLines = bodyText.components(separatedBy: .newlines)
                for line in bodyLines {
                    if line.contains(docketNum) {
                        // Extract everything after the docket number on this line
                        if let docketRange = line.range(of: docketNum) {
                            let afterDocket = String(line[docketRange.upperBound...])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // Remove common separators
                            var candidate = afterDocket
                            candidate = candidate.replacingOccurrences(of: #"^[-–:\s]+"#, with: "", options: .regularExpression)
                            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // Take only first line if multiple
                            if let firstLine = candidate.components(separatedBy: .newlines).first {
                                candidate = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            
                            if !candidate.isEmpty && candidate.count > 2 && candidate.count < 100 {
                                jobName = candidate
                                break
                            }
                        }
                    }
                }
            }
            
            // PRIORITY 3: If not found, try to extract from body using common patterns (single line only)
            if jobName == nil {
                let jobNamePatterns = [
                    #"(?i)job\s+name\s+is\s+([^\n\.]+?)(?:\.|$|\n)"#,
                    #"(?i)job\s+name[:\s]+([^\n\.]+?)(?:\.|$|\n)"#,
                    #"(?i)job[:\s]+([^\n\.]+?)(?:\.|$|\n)"#,
                    #"(?i)project\s+name\s+is\s+([^\n\.]+?)(?:\.|$|\n)"#,
                    #"(?i)project[:\s]+([^\n\.]+?)(?:\.|$|\n)"#,
                    #"(?i)client\s+is\s+([^\n\.]+?)(?:\.|$|\n)"#,
                    #"(?i)client[:\s]+([^\n\.]+?)(?:\.|$|\n)"#
                ]
                
                for pattern in jobNamePatterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                       let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText)),
                       match.numberOfRanges >= 2 {
                        let jobRange = Range(match.range(at: 1), in: bodyText)!
                        var extracted = String(bodyText[jobRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Ensure only single line - take first line if multiple
                        if let firstLine = extracted.components(separatedBy: .newlines).first {
                            extracted = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        
                        if extracted.count > 2 && extracted.count < 100 {
                            jobName = extracted
                            break
                        }
                    }
                }
            }
            
            // PRIORITY 4: If still no job name, try to get meaningful text from body (first substantial line only)
            if jobName == nil {
                let bodyLines = bodyText.components(separatedBy: .newlines)
                for line in bodyLines {
                    let cleanedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Skip very short lines, lines that are just numbers, or signature lines
                    let isJustNumber = cleanedLine.range(of: #"^\d+$"#, options: .regularExpression) != nil
                    if cleanedLine.count > 5 && cleanedLine.count < 100,
                       !isJustNumber,
                       !cleanedLine.lowercased().contains("sound designer"),
                       !cleanedLine.lowercased().contains("media services"),
                       !cleanedLine.lowercased().contains("@"),
                       !cleanedLine.contains("ADELAIDE") {
                        jobName = cleanedLine
                        break
                    }
                }
            }
            
            // If we found a docket number, use it; otherwise use "TBD"
            let finalDocketNumber = foundDocketNumber ?? "TBD"
            
            // Check if docket number was found in email
            let foundInEmail = foundDocketNumber != nil && (subjectText.contains(foundDocketNumber!) || bodyText.contains(foundDocketNumber!))
            
            // Try to improve job name with fuzzy matching and metadata lookup
            var finalJobName = jobName ?? "New Docket"
            
            // Try metadata lookup first (most reliable)
            if let docketNum = foundDocketNumber,
               let metadata = metadataManager?.getMetadata(for: docketNum, jobName: finalJobName),
               !metadata.jobName.isEmpty {
                finalJobName = metadata.jobName
            }
            // Try fuzzy matching against company cache
            else if let matcher = companyNameMatcher, finalJobName == "New Docket" || finalJobName.count < 5 {
                let combinedText = "\(subjectText)\n\(bodyText)"
                if let match = matcher.findBestMatch(in: combinedText) {
                    finalJobName = match.name
                }
            }
            
            // Validate: if we have a docket number, it must have valid year format
            if let docketNum = foundDocketNumber {
                guard isValidYearBasedDocket(docketNum) else {
                    #if DEBUG
                    print("EmailDocketParser: ⚠️ Rejecting new docket fallback - invalid year format: \(docketNum)")
                    #endif
                    return nil
                }
                
                // Validate: docket number must be found in email
                guard foundInEmail else {
                    #if DEBUG
                    print("EmailDocketParser: ⚠️ Rejecting new docket fallback - docket number not found in email: \(docketNum)")
                    #endif
                    return nil
                }
            }
            
            // Require a valid docket number
            guard foundDocketNumber != nil else {
                // #region agent log
                _parserLog("fallback exit", ["reason": "foundDocketNumber nil"], "H4")
                // #endregion
                return nil
            }
            _parserLog("parsed ok", ["method": "new_docket_with_number", "docketNumber": finalDocketNumber], "H2")
            return ParsedDocket(
                docketNumber: finalDocketNumber,
                jobName: finalJobName,
                sourceEmail: from ?? "unknown",
                rawData: [
                    "method": "new_docket_with_number",
                    "subject": subjectText,
                    "body": bodyText,
                    "has_docket_number": foundDocketNumber != nil,
                    "original_job_name": jobName ?? "New Docket",
                    "final_job_name": finalJobName,
                    "found_in_email": foundInEmail,
                    "year_valid": foundDocketNumber != nil ? isValidYearBasedDocket(foundDocketNumber!) : false,
                    "asana_exists": foundDocketNumber != nil ? docketExistsInAsana(foundDocketNumber!) : false
                ]
            )
        }
        // #region agent log
        _parserLog("parse nil end", ["hasNewAndDocket": hasNewAndDocket, "hasDocketIntent": hasDocketIntent, "reason": "no match or fallback not entered"], "H1")
        // #endregion
        return nil
    }
    
    /// Try a regex pattern against the text
    private func tryPattern(_ pattern: String, in text: String) -> (docketNumber: String, jobName: String, matchedText: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        
        guard let match = matches.first, match.numberOfRanges >= 3 else {
            return nil
        }
        
        let range1 = match.range(at: 1)
        let range2 = match.range(at: 2)
        
        guard range1.location != NSNotFound, range2.location != NSNotFound else {
            return nil
        }
        
        let value1 = nsString.substring(with: range1)
        let value2 = nsString.substring(with: range2)
        let matchedText = nsString.substring(with: match.range)
        
        // Determine which range is the docket number and which is the job name
        // Pattern 3b has job name first, then docket number (reversed order)
        let isReversedPattern = pattern.contains(#"(?:New|NEW)\s+Docket\s+(.+?)\s+(\d{5,})"#)
        
        let docketNumber: String
        let jobName: String
        
        if isReversedPattern {
            // Pattern 3b: job name is in range1, docket is in range2
            docketNumber = value2
            jobName = value1
        } else {
            // Normal patterns: docket is in range1, job name is in range2
            docketNumber = value1
            jobName = value2
        }
        
        // Validate docket number: 5+ digits, optionally with 2-3 letter country suffix (e.g. -US, -CAN)
        let components = docketNumber.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count <= 2,
              let numericPart = components.first,
              numericPart.count >= 5,
              numericPart.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        if components.count == 2 {
            let suffix = components[1]
            guard (2...3).contains(suffix.count), suffix.allSatisfy({ $0.isLetter }) else {
                return nil
            }
        }
        
        // Validate job name (should not be empty and reasonable length)
        let trimmedJobName = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJobName.isEmpty, trimmedJobName.count <= 200 else {
            return nil
        }
        
        return (docketNumber, trimmedJobName, matchedText)
    }
    
    /// Extract docket info from subject using common fallback patterns
    private func extractFromSubject(_ subject: String) -> (docketNumber: String, jobName: String)? {
        // Try simple format: "12345 JobName"
        if let regex = try? NSRegularExpression(pattern: #"^(\d+)\s+(.+)$"#, options: []),
           let match = regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
           match.numberOfRanges >= 3 {
            let docketRange = Range(match.range(at: 1), in: subject)!
            let jobRange = Range(match.range(at: 2), in: subject)!
            let docketNumber = String(subject[docketRange])
            let jobName = String(subject[jobRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !jobName.isEmpty {
                return (docketNumber, jobName)
            }
        }
        
        return nil
    }

    /// Strong context signal: one of the first lines starts with "26060 Job Name"
    /// This catches forwarded docket emails that omit explicit "new docket" wording.
    private func hasDocketStyleLineNearTop(in body: String, maxNonEmptyLines: Int = 8) -> Bool {
        let lines = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxNonEmptyLines)

        let pattern = #"^\d{5}(?:-[A-Z]{2,3})?\s+.{3,}$"#
        return lines.contains { line in
            line.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Secondary context signal: "docket ... 26060" appears in the message.
    private func hasDocketKeywordNumberPattern(in lowercasedText: String) -> Bool {
        lowercasedText.range(
            of: #"docket[^0-9]{0,20}\d{5}(?:-[a-z]{2,3})?"#,
            options: .regularExpression
        ) != nil
    }
    
    /// Get valid year prefixes for docket numbers based on current date
    /// - Returns: Array of valid two-digit year prefixes (only current year and next year)
    ///   Examples: If current year is 2025, returns [25, 26]
    ///             If current year is 2027, returns [27, 28]
    private func getValidYearPrefixes() -> [Int] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let currentYearLastTwo = currentYear % 100
        
        // Only current year and next year are valid
        let nextYearLastTwo = (currentYearLastTwo + 1) % 100
        
        return [currentYearLastTwo, nextYearLastTwo]
    }
    
    /// Validate that a docket number starts with the last two digits of a year
    /// - Parameter docketNumber: The docket number to validate
    /// - Returns: True if the docket number starts with valid year digits (dynamically calculated based on current date)
    private func isValidYearBasedDocket(_ docketNumber: String) -> Bool {
        // Remove country code suffix if present (e.g., "25484-US" -> "25484")
        let numericPart = docketNumber.components(separatedBy: "-").first ?? docketNumber
        
        // Must be at least 5 digits
        guard numericPart.count >= 5, numericPart.allSatisfy({ $0.isNumber }) else {
            return false
        }
        
        // Get the first two digits (year prefix)
        let yearPrefix = String(numericPart.prefix(2))
        guard let yearDigits = Int(yearPrefix) else {
            return false
        }
        
        // Get valid year prefixes dynamically based on current date
        // This allows: current year, next year, previous years (for revivals), and future years (for planning)
        let validYears = getValidYearPrefixes()
        
        return validYears.contains(yearDigits)
    }
    
    /// Check if a docket number exists in Asana cache
    /// - Parameter docketNumber: The docket number to check
    /// - Returns: True if the docket exists in Asana cache
    private func docketExistsInAsana(_ docketNumber: String) -> Bool {
        guard let asanaCache = asanaCacheManager else {
            return false
        }
        
        // Remove country code suffix if present for comparison
        let numericPart = docketNumber.components(separatedBy: "-").first ?? docketNumber
        
        // Load cached dockets and check if any match
        // Note: AsanaCacheManager is @MainActor. Since EmailScanningService (which calls this)
        // is also @MainActor, we can use assumeIsolated safely.
        // If we're not on MainActor, this will crash - but that shouldn't happen given the call sites.
        return MainActor.assumeIsolated {
            let dockets = asanaCache.loadCachedDockets()
            return dockets.contains { $0.number == numericPart || $0.number == docketNumber }
        }
    }
    
}

