import Foundation

/// Detailed result of qualification check with debug information
struct QualificationResult {
    let qualifies: Bool
    let reasons: [String] // Reasons why it qualified or didn't qualify
    let matchedCriteria: [String] // Which criteria matched (subject pattern, file hosting link, etc.)
    let exclusionReasons: [String] // Why it was excluded (if applicable)
    
    init(qualifies: Bool, reasons: [String] = [], matchedCriteria: [String] = [], exclusionReasons: [String] = []) {
        self.qualifies = qualifies
        self.reasons = reasons
        self.matchedCriteria = matchedCriteria
        self.exclusionReasons = exclusionReasons
    }
}

/// Service to determine if an email thread qualifies as a media-file-delivery thread
struct MediaThreadQualifier {
    let subjectPatterns: [String]
    let subjectExclusions: [String]
    let attachmentTypes: [String]
    let fileHostingWhitelist: [String]
    let senderWhitelist: [String]
    let bodyExclusions: [String]
    
    /// Check if a thread qualifies as media-file-delivery (returns detailed debug info)
    /// At least one filter must match for the thread to qualify
    /// Exclusions take priority - if any exclusion matches, the thread does NOT qualify
    func qualifiesAsMediaFileDeliveryWithDebug(
        subject: String?,
        body: String?,
        attachments: [String]?,
        labelIds: [String]?,
        senderEmail: String?
    ) -> QualificationResult {
        let originalSubjectLower = (subject ?? "").lowercased()
        var subjectLower = originalSubjectLower
        let bodyLower = (body ?? "").lowercased()
        var reasons: [String] = []
        var matchedCriteria: [String] = []
        var exclusionReasons: [String] = []
        
        reasons.append("📧 Email Qualification Debug:")
        reasons.append("  Subject: \(subject ?? "(none)")")
        reasons.append("  Sender: \(senderEmail ?? "(unknown)")")
        reasons.append("  Body length: \(body?.count ?? 0) chars")
        reasons.append("  Attachments: \(attachments?.count ?? 0)")
        
        // Remove common email prefixes (Fwd:, Re:, FW:) to check the actual subject
        // This handles cases where emails are forwarded or replied to
        let prefixes = ["fwd:", "re:", "fw:"]
        for prefix in prefixes {
            if subjectLower.hasPrefix(prefix) {
                subjectLower = String(subjectLower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                reasons.append("  Removed email prefix: \(prefix)")
            }
        }
        
        // EXCLUSION CHECKS (take priority - if any exclusion matches, return false immediately)
        
        // Always exclude if "new docket" appears in subject or body (hardcoded exclusion - highest priority)
        // This prevents file delivery notifications from being created for new docket emails
        // Check both original and cleaned subject to catch it even with email prefixes
        if originalSubjectLower.contains("new docket") || 
           subjectLower.contains("new docket") || 
           bodyLower.contains("new docket") {
            exclusionReasons.append("❌ EXCLUDED: Contains 'new docket' (hardcoded exclusion)")
            reasons.append(exclusionReasons.last!)
            return QualificationResult(
                qualifies: false,
                reasons: reasons,
                matchedCriteria: [],
                exclusionReasons: exclusionReasons
            )
        }
        
        // Check subject exclusions (if user has configured any)
        if !subjectExclusions.isEmpty {
            for exclusion in subjectExclusions {
                if subjectLower.contains(exclusion.lowercased()) {
                    exclusionReasons.append("❌ EXCLUDED: Subject contains exclusion pattern '\(exclusion)'")
                    reasons.append(exclusionReasons.last!)
                    return QualificationResult(
                        qualifies: false,
                        reasons: reasons,
                        matchedCriteria: [],
                        exclusionReasons: exclusionReasons
                    )
                }
            }
        }
        
        // Check body exclusions
        if !bodyExclusions.isEmpty {
            for exclusion in bodyExclusions {
                if bodyLower.contains(exclusion.lowercased()) {
                    exclusionReasons.append("❌ EXCLUDED: Body contains exclusion pattern '\(exclusion)'")
                    reasons.append(exclusionReasons.last!)
                    return QualificationResult(
                        qualifies: false,
                        reasons: reasons,
                        matchedCriteria: [],
                        exclusionReasons: exclusionReasons
                    )
                }
            }
        }
        
        // Check sender exclusions (noreply addresses, vendors, etc.)
        if let senderEmail = senderEmail {
            let senderLower = senderEmail.lowercased()
            // Exclude common automated/vendor email patterns
            if senderLower.contains("noreply") {
                exclusionReasons.append("❌ EXCLUDED: Sender contains 'noreply'")
                reasons.append(exclusionReasons.last!)
                return QualificationResult(
                    qualifies: false,
                    reasons: reasons,
                    matchedCriteria: [],
                    exclusionReasons: exclusionReasons
                )
            }
            if senderLower.contains("no-reply") {
                exclusionReasons.append("❌ EXCLUDED: Sender contains 'no-reply'")
                reasons.append(exclusionReasons.last!)
                return QualificationResult(
                    qualifies: false,
                    reasons: reasons,
                    matchedCriteria: [],
                    exclusionReasons: exclusionReasons
                )
            }
            if senderLower.contains("invoice") {
                exclusionReasons.append("❌ EXCLUDED: Sender contains 'invoice'")
                reasons.append(exclusionReasons.last!)
                return QualificationResult(
                    qualifies: false,
                    reasons: reasons,
                    matchedCriteria: [],
                    exclusionReasons: exclusionReasons
                )
            }
            if senderLower.contains("sales@") && !senderLower.contains("@graysonmusicgroup.com") {
                exclusionReasons.append("❌ EXCLUDED: Sender is sales@ (not from graysonmusicgroup.com)")
                reasons.append(exclusionReasons.last!)
                return QualificationResult(
                    qualifies: false,
                    reasons: reasons,
                    matchedCriteria: [],
                    exclusionReasons: exclusionReasons
                )
            }
        }
        
        reasons.append("  ✅ Passed all exclusion checks")
        
        // QUALIFICATION CHECKS (at least one must match)
        var matches: [Bool] = []
        var matchDetails: [String] = []
        
        // Subject pattern filtering
        if !subjectPatterns.isEmpty {
            reasons.append("  Checking subject patterns: \(subjectPatterns)")
            for pattern in subjectPatterns {
                if subjectLower.contains(pattern.lowercased()) {
                    let matchDetail = "✅ MATCHED: Subject pattern '\(pattern)'"
                    matchedCriteria.append("Subject pattern: '\(pattern)'")
                    matchDetails.append(matchDetail)
                    reasons.append("    \(matchDetail)")
                    matches.append(true)
                    break
                } else {
                    reasons.append("    ❌ No match for pattern '\(pattern)'")
                }
            }
            if !matchDetails.isEmpty {
                matches.append(true)
            } else {
                matches.append(false)
            }
        }
        
        // Attachment type filtering
        // Exclude image types from counting as file deliveries (they're usually signature logos)
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "ico", "tiff", "tif"]
        
        if !attachmentTypes.isEmpty, let attachments = attachments {
            reasons.append("  Checking attachment types: \(attachmentTypes)")
            let attachmentExtensions = attachments.compactMap { url -> String? in
                // Extract file extension from URL or filename
                if let urlObj = URL(string: url) {
                    return urlObj.pathExtension.lowercased()
                }
                // Try to extract from filename if URL parsing fails
                if let lastDot = url.lastIndex(of: ".") {
                    return String(url[url.index(after: lastDot)...]).lowercased()
                }
                return nil
            }
            
            reasons.append("    Found attachment extensions: \(attachmentExtensions)")
            
            // Filter out image extensions - these are typically signature logos, not file deliveries
            let nonImageExtensions = attachmentExtensions.filter { ext in
                !imageExtensions.contains(ext)
            }
            
            reasons.append("    Non-image extensions (after filtering): \(nonImageExtensions)")
            
            // Only check non-image attachments
            var foundMatchingAttachment = false
            for ext in nonImageExtensions {
                for type in attachmentTypes {
                    if ext == type.lowercased() {
                        let matchDetail = "✅ MATCHED: Attachment type '\(ext)'"
                        matchedCriteria.append("Attachment type: '\(ext)'")
                        matchDetails.append(matchDetail)
                        reasons.append("    \(matchDetail)")
                        foundMatchingAttachment = true
                        break
                    }
                }
            }
            matches.append(foundMatchingAttachment)
            if !foundMatchingAttachment {
                reasons.append("    ❌ No matching attachment types found")
            }
        }
        
        // File hosting whitelist filtering (primary method)
        if !fileHostingWhitelist.isEmpty {
            reasons.append("  Checking file hosting whitelist: \(fileHostingWhitelist)")
            var foundFileHosting = false
            for domain in fileHostingWhitelist {
                if bodyLower.contains(domain.lowercased()) {
                    let matchDetail = "✅ MATCHED: File hosting domain '\(domain)'"
                    matchedCriteria.append("File hosting domain: '\(domain)'")
                    matchDetails.append(matchDetail)
                    reasons.append("    \(matchDetail)")
                    foundFileHosting = true
                    break
                } else {
                    reasons.append("    ❌ Domain '\(domain)' not found in body")
                }
            }
            matches.append(foundFileHosting)
        }
        
        // Sender whitelisting
        if !senderWhitelist.isEmpty, let senderEmail = senderEmail {
            reasons.append("  Checking sender whitelist: \(senderWhitelist)")
            let senderLower = senderEmail.lowercased()
            var foundSender = false
            for whitelisted in senderWhitelist {
                if senderLower == whitelisted.lowercased() ||
                   senderLower.contains(whitelisted.lowercased()) {
                    let matchDetail = "✅ MATCHED: Sender whitelist '\(whitelisted)'"
                    matchedCriteria.append("Sender whitelist: '\(whitelisted)'")
                    matchDetails.append(matchDetail)
                    reasons.append("    \(matchDetail)")
                    foundSender = true
                    break
                } else {
                    reasons.append("    ❌ Sender '\(senderEmail)' doesn't match '\(whitelisted)'")
                }
            }
            matches.append(foundSender)
        }
        
        // At least one filter must match (if any filters are configured)
        let hasFilters = !subjectPatterns.isEmpty || !attachmentTypes.isEmpty || !fileHostingWhitelist.isEmpty || !senderWhitelist.isEmpty
        
        if !hasFilters {
            reasons.append("  ❌ NO FILTERS CONFIGURED: Cannot qualify (safety measure)")
            return QualificationResult(
                qualifies: false,
                reasons: reasons,
                matchedCriteria: [],
                exclusionReasons: exclusionReasons
            )
        }
        
        // At least one filter must match
        let qualifies = matches.contains(true)
        
        if qualifies {
            reasons.append("  ✅ QUALIFIED: At least one criteria matched")
            reasons.append("  Matched criteria: \(matchedCriteria.joined(separator: ", "))")
        } else {
            reasons.append("  ❌ NOT QUALIFIED: No criteria matched")
            reasons.append("  Configured filters: Subject patterns=\(!subjectPatterns.isEmpty), Attachments=\(!attachmentTypes.isEmpty), File hosting=\(!fileHostingWhitelist.isEmpty), Sender=\(!senderWhitelist.isEmpty)")
        }
        
        return QualificationResult(
            qualifies: qualifies,
            reasons: reasons,
            matchedCriteria: matchedCriteria,
            exclusionReasons: exclusionReasons
        )
    }
    
    /// Check if a thread qualifies as media-file-delivery (simple boolean version for backward compatibility)
    func qualifiesAsMediaFileDelivery(
        subject: String?,
        body: String?,
        attachments: [String]?,
        labelIds: [String]?,
        senderEmail: String?
    ) -> Bool {
        return qualifiesAsMediaFileDeliveryWithDebug(
            subject: subject,
            body: body,
            attachments: attachments,
            labelIds: labelIds,
            senderEmail: senderEmail
        ).qualifies
    }
    
    /// Check if email body contains file hosting links from the whitelist (with debug info)
    /// Also checks for review platform links (which should be excluded)
    func qualifiesByFileHostingLinksWithDebug(_ body: String) -> QualificationResult {
        var reasons: [String] = []
        var matchedCriteria: [String] = []
        var exclusionReasons: [String] = []
        
        reasons.append("🔗 File Hosting Link Check:")
        reasons.append("  Body length: \(body.count) characters")
        reasons.append("  Body preview (first 200 chars): \(body.prefix(200))")
        reasons.append("  Whitelist: \(fileHostingWhitelist)")
        
        let bodyLower = body.lowercased()
        
        // Exclude review platform links (these are NOT file delivery)
        let reviewPlatforms = [
            "simian.me",      // Review platform
            "disco.ac",       // Review platform
            "frame.io/review" // Review links (not delivery)
        ]
        
        for platform in reviewPlatforms {
            if bodyLower.contains(platform) {
                exclusionReasons.append("❌ EXCLUDED: Found review platform '\(platform)'")
                reasons.append(exclusionReasons.last!)
                return QualificationResult(
                    qualifies: false,
                    reasons: reasons,
                    matchedCriteria: [],
                    exclusionReasons: exclusionReasons
                )
            }
        }
        
        // Exclude social media and image hosting domains (signature logos, etc.)
        let excludedDomains = [
            "instagram.com",
            "facebook.com",
            "twitter.com",
            "x.com",
            "linkedin.com",
            "youtube.com",
            "tiktok.com",
            "pinterest.com",
            "snapchat.com",
            "reddit.com",
            "imgur.com",
            "flickr.com",
            "500px.com",
            "unsplash.com",
            "pexels.com",
            "pixabay.com",
            "shutterstock.com",
            "gettyimages.com",
            "i.imgur.com",
            "cdninstagram.com",
            "fbcdn.net",
            "twimg.com"
        ]
        
        for excludedDomain in excludedDomains {
            if bodyLower.contains(excludedDomain) {
                reasons.append("  Found excluded domain '\(excludedDomain)' in body (will check if legitimate domains also present)")
            }
        }
        
        // Check for whitelisted file hosting links
        // Look for both full URLs (https://domain) and plain domain text
        if !fileHostingWhitelist.isEmpty {
            // First, check if body contains any excluded domains
            var hasExcludedDomains = false
            for excludedDomain in excludedDomains {
                if bodyLower.contains(excludedDomain) {
                    hasExcludedDomains = true
                    reasons.append("  Found excluded domain '\(excludedDomain)' in body")
                    break
                }
            }
            
            var foundLegitimateDomain = false
            var foundDomain: String?
            
            for domain in fileHostingWhitelist {
                let domainLower = domain.lowercased()
                reasons.append("  Checking for domain: \(domainLower)")
                
                // Check if domain appears in body (could be in URL or plain text)
                if bodyLower.contains(domainLower) {
                    // Additional check: exclude frame.io review links even if f.io is in whitelist
                    if domainLower == "f.io" && bodyLower.contains("frame.io/review") {
                        reasons.append("    Skipped: f.io found but it's a review link")
                        continue // Skip this, it's a review link
                    }
                    
                    // Check if this domain match is actually within an excluded domain URL
                    // Extract all URLs containing this domain and check if they also contain excluded domains
                    if hasExcludedDomains {
                        // Use regex to find URLs containing this domain
                        let urlPattern = #"https?://[^\s<>"']+"#
                        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
                            let matches = regex.matches(in: bodyLower, range: NSRange(bodyLower.startIndex..., in: bodyLower))
                            var allUrlsContainExcludedDomain = true
                            
                            for match in matches {
                                if let urlRange = Range(match.range, in: bodyLower) {
                                    let url = String(bodyLower[urlRange])
                                    // Check if this URL contains the whitelist domain
                                    if url.contains(domainLower) {
                                        // Check if this URL also contains an excluded domain
                                        var urlContainsExcluded = false
                                        for excludedDomain in excludedDomains {
                                            if url.contains(excludedDomain) {
                                                urlContainsExcluded = true
                                                reasons.append("    Skipped: URL containing '\(domainLower)' also contains excluded domain '\(excludedDomain)'")
                                                break
                                            }
                                        }
                                        if !urlContainsExcluded {
                                            allUrlsContainExcludedDomain = false
                                            foundLegitimateDomain = true
                                            foundDomain = domainLower
                                            reasons.append("    ✅ Found matching URL: \(url)")
                                            reasons.append("    ✅ Found whitelisted domain: \(domainLower) in legitimate URL")
                                            break
                                        }
                                    }
                                }
                            }
                            
                            if !allUrlsContainExcludedDomain {
                                matchedCriteria.append("File hosting domain: '\(foundDomain ?? domainLower)'")
                                reasons.append("  ✅ QUALIFIED: Found legitimate file hosting link")
                                return QualificationResult(
                                    qualifies: true,
                                    reasons: reasons,
                                    matchedCriteria: matchedCriteria,
                                    exclusionReasons: exclusionReasons
                                )
                            }
                        }
                    } else {
                        // No excluded domains found, so this is a legitimate match
                        foundLegitimateDomain = true
                        foundDomain = domainLower
                        
                        // Try to find the actual URL containing this domain for better debugging
                        let urlPattern = #"https?://[^\s<>"']+"#
                        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
                            let matches = regex.matches(in: bodyLower, range: NSRange(bodyLower.startIndex..., in: bodyLower))
                            for match in matches {
                                if let urlRange = Range(match.range, in: bodyLower) {
                                    let url = String(bodyLower[urlRange])
                                    if url.contains(domainLower) {
                                        reasons.append("    ✅ Found matching URL: \(url)")
                                        break
                                    }
                                }
                            }
                        }
                        
                        matchedCriteria.append("File hosting domain: '\(domainLower)'")
                        reasons.append("  ✅ QUALIFIED: Found whitelisted domain: \(domainLower)")
                        return QualificationResult(
                            qualifies: true,
                            reasons: reasons,
                            matchedCriteria: matchedCriteria,
                            exclusionReasons: exclusionReasons
                        )
                    }
                } else {
                    reasons.append("    ❌ Domain '\(domainLower)' not found in body")
                }
            }
            
            if !foundLegitimateDomain {
                reasons.append("  ❌ NOT QUALIFIED: No whitelisted domains found in body (or all matches were excluded)")
            }
        }
        
        // Fallback: use the general FileHostingLinkDetector if whitelist is empty
        if fileHostingWhitelist.isEmpty {
            reasons.append("  Whitelist is empty, using fallback detector")
            let fallbackResult = FileHostingLinkDetector.containsFileHostingLink(body)
            if fallbackResult {
                matchedCriteria.append("File hosting link (fallback detector)")
                reasons.append("  ✅ QUALIFIED: Fallback detector found file hosting link")
            } else {
                reasons.append("  ❌ NOT QUALIFIED: Fallback detector found no file hosting links")
            }
            return QualificationResult(
                qualifies: fallbackResult,
                reasons: reasons,
                matchedCriteria: matchedCriteria,
                exclusionReasons: exclusionReasons
            )
        }
        
        return QualificationResult(
            qualifies: false,
            reasons: reasons,
            matchedCriteria: [],
            exclusionReasons: exclusionReasons
        )
    }
    
    /// Check if email body contains file hosting links from the whitelist (simple boolean version)
    func qualifiesByFileHostingLinks(_ body: String) -> Bool {
        return qualifiesByFileHostingLinksWithDebug(body).qualifies
    }
}

