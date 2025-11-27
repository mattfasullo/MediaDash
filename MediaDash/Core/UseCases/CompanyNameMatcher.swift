import Foundation

// MARK: - Company Name Matcher

/// Utility for fuzzy matching company names against a cache
struct CompanyNameMatcher {
    let companyNames: [String]
    let confidenceThreshold: Double
    
    init(companyNames: [String], confidenceThreshold: Double = 0.75) {
        self.companyNames = companyNames
        self.confidenceThreshold = confidenceThreshold
    }
    
    /// Find the best matching company name in the given text
    /// - Parameter text: The text to search (email subject + body)
    /// - Returns: Best matching company name and confidence score, or nil if no good match
    func findBestMatch(in text: String) -> (name: String, confidence: Double)? {
        guard !companyNames.isEmpty else { return nil }
        
        let tokens = tokenize(text)
        var bestMatch: (name: String, confidence: Double)? = nil
        
        // Try exact matches first
        for companyName in companyNames {
            let lowerCompany = companyName.lowercased()
            let lowerText = text.lowercased()
            
            // Exact match (case-insensitive)
            if lowerText.contains(lowerCompany) {
                return (companyName, 1.0)
            }
            
            // Try matching individual words
            let companyWords = companyName.components(separatedBy: .whitespaces)
            if companyWords.count > 1 {
                // Multi-word company name - check if all words appear in text
                let allWordsFound = companyWords.allSatisfy { word in
                    let lowerWord = word.lowercased()
                    return lowerText.contains(lowerWord) || 
                           tokens.contains { $0.lowercased() == lowerWord }
                }
                if allWordsFound {
                    return (companyName, 0.95)
                }
            }
        }
        
        // Try fuzzy matching against tokens
        for token in tokens {
            guard token.count >= 3 else { continue } // Skip very short tokens
            
            for companyName in companyNames {
                let confidence = calculateConfidence(token: token, companyName: companyName)
                
                if confidence >= confidenceThreshold {
                    if let existing = bestMatch {
                        if confidence > existing.confidence {
                            bestMatch = (companyName, confidence)
                        }
                    } else {
                        bestMatch = (companyName, confidence)
                    }
                }
            }
        }
        
        // Also try fuzzy matching against the full text (for multi-word companies)
        for companyName in companyNames {
            let words = companyName.components(separatedBy: .whitespaces)
            if words.count > 1 {
                // Calculate average confidence across all words
                var totalConfidence = 0.0
                var matchedWords = 0
                
                for word in words {
                    guard word.count >= 3 else { continue }
                    var bestWordConfidence = 0.0
                    
                    for token in tokens {
                        let confidence = calculateConfidence(token: token, companyName: word)
                        bestWordConfidence = max(bestWordConfidence, confidence)
                    }
                    
                    if bestWordConfidence >= 0.6 {
                        totalConfidence += bestWordConfidence
                        matchedWords += 1
                    }
                }
                
                if matchedWords == words.count {
                    let avgConfidence = totalConfidence / Double(matchedWords)
                    if avgConfidence >= confidenceThreshold {
                        if let existing = bestMatch {
                            if avgConfidence > existing.confidence {
                                bestMatch = (companyName, avgConfidence)
                            }
                        } else {
                            bestMatch = (companyName, avgConfidence)
                        }
                    }
                }
            }
        }
        
        return bestMatch
    }
    
    /// Tokenize text into words and phrases
    private func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        
        // Split by whitespace and punctuation
        let words = text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .filter { !$0.isEmpty && $0.count >= 2 }
        
        tokens.append(contentsOf: words)
        
        // Also create 2-word and 3-word phrases
        for i in 0..<words.count {
            if i + 1 < words.count {
                tokens.append("\(words[i]) \(words[i + 1])")
            }
            if i + 2 < words.count {
                tokens.append("\(words[i]) \(words[i + 1]) \(words[i + 2])")
            }
        }
        
        return tokens
    }
    
    /// Calculate confidence score between a token and company name
    private func calculateConfidence(token: String, companyName: String) -> Double {
        let tokenLower = token.lowercased()
        let companyLower = companyName.lowercased()
        
        // Exact match
        if tokenLower == companyLower {
            return 1.0
        }
        
        // Substring match
        if companyLower.contains(tokenLower) || tokenLower.contains(companyLower) {
            let longer = max(tokenLower.count, companyLower.count)
            let shorter = min(tokenLower.count, companyLower.count)
            return Double(shorter) / Double(longer)
        }
        
        // Levenshtein distance
        let distance = MediaLogic.levenshteinDistance(tokenLower, companyLower)
        let maxLength = max(tokenLower.count, companyLower.count)
        
        if maxLength == 0 {
            return 0.0
        }
        
        let similarity = 1.0 - (Double(distance) / Double(maxLength))
        return max(0.0, similarity)
    }
}

