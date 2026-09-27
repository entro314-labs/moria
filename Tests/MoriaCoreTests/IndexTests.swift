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
        let ranked = index.search(unit([0, 1, 0, 0]), limit: 5, minimumScore: 0)
        #expect(ranked.map(\.fileID) == [ids[0], ids[1]])
        #expect(abs(ranked[0].score - 1) < 0.01)
        #expect(abs(ranked[1].score - 0.8) < 0.01)
    }
}
