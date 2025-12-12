import Foundation

/// Result of parsing an email for docket information
struct ParsedDocket {
    let docketNumber: String
    let jobName: String
    let sourceEmail: String
    let confidence: Double // 0.0 to 1.0
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
            #"(\d{5,}-[A-Z]{2})"#,
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
    
    /// Check if parser can confidently parse this email (without needing CodeMind)
    /// - Parameters:
    ///   - subject: Email subject line
    ///   - body: Email body text
    ///   - from: Email sender
    /// - Returns: ParsedDocket if parser can confidently parse (confidence >= 0.8), nil otherwise
    func canParseWithHighConfidence(subject: String?, body: String?, from: String?) -> ParsedDocket? {
        guard let parsed = parseEmail(subject: subject, body: body, from: from) else {
            return nil
        }
        // Only return if confidence is high enough to skip CodeMind
        return parsed.confidence >= 0.8 ? parsed : nil
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
        
        // If body is empty but subject contains "Fwd:" or "Re:", try to extract from subject
        // Forwarded emails might have the docket info in the subject line
        if bodyText.isEmpty && (subjectText.contains("Fwd:") || subjectText.contains("Re:")) {
            // Try to extract docket info from subject for forwarded emails
            print("EmailDocketParser: Body is empty, attempting to parse from subject only")
        }
        
        // Clean up HTML/table formatting that might interfere with parsing
        // Remove HTML table tags but preserve cell content
        bodyText = bodyText.replacingOccurrences(of: #"<td[^>]*>"#, with: " | ", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"</td>"#, with: "", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"<tr[^>]*>"#, with: "\n", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"</tr>"#, with: "", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression) // Remove remaining HTML tags
        bodyText = bodyText.replacingOccurrences(of: #"&nbsp;"#, with: " ", options: .regularExpression)
        bodyText = bodyText.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) // Normalize whitespace
        
        let combinedText = "\(subjectText)\n\(bodyText)"
        
        // First, try to extract docket number from body (like "25484-US")
        var extractedDocketNumber: String?
        var extractedJobName: String?
        
        // FIRST: Try to find docket number and job name on the first line of body (most common case)
        // Pattern: "25489 12 Days of Connection" or "25489 Job Name"
        // Made more restrictive: only match exactly 5 digits (not 5+) to prevent false positives
        let firstLinePattern = #"^(\d{5})\s+(.+?)(?:\s*$|\n|\.)"#
        if let regex = try? NSRegularExpression(pattern: firstLinePattern, options: [.anchorsMatchLines]),
           let match = regex.firstMatch(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText)),
           match.numberOfRanges >= 3 {
            let docketRange = Range(match.range(at: 1), in: bodyText)!
            let jobRange = Range(match.range(at: 2), in: bodyText)!
            let docketNum = String(bodyText[docketRange])
            let jobName = String(bodyText[jobRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Take only first line of job name if multiple lines
            if let firstLine = jobName.components(separatedBy: .newlines).first {
                let cleanedJobName = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanedJobName.isEmpty && cleanedJobName.count > 2 && cleanedJobName.count < 100 {
                    extractedDocketNumber = docketNum
                    extractedJobName = cleanedJobName
                }
            }
        }
        
        // SECOND: If not found on first line, try other patterns
        if extractedDocketNumber == nil {
        for pattern in patterns {
            if let parsed = tryPattern(pattern, in: bodyText) {
                extractedDocketNumber = parsed.docketNumber
                // If we got a job name too, use it
                if !parsed.jobName.isEmpty {
                    extractedJobName = parsed.jobName
                }
                break
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
            jobName = jobName.replacingOccurrences(of: #"\d{5,}(?:-[A-Z]{2})?"#, with: "", options: .regularExpression)
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
            var baseConfidence: Double = 0.8
            
            // Try metadata lookup first (most reliable)
            if let metadata = metadataManager?.getMetadata(for: docketNumber, jobName: jobName),
               !metadata.jobName.isEmpty {
                finalJobName = metadata.jobName
                baseConfidence = 0.95
            }
            // Try fuzzy matching against company cache
            else if let matcher = companyNameMatcher {
                let combinedText = "\(subjectText)\n\(bodyText)"
                if let match = matcher.findBestMatch(in: combinedText) {
                    finalJobName = match.name
                    baseConfidence = 0.85
                }
            }
            
            // Apply year validation and Asana cache checking
            let finalConfidence = calculateConfidence(
                pattern: "first_line_body",
                subject: subjectText,
                docketNumber: docketNumber,
                foundInEmail: true
            )
            // Use the higher of base confidence or calculated confidence
            let confidence = max(baseConfidence, finalConfidence)
            
            return ParsedDocket(
                docketNumber: docketNumber,
                jobName: finalJobName,
                sourceEmail: from ?? "unknown",
                confidence: confidence,
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
                        print("EmailDocketParser: ⚠️ Rejecting Pattern 7 match - invalid year format: \(parsed.docketNumber)")
                        continue // Skip this match, try next pattern or return nil
                    }
                    // Also require that the docket number appears in the email content
                    if !foundInEmail {
                        print("EmailDocketParser: ⚠️ Rejecting Pattern 7 match - docket number not found in email: \(parsed.docketNumber)")
                        continue
                    }
                }
                
                return ParsedDocket(
                    docketNumber: parsed.docketNumber,
                    jobName: parsed.jobName.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceEmail: from ?? "unknown",
                    confidence: calculateConfidence(
                        pattern: pattern,
                        subject: subjectText,
                        docketNumber: parsed.docketNumber,
                        foundInEmail: foundInEmail
                    ),
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
            
            return ParsedDocket(
                docketNumber: parsed.docketNumber,
                jobName: parsed.jobName,
                sourceEmail: from ?? "unknown",
                confidence: calculateConfidence(
                    pattern: "subject_fallback",
                    subject: subjectText,
                    docketNumber: parsed.docketNumber,
                    foundInEmail: foundInEmail
                ),
                rawData: [
                    "method": "subject_fallback",
                    "subject": subjectText,
                    "found_in_email": foundInEmail,
                    "year_valid": isValidYearBasedDocket(parsed.docketNumber),
                    "asana_exists": docketExistsInAsana(parsed.docketNumber)
                ]
            )
        }
        
        // Final fallback: Search for docket numbers anywhere, even without "new docket" text
        // This handles cases where producers just write the docket info in the body without mentioning "new docket"
        // Also check if body contains "new docket" (case-insensitive)
        let hasNewDocketText = subjectText.uppercased().contains("NEW DOCKET") || 
                               subjectText.uppercased().contains("DOCKET") ||
                               bodyText.uppercased().contains("NEW DOCKET") ||
                               bodyText.uppercased().contains("NEW DOCKET -") ||
                               bodyText.lowercased().contains("new docket") ||
                               bodyText.lowercased().contains("new docket -")
        
        // Be more aggressive: if we find a 5+ digit number that looks like a docket (starts with valid year prefixes),
        // treat it as a potential docket even without "new docket" text
        let validYearPrefixes = getValidYearPrefixes()
        let yearPrefixPattern = validYearPrefixes.map { String(format: "%02d", $0) }.joined(separator: "|")
        let docketYearPattern = "\\b(\(yearPrefixPattern))\\d{3,}\\b"
        let hasPotentialDocketNumber = bodyText.range(of: docketYearPattern, options: .regularExpression) != nil ||
                                      subjectText.range(of: docketYearPattern, options: .regularExpression) != nil
        
        if hasNewDocketText || hasPotentialDocketNumber {
            // Search for docket numbers (5+ digits, optionally with country code) anywhere in subject or body
            // Also match 4+ digit numbers at word boundaries (some dockets might be 4 digits)
            let docketPattern = #"\b(\d{4,}(?:-[A-Z]{2})?)\b"#
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
            // FIRST: Check first line of body for "25489 Job Name" pattern
            if foundDocketNumber == nil {
                let firstLinePattern = #"^(\d{5,})\s+(.+?)(?:\s*$|\n|\.)"#
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
                if foundDocketNumber == nil {
                    if let regex = try? NSRegularExpression(pattern: docketPattern, options: []) {
                        let matches = regex.matches(in: bodyText, range: NSRange(bodyText.startIndex..., in: bodyText))
                        
                        // Prefer 5+ digit numbers, but accept 4+ digit numbers
                        for match in matches {
                            guard match.numberOfRanges >= 2 else { continue }
                            let docketRange = Range(match.range(at: 1), in: bodyText)!
                            let candidate = String(bodyText[docketRange])
                            
                            // Prefer 5+ digit numbers
                            if candidate.count >= 5 {
                                foundDocketNumber = candidate
                                break
                            } else if foundDocketNumber == nil {
                                // Accept 4 digit numbers as fallback
                                foundDocketNumber = candidate
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
            subjectJobName = subjectJobName.replacingOccurrences(of: #"\b\d{5,}(?:-[A-Z]{2})?\b"#, with: "", options: .regularExpression)
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
            var baseConfidence: Double = foundDocketNumber != nil ? 0.7 : 0.3
            
            // Try metadata lookup first (most reliable)
            if let docketNum = foundDocketNumber,
               let metadata = metadataManager?.getMetadata(for: docketNum, jobName: finalJobName),
               !metadata.jobName.isEmpty {
                finalJobName = metadata.jobName
                baseConfidence = 0.9
            }
            // Try fuzzy matching against company cache
            else if let matcher = companyNameMatcher, finalJobName == "New Docket" || finalJobName.count < 5 {
                let combinedText = "\(subjectText)\n\(bodyText)"
                if let match = matcher.findBestMatch(in: combinedText) {
                    finalJobName = match.name
                    baseConfidence = 0.75
                }
            }
            
            // Apply year validation and Asana cache checking
            let calculatedConfidence = calculateConfidence(
                pattern: "new_docket_fallback",
                subject: subjectText,
                docketNumber: foundDocketNumber,
                foundInEmail: foundInEmail
            )
            // Use the higher of base confidence or calculated confidence
            let confidence = max(baseConfidence, calculatedConfidence)
            
            return ParsedDocket(
                docketNumber: finalDocketNumber,
                jobName: finalJobName,
                sourceEmail: from ?? "unknown",
                confidence: confidence,
                rawData: [
                    "method": foundDocketNumber != nil ? "new_docket_with_number" : "new_docket_label_fallback",
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
        
        // Validate docket number (should be numeric)
        guard docketNumber.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil else {
            return nil
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
    
    /// Get valid year prefixes for docket numbers based on current date
    /// - Returns: Array of valid two-digit year prefixes (e.g., [21, 22, 23, 24, 25, 26, 27])
    private func getValidYearPrefixes() -> [Int] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let currentYearLastTwo = currentYear % 100
        
        var validYears: [Int] = []
        
        // Current year: always valid
        validYears.append(currentYearLastTwo)
        
        // Next year: valid for planning ahead
        validYears.append((currentYearLastTwo + 1) % 100)
        
        // Future years: allow 1-2 years ahead for planning (but not too far)
        for i in 2...3 {
            let futureYear = (currentYearLastTwo + i) % 100
            // Only include if it's reasonable (not wrapping around too far)
            // If we're in 2025 (25), 26 and 27 are valid, but 28 might wrap to 28 (2028) which is fine
            // We want to avoid wrapping to very low numbers (like 0, 1, 2) which would be 2100, 2101, 2102
            if futureYear > currentYearLastTwo || (futureYear < currentYearLastTwo && futureYear < 10) {
                validYears.append(futureYear)
            }
        }
        
        // Previous years: allow last 10-15 years for revivals
        // This handles cases like "we're reviving a docket from 2021"
        // If we're in 2025 (25), we want: 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10
        // We want to avoid wrapping to 99, 98, etc. (which would be 1999, 1998 - too old)
        for i in 1...15 {
            let pastYear = (currentYearLastTwo - i + 100) % 100
            // Only include if it's within reasonable range
            // If pastYear <= currentYearLastTwo, it's definitely a valid past year (e.g., 24 <= 25)
            // If pastYear > currentYearLastTwo, it wrapped around to 1900s (e.g., 99 > 25 means 1999), so skip it
            if pastYear <= currentYearLastTwo {
                validYears.append(pastYear)
            }
        }
        
        // Remove duplicates and sort
        return Array(Set(validYears)).sorted()
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
    
    /// Calculate confidence score based on pattern match, context, year validation, and Asana cache
    /// - Parameters:
    ///   - pattern: The pattern that matched
    ///   - subject: Email subject
    ///   - docketNumber: Extracted docket number
    ///   - foundInEmail: Whether docket number was found in email content
    /// - Returns: Confidence score (0.0 to 1.0)
    private func calculateConfidence(pattern: String, subject: String, docketNumber: String?, foundInEmail: Bool) -> Double {
        var confidence: Double = 0.7 // Base confidence
        
        // CRITICAL: If docket number is NOT found in email, significantly lower confidence
        // ALL dockets should be mentioned in the email
        if !foundInEmail {
            confidence -= 0.4 // Heavy penalty
        }
        
        // CRITICAL: Year validation - heavily weighted
        if let docketNum = docketNumber {
            if isValidYearBasedDocket(docketNum) {
                confidence += 0.25 // Heavy boost for valid year-based docket
            } else {
                confidence -= 0.3 // Heavy penalty for invalid year format
            }
            
            // Asana cache check - boost confidence if docket exists
            if docketExistsInAsana(docketNum) {
                confidence += 0.15 // Boost for existing docket
            }
        }
        
        // Higher confidence if match is in subject (more reliable)
        if subject.lowercased().contains("docket") {
            confidence += 0.1
        }
        
        // Higher confidence for more specific patterns
        if pattern.contains("Docket") && pattern.contains("Job") {
            confidence += 0.05
        }
        
        return min(1.0, max(0.0, confidence))
    }
    
    /// Calculate confidence score based on pattern match and context (legacy method for backward compatibility)
    private func calculateConfidence(pattern: String, subject: String) -> Double {
        return calculateConfidence(pattern: pattern, subject: subject, docketNumber: nil, foundInEmail: true)
    }
}

