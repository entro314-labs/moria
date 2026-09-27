import Foundation

/// Renders a `SearchQuery` back into query syntax that `QueryParser` accepts, so an
/// interpreted plain-language request can be shown and edited as an ordinary query.
public struct QueryFormatter: Sendable {
    public var calendar: Calendar
    public var home: String

    public init(calendar: Calendar = .current, home: String = NSHomeDirectory()) {
        self.calendar = calendar
        self.home = home
    }

    public func string(from query: SearchQuery) -> String {
        var parts: [String] = []
        parts += query.terms.map(quotedIfNeeded)
        parts += query.phrases.map { "\"\($0)\"" }
        parts += query.nameTerms.map { "name:" + quotedIfNeeded($0) }
        parts += query.namePatterns.map { "name:" + quotedIfNeeded($0.syntax) }
        parts += query.pathContains.map { "path:" + quotedIfNeeded($0) }
        parts += query.contentTerms.map { "content:" + quotedIfNeeded($0) }
        parts += query.excludedTerms.map { "-" + $0 }
        if !query.extensions.isEmpty { parts.append("ext:" + query.extensions.sorted().joined(separator: ",")) }
        if !query.excludedExtensions.isEmpty { parts.append("-ext:" + query.excludedExtensions.sorted().joined(separator: ",")) }
        if !query.kinds.isEmpty { parts.append("kind:" + query.kinds.map(\.rawValue).sorted().joined(separator: ",")) }
        if !query.excludedKinds.isEmpty { parts.append("-kind:" + query.excludedKinds.map(\.rawValue).sorted().joined(separator: ",")) }
        switch (query.minSize, query.maxSize) {
        case let (min?, max?): parts.append("size:\(bytes(min))..\(bytes(max))")
        case let (min?, nil): parts.append("size:>\(bytes(min))")
        case let (nil, max?): parts.append("size:<\(bytes(max))")
        case (nil, nil): break
        }
        if let modified = query.modified { parts.append("modified:" + dates(modified)) }
        if let created = query.created { parts.append("created:" + dates(created)) }
        parts += query.folders.map { "in:" + quotedIfNeeded(abbreviate($0)) }
        parts += query.excludedFolders.map { "-in:" + quotedIfNeeded(abbreviate($0)) }
        if let hidden = query.hidden { parts.append("hidden:" + (hidden ? "yes" : "no")) }
        if let cloud = query.cloudOnly { parts.append("cloud:" + (cloud ? "yes" : "no")) }
        return parts.joined(separator: " ")
    }

    private func abbreviate(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func quotedIfNeeded(_ text: String) -> String {
        text.contains(where: \.isWhitespace) ? "\"\(text)\"" : text
    }

    private func bytes(_ value: Int64) -> String {
        for (unit, size) in [("gb", Int64(1_073_741_824)), ("mb", 1_048_576), ("kb", 1024)] where value >= size {
            let amount = Double(value) / Double(size)
            return (amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)) + unit
        }
        return String(value)
    }

    /// `YYYY-MM-DD..YYYY-MM-DD` with an inclusive end day; open ends use `<`/`>`.
    private func dates(_ interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let lastDay = calendar.date(byAdding: .second, value: -1, to: interval.end) ?? interval.end
        if interval.start == .distantPast { return "<" + formatter.string(from: interval.end) }
        if interval.end == .distantFuture { return ">" + formatter.string(from: calendar.date(byAdding: .day, value: -1, to: interval.start)!) }
        return formatter.string(from: interval.start) + ".." + formatter.string(from: lastDay)
    }
}
