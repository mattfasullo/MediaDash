import Foundation

/// Service to determine if an email thread qualifies as a media-file-delivery thread
struct MediaThreadQualifier {
    let subjectPatterns: [String]
    let subjectExclusions: [String]
    let attachmentTypes: [String]
    let fileHostingWhitelist: [String]
    let senderWhitelist: [String]
    let bodyExclusions: [String]
    
    /// Check if a thread qualifies as media-file-delivery
    /// At least one filter must match for the thread to qualify
    /// Exclusions take priority - if any exclusion matches, the thread does NOT qualify
    func qualifiesAsMediaFileDelivery(
        subject: String?,
        body: String?,
        attachments: [String]?,
        labelIds: [String]?,
        senderEmail: String?
    ) -> Bool {
        var subjectLower = (subject ?? "").lowercased()
        let bodyLower = (body ?? "").lowercased()
        
        // Remove common email prefixes (Fwd:, Re:, FW:) to check the actual subject
        // This handles cases where emails are forwarded or replied to
        let prefixes = ["fwd:", "re:", "fw:"]
        for prefix in prefixes {
            if subjectLower.hasPrefix(prefix) {
                subjectLower = String(subjectLower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // EXCLUSION CHECKS (take priority - if any exclusion matches, return false immediately)
        
        // Check subject exclusions (if user has configured any)
        if !subjectExclusions.isEmpty {
            let matchesExclusion = subjectExclusions.contains { exclusion in
                subjectLower.contains(exclusion.lowercased())
            }
            if matchesExclusion {
                return false // Excluded by subject
            }
        }
        
        // Check body exclusions
        if !bodyExclusions.isEmpty {
            let matchesExclusion = bodyExclusions.contains { exclusion in
                bodyLower.contains(exclusion.lowercased())
            }
            if matchesExclusion {
                return false // Excluded by body
            }
        }
        
        // Check sender exclusions (noreply addresses, vendors, etc.)
        if let senderEmail = senderEmail {
            let senderLower = senderEmail.lowercased()
            // Exclude common automated/vendor email patterns
            if senderLower.contains("noreply") || 
               senderLower.contains("no-reply") ||
               senderLower.contains("invoice") ||
               senderLower.contains("sales@") && !senderLower.contains("@graysonmusicgroup.com") {
                return false // Excluded by sender
            }
        }
        
        // QUALIFICATION CHECKS (at least one must match)
        var matches: [Bool] = []
        
        // Subject pattern filtering
        if !subjectPatterns.isEmpty {
            let matchesSubject = subjectPatterns.contains { pattern in
                subjectLower.contains(pattern.lowercased())
            }
            matches.append(matchesSubject)
        }
        
        // Attachment type filtering
        if !attachmentTypes.isEmpty, let attachments = attachments {
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
            
            let matchesAttachment = attachmentExtensions.contains { ext in
                attachmentTypes.contains { type in
                    ext == type.lowercased()
                }
            }
            matches.append(matchesAttachment)
        }
        
        // File hosting whitelist filtering (primary method)
        if !fileHostingWhitelist.isEmpty {
            let matchesFileHosting = fileHostingWhitelist.contains { domain in
                bodyLower.contains(domain.lowercased())
            }
            matches.append(matchesFileHosting)
        }
        
        // Sender whitelisting
        if !senderWhitelist.isEmpty, let senderEmail = senderEmail {
            let senderLower = senderEmail.lowercased()
            let matchesSender = senderWhitelist.contains { whitelisted in
                senderLower == whitelisted.lowercased() ||
                senderLower.contains(whitelisted.lowercased())
            }
            matches.append(matchesSender)
        }
        
        // At least one filter must match (if any filters are configured)
        let hasFilters = !subjectPatterns.isEmpty || !attachmentTypes.isEmpty || !fileHostingWhitelist.isEmpty || !senderWhitelist.isEmpty
        
        if !hasFilters {
            // If no filters are configured, don't qualify (safety measure)
            return false
        }
        
        // At least one filter must match
        return matches.contains(true)
    }
    
    /// Check if email body contains file hosting links from the whitelist
    /// Also checks for review platform links (which should be excluded)
    func qualifiesByFileHostingLinks(_ body: String) -> Bool {
        let bodyLower = body.lowercased()
        
        print("MediaThreadQualifier: Checking file hosting links in body")
        print("  Body preview: \(bodyLower.prefix(200))")
        print("  Whitelist: \(fileHostingWhitelist)")
        
        // Exclude review platform links (these are NOT file delivery)
        let reviewPlatforms = [
            "simian.me",      // Review platform
            "disco.ac",       // Review platform
            "frame.io/review" // Review links (not delivery)
        ]
        
        for platform in reviewPlatforms {
            if bodyLower.contains(platform) {
                print("  Excluded: Found review platform '\(platform)'")
                return false // This is a review link, not a delivery link
            }
        }
        
        // Check for whitelisted file hosting links
        // Look for both full URLs (https://domain) and plain domain text
        if !fileHostingWhitelist.isEmpty {
            for domain in fileHostingWhitelist {
                let domainLower = domain.lowercased()
                print("  Checking for domain: \(domainLower)")
                
                // Check if domain appears in body (could be in URL or plain text)
                if bodyLower.contains(domainLower) {
                    // Additional check: exclude frame.io review links even if f.io is in whitelist
                    if domainLower == "f.io" && bodyLower.contains("frame.io/review") {
                        print("  Skipped: f.io found but it's a review link")
                        continue // Skip this, it's a review link
                    }
                    print("  ✅ Found whitelisted domain: \(domainLower)")
                    return true // Found a whitelisted file hosting link
                }
            }
            print("  ❌ No whitelisted domains found in body")
        }
        
        // Fallback: use the general FileHostingLinkDetector if whitelist is empty
        if fileHostingWhitelist.isEmpty {
            print("  Whitelist is empty, using fallback detector")
            return FileHostingLinkDetector.containsFileHostingLink(body)
        }
        
        return false
    }
}

