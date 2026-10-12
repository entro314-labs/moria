import Foundation
import MoriaCore
import Testing
@testable import MoriaApp

@MainActor
struct SearchModelTests {
    @Test func droppedFolderIsSearchedInside() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        let root = FileManager.default.temporaryDirectory.appending(path: "moria-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appending(path: "notes.txt")
        try Data("x".utf8).write(to: file)

        #expect(!model.searchInside([file]))
        #expect(model.filters.folder == nil)
        #expect(model.searchInside([file, folder]))
        // Canonical, as the index stores it: the temporary folder is under /private.
        #expect(model.filters.folder == "/private" + folder.path(percentEncoded: false).dropLast())
    }
}

@MainActor
struct QueryBuildingTests {
    /// The criteria builder counts what Search would show: the mode and the chosen filters
    /// apply to its query as they do to the search field's.
    @Test func queriesCarryTheModeAndTheFilters() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        var filters = FilterState()
        filters.kinds = [.pdf]
        let query = model.query(for: "lease \"rent receipt\"", scope: .names, filters: filters)
        #expect(query.nameTerms == ["lease", "rent receipt"] && query.terms.isEmpty && query.phrases.isEmpty)
        #expect(query.kinds == [.pdf])
        #expect(model.query(for: "lease", scope: .contents, filters: FilterState()).contentTerms == ["lease"])
    }
}

@MainActor
struct HandOffTests {
    /// A request from the quick panel, a link, a Service or the CLI is the whole search: the
    /// window's filters and Ask mode go; what the request leaves out stays.
    @Test func aRequestReplacesTheFiltersAndKeepsWhatItLeavesOut() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        model.filters.kinds = [.pdf]
        model.scope = .names
        model.show(SearchRequest(text: "lease", scope: .contents))
        #expect(model.filters == FilterState() && model.scope == .contents && model.text == "lease" && !model.askMode)
        model.filters.size = .huge
        model.show(SearchRequest(text: nil, scope: nil))
        #expect(model.text == "lease" && model.scope == .contents && model.filters == FilterState())
    }

    @Test func savedSearchesRoundTripThroughTheModel() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        var filters = FilterState()
        filters.date = .week
        let saved = SearchModel.SavedSearch(name: "Recent leases", text: "lease ext:pdf", scope: .contents, filters: filters)
        model.apply(saved)
        #expect(model.text == saved.text && model.scope == .contents && model.filters == filters && !model.askMode)
        let again = model.currentAsSaved(named: "Again")
        #expect(again.text == saved.text && again.scope == saved.scope && again.filters == saved.filters)
    }

    /// Find Similar is the `similar:` token, so it shows as query text that parses back to the file.
    @Test func findSimilarBecomesQueryText() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        model.scope = .names
        model.filters.kinds = [.image]
        let path = NSHomeDirectory() + "/Documents/My lease.pdf"
        model.findSimilar(to: path)
        #expect(model.text == "similar:\"~/Documents/My lease.pdf\"" && model.scope == .everything && model.filters == FilterState())
        #expect(QueryParser().parse(model.text).similarTo == path)
    }

    /// Sidebar items hand their search to the field; typing or changing the folder leaves them.
    @Test func sidebarSelectionDrivesTheSearchAndTypingLeavesIt() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        model.filters.kinds = [.code]
        model.sidebarSelection = .collection("PDFs")
        #expect(model.text == "ext:pdf -in:~/Library hidden:no " && model.filters == FilterState())
        model.text = "invoice"
        #expect(model.sidebarSelection == nil)

        model.sidebarSelection = .location("/Volumes/Archive")
        #expect(model.filters.folder == "/Volumes/Archive")
        model.text = "invoice 2026"
        #expect(model.sidebarSelection == .location("/Volumes/Archive"))
        model.filters.folder = nil
        #expect(model.sidebarSelection == nil)

        model.sidebarSelection = .home
        #expect(model.text.isEmpty && model.filters == FilterState())
    }

    @Test func askIsAModeOnlyWhenTurnedOn() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        #expect(!model.canAsk)
        model.mode = .ask
        #expect(model.mode == .everything && !model.askMode)
        model.mode = .regex
        #expect(model.scope == .regex && model.mode == .regex)
        model.mode = .names
        #expect(model.scope == .names)
    }

    /// Chips remove what they stand for: a typed token from the text, a chosen filter from the bar.
    @Test func chipsRemoveTypedTokensAndChosenFilters() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        model.text = "invoice kind:pdf -draft"
        model.filters.size = .large
        #expect(model.typedChips.map(\.label) == ["PDF", "Without “draft”"])
        #expect(model.activeChips.count == 3)
        model.remove(model.typedChips[0])
        #expect(model.text == "invoice -draft")
        let chosen = try #require(model.activeChips.first { if case .sidebar = $0.source { true } else { false } })
        model.remove(chosen)
        #expect(model.filters.size == .any && model.activeChips.count == 1)
    }
}

/// A search model on a scratch index of two text files.
@MainActor
func indexedModel() async throws -> SearchModel {
    let (app, _) = try makeAppModel()
    let root = FileManager.default.temporaryDirectory.appending(path: "moria-stop-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("quarterly invoice".utf8).write(to: root.appending(path: "invoice.txt"))
    try Data("holiday plans".utf8).write(to: root.appending(path: "plans.txt"))
    var settings = app.settings
    settings.roots = [root.resolvingSymlinksInPath().path]
    try await app.controller.updateSettings(settings)
    try await app.controller.indexNow(full: true)
    return SearchModel(app: app)
}

/// Waits for the running search to finish.
@MainActor
func settle(_ model: SearchModel) async throws {
    for _ in 0..<200 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
}

@MainActor
struct ResultOrderTests {
    /// Regex results arrive in batches; each batch keeps the chosen sort, as the header shows it.
    @Test func regexResultsFollowTheChosenSort() async throws {
        let model = try await indexedModel()
        model.sort(by: .name)
        model.sortAscending = false
        model.scope = .regex
        model.text = "txt"
        try await settle(model)
        #expect(model.items.map(\.result.name) == ["plans.txt", "invoice.txt"])
        model.sortAscending = true
        #expect(model.items.map(\.result.name) == ["invoice.txt", "plans.txt"])
    }

    /// Rows from a new search replace the old ones (the table goes back to the top); rows a
    /// running regex search adds keep the generation (the table keeps its place).
    @Test func rowsOfANewSearchChangeTheGeneration() async throws {
        let model = try await indexedModel()
        let start = model.resultsGeneration
        model.text = "invoice"
        try await settle(model)
        #expect(model.resultsGeneration == start + 1)
        model.text = "plans"
        try await settle(model)
        #expect(model.resultsGeneration == start + 2)
        model.text = ""
        #expect(model.items.isEmpty && model.resultsGeneration == start + 3)
    }
}

@MainActor
struct StopSearchTests {
    @Test func stopEndsTheSearchAndClearsRowsFromThePreviousOne() async throws {
        let model = try await indexedModel()
        model.text = "invoice"
        try await settle(model)
        #expect(model.items.map(\.result.name) == ["invoice.txt"])

        // The next search counts as running from the keystroke, before its pause is over.
        model.text = "holiday"
        #expect(model.isSearching)
        model.stop()
        #expect(!model.isSearching && model.isStopped)
        // The invoice row doesn't answer "holiday": it goes.
        #expect(model.items.isEmpty)
        #expect(model.summary == "Stopped")
        // Nothing still running brings results in afterwards.
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.items.isEmpty && !model.isSearching)

        // Searching again works, and the stop is forgotten.
        model.search(debounce: false)
        try await settle(model)
        #expect(!model.isStopped)
        #expect(model.items.map(\.result.name) == ["plans.txt"])
    }

    @Test func stoppingWhenNothingRunsChangesNothing() async throws {
        let model = try await indexedModel()
        model.text = "invoice"
        try await settle(model)
        model.stop()
        #expect(!model.isStopped)
        #expect(model.items.map(\.result.name) == ["invoice.txt"])
    }
}
