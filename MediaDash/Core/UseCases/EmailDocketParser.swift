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
    
    init(patterns: [String] = []) {
        self.patterns = patterns.isEmpty ? Self.defaultPatterns : patterns
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
            #"(\d{5,})\s+(.+?)(?:\n|$|\.)"#,
            // Pattern 6: "Docket #12345 - JobName"
            #"Docket\s*#?\s*(\d+)\s*[-–]\s*(.+?)(?:\s|$|,|\.)"#,
            // Pattern 7: Just numeric docket "12345" or "25484" anywhere
            #"(\d{5,})(?:\s|$|,|\.)"#
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
        let bodyText = body ?? ""
        let combinedText = "\(subjectText)\n\(bodyText)"
        
        // First, try to extract docket number from body (like "25484-US")
        var extractedDocketNumber: String?
        var extractedJobName: String?
        
        // FIRST: Try to find docket number and job name on the first line of body (most common case)
        // Pattern: "25489 12 Days of Connection" or "25489 Job Name"
        let firstLinePattern = #"^(\d{5,})\s+(.+?)(?:\s*$|\n|\.)"#
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
        
        // If we have both, return the parsed docket
        if let docketNumber = extractedDocketNumber, let jobName = extractedJobName {
            return ParsedDocket(
                docketNumber: docketNumber,
                jobName: jobName,
                sourceEmail: from ?? "unknown",
                confidence: 0.8,
                rawData: [
                    "method": "body_subject_combination",
                    "subject": subjectText,
                    "body": bodyText
                ]
            )
        }
        
        // Try each pattern on combined text
        for pattern in patterns {
            if let parsed = tryPattern(pattern, in: combinedText) {
                return ParsedDocket(
                    docketNumber: parsed.docketNumber,
                    jobName: parsed.jobName.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceEmail: from ?? "unknown",
                    confidence: calculateConfidence(pattern: pattern, subject: subjectText),
                    rawData: [
                        "pattern": pattern,
                        "subject": subjectText,
                        "matchedText": parsed.matchedText
                    ]
                )
            }
        }
        
        // If no pattern matches, try to extract from subject alone using common formats
        if let parsed = extractFromSubject(subjectText) {
            return ParsedDocket(
                docketNumber: parsed.docketNumber,
                jobName: parsed.jobName,
                sourceEmail: from ?? "unknown",
                confidence: 0.5, // Lower confidence for fallback
                rawData: [
                    "method": "subject_fallback",
                    "subject": subjectText
                ]
            )
        }
        
        // Final fallback: If subject contains "NEW DOCKET" or "New Docket", search for docket numbers anywhere
        // This handles cases where emails are labeled "NEW DOCKET" and we need to find numbers in subject or body
        if subjectText.uppercased().contains("NEW DOCKET") || subjectText.uppercased().contains("DOCKET") {
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
            
            // Final fallback
            let finalJobName = jobName ?? "New Docket"
            
            return ParsedDocket(
                docketNumber: finalDocketNumber,
                jobName: finalJobName,
                sourceEmail: from ?? "unknown",
                confidence: foundDocketNumber != nil ? 0.7 : 0.3,
                rawData: [
                    "method": foundDocketNumber != nil ? "new_docket_with_number" : "new_docket_label_fallback",
                    "subject": subjectText,
                    "body": bodyText,
                    "has_docket_number": foundDocketNumber != nil
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
    
    /// Calculate confidence score based on pattern match and context
    private func calculateConfidence(pattern: String, subject: String) -> Double {
        var confidence: Double = 0.7 // Base confidence
        
        // Higher confidence if match is in subject (more reliable)
        if subject.lowercased().contains("docket") {
            confidence += 0.2
        }
        
        // Higher confidence for more specific patterns
        if pattern.contains("Docket") && pattern.contains("Job") {
            confidence += 0.1
        }
        
        return min(1.0, confidence)
    }
}

