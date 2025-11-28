import Foundation

/// Utility to detect file hosting links in email content
struct FileHostingLinkDetector {
    /// Known file hosting domains (fallback list - should use whitelist from settings when available)
    private static let hostingDomains: [String] = [
        "drive.google.com",
        "docs.google.com",
        "frame.io",
        "wdrv.it",              // WeTransfer short link
        "wetransfer.com",       // WeTransfer
        "dropbox.com",
        "dropboxusercontent.com",
        "onedrive.live.com",
        "sharepoint.com",
        "box.com",
        "boxusercontent.com",
        "wpp.box.com",          // Box (WPP)
        "hightail.com",
        "sendspace.com",
        "mediafire.com",
        "mega.nz",
        "pcloud.com",
        "icloud.com",
        "icloud.com.cn",
        "psi.schoolediting.com" // School Editing custom hosting
    ]
    
    /// Domains to exclude from file hosting detection (social media, image hosting for logos, etc.)
    private static let excludedDomains: [String] = [
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
    
    /// Check if a URL points to an image file
    private static func isImageURL(_ url: String) -> Bool {
        let imageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".svg", ".ico", ".tiff", ".tif", ".heic", ".heif"]
        let urlLower = url.lowercased()
        // Check if URL ends with an image extension or contains one in the path
        for ext in imageExtensions {
            if urlLower.contains(ext) {
                // Make sure it's actually the file extension, not part of a longer word
                if urlLower.hasSuffix(ext) || urlLower.contains(ext + "?") || urlLower.contains(ext + "&") || urlLower.contains(ext + "#") || urlLower.contains(ext + "/") {
                    return true
                }
            }
        }
        return false
    }
    
    /// Check if a URL is embedded in an HTML img tag
    private static func isEmbeddedInImageTag(_ url: String, htmlText: String) -> Bool {
        // Look for <img> tags that reference this URL
        // Check if the URL appears within an <img> tag's src attribute
        let htmlLower = htmlText.lowercased()
        let urlLower = url.lowercased()
        
        // Find all <img> tags
        let imgTagPattern = #"<img[^>]*>"#
        if let imgRegex = try? NSRegularExpression(pattern: imgTagPattern, options: .caseInsensitive) {
            let matches = imgRegex.matches(in: htmlLower, range: NSRange(htmlLower.startIndex..., in: htmlLower))
            for match in matches {
                if let tagRange = Range(match.range, in: htmlLower) {
                    let imgTag = String(htmlLower[tagRange])
                    // Check if this img tag contains the URL in its src attribute
                    if imgTag.contains(urlLower) {
                        return true
                    }
                }
            }
        }
        
        // Also check for data URIs and embedded images
        if urlLower.hasPrefix("data:image/") {
            return true
        }
        return false
    }
    
    /// Check if email body contains file hosting links
    static func containsFileHostingLink(_ text: String) -> Bool {
        // Extract all URLs first
        let urlPattern = #"https?://[^\s<>"']+"#
        var legitimateHostingLinks: [String] = []
        
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let urlRange = Range(match.range, in: text) {
                    let url = String(text[urlRange])
                    let urlLower = url.lowercased()
                    
                    // Skip if it's an image URL
                    if isImageURL(url) {
                        continue
                    }
                    
                    // Skip if it's embedded in an image tag
                    if isEmbeddedInImageTag(url, htmlText: text) {
                        continue
                    }
                    
                    // Skip if it's an excluded domain
                    var isExcluded = false
                    for excludedDomain in excludedDomains {
                        if urlLower.contains(excludedDomain) {
                            isExcluded = true
                            break
                        }
                    }
                    if isExcluded {
                        continue
                    }
                    
                    // Check if it's a legitimate hosting domain
                    for domain in hostingDomains {
                        if urlLower.contains(domain) {
                            legitimateHostingLinks.append(url)
                            break
                        }
                    }
                }
            }
        }
        
        // Return true only if we found at least one legitimate (non-image, non-embedded) file hosting link
        if !legitimateHostingLinks.isEmpty {
            return true
        }
        
        // Also check for common link patterns (but exclude social media domains and image URLs)
        let urlPatterns = [
            #"https?://[^\s]+\.(drive|docs|frame|wetransfer|dropbox|onedrive|sharepoint|box|hightail|sendspace|mediafire|mega|pcloud|icloud)"#,
            #"https?://[^\s]+/(drive|docs|frame|wetransfer|dropbox|onedrive|sharepoint|box|hightail|sendspace|mediafire|mega|pcloud|icloud)"#
        ]
        
        for pattern in urlPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                // Check if the matched URL contains an excluded domain or is an image
                if let matchRange = Range(match.range, in: text) {
                    let matchedUrl = String(text[matchRange])
                    let matchedUrlLower = matchedUrl.lowercased()
                    
                    // Skip if it's an image URL
                    if isImageURL(matchedUrl) {
                        continue
                    }
                    
                    // Skip if it's embedded in an image tag
                    if isEmbeddedInImageTag(matchedUrl, htmlText: text) {
                        continue
                    }
                    
                    var isExcluded = false
                    for excludedDomain in excludedDomains {
                        if matchedUrlLower.contains(excludedDomain) {
                            isExcluded = true
                            break
                        }
                    }
                    if !isExcluded {
                        return true
                    }
                }
            }
        }
        
        return false
    }
    
    /// Normalize URL for deduplication (removes protocol to treat http/https as same)
    private static func normalizeUrlForDedup(_ url: String) -> String {
        var normalized = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove protocol for comparison (http:// and https:// should be treated as same)
        if normalized.hasPrefix("http://") {
            normalized = String(normalized.dropFirst(7))
        } else if normalized.hasPrefix("https://") {
            normalized = String(normalized.dropFirst(8))
        }
        // Remove trailing slash for comparison
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        return normalized
    }
    
    /// Extract file hosting links from email body
    static func extractFileHostingLinks(_ text: String) -> [String] {
        var links: [String] = []
        var seenNormalizedLinks = Set<String>() // To avoid duplicates (normalized)
        var linkMap: [String: String] = [:] // Maps normalized URL to preferred URL (prefer HTTPS)
        
        // First, try to extract from HTML href attributes (with or without protocol)
        let hrefPattern = #"href=["'](https?://[^"']+)["']"#
        if let hrefRegex = try? NSRegularExpression(pattern: hrefPattern, options: .caseInsensitive) {
            let hrefMatches = hrefRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in hrefMatches {
                if match.numberOfRanges >= 2,
                   let urlRange = Range(match.range(at: 1), in: text) {
                    let url = String(text[urlRange])
                    let urlLowercased = url.lowercased()
                    
                    // Skip if it's an image URL
                    if isImageURL(url) {
                        continue
                    }
                    
                    // Skip if it's embedded in an image tag
                    if isEmbeddedInImageTag(url, htmlText: text) {
                        continue
                    }
                    
                    // Check if URL contains any hosting domain (exclude social media/image hosting)
                    var isExcluded = false
                    for excludedDomain in excludedDomains {
                        if urlLowercased.contains(excludedDomain) {
                            isExcluded = true
                            break
                        }
                    }
                    
                    if !isExcluded {
                        for domain in hostingDomains {
                            if urlLowercased.contains(domain) {
                                let cleanedUrl = cleanUrl(url)
                                let normalized = normalizeUrlForDedup(cleanedUrl)
                                if !seenNormalizedLinks.contains(normalized) {
                                    links.append(cleanedUrl)
                                    seenNormalizedLinks.insert(normalized)
                                    linkMap[normalized] = cleanedUrl
                                } else {
                                    // If we've seen this URL before, prefer HTTPS over HTTP
                                    if let existingUrl = linkMap[normalized] {
                                        let prefersHttps = cleanedUrl.lowercased().hasPrefix("https://")
                                        let existingPrefersHttps = existingUrl.lowercased().hasPrefix("https://")
                                        if prefersHttps && !existingPrefersHttps {
                                            // Replace HTTP with HTTPS version
                                            if let index = links.firstIndex(of: existingUrl) {
                                                links[index] = cleanedUrl
                                                linkMap[normalized] = cleanedUrl
                                            }
                                        }
                                    }
                                }
                                break
                            }
                        }
                    }
                }
            }
        }
        
        // Extract URLs with protocol (https:// or http://)
        let urlPattern = #"https?://[^\s<>"']+"#
        
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            
            for match in matches {
                if let urlRange = Range(match.range, in: text) {
                    var url = String(text[urlRange])
                    // Clean up URL (remove trailing punctuation that might have been captured)
                    url = cleanUrl(url)
                    let urlLowercased = url.lowercased()
                    
                    // Skip if it's an image URL
                    if isImageURL(url) {
                        continue
                    }
                    
                    // Skip if it's embedded in an image tag
                    if isEmbeddedInImageTag(url, htmlText: text) {
                        continue
                    }
                    
                    // Check if URL contains any hosting domain (exclude social media/image hosting)
                    var isExcluded = false
                    for excludedDomain in excludedDomains {
                        if urlLowercased.contains(excludedDomain) {
                            isExcluded = true
                            break
                        }
                    }
                    
                    if !isExcluded {
                        for domain in hostingDomains {
                            if urlLowercased.contains(domain) {
                                let normalized = normalizeUrlForDedup(url)
                                if !seenNormalizedLinks.contains(normalized) {
                                    links.append(url)
                                    seenNormalizedLinks.insert(normalized)
                                    linkMap[normalized] = url
                                } else {
                                    // If we've seen this URL before, prefer HTTPS over HTTP
                                    if let existingUrl = linkMap[normalized] {
                                        let prefersHttps = url.lowercased().hasPrefix("https://")
                                        let existingPrefersHttps = existingUrl.lowercased().hasPrefix("https://")
                                        if prefersHttps && !existingPrefersHttps {
                                            // Replace HTTP with HTTPS version
                                            if let index = links.firstIndex(of: existingUrl) {
                                                links[index] = url
                                                linkMap[normalized] = url
                                            }
                                        }
                                    }
                                }
                                break
                            }
                        }
                    }
                }
            }
        }
        
        // Extract links without protocol (like "wdrv.it" or "drive.google.com/file/...")
        // Use a simpler, safer approach with NSRange to avoid String index issues
        let lowercasedText = text.lowercased()
        
        for domain in hostingDomains {
            // Skip if this domain matches any excluded domain
            var isExcluded = false
            for excludedDomain in excludedDomains {
                if domain.lowercased().contains(excludedDomain) || excludedDomain.contains(domain.lowercased()) {
                    isExcluded = true
                    break
                }
            }
            if isExcluded {
                continue
            }
            
            var searchRange = NSRange(location: 0, length: lowercasedText.count)
            
            while searchRange.location < lowercasedText.count {
                let foundRange = (lowercasedText as NSString).range(of: domain, options: .caseInsensitive, range: searchRange)
                
                guard foundRange.location != NSNotFound else {
                    break
                }
                
                // Check if there's an excluded domain nearby (within 50 chars before or after)
                let contextStart = max(0, foundRange.location - 50)
                let contextEnd = min(lowercasedText.count, foundRange.location + foundRange.length + 50)
                let contextRange = NSRange(location: contextStart, length: contextEnd - contextStart)
                let contextText = (lowercasedText as NSString).substring(with: contextRange)
                
                var contextContainsExcluded = false
                for excludedDomain in excludedDomains {
                    if contextText.contains(excludedDomain) {
                        contextContainsExcluded = true
                        break
                    }
                }
                
                if contextContainsExcluded {
                    searchRange = NSRange(location: foundRange.location + foundRange.length, length: text.count - (foundRange.location + foundRange.length))
                    continue
                }
                
                // Check if there's "http://" or "https://" before this domain (within 20 chars)
                let lookbackStart = max(0, foundRange.location - 20)
                let lookbackRange = NSRange(location: lookbackStart, length: foundRange.location - lookbackStart)
                let lookbackText = (text as NSString).substring(with: lookbackRange).lowercased()
                
                // Skip if it's already part of a URL with protocol
                if !lookbackText.contains("http://") && !lookbackText.contains("https://") {
                    // Extract the domain and any path that follows
                    var urlEnd = foundRange.location + foundRange.length
                    let remainingRange = NSRange(location: urlEnd, length: text.count - urlEnd)
                    
                    if remainingRange.length > 0 {
                        let remainingText = (text as NSString).substring(with: remainingRange)
                        
                        // Try to find a path (anything after / that's not whitespace or common punctuation)
                        if let slashIndex = remainingText.firstIndex(of: "/") {
                            let slashOffset = remainingText.distance(from: remainingText.startIndex, to: slashIndex)
                            let pathStart = urlEnd + slashOffset
                            let pathRemaining = NSRange(location: pathStart, length: text.count - pathStart)
                            
                            if pathRemaining.length > 0 {
                                let pathText = (text as NSString).substring(with: pathRemaining)
                                
                                // Find where the path ends - stop at newline, whitespace, >, ", ', or end of string
                                if let pathEndIndex = pathText.firstIndex(where: { $0.isNewline || $0.isWhitespace || $0 == ">" || $0 == "\"" || $0 == "'" || $0 == "<" }) {
                                    let pathEndOffset = pathText.distance(from: pathText.startIndex, to: pathEndIndex)
                                    urlEnd = pathStart + pathEndOffset
                                } else {
                                    // Path goes to end of text
                                    urlEnd = text.count
                                }
                            }
                        } else {
                            // No path, domain ends at newline, whitespace, or punctuation (but not /)
                            // Stop immediately at newline to avoid capturing signature blocks
                            if let endIndex = remainingText.firstIndex(where: { $0.isNewline || $0.isWhitespace || [".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "\"", "'", "<"].contains($0) }) {
                                let endOffset = remainingText.distance(from: remainingText.startIndex, to: endIndex)
                                urlEnd = foundRange.location + foundRange.length + endOffset
                            }
                        }
                    }
                    
                    // Ensure urlEnd is valid
                    guard urlEnd > foundRange.location && urlEnd <= text.count else {
                        searchRange = NSRange(location: foundRange.location + foundRange.length, length: text.count - (foundRange.location + foundRange.length))
                        continue
                    }
                    
                    // Extract the URL using NSRange
                    let urlRange = NSRange(location: foundRange.location, length: urlEnd - foundRange.location)
                    var url = (text as NSString).substring(with: urlRange)
                    url = cleanUrl(url)
                    
                    // Add https:// prefix
                    let finalUrl = "https://" + url
                    
                    // Skip if it's an image URL
                    if isImageURL(finalUrl) {
                        searchRange = NSRange(location: foundRange.location + foundRange.length, length: text.count - (foundRange.location + foundRange.length))
                        continue
                    }
                    
                    // Skip if it's embedded in an image tag
                    if isEmbeddedInImageTag(finalUrl, htmlText: text) {
                        searchRange = NSRange(location: foundRange.location + foundRange.length, length: text.count - (foundRange.location + foundRange.length))
                        continue
                    }
                    
                    let normalized = normalizeUrlForDedup(finalUrl)
                    if !seenNormalizedLinks.contains(normalized) {
                        links.append(finalUrl)
                        seenNormalizedLinks.insert(normalized)
                        linkMap[normalized] = finalUrl
                    } else {
                        // If we've seen this URL before, prefer HTTPS over HTTP
                        // (finalUrl is always HTTPS, so this should replace any HTTP version)
                        if let existingUrl = linkMap[normalized] {
                            let existingPrefersHttps = existingUrl.lowercased().hasPrefix("https://")
                            if !existingPrefersHttps {
                                // Replace HTTP with HTTPS version
                                if let index = links.firstIndex(of: existingUrl) {
                                    links[index] = finalUrl
                                    linkMap[normalized] = finalUrl
                                }
                            }
                        }
                    }
                }
                
                // Continue searching after this match
                searchRange = NSRange(location: foundRange.location + foundRange.length, length: text.count - (foundRange.location + foundRange.length))
            }
        }
        
        return links
    }
    
    /// Clean up a URL by removing trailing characters that shouldn't be part of the URL
    private static func cleanUrl(_ url: String) -> String {
        // Remove all newlines, carriage returns, and other control characters first
        var cleaned = url.replacingOccurrences(of: "\r\n", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\n", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove any content after newline-like characters or signature markers
        if let newlineIndex = cleaned.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) {
            cleaned = String(cleaned[..<newlineIndex])
        }
        
        // Remove signature markers (common email signature patterns)
        if let dashIndex = cleaned.range(of: "-- ") {
            cleaned = String(cleaned[..<dashIndex.lowerBound])
        }
        
        // Remove trailing punctuation that might have been captured
        while let lastChar = cleaned.last, 
              [".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "\"", "'", "<"].contains(lastChar) {
            cleaned = String(cleaned.dropLast())
        }
        
        // Final trim
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
}

