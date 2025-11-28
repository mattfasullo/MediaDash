import Foundation

/// Service to fetch random images from Reddit subreddits
@MainActor
class RedditImageService {
    
    /// Known NSFW subreddits that should be excluded
    private static let nsfwSubreddits: Set<String> = [
        "nsfw", "gonewild", "realgirls", "nsfw_gif", "porn", "sex", "nsfw2",
        "nsfw411", "nsfwcosplay", "nsfwoutfits", "nsfw_hardcore", "nsfw_softcore"
    ]
    
    /// Fetch a random image URL from the specified subreddit
    /// - Parameter subreddit: Name of the subreddit (without r/ prefix)
    /// - Returns: URL of a random image post, or nil if no image found
    func fetchRandomImageURL(from subreddit: String) async throws -> URL? {
        // Validate subreddit name
        let cleanSubreddit = subreddit.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "r/", with: "")
            .replacingOccurrences(of: "/", with: "")
        
        guard !cleanSubreddit.isEmpty else {
            throw RedditImageError.invalidSubreddit("Subreddit name cannot be empty")
        }
        
        // Check if subreddit is NSFW
        if Self.nsfwSubreddits.contains(cleanSubreddit) {
            throw RedditImageError.nsfwSubreddit("NSFW subreddits are not allowed")
        }
        
        // Try to fetch a random post from the subreddit
        // Reddit's random.json endpoint returns a random post
        let urlString = "https://www.reddit.com/r/\(cleanSubreddit)/random.json"
        guard let url = URL(string: urlString) else {
            throw RedditImageError.invalidSubreddit("Invalid subreddit name: \(cleanSubreddit)")
        }
        
        var request = URLRequest(url: url)
        request.setValue("MediaDash/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RedditImageError.networkError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw RedditImageError.subredditNotFound("Subreddit '\(cleanSubreddit)' not found or is private")
            }
            throw RedditImageError.networkError("HTTP \(httpResponse.statusCode)")
        }
        
        // Parse JSON response
        // Reddit's random.json returns an array with one listing containing one post
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let listing = jsonArray.first,
              let dataDict = listing["data"] as? [String: Any],
              let children = dataDict["children"] as? [[String: Any]],
              let firstChild = children.first,
              let postData = firstChild["data"] as? [String: Any] else {
            throw RedditImageError.parseError("Failed to parse Reddit response")
        }
        
        // Check if post is NSFW (over18 flag)
        if let over18 = postData["over_18"] as? Bool, over18 {
            throw RedditImageError.nsfwContent("Post is marked as NSFW")
        }
        
        // Extract image URL from post
        // Reddit posts can have images in several formats:
        // 1. Direct image URL in 'url' field (for image posts)
        // 2. Preview images in 'preview' -> 'images' -> 'source' -> 'url'
        // 3. Thumbnail in 'thumbnail' field
        
        // First, try to get direct image URL
        if let urlString = postData["url"] as? String,
           let imageURL = URL(string: urlString),
           isImageURL(urlString) {
            return imageURL
        }
        
        // Try preview images
        if let preview = postData["preview"] as? [String: Any],
           let images = preview["images"] as? [[String: Any]],
           let firstImage = images.first,
           let source = firstImage["source"] as? [String: Any],
           let urlString = source["url"] as? String {
            // Reddit preview URLs are HTML-encoded, decode them
            let decodedURLString = urlString.replacingOccurrences(of: "&amp;", with: "&")
            if let imageURL = URL(string: decodedURLString) {
                return imageURL
            }
        }
        
        // Try thumbnail (usually lower quality, but better than nothing)
        if let thumbnail = postData["thumbnail"] as? String,
           thumbnail.hasPrefix("http"),
           let imageURL = URL(string: thumbnail),
           isImageURL(thumbnail) {
            return imageURL
        }
        
        // No image found in this post
        throw RedditImageError.noImageFound("No image found in post")
    }
    
    /// Check if a URL points to an image
    private func isImageURL(_ urlString: String) -> Bool {
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg"]
        let lowercased = urlString.lowercased()
        return imageExtensions.contains { lowercased.hasSuffix(".\($0)") } ||
               lowercased.contains("i.redd.it") ||
               lowercased.contains("preview.redd.it") ||
               lowercased.contains("redd.it")
    }
    
    /// Fetch a random image URL with retries (tries multiple times if NSFW content is found)
    /// - Parameters:
    ///   - subreddit: Name of the subreddit
    ///   - maxRetries: Maximum number of retries (default: 3)
    /// - Returns: URL of a random image post
    func fetchRandomImageURLWithRetry(from subreddit: String, maxRetries: Int = 3) async throws -> URL? {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                if let url = try await fetchRandomImageURL(from: subreddit) {
                    return url
                }
            } catch RedditImageError.nsfwContent(let message) {
                // If we hit NSFW content, try again
                lastError = RedditImageError.nsfwContent(message)
                if attempt < maxRetries {
                    // Small delay before retry
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    continue
                }
            } catch {
                // For other errors, throw immediately
                throw error
            }
        }
        
        // If we exhausted retries, throw the last error
        throw lastError ?? RedditImageError.noImageFound("Failed to find suitable image after \(maxRetries) attempts")
    }
}

// MARK: - Errors

enum RedditImageError: LocalizedError {
    case invalidSubreddit(String)
    case nsfwSubreddit(String)
    case subredditNotFound(String)
    case networkError(String)
    case parseError(String)
    case nsfwContent(String)
    case noImageFound(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidSubreddit(let message):
            return "Invalid subreddit: \(message)"
        case .nsfwSubreddit(let message):
            return "NSFW subreddit not allowed: \(message)"
        case .subredditNotFound(let message):
            return "Subreddit not found: \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .nsfwContent(let message):
            return "NSFW content: \(message)"
        case .noImageFound(let message):
            return "No image found: \(message)"
        }
    }
}

