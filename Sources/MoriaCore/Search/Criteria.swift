import Foundation

/// One row of the criteria builder: attribute, operator, value.
///
/// Every criterion maps to exactly one query token, so the builder, the typed query and saved
/// searches are the same thing. All rows must match (the query syntax has no OR across
/// different attributes; values within one row can list alternatives, e.g. `pdf, docx`).
public struct Criterion: Identifiable, Equatable, Sendable {
    public enum Attribute: String, CaseIterable, Identifiable, Sendable {
        case words, name, ext, contents, kind, path, folder, size, modified, created, hidden, cloud

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .words: "Name or Contents"
            case .name: "Name"
            case .ext: "Extension"
            case .contents: "Contents"
            case .kind: "Kind"
            case .path: "Path"
            case .folder: "Folder"
            case .size: "Size"
            case .modified: "Date Modified"
            case .created: "Date Created"
            case .hidden: "Hidden Files"
            case .cloud: "Cloud-Only Files"
            }
        }

        public var operators: [Operator] {
            switch self {
            case .words: [.contains, .containsPhrase, .doesNotContain]
            case .name: [.contains, .beginsWith, .endsWith, .isExactly, .matchesRegex]
            case .ext, .kind, .folder: [.is, .isNot]
            case .contents: [.contains, .containsPhrase]
            case .path: [.contains]
            case .size: [.greaterThan, .lessThan, .between]
            case .modified, .created: [.withinLast, .before, .after, .between, .on]
            case .hidden, .cloud: [.include, .exclude]
            }
        }
    }

    public enum Operator: String, CaseIterable, Sendable {
        case contains, containsPhrase, doesNotContain, beginsWith, endsWith, isExactly, matchesRegex
        case `is`, isNot, greaterThan, lessThan, between, withinLast, before, after, on, include, exclude

        public var title: String {
            switch self {
            case .contains: "contains"
            case .containsPhrase: "contains phrase"
            case .doesNotContain: "does not contain"
            case .beginsWith: "begins with"
            case .endsWith: "ends with"
            case .isExactly: "is exactly"
            case .matchesRegex: "matches regex"
            case .is: "is"
            case .isNot: "is not"
            case .greaterThan: "is larger than"
            case .lessThan: "is smaller than"
            case .between: "is between"
            case .withinLast: "is within the last"
            case .before: "is before"
            case .after: "is after"
            case .on: "is on"
            case .include: "only"
            case .exclude: "leave out"
            }
        }
    }

    public var id = UUID()
    public var attribute: Attribute
    public var op: Operator
    /// Text, number, kind name, folder path or `yyyy-MM-dd` date, depending on the attribute.
    public var value: String
    /// Upper bound for `between`.
    public var value2: String
    /// `kb`/`mb`/`gb` for sizes; `d`/`w`/`m`/`y` for "within the last".
    public var unit: String

    public init(attribute: Attribute, op: Operator? = nil, value: String = "", value2: String = "", unit: String = "") {
        self.attribute = attribute
        self.op = op ?? attribute.operators[0]
        self.value = value
        self.value2 = value2
        self.unit = unit.isEmpty ? Self.defaultUnit(for: attribute) : unit
    }

    static func defaultUnit(for attribute: Attribute) -> String {
        switch attribute {
        case .size: "mb"
        case .modified, .created: "d"
        default: ""
        }
    }

    public static func == (a: Criterion, b: Criterion) -> Bool {
        a.attribute == b.attribute && a.op == b.op && a.value == b.value && a.value2 == b.value2
            && (a.unit == b.unit || !a.usesUnit)
    }

    private var usesUnit: Bool {
        attribute == .size || (op == .withinLast)
    }

    /// The query token, or nil while the row is incomplete.
    public var token: String? {
        let value = value.trimmingCharacters(in: .whitespaces)
        func quoted(_ text: String) -> String { text.contains(where: \.isWhitespace) ? "\"\(text)\"" : text }
        switch (attribute, op) {
        case (.hidden, _), (.cloud, _):
            return "\(attribute == .hidden ? "hidden" : "cloud"):\(op == .include ? "yes" : "no")"
        default:
            break
        }
        guard !value.isEmpty else { return nil }
        switch (attribute, op) {
        case (.words, .contains): return value
        case (.words, .containsPhrase), (.contents, .containsPhrase):
            return attribute == .words ? "\"\(value)\"" : "content:\"\(value)\""
        case (.words, .doesNotContain): return "-" + quoted(value)
        case (.name, .contains): return "name:" + quoted(value)
        case (.name, .beginsWith): return "name:" + quoted(value + "*")
        case (.name, .endsWith): return "name:" + quoted("*" + value)
        case (.name, .isExactly): return "name:" + quoted("=" + value)
        case (.name, .matchesRegex): return "name:" + quoted("/" + value + "/")
        case (.contents, _): return "content:" + quoted(value)
        case (.ext, .is): return "ext:" + value.replacingOccurrences(of: " ", with: "")
        case (.ext, _): return "-ext:" + value.replacingOccurrences(of: " ", with: "")
        case (.kind, .is): return "kind:" + value
        case (.kind, _): return "-kind:" + value
        case (.path, _): return "path:" + quoted(value)
        case (.folder, .is): return "in:" + quoted(value)
        case (.folder, _): return "-in:" + quoted(value)
        case (.size, .greaterThan): return "size:>\(value)\(unit)"
        case (.size, .lessThan): return "size:<\(value)\(unit)"
        case (.size, _):
            let high = value2.trimmingCharacters(in: .whitespaces)
            return high.isEmpty ? nil : "size:\(value)\(unit)..\(high)\(unit)"
        case (.modified, _), (.created, _):
            let key = attribute == .modified ? "modified" : "created"
            switch op {
            case .withinLast: return "\(key):<\(value)\(unit)"
            case .before: return "\(key):<\(value)"
            case .after: return "\(key):>\(value)"
            case .on: return "\(key):\(value)"
            default:
                let high = value2.trimmingCharacters(in: .whitespaces)
                return high.isEmpty ? nil : "\(key):\(value)..\(high)"
            }
        default:
            return nil
        }
    }

    /// Joins complete criteria into query text.
    public static func query(from criteria: [Criterion]) -> String {
        criteria.compactMap(\.token).joined(separator: " ")
    }

    /// Criteria for existing query text; tokens that don't map to a row become
    /// "Name or Contents contains".
    public static func criteria(from text: String, home: String = NSHomeDirectory()) -> [Criterion] {
        QueryParser.tokenize(text).map { criterion(for: $0, home: home) }
    }

    private static func criterion(for token: QueryParser.Token, home: String) -> Criterion {
        if token.quoted { return Criterion(attribute: .words, op: .containsPhrase, value: token.text) }
        var text = token.text
        let negated = text.hasPrefix("-") && text.count > 1
        if negated { text.removeFirst() }
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else {
            return Criterion(attribute: .words, op: negated ? .doesNotContain : .contains, value: text)
        }
        let key = text[..<colon].lowercased()
        let value = String(text[text.index(after: colon)...])
        let fallback = Criterion(attribute: .words, op: negated ? .doesNotContain : .contains, value: token.text.replacingOccurrences(of: "-", with: "", options: .anchored))
        switch key {
        case "name" where !negated:
            switch NamePattern(syntax: value) {
            case let .prefix(text)?: return Criterion(attribute: .name, op: .beginsWith, value: text)
            case let .suffix(text)?: return Criterion(attribute: .name, op: .endsWith, value: text)
            case let .exact(text)?: return Criterion(attribute: .name, op: .isExactly, value: text)
            case let .regex(text)?: return Criterion(attribute: .name, op: .matchesRegex, value: text)
            case nil: return Criterion(attribute: .name, op: .contains, value: value)
            }
        case "ext", "extension", "type": return Criterion(attribute: .ext, op: negated ? .isNot : .is, value: value)
        case "kind": return Criterion(attribute: .kind, op: negated ? .isNot : .is, value: value)
        case "content", "text" where !negated:
            return Criterion(attribute: .contents, op: value.contains(" ") ? .containsPhrase : .contains, value: value)
        case "path" where !negated: return Criterion(attribute: .path, op: .contains, value: value)
        case "in", "folder":
            let expanded = value.hasPrefix("~") ? home + value.dropFirst() : value
            return Criterion(attribute: .folder, op: negated ? .isNot : .is, value: expanded)
        case "hidden", "cloud":
            let on = ["yes", "true", "1", "only"].contains(value.lowercased())
            return Criterion(attribute: key == "hidden" ? .hidden : .cloud, op: on ? .include : .exclude)
        case "size" where !negated:
            return sizeCriterion(value) ?? fallback
        case "modified", "mod", "date", "created":
            return dateCriterion(value, attribute: key == "created" ? .created : .modified) ?? fallback
        default:
            return fallback
        }
    }

    private static func splitUnit(_ text: String, units: [String]) -> (String, String)? {
        let lower = text.lowercased()
        for unit in units where lower.hasSuffix(unit) && Double(lower.dropLast(unit.count)) != nil {
            return (String(lower.dropLast(unit.count)), unit)
        }
        return nil
    }

    private static func sizeCriterion(_ value: String) -> Criterion? {
        let units = ["gb", "mb", "kb"]
        if let range = value.range(of: ".."),
           let low = splitUnit(String(value[..<range.lowerBound]), units: units),
           let high = splitUnit(String(value[range.upperBound...]), units: units) {
            return Criterion(attribute: .size, op: .between, value: low.0, value2: high.0, unit: low.1)
        }
        for (prefix, op) in [(">", Operator.greaterThan), ("<", .lessThan)] where value.hasPrefix(prefix) {
            if let (number, unit) = splitUnit(String(value.dropFirst()), units: units) {
                return Criterion(attribute: .size, op: op, value: number, unit: unit)
            }
        }
        return nil
    }

    private static func dateCriterion(_ value: String, attribute: Attribute) -> Criterion? {
        if value.hasPrefix("<"), let (number, unit) = splitUnit(String(value.dropFirst()), units: ["d", "w", "m", "y"]) {
            return Criterion(attribute: attribute, op: .withinLast, value: number, unit: unit)
        }
        let isDate = { (text: String) in text.range(of: #"^\d{4}(-\d{2}(-\d{2})?)?$"#, options: .regularExpression) != nil }
        if let range = value.range(of: ".."), isDate(String(value[..<range.lowerBound])), isDate(String(value[range.upperBound...])) {
            return Criterion(attribute: attribute, op: .between, value: String(value[..<range.lowerBound]),
                             value2: String(value[range.upperBound...]))
        }
        if value.hasPrefix("<"), isDate(String(value.dropFirst())) { return Criterion(attribute: attribute, op: .before, value: String(value.dropFirst())) }
        if value.hasPrefix(">"), isDate(String(value.dropFirst())) { return Criterion(attribute: attribute, op: .after, value: String(value.dropFirst())) }
        if isDate(value) { return Criterion(attribute: attribute, op: .on, value: value) }
        return nil
    }
}
