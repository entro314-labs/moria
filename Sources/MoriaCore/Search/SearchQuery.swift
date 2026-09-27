import Foundation

/// A parsed search: free-text terms plus metadata filters.
///
/// Built by `QueryParser` from the query syntax, by the filter sidebar, or by the
/// natural-language parser; all three produce the same structure.
public struct SearchQuery: Sendable, Equatable {
    /// Must each appear in the file name, or each appear in the content.
    public var terms: [String] = []
    /// Exact phrases (content, or name for single words).
    public var phrases: [String] = []
    /// `name:` terms, matched against file names only.
    public var nameTerms: [String] = []
    /// `content:` terms, matched against extracted text only.
    public var contentTerms: [String] = []
    /// `-term`: files whose name or content contains it are dropped.
    public var excludedTerms: [String] = []
    public var extensions: Set<String> = []
    public var kinds: Set<FileKind> = []
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modified: DateInterval?
    public var created: DateInterval?
    /// `in:` folders; a result must be inside one of them.
    public var folders: [String] = []
    /// nil = don't care.
    public var hidden: Bool?
    public var cloudOnly: Bool?

    public init() {}

    public var hasTextCriteria: Bool {
        !terms.isEmpty || !phrases.isEmpty || !nameTerms.isEmpty || !contentTerms.isEmpty
    }

    public var hasFilters: Bool {
        !extensions.isEmpty || !kinds.isEmpty || minSize != nil || maxSize != nil || modified != nil
            || created != nil || !folders.isEmpty || hidden != nil || cloudOnly != nil
    }

    public var isEmpty: Bool {
        !hasTextCriteria && !hasFilters && excludedTerms.isEmpty
    }

    /// The words a semantic query should embed.
    public var semanticText: String {
        (terms + phrases + contentTerms).joined(separator: " ")
    }
}

/// Parses the query syntax:
///
///     invoice "rent receipt" -draft ext:pdf,docx kind:image size:>10mb size:1mb..5mb
///     modified:<7d modified:2026-03..2026-05 created:today in:~/Documents name:2024
///     content:lease hidden:no cloud:no
///
/// Unknown `key:value` tokens are treated as plain terms so URLs and times still search.
public struct QueryParser: Sendable {
    public var now: Date
    public var calendar: Calendar
    public var home: String

    public init(now: Date = Date(), calendar: Calendar = .current, home: String = NSHomeDirectory()) {
        self.now = now
        self.calendar = calendar
        self.home = home
    }

    public func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        for token in Self.tokenize(input) {
            if token.quoted {
                query.phrases.append(token.text)
                continue
            }
            let text = token.text
            if text.hasPrefix("-"), text.count > 1 {
                query.excludedTerms.append(String(text.dropFirst()))
                continue
            }
            if let colon = text.firstIndex(of: ":"), colon != text.startIndex {
                let key = text[..<colon].lowercased()
                let value = String(text[text.index(after: colon)...])
                if !value.isEmpty, apply(key: key, value: value, to: &query) { continue }
            }
            query.terms.append(text)
        }
        return query
    }

    /// Applies a filter token. Returns false if the key or value isn't recognized.
    private func apply(key: String, value: String, to query: inout SearchQuery) -> Bool {
        switch key {
        case "ext", "extension", "type":
            let exts = value.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            query.extensions.formUnion(exts.filter { !$0.isEmpty })
            return true
        case "kind":
            let kinds = value.split(separator: ",").compactMap { Self.kind(named: $0.lowercased()) }
            guard !kinds.isEmpty else { return false }
            query.kinds.formUnion(kinds)
            return true
        case "size":
            guard let (min, max) = parseSize(value) else { return false }
            if let min { query.minSize = min }
            if let max { query.maxSize = max }
            return true
        case "modified", "mod", "date":
            guard let interval = parseDate(value) else { return false }
            query.modified = interval
            return true
        case "created":
            guard let interval = parseDate(value) else { return false }
            query.created = interval
            return true
        case "in", "path", "folder":
            query.folders.append(expand(value))
            return true
        case "name":
            query.nameTerms.append(value)
            return true
        case "content", "text":
            query.contentTerms.append(value)
            return true
        case "hidden":
            guard let flag = Self.bool(value) else { return false }
            query.hidden = flag
            return true
        case "cloud":
            guard let flag = Self.bool(value) else { return false }
            query.cloudOnly = flag
            return true
        default:
            return false
        }
    }

    // MARK: - Values

    static func kind(named name: some StringProtocol) -> FileKind? {
        switch name {
        case "folder", "dir", "directory": .folder
        case "app", "application": .application
        case "doc", "docs", "document": .document
        case "img", "image", "photo", "picture": .image
        case "music", "sound": .audio
        case "movie", "film": .video
        case "zip": .archive
        case "source", "script": .code
        default: FileKind(rawValue: String(name))
        }
    }

    private static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "yes", "true", "1", "only": true
        case "no", "false", "0": false
        default: nil
        }
    }

    private func expand(_ path: String) -> String {
        var expanded = path.hasPrefix("~") ? home + path.dropFirst() : path
        while expanded.count > 1, expanded.hasSuffix("/") { expanded.removeLast() }
        return expanded
    }

    /// `>10mb`, `<1k`, `>=2gb`, `1mb..5mb`, `500kb`
    func parseSize(_ value: String) -> (Int64?, Int64?)? {
        if let range = value.range(of: "..") {
            let low = Self.bytes(String(value[..<range.lowerBound]))
            let high = Self.bytes(String(value[range.upperBound...]))
            guard low != nil || high != nil else { return nil }
            return (low, high)
        }
        var text = Substring(value)
        var comparison = "="
        for op in [">=", "<=", ">", "<"] where text.hasPrefix(op) {
            comparison = op
            text = text.dropFirst(op.count)
            break
        }
        guard let bytes = Self.bytes(String(text)) else { return nil }
        switch comparison {
        case ">", ">=": return (bytes, nil)
        case "<", "<=": return (nil, bytes)
        default:
            // A bare size means "about this size": ±10%.
            return (bytes * 9 / 10, bytes * 11 / 10)
        }
    }

    static func bytes(_ text: String) -> Int64? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [
            ("gb", 1_073_741_824), ("g", 1_073_741_824), ("mb", 1_048_576), ("m", 1_048_576),
            ("kb", 1024), ("k", 1024), ("b", 1),
        ]
        for (suffix, multiplier) in units where lower.hasSuffix(suffix) {
            guard let number = Double(lower.dropLast(suffix.count)) else { return nil }
            return Int64(number * multiplier)
        }
        return Double(lower).map { Int64($0) }
    }

    /// `today`, `yesterday`, `week`, `month`, `year`, `<7d`, `>2w`, `<3m`, `>1y`,
    /// `2026`, `2026-03`, `2026-03-15`, ranges `2026-03..2026-05`, `>2026-01-01`, `<2025`.
    func parseDate(_ value: String) -> DateInterval? {
        let lower = value.lowercased()
        let startOfToday = calendar.startOfDay(for: now)
        switch lower {
        case "today": return DateInterval(start: startOfToday, end: now.addingTimeInterval(1))
        case "yesterday":
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            return DateInterval(start: start, end: startOfToday)
        case "week", "thisweek": return interval(back: .day, 7)
        case "month", "thismonth": return interval(back: .month, 1)
        case "year", "thisyear": return interval(back: .year, 1)
        default: break
        }
        if let range = lower.range(of: "..") {
            let low = datePeriod(String(lower[..<range.lowerBound]))
            let high = datePeriod(String(lower[range.upperBound...]))
            guard low != nil || high != nil else { return nil }
            let start = low?.start ?? .distantPast
            let end = high?.end ?? now.addingTimeInterval(1)
            return end > start ? DateInterval(start: start, end: end) : nil
        }
        for op in ["<", ">"] where lower.hasPrefix(op) {
            let rest = String(lower.dropFirst())
            if let relative = relativeAmount(rest) {
                // "<7d": within the last 7 days. ">7d": older than 7 days.
                let boundary = calendar.date(byAdding: relative.unit, value: -relative.amount, to: now)!
                return op == "<" ? DateInterval(start: boundary, end: now.addingTimeInterval(1))
                    : DateInterval(start: .distantPast, end: boundary)
            }
            guard let period = datePeriod(rest) else { return nil }
            // "<2026-03": before March 2026. ">2026-03": after March 2026.
            return op == "<" ? DateInterval(start: .distantPast, end: period.start)
                : DateInterval(start: period.end, end: .distantFuture)
        }
        if let relative = relativeAmount(lower) {
            return interval(back: relative.unit, relative.amount)
        }
        return datePeriod(lower)
    }

    private func interval(back unit: Calendar.Component, _ amount: Int) -> DateInterval {
        DateInterval(start: calendar.date(byAdding: unit, value: -amount, to: now)!, end: now.addingTimeInterval(1))
    }

    /// `7d`, `2w`, `3m`, `1y`, `12h`
    private func relativeAmount(_ text: String) -> (unit: Calendar.Component, amount: Int)? {
        guard let last = text.last, let amount = Int(text.dropLast()), amount >= 0 else { return nil }
        switch last {
        case "h": return (.hour, amount)
        case "d": return (.day, amount)
        case "w": return (.day, amount * 7)
        case "m": return (.month, amount)
        case "y": return (.year, amount)
        default: return nil
        }
    }

    /// A calendar year, month or day: `2026`, `2026-03`, `2026-03-15`.
    func datePeriod(_ text: String) -> DateInterval? {
        let parts = text.split(separator: "-").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.map { $0! }
        guard (1900...2200).contains(numbers[0]) else { return nil }
        var components = DateComponents(year: numbers[0], month: 1, day: 1)
        let unit: Calendar.Component
        switch numbers.count {
        case 1: unit = .year
        case 2:
            guard (1...12).contains(numbers[1]) else { return nil }
            components.month = numbers[1]
            unit = .month
        default:
            guard (1...12).contains(numbers[1]), (1...31).contains(numbers[2]) else { return nil }
            components.month = numbers[1]
            components.day = numbers[2]
            unit = .day
        }
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: unit, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }

    // MARK: - Tokenizer

    struct Token: Equatable {
        var text: String
        var quoted: Bool
    }

    /// Splits on whitespace, keeping `"quoted phrases"` and `key:"quoted values"` together.
    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        var quotedToken = false
        func flush() {
            let text = current.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { tokens.append(Token(text: text, quoted: quotedToken)) }
            current = ""
            quotedToken = false
        }
        for char in input {
            if char == "\"" || char == "“" || char == "”" {
                if inQuotes {
                    inQuotes = false
                } else {
                    inQuotes = true
                    if current.isEmpty { quotedToken = true }
                }
            } else if char.isWhitespace, !inQuotes {
                flush()
            } else {
                current.append(char)
            }
        }
        flush()
        return tokens
    }
}
