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
        // Name operators, path and extension filters.
        #expect(try await search(engine, "name:Bill*") == ["Documents/Billing.swift"])
        #expect(try await search(engine, "name:*.md") == ["Documents/greek-note.md"])
        #expect(try await search(engine, "name:/^(draft|receipt)\\.txt$/").sorted() == ["Documents/Taxes/receipt.txt", "Documents/draft.txt"])
        #expect(try await search(engine, "path:Taxes kind:text") == ["Documents/Taxes/receipt.txt"])
        #expect(try await search(engine, "rent -ext:txt").isEmpty)

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

    @Test func combinesNameAndContentConditions() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        // The criteria builder writes "Name contains" + "Contents contains" as these two tokens.
        #expect(try await search(engine, "name:receipt content:apartment") == ["Documents/Taxes/receipt.txt"])
        #expect(try await search(engine, "name:draft content:apartment").isEmpty)
        // Short name words are prefixes, as in name-only searches.
        #expect(try await search(engine, "name:re content:apartment") == ["Documents/Taxes/receipt.txt"])
        // A plain word may match the contents of a file whose name has the `name:` word.
        #expect(try await search(engine, "name:receipt apartment") == ["Documents/Taxes/receipt.txt"])
        // Name-only and contents-only words never cross over (the Names and Contents modes).
        var names = SearchQuery()
        names.nameTerms = ["rent receipt"]
        #expect(try await engine.search(names).isEmpty)
        var contents = SearchQuery()
        contents.contentTerms = ["receipt"]
        #expect(try await engine.search(contents).allSatisfy { !$0.matchedName })
    }

    @Test func exclusionsApplyWithoutSearchWords() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        #expect(try await search(engine, "kind:text -draft").sorted()
            == ["App/build/output.txt", "Documents/Taxes/receipt.txt", "Documents/greek-note.md"])
        // Content exclusion: both receipts mention rent; build output has no indexed text.
        #expect(try await search(engine, "kind:text -rent").sorted() == ["App/build/output.txt", "Documents/greek-note.md"])
        let everythingButDrafts = try await search(engine, "-draft")
        #expect(!everythingButDrafts.isEmpty && !everythingButDrafts.contains("Documents/draft.txt"))
        // Accents in the name don't defeat an exclusion.
        // Composed "é", as Finder names files (Foundation's URL writes would decompose it).
        let cafe = root.path + "/Documents/Caf\u{E9} menu.txt"
        close(creat(cafe, 0o644))
        try await controller.apply([FileChange(path: cafe, rescanSubtree: false)])
        #expect(try await search(engine, "menu") == ["Documents/Café menu.txt"])
        #expect(try await search(engine, "menu -cafe").isEmpty)
    }

    @Test func settingsChangedByAnotherProcessTriggerAScan() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let extra = try TestSupport.makeTempDirectory()
        try Data("wombat burrow survey".utf8).write(to: extra.appending(path: "field.txt"))

        // `moria config --set roots=…` changes the roots from its own controller, then exits.
        let cli = try IndexController(database: database)
        var settings = await cli.settings
        settings.roots.append(extra.path)
        try await cli.updateSettings(settings)

        // The next controller (the app at launch) must scan instead of resuming from FSEvents.
        let app = try IndexController(database: database)
        try await app.indexNow(full: false)
        let engine = SearchEngine(database: database, home: root.path)
        #expect(try await engine.search(QueryParser().parse("wombat")).map(\.name) == ["field.txt"])
    }

    @Test func runningControllerAdoptsSettingsSavedElsewhere() async throws {
        let (database, running) = try await TestSupport.makeIndex(root: root)
        try await running.indexNow(full: true)
        let extra = try TestSupport.makeTempDirectory()
        try Data("wombat burrow survey".utf8).write(to: extra.appending(path: "field.txt"))

        let cli = try IndexController(database: database)
        var settings = await cli.settings
        settings.roots.append(extra.path)
        try await cli.updateSettings(settings)

        #expect(try await running.reloadSettings().roots == [root.path, extra.path])
        try await running.indexNow(full: false)
        let engine = SearchEngine(database: database, home: root.path)
        #expect(try await engine.search(QueryParser().parse("wombat")).map(\.name) == ["field.txt"])
        // A later change from the running app keeps what the CLI set.
        var mine = await running.settings
        mine.ocrScannedPDFs = false
        try await running.updateSettings(mine)
        #expect(try database.loadSettings().roots == [root.path, extra.path])
    }

    @Test func extractionSettingChangesKeepTextSearchable() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        var settings = await controller.settings
        settings.maxContentKilobytes = 128
        try await controller.updateSettings(settings)
        // Queued to be read again, but the old text still finds the file meanwhile.
        #expect(try database.stats().contentPending == 4)
        #expect(try await search(engine, "apartment") == ["Documents/Taxes/receipt.txt"])
        try await controller.indexNow(full: false)
        #expect(try database.stats().contentPending == 0)
        #expect(try await search(engine, "apartment") == ["Documents/Taxes/receipt.txt"])

        // A stale file that no longer yields text loses its old text.
        try database.requeueContent()
        let (id, mtime) = try await database.pool.read { db in
            (try Int64.fetchOne(db, sql: "SELECT id FROM file WHERE name = 'receipt.txt'")!,
             try Double.fetchOne(db, sql: "SELECT mtime FROM file WHERE name = 'receipt.txt'")!)
        }
        try database.store([ExtractionResult(id: id, mtime: mtime, state: .none, text: nil, storeText: false)])
        #expect(try await search(engine, "apartment").isEmpty)
    }

    @Test func symlinksAreIndexedByNameOnly() async throws {
        let outside = try TestSupport.makeTempDirectory()
        try Data("platypus habitat notes".utf8).write(to: outside.appending(path: "notes.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "Documents/link.txt").path,
                                                   withDestinationPath: outside.appending(path: "notes.txt").path)
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        #expect(try await search(engine, "platypus").isEmpty)
        #expect(try await search(engine, "name:link") == ["Documents/link.txt"])
        guard RegexSearcher.locateRipgrep() != nil else { return }
        var hits: [RegexHit] = []
        for try await hit in try RegexSearcher(database: database).search(pattern: "platypus", filters: SearchQuery()) {
            hits.append(hit)
        }
        #expect(hits.isEmpty)
    }

    @Test func packageLocationsAndLocationsUnderHiddenFoldersGetLiveUpdates() async throws {
        // A package added as a location is crawled and updated like a folder.
        let package = root.appending(path: "Tools.app")
        let (database, controller) = try await TestSupport.makeIndex(root: package)
        try await controller.indexNow(full: true)
        try Data("zanzibar release notes".utf8).write(to: package.appending(path: "Contents/notes.txt"))
        try await controller.apply([FileChange(path: package.appending(path: "Contents/notes.txt").path, rescanSubtree: false)])
        try await controller.indexNow(full: false)
        let engine = SearchEngine(database: database, home: root.path)
        #expect(try await engine.search(QueryParser().parse("zanzibar")).map(\.name) == ["notes.txt"])

        // Folders above a location don't exclude it, as in the crawl.
        let project = root.appending(path: ".config/project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let (hiddenDatabase, hiddenController) = try await TestSupport.makeIndex(root: project)
        var settings = await hiddenController.settings
        settings.includeHidden = false
        try await hiddenController.updateSettings(settings)
        try await hiddenController.indexNow(full: true)
        try Data("quetzal".utf8).write(to: project.appending(path: "bird.txt"))
        try await hiddenController.apply([FileChange(path: project.appending(path: "bird.txt").path, rescanSubtree: false)])
        let hiddenEngine = SearchEngine(database: hiddenDatabase, home: root.path)
        #expect(try await hiddenEngine.search(QueryParser().parse("name:bird")).map(\.name) == ["bird.txt"])
    }

    @Test func cancelledScanKeepsTheIndex() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let files = try database.stats().files

        let scan = Task { try await controller.scanOnly() }
        scan.cancel()
        _ = await scan.result
        #expect(try database.stats().files == files)
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
        try await controller.indexNow(full: true)
        #expect(try database.meta("scan.generation") == "2")
        // The erase waits for the work loop, so it can never interleave with a running scan
        // (which would leave rows under deleted folders and a reset generation counter).
        await controller.rebuild()
        #expect(try database.stats().files > 0)
        try await controller.indexNow(full: false)  // the requested rebuild runs here
        #expect(try database.meta("scan.generation") == "1")
        #expect(try database.stats().contentIndexed == 4)
        let orphans = try await database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM file WHERE dirId NOT IN (SELECT id FROM dir)")
        }
        #expect(orphans == 0)
        await controller.setPaused(true)
        #expect(await controller.currentProgress().isPaused)
        // Confirming a rebuild means now: it resumes paused indexing.
        await controller.rebuild()
        #expect(await !controller.currentProgress().isPaused)
    }

    @Test func picksUpChangesFromFSEvents() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        try await controller.start()
        defer { Task { await controller.stop() } }
        let engine = SearchEngine(database: database, home: root.path)

        // Written by another process: the stream ignores this process's own events.
        let writer = try Process.run(URL(fileURLWithPath: "/bin/sh"), arguments: [
            "-c", "echo 'quokka sighting notes' > \"$0\"", root.appending(path: "Documents/new.txt").path,
        ])
        writer.waitUntilExit()
        var found: [String] = []
        for _ in 0..<40 where found.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
            found = try await search(engine, "quokka")
        }
        #expect(found == ["Documents/new.txt"])

        // Tagging in another process (as Finder does) changes only an extended attribute.
        let tagger = try Process.run(URL(fileURLWithPath: "/usr/bin/xattr"), arguments: [
            "-wx", "com.apple.metadata:_kMDItemUserTags",
            // A binary property list of ["Purple"].
            "62706C6973743030A10156507572706C65080A0000000000000101000000000000000200000000000000000000000000000011",
            root.appending(path: "Documents/draft.txt").path,
        ])
        tagger.waitUntilExit()
        var tagged: [String] = []
        for _ in 0..<40 where tagged.isEmpty {
            try await Task.sleep(for: .milliseconds(250))
            tagged = try await search(engine, "tag:purple")
        }
        #expect(tagged == ["Documents/draft.txt"])
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

        // Files get PCRE2 when a pattern needs it, so look-around and inline flags work as for
        // names and document text.
        func names(_ pattern: String) async throws -> Set<String> {
            var found = Set<String>()
            for try await hit in searcher.search(pattern: pattern, filters: SearchQuery()) {
                found.insert((hit.path as NSString).lastPathComponent)
            }
            return found
        }
        #expect(try await names(#"(?<=rent )receipt\b"#) == ["receipt.txt", "draft.txt"])
        #expect(try await names(#"(?<=Invoice )INV-\d+"#) == ["invoice.pdf"])
        #expect(try await names("monthly rent") == ["receipt.txt"])
        #expect(try await names("(?-i)monthly rent").isEmpty)
    }

    @Test func filesOutsideTheSemanticIndexNeverWaitForEmbedding() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        func waiting() async throws -> [String] {
            try database.filesNeedingEmbedding(limit: 100, home: root.path).map { ($0.path as NSString).lastPathComponent }.sorted()
        }
        func backlog() async throws -> Int {
            try await database.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM file WHERE embedState = 0 AND contentState = 1")! }
        }
        // Newly read code is marked when it is stored; documents wait.
        #expect(try await waiting() == ["draft.txt", "greek-note.md", "receipt.txt"])
        #expect(try await backlog() == 3)
        // Indexes from before that are cleaned in one pass.
        try await database.pool.write { db in try db.execute(sql: "UPDATE file SET embedState = 0 WHERE contentState = 1") }
        #expect(try await backlog() == 4)
        try database.markNotEmbeddable(home: root.path)
        #expect(try await backlog() == 3)
        // Turning meaning off and on again keeps them out.
        try database.clearEmbeddings()
        #expect(try await backlog() == 3)
    }

    @Test func vectorIndexReloadsAtMostOnceAMinute() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let id = try await database.pool.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM file WHERE isDir = 0 LIMIT 1")! }
        try database.storeEmbeddings([(id, [(0, [1, 0])])])
        let cache = VectorCache()
        let start = Date()
        let first = try await cache.index(for: database, now: start)
        try database.storeEmbeddings([(id, [(0, [0, 1])])])
        #expect(try await cache.index(for: database, now: start.addingTimeInterval(10)).version == first.version)
        #expect(try await cache.index(for: database, now: start.addingTimeInterval(61)).version == first.version + 1)
    }

    @Test func vectorIndexRanksByBestChunk() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let ids = try await database.pool.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM file WHERE isDir = 0 ORDER BY id LIMIT 2") }
        func unit(_ values: [Float]) -> [Float] {
            let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
            return values.map { $0 / norm }
        }
        // Chunk positions are kept as given: a skipped chunk (unsupported language) leaves a gap.
        try database.storeEmbeddings([
            (ids[0], [(0, unit([1, 0, 0, 0])), (2, unit([0, 1, 0, 0]))]),
            (ids[1], [(0, unit([0.6, 0.8, 0, 0]))]),
        ])
        let index = try VectorIndex(database: database)
        let ranking = index.search(unit([0, 1, 0, 0]), limit: 5)
        #expect(ranking.hits.map(\.fileID) == [ids[0], ids[1]])
        #expect(ranking.hits[0].chunk == 2)
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

    @Test func similarRanksDocumentsCloseInMeaningAndLeavesOutTheFile() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        func id(_ path: String) async throws -> Int64 {
            try await database.pool.read { db in
                try Int64.fetchOne(db, sql: "SELECT f.id FROM file f JOIN dir d ON d.id = f.dirId WHERE d.path || '/' || f.name = ?",
                                   arguments: [root.path + "/" + path])!
            }
        }
        func unit(_ values: [Float]) -> [Float] {
            let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
            return values.map { $0 / norm }
        }
        let receipt = try await id("Documents/Taxes/receipt.txt")
        let draft = try await id("Documents/draft.txt")
        try database.storeEmbeddings([
            (receipt, [(0, unit([1, 0, 0, 0]))]),
            (draft, [(0, unit([0.95, 0.05, 0, 0]))]),
            (try await id("Documents/greek-note.md"), [(0, unit([0, 1, 0, 0]))]),
            (try await id("Documents/Billing.swift"), [(0, unit([0, 0, 1, 0]))]),
            (try await id("App/build/output.txt"), [(0, unit([0, 0, 0, 1]))]),
        ])
        let engine = SearchEngine(database: database, home: root.path)
        let similar = try await engine.search(QueryParser(home: root.path).parse("similar:\(root.path)/Documents/Taxes/receipt.txt"))
        #expect(similar.map(\.id) == [draft])
        #expect(similar.first?.matchedMeaning == true)
        // Filters and words narrow the matches.
        #expect(try await engine.search(QueryParser(home: root.path).parse("similar:\(root.path)/Documents/Taxes/receipt.txt ext:md")).isEmpty)
        #expect(try await engine.search(QueryParser(home: root.path).parse("draft similar:\(root.path)/Documents/Taxes/receipt.txt")).map(\.id) == [draft])
        #expect(try await engine.search(QueryParser(home: root.path).parse("apartment similar:\(root.path)/Documents/Taxes/receipt.txt")).isEmpty)
        // A file without vectors can't be a starting point.
        await #expect(throws: SearchEngine.SearchError.self) {
            try await engine.search(QueryParser(home: root.path).parse("similar:\(root.path)/Tools.app"))
        }
    }

    @Test func finderTagsAreIndexedWhereContentsAreRead() async throws {
        func tag(_ path: String, _ tags: [String]) throws {
            try (root.appending(path: path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        try tag("Documents/Taxes/receipt.txt", ["Red", "Needs Review"])
        try tag("Documents/draft.txt", ["Blue"])
        try tag("App/build/output.txt", ["Red"])  // names-only folder: tags aren't read there
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        #expect(try await search(engine, "tag:red") == ["Documents/Taxes/receipt.txt"])
        #expect(try await search(engine, #"tag:"needs review""#) == ["Documents/Taxes/receipt.txt"])
        #expect(try await search(engine, "tag:blue,red").sorted() == ["Documents/Taxes/receipt.txt", "Documents/draft.txt"])
        #expect(try await search(engine, "rent -tag:red") == ["Documents/draft.txt"])
        // A whole tag, not part of one.
        #expect(try await search(engine, "tag:re").isEmpty)
        let hit = try #require(try await engine.search(QueryParser(home: root.path).parse("tag:red")).first)
        #expect(hit.tags == ["Red", "Needs Review"])
        #expect(try engine.tagNames() == ["Blue", "Needs Review", "Red"])

        // Tagging changes neither the date nor the size; the watcher reports the path and the
        // change is picked up.
        try tag("Documents/draft.txt", [])
        try tag("Documents/Billing.swift", ["Green"])
        try await controller.apply([
            FileChange(path: root.appending(path: "Documents/draft.txt").path, rescanSubtree: false),
            FileChange(path: root.appending(path: "Documents/Billing.swift").path, rescanSubtree: false),
        ])
        #expect(try await search(engine, "tag:blue").isEmpty)
        #expect(try await search(engine, "tag:green") == ["Documents/Billing.swift"])
    }
}
