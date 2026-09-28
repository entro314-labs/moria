import Foundation
import GRDB

/// One ranked search hit.
public struct SearchResult: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var path: String
    public var name: String
    public var ext: String
    public var kind: FileKind
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var created: Date
    public var isCloudOnly: Bool
    /// On a drive or network volume that isn't connected: indexed, but can't be opened now.
    public var isOffline = false
    /// When a photo was taken; length of audio or video in seconds; a document's author.
    public var taken: Date?
    public var duration: Double?
    public var author: String?
    /// What a photo shows, as recognized ("beach", "screenshot").
    public var labels: [String] = []
    /// For `duplicates:yes`: which group of identical files this is in (1 = most space wasted),
    /// and how many files the group has.
    public var duplicateGroup: Int?
    public var copies: Int?
    /// Finder tag names.
    public var tags: [String] = []
    /// Why it matched.
    public var matchedName: Bool
    public var matchedContent: Bool
    public var matchedMeaning: Bool
    /// The words describe what the photo shows (its labels).
    public var matchedLabel = false
    /// For meaning matches: which embedded chunk of the document was closest.
    public var meaningChunk: Int?
    /// Content excerpt, filled by `SearchEngine.snippet(for:query:)`; matched spans are wrapped
    /// in `highlightStart`/`highlightEnd`.
    public var snippet: String?
    public var score: Double

    public static let highlightStart: Character = "\u{1}"
    public static let highlightEnd: Character = "\u{2}"

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Content match details for one result.
public struct MatchDetails: Sendable, Equatable {
    /// One-line excerpt with highlight markers.
    public var snippet: String?
    /// Matching lines in the text read (the first 256 KB, or the stored document text).
    public var matchCount: Int
    public var lines: [MatchLine]
    /// For meaning matches, the passage closest to the query.
    public var passage: String?
}

/// A matching line with highlight markers.
public struct MatchLine: Sendable, Equatable, Hashable {
    public var number: Int
    public var text: String
}

/// Runs searches against the index.
///
/// Every database read in a search is an async GRDB read: it runs on GRDB's reader queue and,
/// when the searching task is cancelled (a new search started, or Stop), SQLite is interrupted
/// and `CancellationError` is thrown, so an abandoned search stops within milliseconds instead of
/// running to the end.
///
/// Name and content hits come from separate FTS5 tables and are fused with reciprocal rank
/// fusion (RRF); semantic hits join the fusion when enabled. RRF only needs each list's order,
/// so BM25 scores from different tables never have to be compared directly.
public final class SearchEngine: Sendable {
    public let database: IndexDatabase
    private let embedder: Embedder
    private let vectors = VectorCache()
    let home: String

    public init(database: IndexDatabase, embedder: Embedder = Embedder(), home: String = NSHomeDirectory()) {
        self.database = database
        self.embedder = embedder
        self.home = home
    }

    /// RRF constant; 60 is the value from the original paper and works well untuned.
    static let fusionK = 60.0
    static let nameWeight = 1.5
    static let contentWeight = 1.0
    static let labelWeight = 0.8
    static let semanticWeight = 0.9

    public enum SearchError: Error, CustomStringConvertible, LocalizedError {
        /// `similar:` names a file the semantic index doesn't cover.
        case notInMeaningIndex(String)

        public var description: String {
            switch self {
            case let .notInMeaningIndex(path):
                "“\((path as NSString).lastPathComponent)” isn't in the meaning index. Turn on Meaning in Settings › Intelligence; it covers documents, PDFs, notes and recognized text outside Library and hidden folders."
            }
        }

        public var errorDescription: String? { description }
    }

    public func search(_ query: SearchQuery, limit: Int = 500, semantic: Bool = false) async throws -> [SearchResult] {
        try markOffline(try await rankedResults(query, limit: limit, semantic: semantic))
    }

    /// Flags results on drives that aren't connected.
    private func markOffline(_ results: [SearchResult]) throws -> [SearchResult] {
        let offline = try database.offlineMountPoints()
        guard !offline.isEmpty else { return results }
        return results.map { result in
            var result = result
            result.isOffline = offline.contains { Volumes.isInside(result.path, $0) }
            return result
        }
    }

    private func rankedResults(_ query: SearchQuery, limit: Int, semantic: Bool) async throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        if query.duplicatesOnly {
            return try await duplicates(query, limit: limit, semantic: semantic)
        }
        if let path = query.similarTo {
            return try await similar(to: path, query: query, limit: limit)
        }
        guard query.hasTextCriteria else {
            return try await filterOnly(query, limit: limit)
        }
        let (nameHits, contentHits, labelHits) = try await database.pool.read { db in
            (try self.nameMatches(query, db: db, limit: limit),
             try self.textMatches(query, in: "content_fts", db: db, limit: limit).map { hit in
                 var hit = hit
                 hit.matchedContent = true
                 return hit
             },
             try self.textMatches(query, in: "label_fts", db: db, limit: limit).map { hit in
                 var hit = hit
                 hit.matchedLabel = true
                 return hit
             })
        }
        var semanticHits: [(fileID: Int64, chunk: Int)] = []
        if semantic, !query.semanticText.isEmpty {
            semanticHits = try await semanticMatches(query, limit: 200)
        }
        return try await fuse(query: query, names: nameHits, contents: contentHits, labels: labelHits, semantic: semanticHits, limit: limit)
    }

    // MARK: - Candidate lists

    private func nameMatches(_ query: SearchQuery, db: Database, limit: Int) throws -> [SearchResult] {
        let words = query.terms + query.nameTerms + query.phrases
        guard query.contentTerms.isEmpty, !words.isEmpty else { return [] }
        // Trigram FTS needs 3+ characters; shorter words become a filename prefix match. Greek
        // and Cyrillic words match by their stem (a substring of every form); phrases don't.
        let folded = (query.terms + query.nameTerms).map { Stemmer.stem($0.searchFolded) ?? $0.searchFolded }
            + query.phrases.map(\.searchFolded)
        let long = folded.filter { $0.count >= 3 }
        let short = folded.filter { $0.count < 3 }
        var filter = FilterSQL(query: query, home: home)
        for word in short {
            filter.addNamePrefix(word)
        }
        if long.isEmpty {
            // Prefix match without ORDER BY, so the scan stops at the first `limit` hits
            // instead of sorting millions of rows while the user is still typing.
            return try Row.fetchAll(db, sql: """
                SELECT \(Self.columns), 0 AS rank FROM file f JOIN dir d ON d.id = f.dirId
                WHERE \(filter.clause) LIMIT ?
                """, arguments: filter.arguments + [limit]).map { Self.result(from: $0, name: true) }
        }
        let match = long.map(Self.quote).joined(separator: " AND ")
        return try Row.fetchAll(db, sql: """
            SELECT \(Self.columns), name_fts.rank AS rank
            FROM name_fts JOIN file f ON f.id = name_fts.rowid JOIN dir d ON d.id = f.dirId
            WHERE name_fts MATCH ? AND \(filter.clause)
            ORDER BY name_fts.rank LIMIT ?
            """, arguments: [match] + filter.arguments + [limit]).map { Self.result(from: $0, name: true) }
    }

    /// Files whose text (`content_fts`) or photo labels (`label_fts`) contain the words.
    private func textMatches(_ query: SearchQuery, in table: String, db: Database, limit: Int) throws -> [SearchResult] {
        // A single letter says nothing about contents and matches most documents.
        var parts = (query.terms.filter { $0.count > 1 } + query.contentTerms).compactMap(Self.contentTerm)
        parts += query.phrases.map(Self.quote)
        guard !parts.isEmpty else { return [] }
        var filter = FilterSQL(query: query, home: home)
        // `name:` words narrow content matches to files whose names contain them.
        for word in query.nameTerms.map(\.searchFolded) {
            if word.count >= 3 {
                filter.add("f.id IN (SELECT rowid FROM name_fts WHERE name_fts MATCH ?)", Self.quote(word))
            } else {
                filter.addNamePrefix(word)
            }
        }
        return try Row.fetchAll(db, sql: """
            SELECT \(Self.columns), \(table).rank AS rank
            FROM \(table) JOIN file f ON f.id = \(table).rowid JOIN dir d ON d.id = f.dirId
            WHERE \(table) MATCH ? AND \(filter.clause)
            ORDER BY \(table).rank LIMIT ?
            """, arguments: [parts.joined(separator: " AND ")] + filter.arguments + [limit]
        ).map { Self.result(from: $0) }
    }

    private func semanticMatches(_ query: SearchQuery, limit: Int) async throws -> [(fileID: Int64, chunk: Int)] {
        guard let vector = try await embedder.embedQuery(query.semanticText) else { return [] }
        let index = try await vectors.index(for: database)
        let ranking = index.search(vector, limit: limit)
        return Self.standouts(ranking).map { ($0.fileID, $0.chunk) }
    }

    /// Documents closest in meaning to the file at `path`, best first, narrowed by the query's
    /// filters and, when it has words, to files whose contents contain them. The file itself
    /// is left out. Uses the file's embedded chunks, averaged, as the query vector.
    private func similar(to path: String, query: SearchQuery, limit: Int) async throws -> [SearchResult] {
        let fileID = try await fileID(atPath: path)
        let index = try await vectors.index(for: database)
        guard let fileID, let vector = index.meanVector(of: fileID) else { throw SearchError.notInMeaningIndex(path) }
        var ranking = index.search(vector, limit: limit + 1)
        ranking.hits.removeAll { $0.fileID == fileID }
        let hits = Self.standouts(ranking)
        let words = (query.terms + query.contentTerms + query.nameTerms).compactMap(Self.contentTerm) + query.phrases.map(Self.quote)
        let rows = try await fetch(ids: hits.map(\.fileID), query: query, contentMatch: words.isEmpty ? nil : words.joined(separator: " AND "))
        return hits.compactMap { hit in
            guard var result = rows[hit.fileID] else { return nil }
            result.matchedMeaning = true
            result.meaningChunk = hit.chunk
            result.score = Double(hit.score)
            return result
        }
    }

    private func fileID(atPath path: String) async throws -> Int64? {
        try await database.pool.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT f.id FROM file f JOIN dir d ON d.id = f.dirId WHERE d.path = ? AND f.name = ?
                """, arguments: [(path as NSString).deletingLastPathComponent, (path as NSString).lastPathComponent])
        }
    }

    /// Hits that stand out from the corpus. Absolute cosine values shift with query length
    /// (short queries score ~0.6, sentences ~0.8), so the cutoff is relative: two standard
    /// deviations above the mean similarity (one for small indexes, where even the best match
    /// can't stand out that far), and near the best hit.
    static func standouts(_ ranking: VectorIndex.Ranking) -> [VectorIndex.Hit] {
        guard let best = ranking.hits.first?.score else { return [] }
        let deviations: Float = ranking.count >= 200 ? 2 : 1
        let cutoff = max(ranking.mean + deviations * ranking.deviation, best - 0.06)
        return ranking.hits.filter { $0.score >= cutoff }
    }

    /// Filter-only searches, newest first.
    ///
    /// Selective filters (a kind, a size range, a name prefix) are fastest through their own
    /// index, but `ORDER BY mtime` makes SQLite walk the date index instead, which can mean
    /// millions of rows for a handful of hits. So candidates are collected without ordering
    /// first; only when there are many does the date-ordered query (which then stops early) run.
    private func filterOnly(_ query: SearchQuery, limit: Int) async throws -> [SearchResult] {
        let filter = FilterSQL(query: query, home: home)
        let candidateLimit = 20000
        return try await database.pool.read { db in
            let candidates = try Row.fetchAll(db, sql: """
                SELECT f.id, f.mtime FROM file f JOIN dir d ON d.id = f.dirId WHERE \(filter.clause) LIMIT ?
                """, arguments: filter.arguments + [candidateLimit])
            if candidates.count < candidateLimit {
                let newest = candidates.sorted { ($0["mtime"] as Double) > ($1["mtime"] as Double) }
                    .prefix(limit).map { $0["id"] as Int64 }
                guard !newest.isEmpty else { return [] }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT \(Self.columns) FROM file f JOIN dir d ON d.id = f.dirId
                    WHERE f.id IN (\(newest.map(String.init).joined(separator: ",")))
                    """)
                return rows.map { Self.result(from: $0) }.sorted { $0.modified > $1.modified }
            }
            return try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM file f JOIN dir d ON d.id = f.dirId
                WHERE \(filter.clause) ORDER BY f.mtime DESC LIMIT ?
                """, arguments: filter.arguments + [limit]).map { Self.result(from: $0) }
        }
    }

    // MARK: - Fusion

    private func fuse(
        query: SearchQuery, names: [SearchResult], contents: [SearchResult], labels: [SearchResult],
        semantic: [(fileID: Int64, chunk: Int)], limit: Int
    ) async throws -> [SearchResult] {
        var byID: [Int64: SearchResult] = [:]
        func add(_ hit: SearchResult, rank: Int, weight: Double) {
            let contribution = weight / (Self.fusionK + Double(rank + 1))
            if var existing = byID[hit.id] {
                existing.score += contribution
                existing.matchedName = existing.matchedName || hit.matchedName
                existing.matchedContent = existing.matchedContent || hit.matchedContent
                existing.matchedLabel = existing.matchedLabel || hit.matchedLabel
                byID[hit.id] = existing
            } else {
                var hit = hit
                hit.score = contribution
                byID[hit.id] = hit
            }
        }
        let wanted = (query.terms + query.nameTerms).map(\.searchFolded)
        for (rank, hit) in names.enumerated() {
            add(hit, rank: rank, weight: Self.nameWeight * Self.nameBonus(hit.name.searchFolded, wanted: wanted))
        }
        for (rank, hit) in contents.enumerated() {
            add(hit, rank: rank, weight: Self.contentWeight)
        }
        for (rank, hit) in labels.enumerated() {
            add(hit, rank: rank, weight: Self.labelWeight)
        }
        if !semantic.isEmpty {
            let rows = try await fetch(ids: semantic.map(\.fileID), query: query)
            for (rank, match) in semantic.enumerated() {
                guard var hit = rows[match.fileID] else { continue }
                hit.matchedMeaning = true
                hit.meaningChunk = match.chunk
                add(hit, rank: rank, weight: Self.semanticWeight)
                byID[match.fileID]?.matchedMeaning = true
                byID[match.fileID]?.meaningChunk = match.chunk
            }
        }
        return byID.values
            .map { hit in
                var hit = hit
                if isSystemLocation(hit.path) { hit.score *= 0.7 }
                return hit
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.modified > $1.modified }
            .prefix(limit)
            .map { $0 }
    }

    /// Exact and prefix filename matches outrank substring matches.
    static func nameBonus(_ name: String, wanted: [String]) -> Double {
        guard let first = wanted.first else { return 1 }
        let stem = (name as NSString).deletingPathExtension
        if stem == wanted.joined(separator: " ") || name == first { return 2 }
        if name.hasPrefix(first) { return 1.4 }
        return 1
    }

    /// Files under `~/Library` or in hidden folders are support files, rarely what's wanted.
    private func isSystemLocation(_ path: String) -> Bool {
        path.hasPrefix(home + "/Library/") || path.contains("/.")
    }

    /// Metadata for specific files (e.g. regex hits), keyed by id.
    public func metadata(for ids: [Int64]) async throws -> [Int64: SearchResult] {
        guard !ids.isEmpty else { return [:] }
        let marked = try markOffline(Array(try await fetch(ids: ids, query: SearchQuery()).values))
        return Dictionary(uniqueKeysWithValues: marked.map { ($0.id, $0) })
    }

    /// Rows for `ids` that pass the query's filters and, with `contentMatch`, whose contents
    /// match that FTS expression.
    private func fetch(ids: [Int64], query: SearchQuery, contentMatch: String? = nil) async throws -> [Int64: SearchResult] {
        guard !ids.isEmpty else { return [:] }
        var conditions = FilterSQL(query: query, home: home)
        if let contentMatch {
            conditions.add("f.id IN (SELECT rowid FROM content_fts WHERE content_fts MATCH ?)", contentMatch)
        }
        let filter = conditions
        let idList = ids.map(String.init).joined(separator: ",")
        return try await database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM file f JOIN dir d ON d.id = f.dirId
                WHERE f.id IN (\(idList)) AND \(filter.clause)
                """, arguments: filter.arguments)
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let hit = Self.result(from: row)
                return (hit.id, hit)
            })
        }
    }

    // MARK: - Snippets

    /// Bytes read from a text file to build its snippet.
    static let snippetReadBytes = 256 * 1024

    /// An excerpt showing why `result` matched, read on demand (the content index stores no text).
    ///
    /// Uses the stored text for PDFs, Office files and OCR'd images, and reads the file head
    /// for text and code. Returns nil when no excerpt applies (e.g. a filename-only match).
    public func snippet(for result: SearchResult, query: SearchQuery) async throws -> String? {
        try await details(for: result, query: query)?.snippet
    }

    /// Why a result matched in its contents: an excerpt, the number of matching lines, and the
    /// lines themselves (for the preview). For meaning-only matches, the closest passage.
    public func details(for result: SearchResult, query: SearchQuery) async throws -> MatchDetails? {
        guard result.matchedContent || result.matchedMeaning || result.matchedLabel, !result.isDirectory, !result.isCloudOnly else { return nil }
        if result.matchedLabel, !result.matchedContent, !result.matchedMeaning {
            // Only what the photo shows matched: the labels are the excerpt.
            let terms = query.terms + query.contentTerms + query.phrases
            return MatchDetails(snippet: Snippet.make(from: "Shows " + result.labels.joined(separator: ", "), terms: terms),
                                matchCount: 0, lines: [], passage: nil)
        }
        let text: String?
        if ContentExtractor.keepsExtractedText(result.kind) {
            text = try await database.pool.read { db in
                try String.fetchOne(db, sql: "SELECT body FROM doc_text WHERE fileId = ?", arguments: [result.id])
            }
        } else {
            text = try Self.readHead(of: result.path)
        }
        guard let text else { return nil }
        let terms = query.terms + query.contentTerms + query.phrases
        let lines = Snippet.matchingLines(in: text, terms: terms, limit: 200)
        if let snippet = Snippet.make(from: text, terms: terms) {
            return MatchDetails(snippet: snippet, matchCount: lines.count, lines: lines.lines, passage: nil)
        }
        guard result.matchedMeaning else { return nil }
        let chunks = Embedder.chunks(of: text)
        let passage = result.meaningChunk.flatMap { chunks.indices.contains($0) ? chunks[$0] : nil } ?? chunks.first
        return MatchDetails(snippet: passage.flatMap { Snippet.lead(of: $0) }, matchCount: 0, lines: [], passage: passage)
    }

    private static func readHead(of path: String) throws -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: snippetReadBytes), !data.isEmpty else { return nil }
        return ContentExtractor.decodeText(data)
    }

    // MARK: - SQL helpers

    static let columns = "f.id, \(IndexDatabase.pathSQL) AS path, f.name, f.ext, f.kind, f.isDir, f.size, f.mtime, f.btime, f.isCloudOnly, f.tags, f.taken, f.duration, f.author, f.labels"

    static func result(from row: Row, name: Bool = false) -> SearchResult {
        // Snippets are built on demand by `snippet(for:query:)`.
        SearchResult(
            id: row["id"], path: row["path"], name: row["name"], ext: row["ext"],
            kind: FileKind(rawValue: row["kind"]) ?? .other, isDirectory: row["isDir"], size: row["size"],
            modified: Date(timeIntervalSince1970: row["mtime"]), created: Date(timeIntervalSince1970: row["btime"]),
            isCloudOnly: row["isCloudOnly"],
            taken: (row["taken"] as Double?).map { Date(timeIntervalSince1970: $0) }, duration: row["duration"], author: row["author"],
            labels: (row["labels"] as String?)?.components(separatedBy: ", ") ?? [],
            tags: FinderTags.names(fromStored: row["tags"]),
            matchedName: name, matchedContent: false, matchedMeaning: false, meaningChunk: nil,
            snippet: nil, score: 0
        )
    }

    /// Every Finder tag in the index, most used first (for suggestions).
    public func tagNames() throws -> [String] {
        try database.pool.read { db in
            var counts: [String: Int] = [:]
            let cursor = try String.fetchCursor(db, sql: "SELECT tags FROM file WHERE tags IS NOT NULL")
            while let stored = try cursor.next() {
                for tag in FinderTags.names(fromStored: stored) { counts[tag, default: 0] += 1 }
            }
            return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        }
    }

    /// FTS5 string literal.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A prefix query for one word (`"invo"*`), so results appear while typing. Words under
    /// three characters match whole words only: a prefix like `"ab"*` expands to a large part
    /// of the vocabulary and makes every keystroke slow on a big index.
    /// The content-index query for one word: its prefix, or for Greek and Cyrillic words the
    /// prefix of their stem, which every inflected form shares.
    static func contentTerm(_ term: String) -> String? {
        prefixTerm(Stemmer.stem(term.trimmingCharacters(in: .whitespaces).searchFolded) ?? term)
    }

    static func prefixTerm(_ term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count < 3 ? quote(trimmed) : quote(trimmed) + "*"
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Builds the WHERE clause for metadata filters on aliases `f` (file) and `d` (its dir).
struct FilterSQL {
    private(set) var conditions: [String] = []
    private(set) var arguments: StatementArguments = []

    init(query: SearchQuery, home: String) {
        if !query.extensions.isEmpty {
            add("f.ext IN (\(Array(repeating: "?", count: query.extensions.count).joined(separator: ",")))",
                values: query.extensions.sorted())
        }
        if !query.kinds.isEmpty {
            add("f.kind IN (\(Array(repeating: "?", count: query.kinds.count).joined(separator: ",")))",
                values: query.kinds.map(\.rawValue).sorted())
        }
        if !query.excludedExtensions.isEmpty {
            add("f.ext NOT IN (\(Array(repeating: "?", count: query.excludedExtensions.count).joined(separator: ",")))",
                values: query.excludedExtensions.sorted())
        }
        for pattern in query.namePatterns {
            switch pattern {
            case let .prefix(text): addNamePrefix(text)
            case let .suffix(text): add("f.name LIKE ? ESCAPE '\\'", "%" + SearchEngine.escapeLike(text))
            case let .exact(text): add("f.name = ? COLLATE NOCASE", text)
            case let .regex(pattern): add("moria_regexp(?, f.name)", pattern)
            }
        }
        for text in query.pathContains {
            add("(" + IndexDatabase.pathSQL + " LIKE ? ESCAPE '\\')", "%" + SearchEngine.escapeLike(text) + "%")
        }
        // `-word`: in SQL rather than after ranking, so it also applies when there are no search
        // words and to meaning matches. Names are folded like the name index ("-cafe" drops "Café").
        for term in query.excludedTerms {
            add("moria_fold(f.name) NOT LIKE ? ESCAPE '\\'", "%" + SearchEngine.escapeLike(term.searchFolded) + "%")
            if let match = SearchEngine.contentTerm(term) {
                add("f.id NOT IN (SELECT rowid FROM content_fts WHERE content_fts MATCH ?)", match)
                add("f.id NOT IN (SELECT rowid FROM label_fts WHERE label_fts MATCH ?)", match)
            }
        }
        if !query.excludedKinds.isEmpty {
            add("f.kind NOT IN (\(Array(repeating: "?", count: query.excludedKinds.count).joined(separator: ",")))",
                values: query.excludedKinds.map(\.rawValue).sorted())
        }
        if let min = query.minSize { add("f.size >= ?", min) }
        if let max = query.maxSize { add("f.size <= ?", max) }
        if let modified = query.modified {
            add("f.mtime >= ? AND f.mtime < ?", values: [modified.start.timeIntervalSince1970, modified.end.timeIntervalSince1970])
        }
        if let created = query.created {
            add("f.btime >= ? AND f.btime < ?", values: [created.start.timeIntervalSince1970, created.end.timeIntervalSince1970])
        }
        if !query.folders.isEmpty {
            let clauses = query.folders.map { _ in "(d.path = ? OR (d.path >= ? AND d.path < ?))" }.joined(separator: " OR ")
            add("(\(clauses))", values: query.folders.flatMap { [$0, $0 + "/", $0 + "0"] })
        }
        for folder in query.excludedFolders {
            add("NOT (d.path = ? OR (d.path >= ? AND d.path < ?))", values: [folder, folder + "/", folder + "0"])
        }
        if let hidden = query.hidden {
            add(hidden ? "(f.isHidden = 1 OR d.path LIKE '%/.%')" : "(f.isHidden = 0 AND d.path NOT LIKE '%/.%')")
        }
        if let cloud = query.cloudOnly {
            add("f.isCloudOnly = ?", cloud)
        }
        // Whole tags, folded like names. `tags IS NOT NULL` lets SQLite use the tagged-files index.
        if !query.tags.isEmpty {
            let clauses = query.tags.map { _ in "moria_fold(f.tags) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
            add("(f.tags IS NOT NULL AND (\(clauses)))", values: query.tags.sorted().map(Self.tagPattern))
        }
        if let taken = query.taken {
            add("f.taken >= ? AND f.taken < ?", values: [taken.start.timeIntervalSince1970, taken.end.timeIntervalSince1970])
        }
        if let min = query.minDuration { add("f.duration >= ?", min) }
        if let max = query.maxDuration { add("f.duration <= ?", max) }
        for author in query.authors {
            add("f.author IS NOT NULL AND moria_fold(f.author) LIKE ? ESCAPE '\\'", "%" + SearchEngine.escapeLike(author.searchFolded) + "%")
        }
        for tag in query.excludedTags.sorted() {
            add("(f.tags IS NULL OR moria_fold(f.tags) NOT LIKE ? ESCAPE '\\')", Self.tagPattern(tag))
        }
    }

    private static func tagPattern(_ tag: String) -> String {
        "%\n" + SearchEngine.escapeLike(tag.searchFolded) + "\n%"
    }

    var clause: String {
        conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
    }

    /// Case-insensitive name prefix, written as a range on the NOCASE name index (Apple's
    /// SQLite doesn't turn `LIKE 'ab%'` into an index seek), with LIKE to keep it exact.
    mutating func addNamePrefix(_ prefix: String) {
        add("f.name >= ? COLLATE NOCASE AND f.name < ? COLLATE NOCASE AND f.name LIKE ? ESCAPE '\\'",
            values: [prefix, prefix + "\u{10FFFF}", SearchEngine.escapeLike(prefix) + "%"])
    }

    mutating func add(_ condition: String, _ value: some DatabaseValueConvertible) {
        add(condition, values: [value])
    }

    mutating func add(_ condition: String, values: [any DatabaseValueConvertible] = []) {
        conditions.append(condition)
        arguments += StatementArguments(values)
    }
}

/// Caches the in-memory vector index and reloads it when embeddings change, at most once a
/// minute: while the backlog is embedded, the version changes every 64 files, and reloading
/// every vector (over a gigabyte for a few hundred thousand documents) per search would make
/// each meaning search as slow as a full load.
actor VectorCache {
    private var cached: VectorIndex?
    private var loadedAt = Date.distantPast

    static let minimumReloadInterval: TimeInterval = 60

    func index(for database: IndexDatabase, now: Date = Date()) throws -> VectorIndex {
        if let cached, now.timeIntervalSince(loadedAt) < Self.minimumReloadInterval { return cached }
        let version = try database.embeddingsVersion()
        if let cached, cached.version == version { return cached }
        let index = try VectorIndex(database: database)
        cached = index
        loadedAt = now
        return index
    }
}
