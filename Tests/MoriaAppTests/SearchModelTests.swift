import Foundation
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
struct StopSearchTests {
    /// An app model on a scratch index of two text files.
    private func indexedModel() async throws -> SearchModel {
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

    private func settle(_ model: SearchModel) async throws {
        for _ in 0..<200 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
    }

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
