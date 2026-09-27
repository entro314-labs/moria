import Foundation

/// Builds a short excerpt around the first match of any search term, with every match in the
/// excerpt wrapped in `SearchResult.highlightStart`/`highlightEnd`.
///
/// Matching is case- and diacritic-insensitive to agree with the index's folding tokenizer.
enum Snippet {
    /// Context before the first match; kept short so the match stays visible when the
    /// excerpt is truncated to one line.
    static let leading = 36
    static let trailing = 160

    static func make(from text: String, terms: [String]) -> String? {
        var terms = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var first = terms.compactMap { text.range(of: $0, options: options) }.min { $0.lowerBound < $1.lowerBound }
        if first == nil {
            // The index stems English words; highlight the stem ("invoices" -> "invoic").
            terms = terms.map(stem)
            first = terms.compactMap { text.range(of: $0, options: options) }.min { $0.lowerBound < $1.lowerBound }
        }
        guard let first else { return nil }

        var start = text.index(first.lowerBound, offsetBy: -leading, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(first.upperBound, offsetBy: trailing, limitedBy: text.endIndex) ?? text.endIndex
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

    /// Lines containing any term (or its stem), highlighted and clipped around the first match,
    /// with the total number of matching lines.
    static func matchingLines(in text: String, terms: [String], limit: Int) -> (count: Int, lines: [MatchLine]) {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let words = terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return (0, []) }
        let candidates = [words, words.map(stem)]
        var count = 0
        var lines: [MatchLine] = []
        var number = 0
        text.enumerateLines { line, _ in
            number += 1
            guard let active = candidates.first(where: { set in set.contains { line.range(of: $0, options: options) != nil } }) else { return }
            count += 1
            if lines.count < limit, let highlighted = make(from: line, terms: active) {
                lines.append(MatchLine(number: number, text: highlighted))
            }
        }
        return (count, lines)
    }

    /// Strips common English inflections, approximating the index's Porter stemmer.
    static func stem(_ word: String) -> String {
        let lower = word.lowercased()
        for suffix in ["ies", "es", "s", "ing", "ed", "ly"] where lower.hasSuffix(suffix) && lower.count > suffix.count + 3 {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// The opening words of a text, for results that matched by meaning rather than words.
    static func lead(of text: String, words: Int = 30) -> String? {
        let lead = text.split(whereSeparator: \.isWhitespace).prefix(words).joined(separator: " ")
        return lead.isEmpty ? nil : lead + "…"
    }
}
