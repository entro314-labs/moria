import Foundation

/// Builds a short excerpt around the first match of any search term, with every match in the
/// excerpt wrapped in `SearchResult.highlightStart`/`highlightEnd`.
///
/// Matching is case- and diacritic-insensitive to agree with the index's folding tokenizer.
enum Snippet {
    static let radius = 90

    static func make(from text: String, terms: [String]) -> String? {
        let terms = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let first = terms.compactMap { text.range(of: $0, options: options) }.min { $0.lowerBound < $1.lowerBound }
        guard let first else { return nil }

        var start = text.index(first.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(first.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        // Snap to word boundaries so the excerpt doesn't start or end mid-word.
        if start > text.startIndex, let space = text[start..<first.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        if end < text.endIndex, let space = text[first.upperBound..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        let window = text[start..<end]

        var result = start > text.startIndex ? "…" : ""
        var cursor = window.startIndex
        while cursor < window.endIndex {
            let next = terms.compactMap { window.range(of: $0, options: options, range: cursor..<window.endIndex) }
                .min { $0.lowerBound < $1.lowerBound }
            guard let next else { break }
            result += window[cursor..<next.lowerBound]
            result.append(SearchResult.highlightStart)
            result += window[next]
            result.append(SearchResult.highlightEnd)
            cursor = next.upperBound
        }
        result += window[cursor...]
        if end < text.endIndex { result += "…" }
        return result.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// The opening words of a text, for results that matched by meaning rather than words.
    static func lead(of text: String, words: Int = 30) -> String? {
        let lead = text.split(whereSeparator: \.isWhitespace).prefix(words).joined(separator: " ")
        return lead.isEmpty ? nil : lead + "…"
    }
}
