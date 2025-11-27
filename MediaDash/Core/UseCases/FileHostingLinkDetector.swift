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
    
    /// Check if email body contains file hosting links
    static func containsFileHostingLink(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        
        // Check for common URL patterns
        for domain in hostingDomains {
            if lowercased.contains(domain) {
                return true
            }
        }
        
        // Also check for common link patterns
        let urlPatterns = [
            #"https?://[^\s]+\.(drive|docs|frame|wetransfer|dropbox|onedrive|sharepoint|box|hightail|sendspace|mediafire|mega|pcloud|icloud)"#,
            #"https?://[^\s]+/(drive|docs|frame|wetransfer|dropbox|onedrive|sharepoint|box|hightail|sendspace|mediafire|mega|pcloud|icloud)"#
        ]
        
        for pattern in urlPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        
        return false
    }
    
    /// Extract file hosting links from email body
    static func extractFileHostingLinks(_ text: String) -> [String] {
        var links: [String] = []
        
        // Pattern to match URLs
        let urlPattern = #"https?://[^\s<>"']+"#
        
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            
            for match in matches {
                if let urlRange = Range(match.range, in: text) {
                    let url = String(text[urlRange])
                    let urlLowercased = url.lowercased()
                    
                    // Check if URL contains any hosting domain
                    for domain in hostingDomains {
                        if urlLowercased.contains(domain) {
                            links.append(url)
                            break
                        }
                    }
                }
            }
        }
        
        return links
    }
}

