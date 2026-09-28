import AppKit
import MoriaCore
import Observation

/// What the search text is matched against.
enum SearchScope: String, CaseIterable, Identifiable, Codable {
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
    case created = "Date Created"
    case path = "Where"
    case ext = "Extension"

    var id: String { rawValue }

    /// The direction a column sorts in first: text A–Z; relevance, sizes and dates largest or
    /// newest first.
    var defaultAscending: Bool {
        switch self {
        case .name, .kind, .path, .ext: true
        case .relevance, .size, .modified, .created: false
        }
    }
}

/// A row in the results: a search hit plus, for regex searches, the matching lines.
struct ResultItem: Identifiable, Hashable {
    var result: SearchResult
    var lines: [RegexHit.Line] = []

    var id: Int64 { result.id }
}

/// Sidebar filters, merged into the parsed query where the query text doesn't set them.
struct FilterState: Equatable, Codable {
    enum DatePreset: String, CaseIterable, Identifiable, Codable {
        case any = "Any Time", today = "Today", week = "Past Week", month = "Past Month"
        case quarter = "Past 3 Months", year = "Past Year", older = "Older Than a Year"
        var id: String { rawValue }
    }

    enum SizePreset: String, CaseIterable, Identifiable, Codable {
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
    var filters = FilterState() {
        didSet {
            guard filters != oldValue else { return }
            // A Location stays selected in the sidebar only while its folder filter applies.
            if case let .location(path) = sidebarSelection, filters.folder != path { sidebarSelection = nil }
            search()
        }
    }
    /// Blend semantic matches into results (when semantic search is enabled in Settings).
    var useMeaning = false { didSet { if useMeaning != oldValue { search() } } }
    /// Interpret the text as a plain-language request (runs on Return, not per keystroke).
    var askMode = false { didSet { if askMode != oldValue { interpretation = nil; if !askMode { search() } } } }
    var sort: ResultSort = .relevance { didSet { applySort() } }
    var sortAscending = false { didSet { applySort() } }

    /// Scope and Ask as a single mode.
    var mode: SearchMode {
        get { askMode ? .ask : SearchMode(rawValue: scope.rawValue.lowercased()) ?? .everything }
        set {
            if let scope = newValue.scope {
                askMode = false
                self.scope = scope
            } else if canAsk {
                askMode = true
            }
        }
    }

    /// Sidebar selection; choosing an item runs its search.
    var sidebarSelection: SidebarItem? = .home {
        didSet { if sidebarSelection != oldValue, let sidebarSelection { navigate(to: sidebarSelection) } }
    }
    /// Result counts for collections and saved searches (loaded in the background).
    private(set) var counts: [SidebarItem: Int] = [:]
    /// Recently modified files for the home screen.
    private(set) var recentFiles: [SearchResult] = []

    private(set) var items: [ResultItem] = []
    var selection: Set<Int64> = [] {
        // The ⌘K palette acts on the selection; it closes when there is none.
        didSet { if selection.isEmpty { showActions = false } }
    }
    private(set) var isSearching = false
    private(set) var elapsed: Duration?
    private(set) var message: String?
    /// Shown after the result count, e.g. when Ask fell back to searching the words.
    private(set) var notice: String?
    /// The filters an Ask request was turned into, and the equivalent query text.
    private(set) var interpretation: (summary: String, query: String)?
    /// Content match details per result, loaded when a row first becomes visible.
    private(set) var details: [Int64: MatchDetails] = [:]
    /// Bumped when details arrive so the table can refresh visible rows.
    private(set) var detailsRevision = 0
    /// Shows the ⌘K action palette.
    var showActions = false
    /// Shows the "Save Search" name prompt.
    var showSavePrompt = false
    /// Shows the criteria builder, optionally editing a saved search.
    var showCriteria = false
    var editingSaved: SavedSearch?
    /// Shows the regex builder.
    var showRegexBuilder = false
    /// Bumped to ask the results table to take keyboard focus.
    private(set) var focusResultsRequest = 0
    /// Bumped to ask the window to focus the search field.
    private(set) var focusSearchRequest = 0
    /// Bumped to toggle the Quick Look panel for the selection.
    private(set) var quickLookRequest = 0

    private var activeQuery = SearchQuery()
    private var searchTask: Task<Void, Never>?
    private var pendingDetails: Set<Int64> = []

    init(app: AppModel, limit: Int = 1000) {
        self.app = app
        self.limit = limit
        scope = UserDefaults.standard.string(forKey: "defaultScope").flatMap(SearchScope.init) ?? .everything
    }

    /// Shows a request from the quick panel, a link, a Service or the CLI. The request is the
    /// whole search: filters chosen earlier in this window don't narrow it.
    func show(_ request: SearchRequest) {
        askMode = false
        filters = FilterState()
        if let scope = request.scope { self.scope = scope }
        if let text = request.text { self.text = text }
    }

    /// The window's undo manager, for Move to Trash.
    weak var undoManager: UndoManager?

    /// Moves the selected files to the Trash and drops them from the results. Undo puts them back.
    func moveSelectionToTrash() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        trash(urls)
    }

    private func trash(_ urls: [URL]) {
        Task {
            do {
                let trashed = try await NSWorkspace.shared.recycle(urls)
                let removed = Set(trashed.keys.map(\.path))
                items.removeAll { removed.contains($0.result.path) }
                selection = selection.filter { id in items.contains { $0.id == id } }
                undoManager?.registerUndo(withTarget: self) { model in
                    MainActor.assumeIsolated { model.putBack(trashed) }
                }
                undoManager?.setActionName("Move to Trash")
                await updateIndex(removed.sorted())
            } catch {
                message = "Couldn't move to the Trash: \(error.localizedDescription)"
            }
        }
    }

    /// Undo of Move to Trash: the files go back where they were and the search runs again, so
    /// they reappear. Redo trashes them again.
    private func putBack(_ trashed: [URL: URL]) {
        let restored: [URL]
        do {
            restored = try FileActions.putBack(trashed)
        } catch let error as FileActions.PutBackError {
            restored = error.restored
            app.lastError = error.localizedDescription
        } catch {
            app.lastError = error.localizedDescription
            return
        }
        guard !restored.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.trash(restored) }
        }
        undoManager?.setActionName("Move to Trash")
        Task {
            await updateIndex(restored.map(\.path))
            search(debounce: false)
        }
    }

    /// The index updates directly: the event stream ignores Moria's own changes.
    private func updateIndex(_ paths: [String]) async {
        do {
            try await app.controller.apply(paths.map { FileChange(path: $0, rescanSubtree: true) })
        } catch {
            app.lastError = "The index couldn't be updated after moving files: \(error)"
        }
    }

    /// Results as CSV (path, name, kind, size, modified, match).
    func exportCSV() -> String {
        func field(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        let formatter = ISO8601DateFormatter()
        var lines = ["path,name,kind,size,modified,matched"]
        for item in items {
            let result = item.result
            let matched = [result.matchedName ? "name" : nil, result.matchedContent ? "contents" : nil,
                           result.matchedMeaning ? "meaning" : nil].compactMap { $0 }.joined(separator: "+")
            lines.append([result.path, result.name, result.kind.rawValue, String(result.size),
                          formatter.string(from: result.modified), matched].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    var selectedItems: [ResultItem] {
        items.filter { selection.contains($0.id) }
    }

    var canUseMeaning: Bool { app.settings.semanticSearchEnabled }
    var canAsk: Bool { app.settings.naturalLanguageQueriesEnabled }

    // MARK: - Running searches

    private func textChanged() {
        leaveNavigationIfEdited()
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
        notice = nil
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
        // Phrases move too: left in `phrases`, they would match names in Contents and
        // contents in Names.
        switch scope {
        case .names:
            query.nameTerms += query.terms + query.phrases
            (query.terms, query.phrases) = ([], [])
        case .contents:
            query.contentTerms += query.terms + query.phrases
            (query.terms, query.phrases) = ([], [])
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
            details = [:]
            pendingDetails = []
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
        details = [:]
        pendingDetails = []
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
        notice = nil
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
                // Fall back to the plain parser so a request never yields nothing, and say so.
                await run(query(for: request, scope: .everything))
                notice = "Ask couldn't interpret this (\(error)), so these results match the words"
                if items.isEmpty { message = notice }
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
            case .created: x.created < y.created
            case .path: x.path.localizedStandardCompare(y.path) == .orderedAscending
            case .ext: x.ext < y.ext
            case .relevance: x.score < y.score
            }
            return ascending ? ordered : !ordered
        }
    }

    /// Loads the excerpt and match count for a row the first time it becomes visible.
    func requestDetails(for item: ResultItem) {
        let id = item.id
        guard details[id] == nil, !pendingDetails.contains(id), item.lines.isEmpty,
              item.result.matchedContent || item.result.matchedMeaning else { return }
        pendingDetails.insert(id)
        let query = activeQuery
        let engine = app.engine
        let result = item.result
        Task {
            let loaded = try? await engine.details(for: result, query: query)
            pendingDetails.remove(id)
            if let loaded {
                details[id] = loaded
                detailsRevision += 1
            }
        }
    }

    // MARK: - Chips and facets

    /// A removable chip for an active filter, typed or chosen in the sidebar.
    struct FilterChip: Identifiable {
        enum Source { case typed(Int), sidebar(PartialKeyPath<FilterState>) }
        var label: String
        var symbol: String
        var isExclusion: Bool
        var source: Source
        var id: String { label + "\(isExclusion)" }
    }

    /// Filters typed in the query (or produced by Ask).
    var typedChips: [FilterChip] {
        QueryParser().chips(for: interpretation?.query ?? text).map {
            FilterChip(label: $0.label, symbol: $0.symbol, isExclusion: $0.isExclusion, source: .typed($0.tokenIndex))
        }
    }

    /// Filters in effect: typed tokens plus those chosen in the filter bar.
    var activeChips: [FilterChip] {
        var chips = typedChips
        if !filters.kinds.isEmpty {
            chips.append(FilterChip(label: filters.kinds.map(\.displayName).sorted().joined(separator: ", "),
                                    symbol: "square.grid.2x2", isExclusion: false, source: .sidebar(\.kinds)))
        }
        if filters.date != .any {
            chips.append(FilterChip(label: (filters.dateUsesCreation ? "Created: " : "Modified: ") + filters.date.rawValue,
                                    symbol: "calendar", isExclusion: false, source: .sidebar(\.date)))
        }
        if filters.size != .any {
            chips.append(FilterChip(label: filters.size.rawValue, symbol: "scalemass", isExclusion: false, source: .sidebar(\.size)))
        }
        if let folder = filters.folder {
            chips.append(FilterChip(label: "In " + (folder as NSString).lastPathComponent, symbol: "folder",
                                    isExclusion: false, source: .sidebar(\.folder)))
        }
        if filters.hideSystemFiles {
            chips.append(FilterChip(label: "No Library or hidden files", symbol: "eye.slash", isExclusion: true, source: .sidebar(\.hideSystemFiles)))
        }
        if filters.hideCloudOnly {
            chips.append(FilterChip(label: "Downloaded files only", symbol: "icloud", isExclusion: true, source: .sidebar(\.hideCloudOnly)))
        }
        return chips
    }

    func remove(_ chip: FilterChip) {
        switch chip.source {
        case let .typed(index):
            if let interpretation {
                // Editing an Ask interpretation turns it into an ordinary query.
                askMode = false
                text = QueryParser().removingToken(at: index, from: interpretation.query)
            } else {
                text = QueryParser().removingToken(at: index, from: text)
            }
        case let .sidebar(keyPath):
            let empty = FilterState()
            switch keyPath {
            case \FilterState.kinds: filters.kinds = empty.kinds
            case \FilterState.date: filters.date = empty.date
            case \FilterState.size: filters.size = empty.size
            case \FilterState.folder: filters.folder = empty.folder
            case \FilterState.hideSystemFiles: filters.hideSystemFiles = false
            case \FilterState.hideCloudOnly: filters.hideCloudOnly = false
            default: break
            }
        }
    }

    struct Facet: Identifiable {
        var kind: FileKind
        var count: Int
        var id: FileKind { kind }
    }

    /// Kinds present in the results, most common first, for one-click narrowing.
    var facets: [Facet] {
        guard items.count > 1 else { return [] }
        let counts = Dictionary(grouping: items, by: \.result.kind).mapValues(\.count)
        guard counts.count > 1 else { return [] }
        return counts.map { Facet(kind: $0.key, count: $0.value) }.sorted { $0.count > $1.count }.prefix(6).map { $0 }
    }

    /// Click: only this kind. Option-click: leave it out (added as a typed `-kind:` filter).
    func applyFacet(_ facet: Facet, exclude: Bool) {
        if exclude {
            text = (text.isEmpty ? "" : text + " ") + "-kind:" + facet.kind.rawValue
        } else {
            filters.kinds = [facet.kind]
        }
    }

    // MARK: - Navigation

    private var navigating = false

    private func navigate(to item: SidebarItem) {
        navigating = true
        defer { navigating = false }
        switch item {
        case .home:
            askMode = false
            filters = FilterState()
            text = ""
            loadHome()
        case let .collection(name):
            guard let collection = Collection.all.first(where: { $0.name == name }) else { return }
            askMode = false
            filters = FilterState()
            text = collection.query + " "
        case let .saved(id):
            if let saved = app.savedSearches.first(where: { $0.id == id }) { apply(saved) }
        case let .location(path):
            filters.folder = path
        }
    }

    /// Typing leaves a collection or saved search (the sidebar shows where you started).
    private func leaveNavigationIfEdited() {
        guard !navigating else { return }
        switch sidebarSelection {
        case .collection, .saved: sidebarSelection = nil
        case .home: if !text.isEmpty { sidebarSelection = nil }
        case .location, .none: break
        }
    }

    /// Loads the home screen's recent files and the sidebar counts.
    func loadHome() {
        let engine = app.engine
        let saved = app.savedSearches
        Task {
            var recent = QueryParser().parse("modified:<14d -in:~/Library hidden:no cloud:no")
            recent.excludedKinds = [.folder, .package, .application]
            recentFiles = (try? await engine.search(recent, limit: 24)) ?? []

            var counts: [SidebarItem: Int] = [:]
            for collection in Collection.all {
                let query = QueryParser().parse(collection.query)
                counts[.collection(collection.name)] = (try? await engine.search(query, limit: 1000).count) ?? 0
            }
            for search in saved {
                var query = QueryParser().parse(search.text)
                search.filters.apply(to: &query)
                counts[.saved(search.id)] = (try? await engine.search(query, limit: 1000).count) ?? 0
            }
            self.counts = counts
        }
    }

    // MARK: - Saved searches

    struct SavedSearch: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var text: String
        var scope: SearchScope
        var filters: FilterState
    }

    var canSave: Bool { !text.isEmpty || filters.isActive }

    func currentAsSaved(named name: String) -> SavedSearch {
        SavedSearch(name: name, text: text, scope: scope, filters: filters)
    }

    func apply(_ saved: SavedSearch) {
        askMode = false
        scope = saved.scope
        filters = saved.filters
        text = saved.text
        search(debounce: false)
    }

    /// Sorts by `sort` in its usual direction (the Sort By menu).
    func sort(by sort: ResultSort) {
        sortAscending = sort.defaultAscending
        self.sort = sort
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
        return values.filter { (typed.isEmpty || $0.value.lowercased().hasPrefix(typed)) && $0.value.lowercased() != typed }.prefix(8).map {
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
        if let notice { text += " · " + notice }
        return text
    }
}
