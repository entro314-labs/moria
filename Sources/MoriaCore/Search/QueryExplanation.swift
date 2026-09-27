import Foundation

/// One filter in a query, described in plain words for the chip bar ("PDF", "Modified in the
/// past 7 days", "Not in Library").
public struct QueryChip: Sendable, Equatable, Identifiable {
    /// Index of the token in the query text; pass it to `QueryParser.removingToken(at:from:)`.
    public var tokenIndex: Int
    public var label: String
    public var symbol: String
    /// True for exclusions (drawn differently).
    public var isExclusion: Bool

    public var id: Int { tokenIndex }
}

extension QueryParser {
    /// Chips for the filters and exclusions typed in `input`. Plain words and phrases are not
    /// chips: they're already visible as text.
    public func chips(for input: String) -> [QueryChip] {
        Self.tokenize(input).enumerated().compactMap { index, token in
            guard !token.quoted else { return nil }
            return describe(parse(tokens: [token]), tokenIndex: index)
        }
    }

    /// The query text without the token at `index`, keeping every other token as typed.
    public func removingToken(at index: Int, from input: String) -> String {
        Self.tokenize(input).enumerated()
            .filter { $0.offset != index }
            .map { _, token in
                if token.quoted { return "\"\(token.text)\"" }
                // Re-quote values with spaces: in:"~/My Files".
                if token.text.contains(where: \.isWhitespace), let colon = token.text.firstIndex(of: ":") {
                    return token.text[...colon] + "\"" + token.text[token.text.index(after: colon)...] + "\""
                }
                return token.text
            }
            .joined(separator: " ")
    }

    private func describe(_ query: SearchQuery, tokenIndex: Int) -> QueryChip? {
        func chip(_ label: String, _ symbol: String, exclusion: Bool = false) -> QueryChip {
            QueryChip(tokenIndex: tokenIndex, label: label, symbol: symbol, isExclusion: exclusion)
        }
        if !query.kinds.isEmpty {
            return chip(query.kinds.map(\.displayName).sorted().joined(separator: ", "), "square.grid.2x2")
        }
        if !query.excludedKinds.isEmpty {
            return chip("No " + query.excludedKinds.map(\.displayName).sorted().joined(separator: ", "), "square.grid.2x2", exclusion: true)
        }
        if !query.extensions.isEmpty {
            return chip(query.extensions.sorted().map { "." + $0 }.joined(separator: ", "), "doc")
        }
        if query.minSize != nil || query.maxSize != nil {
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            let label = switch (query.minSize, query.maxSize) {
            case let (min?, max?): "\(format(min)) – \(format(max))"
            case let (min?, nil): "Over \(format(min))"
            case let (nil, max?): "Under \(format(max))"
            case (nil, nil): ""
            }
            return chip(label, "scalemass")
        }
        if let modified = query.modified { return chip("Modified " + describe(modified), "calendar") }
        if let created = query.created { return chip("Created " + describe(created), "calendar.badge.plus") }
        if let folder = query.folders.first { return chip("In " + (folder as NSString).lastPathComponent, "folder") }
        if let folder = query.excludedFolders.first {
            return chip("Not in " + (folder as NSString).lastPathComponent, "folder.badge.minus", exclusion: true)
        }
        if let term = query.nameTerms.first { return chip("Name: " + term, "textformat") }
        if let term = query.contentTerms.first { return chip("Contents: " + term, "text.alignleft") }
        if let term = query.excludedTerms.first { return chip("Without “\(term)”", "minus.circle", exclusion: true) }
        if let hidden = query.hidden { return chip(hidden ? "Only hidden files" : "No hidden files", "eye.slash") }
        if let cloud = query.cloudOnly { return chip(cloud ? "Only cloud-only files" : "Downloaded files only", "icloud") }
        return nil
    }

    /// "today", "in the past 7 days", "Mar 1 – May 31, 2026", "before 2025", "after Jan 15, 2026".
    func describe(_ interval: DateInterval) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        if interval.start == startOfToday, interval.end > now { return "today" }
        let dateOnly = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if interval.start == .distantPast { return "before " + interval.end.formatted(dateOnly) }
        if interval.end == .distantFuture { return "after " + interval.start.addingTimeInterval(-1).formatted(dateOnly) }
        if interval.end > now {
            let days = calendar.dateComponents([.day], from: interval.start, to: now).day ?? 0
            if days >= 1, days < 400 { return "in the past \(days) day\(days == 1 ? "" : "s")" }
        }
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: interval.start, to: interval.end.addingTimeInterval(-1))
    }
}
