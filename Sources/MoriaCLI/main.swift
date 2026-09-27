import ArgumentParser
import Foundation
import MoriaCore

@main
struct Moria: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "moria",
        abstract: "Deep file search for macOS: filenames, contents, regex, meaning.",
        subcommands: [Index.self, Watch.self, Search.self, Stats.self, Config.self]
    )
}

struct DatabaseOption: ParsableArguments {
    @Option(help: "Index database path (default: the Moria app's index).")
    var db: String?

    func open() throws -> IndexDatabase {
        MaterializationGuard.disableDownloads()
        return try IndexDatabase(url: db.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? IndexDatabase.defaultURL)
    }
}

// MARK: - index

struct Index: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan and extract until the index is up to date.")

    @OptionGroup var database: DatabaseOption
    @Flag(help: "Force a full filesystem scan even if the index can be updated incrementally.")
    var full = false
    @Flag(help: "Only crawl metadata; skip content extraction.")
    var metadataOnly = false

    func run() async throws {
        let db = try database.open()
        let controller = try IndexController(database: db)
        let started = Date()
        let reporter = Task {
            var lastPhase: IndexProgress.Phase?
            for await progress in controller.progress {
                let elapsed = String(format: "%6.1fs", Date().timeIntervalSince(started))
                switch progress.phase {
                case .scanning:
                    print("\(elapsed)  scanning   \(progress.scannedEntries) entries")
                case .extracting:
                    print("\(elapsed)  extracting \(progress.extractedFiles) done, \(progress.remainingFiles) left")
                case .recognizingText:
                    print("\(elapsed)  OCR        \(progress.extractedFiles) done, \(progress.remainingFiles) left")
                case .embedding:
                    print("\(elapsed)  embedding  \(progress.embeddedFiles) files")
                case .updating, .idle:
                    if lastPhase != progress.phase { print("\(elapsed)  \(progress.phase.rawValue)") }
                }
                lastPhase = progress.phase
            }
        }
        if metadataOnly {
            try await controller.scanOnly()
        } else {
            try await controller.indexNow(full: full)
        }
        reporter.cancel()
        let progress = await controller.currentProgress()
        let stats = try db.stats()
        print(String(format: "done in %.1fs", Date().timeIntervalSince(started)))
        print(Stats.format(stats))
        if progress.unreadableDirectories > 0 {
            print("\(progress.unreadableDirectories) folders were unreadable (no Full Disk Access, or cloud-only).")
        }
    }
}

// MARK: - watch

struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Keep the index updated from filesystem events until interrupted.")

    @OptionGroup var database: DatabaseOption

    func run() async throws {
        let controller = try IndexController(database: database.open())
        try await controller.start()
        print("Watching for changes. Press Ctrl-C to stop.")
        for await progress in controller.progress where progress.phase != .idle {
            print("\(progress.phase.rawValue): extracted \(progress.extractedFiles), \(progress.remainingFiles) pending")
        }
    }
}

// MARK: - search

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search the index.",
        discussion: """
            Query syntax: words, "phrases", -exclude, ext:pdf,docx kind:image size:>10mb \
            modified:<7d modified:2026-03..2026-05 created:today in:~/Documents name:x content:y \
            hidden:no cloud:no
            """
    )

    @OptionGroup var database: DatabaseOption
    // Options may follow the query (`moria search "lease" --json`); tokens that aren't options,
    // including exclusions such as `-draft` or `-kind:folder`, stay in the query. There are no
    // short options, so an exclusion like `-lease` can't be read as a group of flags.
    @Argument(parsing: .allUnrecognized, help: "The query.")
    var query: [String]
    @Option(help: "Maximum results.")
    var limit = 30
    @Flag(help: "Treat the query as a regular expression over file contents and names.")
    var regex = false
    @Flag(help: "Blend in semantic (meaning-based) matches. Requires embeddings.")
    var semantic = false
    @Flag(help: "Interpret the query as a plain-language request with the on-device model.")
    var ask = false
    @Flag(help: "Print JSON lines.")
    var json = false
    @Flag(help: "Show the search in the Moria app instead of printing results.")
    var show = false

    func run() async throws {
        let text = query.joined(separator: " ")
        if show {
            var components = URLComponents(string: "moria://search")!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            if regex { components.queryItems?.append(URLQueryItem(name: "scope", value: "regex")) }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [components.url!.absoluteString]
            try open.run()
            open.waitUntilExit()
            return
        }
        let db = try database.open()
        let started = Date()
        if regex {
            try await runRegex(db: db, pattern: text)
            return
        }
        var parsed = QueryParser().parse(text)
        if ask {
            let interpretation = try await NaturalLanguageQuery().interpret(text)
            parsed = interpretation.query
            FileHandle.standardError.write(Data("interpreted: \(interpretation.summary)\n".utf8))
        }
        let engine = SearchEngine(database: db)
        let results = try await engine.search(parsed, limit: limit, semantic: semantic)
        let elapsed = Date().timeIntervalSince(started) * 1000
        for var result in results {
            result.snippet = try await engine.snippet(for: result, query: parsed)
            if json {
                print(Self.json(result))
            } else {
                let why = [result.matchedName ? "name" : nil, result.matchedContent ? "content" : nil, result.matchedMeaning ? "meaning" : nil]
                    .compactMap { $0 }.joined(separator: "+")
                print("\(result.path)  [\(why)]")
                if let snippet = result.snippet {
                    print("    " + Self.terminalHighlight(snippet))
                }
            }
        }
        if !json {
            FileHandle.standardError.write(Data(String(format: "%d results in %.1f ms\n", results.count, elapsed).utf8))
        }
    }

    private func runRegex(db: IndexDatabase, pattern: String) async throws {
        var count = 0
        let searcher = try RegexSearcher(database: db)
        for try await hit in searcher.search(pattern: pattern, filters: SearchQuery(), maxFiles: limit) {
            count += 1
            if json {
                let lines = hit.lines.map { ["line": $0.number, "text": $0.text] as [String: Any] }
                let data = try JSONSerialization.data(withJSONObject: ["path": hit.path, "lines": lines])
                print(String(decoding: data, as: UTF8.self))
            } else {
                print(hit.path + (hit.nameMatched ? "  [name]" : ""))
                for line in hit.lines.prefix(3) {
                    print("    \(line.number): \(line.text)")
                }
            }
        }
        FileHandle.standardError.write(Data("\(count) files\n".utf8))
    }

    static func terminalHighlight(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: String(SearchResult.highlightStart), with: "\u{1B}[1;33m")
            .replacingOccurrences(of: String(SearchResult.highlightEnd), with: "\u{1B}[0m")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func json(_ result: SearchResult) -> String {
        let object: [String: Any] = [
            "path": result.path, "kind": result.kind.rawValue, "size": result.size,
            "modified": ISO8601DateFormatter().string(from: result.modified),
            "matchedName": result.matchedName, "matchedContent": result.matchedContent,
            "matchedMeaning": result.matchedMeaning, "score": result.score,
            "snippet": result.snippet.map { $0.filter { $0 != SearchResult.highlightStart && $0 != SearchResult.highlightEnd } } as Any,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - stats

struct Stats: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show index size and counts.")

    @OptionGroup var database: DatabaseOption

    func run() async throws {
        print(Self.format(try database.open().stats()))
    }

    static func format(_ stats: IndexDatabase.Stats) -> String {
        let size = ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file)
        return """
            files: \(stats.files)  folders: \(stats.folders)  cloud-only: \(stats.cloudOnly)
            content indexed: \(stats.contentIndexed)  pending: \(stats.contentPending)  embedded chunks: \(stats.embeddedChunks)
            database: \(size)
            """
    }
}

// MARK: - config

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or change settings (shared with the app).")

    @OptionGroup var database: DatabaseOption
    @Option(help: "Set a setting: key=value. Lists take comma-separated values.")
    var set: [String] = []

    func run() async throws {
        let db = try database.open()
        let controller = try IndexController(database: db)
        var settings = await controller.settings
        if !set.isEmpty {
            for assignment in set {
                try Self.apply(assignment, to: &settings)
            }
            try await controller.updateSettings(settings)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(settings), as: UTF8.self))
    }

    static func apply(_ assignment: String, to settings: inout MoriaSettings) throws {
        guard let equals = assignment.firstIndex(of: "=") else { throw ValidationError("Expected key=value, got \(assignment)") }
        let key = String(assignment[..<equals])
        let value = String(assignment[assignment.index(after: equals)...])
        func list() -> [String] { value.split(separator: ",").map { ($0.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath } }
        func bool() throws -> Bool {
            guard let flag = Bool(value.lowercased()) else { throw ValidationError("\(key) expects true or false") }
            return flag
        }
        func int() throws -> Int {
            guard let number = Int(value), number > 0 else { throw ValidationError("\(key) expects a positive number") }
            return number
        }
        switch key {
        case "roots": settings.roots = list()
        case "excludedPaths": settings.excludedPaths = list()
        case "excludedNames": settings.excludedNames = value.split(separator: ",").map(String.init)
        case "includeHidden": settings.includeHidden = try bool()
        case "descendIntoPackages": settings.descendIntoPackages = try bool()
        case "maxContentKilobytes": settings.maxContentKilobytes = try int()
        case "maxFileMegabytes": settings.maxFileMegabytes = try int()
        case "ocrImages": settings.ocrImages = try bool()
        case "ocrScannedPDFs": settings.ocrScannedPDFs = try bool()
        case "semanticSearchEnabled": settings.semanticSearchEnabled = try bool()
        case "naturalLanguageQueriesEnabled": settings.naturalLanguageQueriesEnabled = try bool()
        default: throw ValidationError("Unknown setting \(key)")
        }
    }
}
