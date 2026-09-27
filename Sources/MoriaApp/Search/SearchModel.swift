import AppKit
import MoriaCore
import Observation

/// What the search text is matched against.
enum SearchScope: String, CaseIterable, Identifiable {
    case everything = "Everything"
    case names = "Names"
    case contents = "Contents"
    case regex = "Regex"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .everything: "File names and contents"
        case .names: "File and folder names only"
        case .contents: "Text inside files only"
        case .regex: "Regular expression over names and contents"
        }
    }
}

enum ResultSort: String, CaseIterable, Identifiable {
    case relevance = "Relevance"
    case name = "Name"
    case kind = "Kind"
    case size = "Size"
    case modified = "Date Modified"

    var id: String { rawValue }
}

/// A row in the results: a search hit plus, for regex searches, the matching lines.
struct ResultItem: Identifiable, Hashable {
    var result: SearchResult
    var lines: [RegexHit.Line] = []

    var id: Int64 { result.id }
}

/// Sidebar filters, merged into the parsed query where the query text doesn't set them.
struct FilterState: Equatable {
    enum DatePreset: String, CaseIterable, Identifiable {
        case any = "Any Time", today = "Today", week = "Past Week", month = "Past Month"
        case quarter = "Past 3 Months", year = "Past Year", older = "Older Than a Year"
        var id: String { rawValue }
    }

    enum SizePreset: String, CaseIterable, Identifiable {
        case any = "Any Size", tiny = "Under 100 KB", small = "100 KB – 10 MB", large = "10 MB – 1 GB", huge = "Over 1 GB"
        var id: String { rawValue }
    }

    var kinds: Set<FileKind> = []
    var date: DatePreset = .any
    var dateUsesCreation = false
    var size: SizePreset = .any
    var folder: String?
    var hideSystemFiles = false
    var hideCloudOnly = false

    var isActive: Bool { self != FilterState() }

    func apply(to query: inout SearchQuery, now: Date = Date(), home: String = NSHomeDirectory()) {
        if query.kinds.isEmpty { query.kinds = kinds }
        if let interval = interval(now: now) {
            if dateUsesCreation {
                if query.created == nil { query.created = interval }
            } else if query.modified == nil {
                query.modified = interval
            }
        }
        if query.minSize == nil, query.maxSize == nil {
            switch size {
            case .any: break
            case .tiny: query.maxSize = 100 * 1024
            case .small: (query.minSize, query.maxSize) = (100 * 1024, 10 * 1_048_576)
            case .large: (query.minSize, query.maxSize) = (10 * 1_048_576, 1_073_741_824)
            case .huge: query.minSize = 1_073_741_824
            }
        }
        if let folder, query.folders.isEmpty { query.folders = [folder] }
        if hideSystemFiles {
            if query.hidden == nil { query.hidden = false }
            query.excludedFolders.append(home + "/Library")
        }
        if hideCloudOnly, query.cloudOnly == nil { query.cloudOnly = false }
    }

    private func interval(now: Date) -> DateInterval? {
        let calendar = Calendar.current
        let end = now.addingTimeInterval(1)
        func back(_ unit: Calendar.Component, _ value: Int) -> DateInterval {
            DateInterval(start: calendar.date(byAdding: unit, value: -value, to: now)!, end: end)
        }
        switch date {
        case .any: return nil
        case .today: return DateInterval(start: calendar.startOfDay(for: now), end: end)
        case .week: return back(.day, 7)
        case .month: return back(.month, 1)
        case .quarter: return back(.month, 3)
        case .year: return back(.year, 1)
        case .older: return DateInterval(start: .distantPast, end: calendar.date(byAdding: .year, value: -1, to: now)!)
        }
    }
}

/// State and logic behind one search surface (the main window or the quick panel).
@Observable
final class SearchModel {
    let app: AppModel
    let limit: Int

    var text = "" { didSet { if text != oldValue { textChanged() } } }
    var scope: SearchScope = .everything { didSet { if scope != oldValue { search() } } }
    var filters = FilterState() { didSet { if filters != oldValue { search() } } }
    /// Blend semantic matches into results (when semantic search is enabled in Settings).
    var useMeaning = false { didSet { if useMeaning != oldValue { search() } } }
    /// Interpret the text as a plain-language request (runs on Return, not per keystroke).
    var askMode = false { didSet { if askMode != oldValue { interpretation = nil; if !askMode { search() } } } }
    var sort: ResultSort = .relevance { didSet { applySort() } }
    var sortAscending = false { didSet { applySort() } }

    private(set) var items: [ResultItem] = []
    var selection: Set<Int64> = []
    private(set) var isSearching = false
    private(set) var elapsed: Duration?
    private(set) var message: String?
    /// The filters an Ask request was turned into, and the equivalent query text.
    private(set) var interpretation: (summary: String, query: String)?
    private(set) var snippets: [Int64: String] = [:]
    /// Bumped when snippets arrive so the table can refresh visible rows.
    private(set) var snippetRevision = 0
    /// Bumped to ask the results table to take keyboard focus.
    private(set) var focusResultsRequest = 0
    /// Bumped to ask the window to focus the search field.
    private(set) var focusSearchRequest = 0
    /// Bumped to toggle the Quick Look panel for the selection.
    private(set) var quickLookRequest = 0

    private var activeQuery = SearchQuery()
    private var searchTask: Task<Void, Never>?
    private var pendingSnippets: Set<Int64> = []

    init(app: AppModel, limit: Int = 1000) {
        self.app = app
        self.limit = limit
    }

    var selectedItems: [ResultItem] {
        items.filter { selection.contains($0.id) }
    }

    var canUseMeaning: Bool { app.settings.semanticSearchEnabled }
    var canAsk: Bool { app.settings.naturalLanguageQueriesEnabled }

    // MARK: - Running searches

    private func textChanged() {
        if askMode {
            interpretation = nil
            return
        }
        search()
    }

    /// Return in the search field: runs an Ask interpretation, or searches immediately.
    func submit() {
        if askMode, canAsk {
            ask()
        } else {
            search(debounce: false)
        }
    }

    func search(debounce: Bool = true) {
        searchTask?.cancel()
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty || filters.isActive else {
            items = []
            selection = []
            message = nil
            elapsed = nil
            isSearching = false
            return
        }
        let scope = scope
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(scope == .regex ? 350 : 110)) }
            guard !Task.isCancelled else { return }
            if scope == .regex {
                await runRegex(pattern: text)
            } else {
                await run(query(for: text, scope: scope))
            }
        }
    }

    private func query(for text: String, scope: SearchScope) -> SearchQuery {
        var query = QueryParser().parse(text)
        switch scope {
        case .names:
            query.nameTerms += query.terms
            query.terms = []
        case .contents:
            query.contentTerms += query.terms
            query.terms = []
        case .everything, .regex:
            break
        }
        filters.apply(to: &query)
        return query
    }

    private func run(_ query: SearchQuery) async {
        isSearching = true
        message = nil
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let results = try await app.engine.search(query, limit: limit, semantic: useMeaning && canUseMeaning)
            guard !Task.isCancelled else { return }
            activeQuery = query
            snippets = [:]
            pendingSnippets = []
            show(results.map { ResultItem(result: $0) })
            elapsed = clock.now - start
            if results.isEmpty { message = "No matches" }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            items = []
            message = "Search failed: \(error)"
        }
        isSearching = false
    }

    private func runRegex(pattern: String) async {
        isSearching = true
        message = nil
        snippets = [:]
        pendingSnippets = []
        items = []
        activeQuery = SearchQuery()
        let clock = ContinuousClock()
        let start = clock.now
        var filterQuery = SearchQuery()
        filters.apply(to: &filterQuery)
        do {
            let searcher = try RegexSearcher(database: app.database)
            var batch: [RegexHit] = []
            var lastFlush = clock.now
            for try await hit in searcher.search(pattern: pattern, filters: filterQuery, maxFiles: limit) {
                batch.append(hit)
                if batch.count >= 50 || clock.now - lastFlush > .milliseconds(150) {
                    try await appendRegexHits(batch)
                    batch = []
                    lastFlush = clock.now
                }
            }
            try await appendRegexHits(batch)
            elapsed = clock.now - start
            if items.isEmpty { message = "No matches" }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            message = String(describing: error)
        }
        isSearching = false
    }

    private func appendRegexHits(_ hits: [RegexHit]) async throws {
        guard !hits.isEmpty, !Task.isCancelled else { return }
        let metadata = try await app.engine.metadata(for: hits.map(\.id))
        let newItems = hits.compactMap { hit -> ResultItem? in
            guard var result = metadata[hit.id] else { return nil }
            result.matchedName = hit.nameMatched
            result.matchedContent = !hit.lines.isEmpty
            return ResultItem(result: result, lines: hit.lines)
        }
        guard !Task.isCancelled else { return }
        items += newItems
        if selection.isEmpty, let first = items.first { selection = [first.id] }
    }

    private func ask() {
        searchTask?.cancel()
        let request = text
        searchTask = Task {
            isSearching = true
            message = "Interpreting…"
            do {
                let interpretation = try await NaturalLanguageQuery().interpret(request)
                guard !Task.isCancelled else { return }
                var query = interpretation.query
                filters.apply(to: &query)
                self.interpretation = (interpretation.summary, QueryFormatter().string(from: interpretation.query))
                await run(query)
            } catch is CancellationError {
                return
            } catch {
                // Fall back to the plain parser so a request never yields nothing.
                message = "Couldn't interpret the request (\(error)); searching the words instead."
                await run(query(for: request, scope: .everything))
            }
        }
    }

    /// Replaces the text with the query an Ask request produced, for editing.
    func editInterpretation() {
        guard let interpretation else { return }
        askMode = false
        text = interpretation.query
    }

    // MARK: - Results

    private func show(_ newItems: [ResultItem]) {
        let previous = selection
        items = newItems
        applySort()
        selection = previous.intersection(Set(items.map(\.id)))
        if selection.isEmpty, let first = items.first { selection = [first.id] }
    }

    private func applySort() {
        guard sort != .relevance else {
            if sortAscending { items.sort { $0.result.score < $1.result.score } }
            else { items.sort { $0.result.score > $1.result.score } }
            return
        }
        let ascending = sortAscending
        items.sort { a, b in
            let (x, y) = (a.result, b.result)
            let ordered: Bool = switch sort {
            case .name: x.name.localizedStandardCompare(y.name) == .orderedAscending
            case .kind: x.kind.displayName < y.kind.displayName
            case .size: x.size < y.size
            case .modified: x.modified < y.modified
            case .relevance: x.score < y.score
            }
            return ascending ? ordered : !ordered
        }
    }

    /// Loads the excerpt for a row the first time it becomes visible.
    func requestSnippet(for item: ResultItem) {
        let id = item.id
        guard snippets[id] == nil, !pendingSnippets.contains(id), item.lines.isEmpty,
              item.result.matchedContent || item.result.matchedMeaning else { return }
        pendingSnippets.insert(id)
        let query = activeQuery
        let engine = app.engine
        let result = item.result
        Task {
            let snippet = try? await engine.snippet(for: result, query: query)
            pendingSnippets.remove(id)
            if let snippet {
                snippets[id] = snippet
                snippetRevision += 1
            }
        }
    }

    func focusResults() {
        guard !items.isEmpty else { return }
        focusResultsRequest += 1
        recordRecent()
    }

    func focusSearch() { focusSearchRequest += 1 }
    func toggleQuickLook() { quickLookRequest += 1 }

    var selectedURLs: [URL] { selectedItems.map(\.result.url) }

    func openSelection() {
        FileActions.open(selectedURLs)
        recordRecent()
    }

    func revealSelection() {
        FileActions.reveal(selectedURLs)
        recordRecent()
    }

    /// Adds a syntax example to the query (from the syntax popover).
    func append(_ fragment: String) {
        let first = fragment.split(separator: " ").first.map(String.init) ?? fragment
        text = text.isEmpty ? first : text + " " + first
    }

    var prompt: String {
        if askMode { return "Describe the file, e.g. PDF invoices about rent from last spring" }
        return scope == .regex ? "Regular expression" : "Search names and contents"
    }

    // MARK: - Suggestions

    struct Suggestion: Identifiable {
        var title: String
        var symbol: String
        var completion: String
        var id: String { completion }
    }

    private static let recentsKey = "recentSearches"

    /// Remembers a query once someone acts on its results.
    private func recordRecent() {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        var recents = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recents.removeAll { $0 == query }
        recents.insert(query, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(8)), forKey: Self.recentsKey)
    }

    /// Recent searches when the field is empty; otherwise completions for the filter being typed.
    var suggestions: [Suggestion] {
        if text.isEmpty {
            return (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []).map {
                Suggestion(title: $0, symbol: "clock.arrow.circlepath", completion: $0)
            }
        }
        guard scope != .regex, !askMode, !text.hasSuffix(" ") else { return [] }
        let head = text.split(separator: " ", omittingEmptySubsequences: false).dropLast().joined(separator: " ")
        let last = String(text.split(separator: " ", omittingEmptySubsequences: false).last ?? "")
        let prefix = head.isEmpty ? "" : head + " "
        guard let colon = last.firstIndex(of: ":") else {
            // Typing the start of a filter name: offer the filter.
            guard last.count >= 2 else { return [] }
            return Self.filterKeys.filter { $0.key.hasPrefix(last.lowercased()) && $0.key != last }.map {
                Suggestion(title: "\($0.key)  \($0.help)", symbol: "line.3.horizontal.decrease.circle", completion: prefix + $0.key)
            }
        }
        let key = last[..<colon].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let typed = last[last.index(after: colon)...].lowercased()
        let values = Self.values(for: key, roots: app.settings.roots)
        return values.filter { typed.isEmpty || $0.value.lowercased().hasPrefix(typed) }.prefix(8).map {
            Suggestion(title: last[..<colon] + ":" + $0.value + ($0.help.isEmpty ? "" : "  —  " + $0.help),
                       symbol: "line.3.horizontal.decrease.circle",
                       completion: prefix + last[...colon] + $0.value + " ")
        }
    }

    private static let filterKeys: [(key: String, help: String)] = [
        ("kind:", "file type"), ("ext:", "extension"), ("size:", "file size"), ("modified:", "date modified"),
        ("created:", "date created"), ("in:", "folder"), ("name:", "name only"), ("content:", "contents only"),
        ("hidden:", "hidden files"), ("cloud:", "cloud-only files"),
    ]

    private static func values(for key: String, roots: [String]) -> [(value: String, help: String)] {
        switch key {
        case "kind":
            return FileKind.allCases.filter { $0 != .other && $0 != .package }.map { ($0.rawValue, $0.displayName) }
        case "ext", "extension", "type":
            return ["pdf", "docx", "xlsx", "pptx", "pages", "md", "txt", "csv", "json", "png", "jpg", "heic", "mov", "zip", "swift", "py", "ts"].map { ($0, "") }
        case "size":
            return [(">1mb", "over 1 MB"), (">10mb", "over 10 MB"), (">100mb", "over 100 MB"), (">1gb", "over 1 GB"), ("<100kb", "under 100 KB")]
        case "modified", "created", "date", "mod":
            return [("today", ""), ("yesterday", ""), ("<7d", "past week"), ("<30d", "past month"), ("<1y", "past year"), (">1y", "older than a year"), ("thisyear", "")]
        case "in", "path", "folder":
            let home = NSHomeDirectory()
            let folders = ["~/Desktop", "~/Documents", "~/Downloads"] + roots.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
            return Array(Set(folders)).sorted().map { ($0, "") }
        case "hidden", "cloud":
            return [("no", "leave out"), ("yes", "only these")]
        default:
            return []
        }
    }

    // MARK: - Status

    var summary: String {
        if isSearching, items.isEmpty { return "Searching…" }
        guard !items.isEmpty else { return message ?? "" }
        let count = items.count >= limit ? "\(limit.formatted())+" : items.count.formatted()
        var text = "\(count) result\(items.count == 1 ? "" : "s")"
        if let elapsed {
            let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
            text += String(format: " · %.0f ms", ms)
        }
        return text
    }
}
