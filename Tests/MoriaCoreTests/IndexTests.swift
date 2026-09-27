import Foundation
import Testing
@testable import MoriaCore

@Suite(.serialized)
struct IndexTests {
    let root: URL

    init() throws {
        root = try TestSupport.makeTempDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "Documents/Taxes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "node_modules/pkg"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "Tools.app/Contents"), withIntermediateDirectories: true)
        try Data("Monthly rent receipt for the apartment, paid in full.".utf8)
            .write(to: root.appending(path: "Documents/Taxes/receipt.txt"))
        try Data("Απόδειξη ενοικίου Σεπτεμβρίου".utf8).write(to: root.appending(path: "Documents/greek-note.md"))
        try Data("func invoiceTotal() -> Decimal { 42 }".utf8).write(to: root.appending(path: "Documents/Billing.swift"))
        try Data("ignored dependency".utf8).write(to: root.appending(path: "node_modules/pkg/index.js"))
        try Data("inside bundle".utf8).write(to: root.appending(path: "Tools.app/Contents/Info.plist"))
        try Data("draft rent receipt".utf8).write(to: root.appending(path: "Documents/draft.txt"))
        try fm.createDirectory(at: root.appending(path: "App/build"), withIntermediateDirectories: true)
        try Data("compiled artifact zebra".utf8).write(to: root.appending(path: "App/build/output.txt"))
    }

    func search(_ engine: SearchEngine, _ text: String) async throws -> [String] {
        try await engine.search(QueryParser(home: root.path).parse(text)).map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
    }

    @Test func indexesNamesAndContentWithRules() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        #expect(try await search(engine, "receipt").contains("Documents/Taxes/receipt.txt"))
        #expect(try await search(engine, "apartment") == ["Documents/Taxes/receipt.txt"])
        // English stemming: plural query, singular text.
        #expect(try await search(engine, "apartments") == ["Documents/Taxes/receipt.txt"])
        // Greek matches without accents or capitals, via the folding tokenizer.
        #expect(try await search(engine, "αποδειξη") == ["Documents/greek-note.md"])
        // Substring filename match (trigram).
        #expect(try await search(engine, "illin") == ["Documents/Billing.swift"])
        // Exclusions and filters.
        #expect(try await search(engine, "rent -draft") == ["Documents/Taxes/receipt.txt"])
        #expect(try await search(engine, "rent ext:swift").isEmpty)
        #expect(try await search(engine, "kind:code") == ["Documents/Billing.swift"])
        #expect(try await search(engine, "rent in:\(root.path)/Documents/Taxes") == ["Documents/Taxes/receipt.txt"])
        // Excluded names are not crawled; packages are one opaque item.
        #expect(try await search(engine, "dependency").isEmpty)
        #expect(try await search(engine, "bundle").isEmpty)
        #expect(try await search(engine, "Tools") == ["Tools.app"])

        // Snippets come from the file (text) since the content index stores no text.
        let hit = try await engine.search(QueryParser().parse("apartment")).first!
        #expect(try await engine.snippet(for: hit, query: QueryParser().parse("apartment"))?.contains("\u{1}apartment\u{2}") == true)
        let details = try await engine.details(for: hit, query: QueryParser().parse("apartment"))
        #expect(details?.matchCount == 1)
        #expect(details?.lines.first?.number == 1)

        // Content-excluded folders (build output) are indexed by name only.
        #expect(try await search(engine, "output") == ["App/build/output.txt"])
        #expect(try await search(engine, "zebra").isEmpty)
        // Changing an extraction setting must not pull excluded files back in.
        var settings = await controller.settings
        settings.maxContentKilobytes = 128
        try await controller.updateSettings(settings)
        try await controller.indexNow(full: false)
        #expect(try await search(engine, "zebra").isEmpty)

        let stats = try database.stats()
        #expect(stats.contentPending == 0)
        #expect(stats.contentIndexed == 4)
    }

    @Test func appliesModificationsAndDeletions() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        let receipt = root.appending(path: "Documents/Taxes/receipt.txt")
        try Data("Electricity bill, nothing about housing.".utf8).write(to: receipt)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: receipt.path)
        try FileManager.default.removeItem(at: root.appending(path: "Documents/greek-note.md"))
        try FileManager.default.moveItem(at: root.appending(path: "Documents/Taxes"), to: root.appending(path: "Archive"))
        try await controller.apply([
            FileChange(path: receipt.path, rescanSubtree: false),
            FileChange(path: root.appending(path: "Documents/greek-note.md").path, rescanSubtree: false),
            FileChange(path: root.appending(path: "Documents/Taxes").path, rescanSubtree: false),
            FileChange(path: root.appending(path: "Archive").path, rescanSubtree: true),
        ])
        try await controller.indexNow(full: false)

        #expect(try await search(engine, "apartment").isEmpty)
        #expect(try await search(engine, "electricity") == ["Archive/receipt.txt"])
        #expect(try await search(engine, "αποδειξη").isEmpty)
    }

    @Test func pauseStopsWorkAndRebuildStartsOver() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        try await controller.rebuild()
        #expect(try database.stats().files == 0)
        #expect(try database.meta("scan.generation") == nil)
        try await controller.indexNow(full: false)  // no resumable state: scans again
        #expect(try database.stats().contentIndexed == 4)
        await controller.setPaused(true)
        #expect(await controller.currentProgress().isPaused)
    }

    @Test func picksUpChangesFromFSEvents() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        try await controller.start()
        defer { Task { await controller.stop() } }
        let engine = SearchEngine(database: database, home: root.path)

        try Data("quokka sighting notes".utf8).write(to: root.appending(path: "Documents/new.txt"))
        var found: [String] = []
        for _ in 0..<40 where found.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
            found = try await search(engine, "quokka")
        }
        #expect(found == ["Documents/new.txt"])
    }

    @Test func regexSearchUsesRipgrepAndIndexedText() async throws {
        guard RegexSearcher.locateRipgrep() != nil else { return }
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try TestSupport.writePDF(text: "Invoice INV-2026-0042 due", to: root.appending(path: "Documents/invoice.pdf"))
        try await controller.indexNow(full: true)
        let searcher = try RegexSearcher(database: database)

        var hits: [RegexHit] = []
        for try await hit in searcher.search(pattern: #"INV-\d{4}-\d+|invoice[A-Z]\w+"#, filters: SearchQuery()) {
            hits.append(hit)
        }
        let paths = Set(hits.map { ($0.path as NSString).lastPathComponent })
        #expect(paths == ["invoice.pdf", "Billing.swift"])
        #expect(hits.first { $0.path.hasSuffix("Billing.swift") }?.lines.first?.number == 1)

        await #expect(throws: RegexSearcher.RegexError.self) {
            for try await _ in searcher.search(pattern: "([", filters: SearchQuery()) {}
        }
    }

    @Test func vectorIndexRanksByBestChunk() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let ids = try await database.pool.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM file WHERE isDir = 0 ORDER BY id LIMIT 2") }
        func unit(_ values: [Float]) -> [Float] {
            let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
            return values.map { $0 / norm }
        }
        try database.storeEmbeddings([
            (ids[0], [unit([1, 0, 0, 0]), unit([0, 1, 0, 0])]),
            (ids[1], [unit([0.6, 0.8, 0, 0])]),
        ])
        let index = try VectorIndex(database: database)
        let ranking = index.search(unit([0, 1, 0, 0]), limit: 5)
        #expect(ranking.hits.map(\.fileID) == [ids[0], ids[1]])
        #expect(ranking.hits[0].chunk == 1)
        #expect(abs(ranking.hits[0].score - 1) < 0.01)
        #expect(abs(ranking.hits[1].score - 0.8) < 0.01)
        // Only the clear winner stands out (0.8 is within reach of the best but not of 2σ).
        let standouts = SearchEngine.standouts(VectorIndex.Ranking(
            hits: [.init(fileID: 1, score: 0.84, chunk: 0), .init(fileID: 2, score: 0.79, chunk: 0), .init(fileID: 3, score: 0.72, chunk: 0)], mean: 0.70, deviation: 0.03, count: 1000))
        #expect(standouts.map(\.fileID) == [1, 2])
        #expect(SearchEngine.standouts(VectorIndex.Ranking(hits: [.init(fileID: 1, score: 0.84, chunk: 0), .init(fileID: 2, score: 0.72, chunk: 0)], mean: 0.70, deviation: 0.03, count: 1000)).map(\.fileID) == [1])
        // Small index: one deviation.
        #expect(SearchEngine.standouts(VectorIndex.Ranking(hits: [.init(fileID: 1, score: 0.84, chunk: 0), .init(fileID: 2, score: 0.79, chunk: 0)], mean: 0.75, deviation: 0.056, count: 5)).map(\.fileID) == [1])
    }
}
