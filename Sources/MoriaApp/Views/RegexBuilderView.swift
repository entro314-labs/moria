import MoriaCore
import SwiftUI

/// Regex builder (⌥⌘R): compose a pattern from building blocks, test it on sample text with
/// live highlighting, read what it means, then search or save it.
struct RegexBuilderView: View {
    let model: SearchModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var pattern = ""
    @State private var sample = """
        Invoice INV-2026-0042 issued 2026-03-15 to anna@example.com
        Server 192.168.1.20 answered in 35 ms, see https://status.example.com
        Order #A-99812, total €1,249.00
        """
    @State private var caseSensitive = false
    @State private var saveName = ""
    @State private var askingName = false
    @FocusState private var patternFocused: Bool

    private static let tokens: [(label: String, insert: String, help: String)] = [
        ("Any character", ".", "any single character"),
        ("Digit", "\\d", "0–9"),
        ("Letter or digit", "\\w", "a word character"),
        ("Whitespace", "\\s", "space, tab or newline"),
        ("Word boundary", "\\b", "start or end of a word"),
        ("Line start", "^", "start of a line"),
        ("Line end", "$", "end of a line"),
        ("One or more", "+", "repeat the previous item"),
        ("Zero or more", "*", "repeat, or nothing"),
        ("Optional", "?", "the previous item may be missing"),
        ("Exactly n", "{4}", "repeat exactly 4 times"),
        ("Either", "(a|b)", "one of the alternatives"),
        ("One of", "[abc]", "any listed character"),
        ("Not one of", "[^abc]", "any character except these"),
    ]

    private static let recipes: [(name: String, pattern: String)] = [
        ("Email address", #"[\w.+-]+@[\w-]+\.[\w.]+"#),
        ("Web address", #"https?://[^\s"'<>]+"#),
        ("Date (2026-03-15)", #"\b\d{4}-\d{2}-\d{2}\b"#),
        ("Date (15/03/2026)", #"\b\d{1,2}/\d{1,2}/\d{4}\b"#),
        ("IPv4 address", #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
        ("UUID", #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#),
        ("Invoice number (INV-2026-0042)", #"\bINV-\d{4}-\d+\b"#),
        ("Amount (€1,249.00)", #"[€$£]\s?\d[\d,]*(?:\.\d{2})?"#),
        ("Hex color", #"#[0-9a-fA-F]{6}\b"#),
        ("TODO / FIXME", #"\b(TODO|FIXME|XXX)\b"#),
        ("Phone number", #"\+?\d[\d\s().-]{7,}\d"#),
    ]

    private var compiled: Result<NSRegularExpression, Error>? {
        guard !pattern.isEmpty else { return nil }
        return Result { try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) }
    }

    /// ripgrep's default engine has no look-around or back-references.
    private var unsupportedByRipgrep: String? {
        if pattern.contains("(?=") || pattern.contains("(?!") || pattern.contains("(?<=") || pattern.contains("(?<!") {
            return "Look-ahead and look-behind aren't supported when searching file contents."
        }
        if pattern.range(of: #"\\[1-9]"#, options: .regularExpression) != nil {
            return "Back-references (\\1) aren't supported when searching file contents."
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            palette
                .frame(width: 250)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pattern").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("e.g. INV-\\d{4}-\\d+", text: $pattern)
                        .font(.system(.title3, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .focused($patternFocused)
                    HStack {
                        Toggle("Case sensitive", isOn: $caseSensitive)
                        Spacer()
                        status
                    }
                    .font(.caption)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Test text").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $sample)
                        .font(.system(.callout, design: .monospaced))
                        .frame(height: 70)
                        .padding(4)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    Text(highlightedSample)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.yellow.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                if !explanation.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What it means").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(explanation.enumerated()), id: \.offset) { _, part in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(part.0).font(.system(.callout, design: .monospaced)).frame(minWidth: 60, alignment: .leading)
                                Text(part.1).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save…") { saveName = ""; askingName = true }
                        .disabled(!isValid)
                    Button("Search Files") {
                        model.mode = .regex
                        model.text = pattern
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
                }
            }
            .padding(18)
        }
        .frame(width: 860, height: 560)
        .onAppear {
            if model.mode == .regex { pattern = model.text }
            patternFocused = true
        }
        .alert("Save Regex Search", isPresented: $askingName) {
            TextField("Name", text: $saveName)
            Button("Save") {
                app.save(SearchModel.SavedSearch(name: saveName.isEmpty ? pattern : saveName, text: pattern, scope: .regex, filters: model.filters))
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var isValid: Bool {
        if case .success = compiled { return true }
        return false
    }

    @ViewBuilder
    private var status: some View {
        switch compiled {
        case .none:
            EmptyView()
        case .failure:
            Label("Not a valid pattern", systemImage: "xmark.octagon").foregroundStyle(.red)
        case let .success(regex):
            let count = regex.numberOfMatches(in: sample, range: NSRange(sample.startIndex..., in: sample))
            if let warning = unsupportedByRipgrep {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Label("\(count) match\(count == 1 ? "" : "es") in the test text", systemImage: count > 0 ? "checkmark.circle" : "circle")
                    .foregroundStyle(count > 0 ? .green : .secondary)
            }
        }
    }

    private var highlightedSample: AttributedString {
        var result = AttributedString(sample)
        guard case let .success(regex)? = compiled else { return result }
        for match in regex.matches(in: sample, range: NSRange(sample.startIndex..., in: sample)) {
            guard let range = Range(match.range, in: sample), let attributed = Range(range, in: result) else { continue }
            result[attributed].backgroundColor = .yellow.opacity(0.45)
            result[attributed].foregroundColor = .primary
        }
        return result
    }

    private var palette: some View {
        List {
            Section("Building Blocks") {
                ForEach(Self.tokens, id: \.label) { token in
                    Button { insert(token.insert) } label: {
                        HStack {
                            Text(token.insert).font(.system(.body, design: .monospaced)).frame(width: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(token.label)
                                Text(token.help).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section("Common Patterns") {
                ForEach(Self.recipes, id: \.name) { recipe in
                    Button(recipe.name) { pattern = recipe.pattern }
                        .buttonStyle(.plain)
                        .help(recipe.pattern)
                }
            }
            let saved = model.app.savedSearches.filter { $0.scope == .regex }
            if !saved.isEmpty {
                Section("Saved") {
                    ForEach(saved) { search in
                        Button(search.name) { pattern = search.text }.buttonStyle(.plain).help(search.text)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func insert(_ fragment: String) {
        pattern += fragment
        patternFocused = true
    }

    /// A plain-words reading of the pattern, token by token.
    private var explanation: [(String, String)] {
        var parts: [(String, String)] = []
        var index = pattern.startIndex
        func take(_ count: Int) -> String {
            let end = pattern.index(index, offsetBy: count, limitedBy: pattern.endIndex) ?? pattern.endIndex
            defer { index = end }
            return String(pattern[index..<end])
        }
        while index < pattern.endIndex, parts.count < 24 {
            let char = pattern[index]
            switch char {
            case "\\":
                let token = take(2)
                let meaning = [
                    "\\d": "a digit", "\\D": "not a digit", "\\w": "a letter, digit or _", "\\W": "not a word character",
                    "\\s": "whitespace", "\\S": "not whitespace", "\\b": "a word boundary", "\\.": "a literal dot",
                ][token] ?? "the character \(token.dropFirst())"
                parts.append((token, meaning))
            case "[":
                let end = pattern[index...].firstIndex(of: "]").map { pattern.index(after: $0) } ?? pattern.endIndex
                let set = String(pattern[index..<end])
                index = end
                parts.append((set, set.hasPrefix("[^") ? "any character not listed" : "one of the listed characters"))
            case "{":
                let end = pattern[index...].firstIndex(of: "}").map { pattern.index(after: $0) } ?? pattern.endIndex
                let count = String(pattern[index..<end])
                index = end
                parts.append((count, "the previous item \(count.dropFirst().dropLast().replacingOccurrences(of: ",", with: " to ")) times"))
            case "(":
                parts.append((take(pattern[index...].hasPrefix("(?:") ? 3 : 1), "start of a group"))
            case ")": parts.append((take(1), "end of the group"))
            case "|": parts.append((take(1), "or"))
            case ".": parts.append((take(1), "any character"))
            case "+": parts.append((take(1), "one or more of the previous item"))
            case "*": parts.append((take(1), "zero or more of the previous item"))
            case "?": parts.append((take(1), "the previous item is optional"))
            case "^": parts.append((take(1), "start of the line"))
            case "$": parts.append((take(1), "end of the line"))
            default:
                var literal = ""
                while index < pattern.endIndex, !"\\[{()|.+*?^$".contains(pattern[index]) {
                    literal.append(pattern[index])
                    index = pattern.index(after: index)
                }
                parts.append((literal, "the text “\(literal)”"))
            }
        }
        return parts
    }
}
