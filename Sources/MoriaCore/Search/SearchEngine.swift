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
    /// Why it matched.
    public var matchedName: Bool
    public var matchedContent: Bool
    public var matchedMeaning: Bool
    /// Content excerpt, filled by `SearchEngine.snippet(for:query:)`; matched spans are wrapped
    /// in `highlightStart`/`highlightEnd`.
    public var snippet: String?
    public var score: Double

    public static let highlightStart: Character = "\u{1}"
    public static let highlightEnd: Character = "\u{2}"

    public var url: URL { URL(fileURLWithPath: path) }
}

/// Runs searches against the index.
///
/// Name and content hits come from separate FTS5 tables and are fused with reciprocal rank
/// fusion (RRF); semantic hits join the fusion when enabled. RRF only needs each list's order,
/// so BM25 scores from different tables never have to be compared directly.
public final class SearchEngine: Sendable {
    public let database: IndexDatabase
    private let embedder: Embedder
    private let vectors = VectorCache()
    private let home: String

    public init(database: IndexDatabase, embedder: Embedder = Embedder(), home: String = NSHomeDirectory()) {
        self.database = database
        self.embedder = embedder
        self.home = home
    }

    /// RRF constant; 60 is the value from the original paper and works well untuned.
    static let fusionK = 60.0
    static let nameWeight = 1.5
    static let contentWeight = 1.0
    static let semanticWeight = 0.9

    public func search(_ query: SearchQuery, limit: Int = 500, semantic: Bool = false) async throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        guard query.hasTextCriteria else {
            return try filterOnly(query, limit: limit)
        }
        let (nameHits, contentHits) = try await database.pool.read { db in
            (try self.nameMatches(query, db: db, limit: limit), try self.contentMatches(query, db: db, limit: limit))
        }
        var semanticHits: [Int64] = []
        if semantic, !query.semanticText.isEmpty {
            semanticHits = try await semanticMatches(query, limit: 200)
        }
        return try fuse(query: query, names: nameHits, contents: contentHits, semantic: semanticHits, limit: limit)
    }

    // MARK: - Candidate lists

    private func nameMatches(_ query: SearchQuery, db: Database, limit: Int) throws -> [SearchResult] {
        let words = query.terms + query.nameTerms + query.phrases
        guard query.contentTerms.isEmpty, !words.isEmpty else { return [] }
        // Trigram FTS needs 3+ characters; shorter words become a filename prefix match.
        let folded = words.map(\.searchFolded)
        let long = folded.filter { $0.count >= 3 }
        let short = folded.filter { $0.count < 3 }
        var filter = FilterSQL(query: query, home: home)
        for word in short {
            filter.add("f.name LIKE ? ESCAPE '\\'", Self.escapeLike(word) + "%")
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

    private func contentMatches(_ query: SearchQuery, db: Database, limit: Int) throws -> [SearchResult] {
        guard query.nameTerms.isEmpty else { return [] }
        var parts = (query.terms + query.contentTerms).compactMap(Self.prefixTerm)
        parts += query.phrases.map(Self.quote)
        guard !parts.isEmpty else { return [] }
        let filter = FilterSQL(query: query, home: home)
        return try Row.fetchAll(db, sql: """
            SELECT \(Self.columns), content_fts.rank AS rank
            FROM content_fts JOIN file f ON f.id = content_fts.rowid JOIN dir d ON d.id = f.dirId
            WHERE content_fts MATCH ? AND \(filter.clause)
            ORDER BY content_fts.rank LIMIT ?
            """, arguments: [parts.joined(separator: " AND ")] + filter.arguments + [limit]
        ).map { Self.result(from: $0, content: true) }
    }

    private func semanticMatches(_ query: SearchQuery, limit: Int) async throws -> [Int64] {
        guard let vector = try await embedder.embedQuery(query.semanticText) else { return [] }
        let index = try await vectors.index(for: database)
        let ranking = index.search(vector, limit: limit)
        return Self.standouts(ranking).map(\.fileID)
    }

    /// Hits that stand out from the corpus. Absolute cosine values shift with query length
    /// (short queries score ~0.6, sentences ~0.8), so the cutoff is relative: two standard
    /// deviations above the mean similarity (one for small indexes, where even the best match
    /// can't stand out that far), and near the best hit.
    static func standouts(_ ranking: VectorIndex.Ranking) -> [(fileID: Int64, score: Float)] {
        guard let best = ranking.hits.first?.score else { return [] }
        let deviations: Float = ranking.count >= 200 ? 2 : 1
        let cutoff = max(ranking.mean + deviations * ranking.deviation, best - 0.06)
        return ranking.hits.filter { $0.score >= cutoff }
    }

    private func filterOnly(_ query: SearchQuery, limit: Int) throws -> [SearchResult] {
        let filter = FilterSQL(query: query, home: home)
        return try database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM file f JOIN dir d ON d.id = f.dirId
                WHERE \(filter.clause) ORDER BY f.mtime DESC LIMIT ?
                """, arguments: filter.arguments + [limit]).map { Self.result(from: $0) }
        }
    }

    // MARK: - Fusion

    private func fuse(
        query: SearchQuery, names: [SearchResult], contents: [SearchResult], semantic: [Int64], limit: Int
    ) throws -> [SearchResult] {
        var byID: [Int64: SearchResult] = [:]
        func add(_ hit: SearchResult, rank: Int, weight: Double) {
            let contribution = weight / (Self.fusionK + Double(rank + 1))
            if var existing = byID[hit.id] {
                existing.score += contribution
                existing.matchedName = existing.matchedName || hit.matchedName
                existing.matchedContent = existing.matchedContent || hit.matchedContent
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
        if !semantic.isEmpty {
            let rows = try fetch(ids: semantic, query: query)
            for (rank, id) in semantic.enumerated() {
                guard var hit = rows[id] else { continue }
                hit.matchedMeaning = true
                add(hit, rank: rank, weight: Self.semanticWeight)
                byID[id]?.matchedMeaning = true
            }
        }
        let excluded = try excludedIDs(query, candidates: Array(byID.keys))
        return byID.values
            .filter { !excluded.contains($0.id) }
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

    private func excludedIDs(_ query: SearchQuery, candidates: [Int64]) throws -> Set<Int64> {
        guard !query.excludedTerms.isEmpty, !candidates.isEmpty else { return [] }
        return try database.pool.read { db in
            var excluded = Set<Int64>()
            let idList = candidates.map(String.init).joined(separator: ",")
            for term in query.excludedTerms {
                let folded = term.searchFolded
                excluded.formUnion(try Int64.fetchAll(db, sql: """
                    SELECT id FROM file WHERE id IN (\(idList)) AND name LIKE ? ESCAPE '\\'
                    """, arguments: ["%" + Self.escapeLike(folded) + "%"]))
                if let match = Self.prefixTerm(term) {
                    excluded.formUnion(try Int64.fetchAll(db, sql: """
                        SELECT rowid FROM content_fts WHERE content_fts MATCH ? AND rowid IN (\(idList))
                        """, arguments: [match]))
                }
            }
            return excluded
        }
    }

    /// Metadata for specific files (e.g. regex hits), keyed by id.
    public func metadata(for ids: [Int64]) async throws -> [Int64: SearchResult] {
        guard !ids.isEmpty else { return [:] }
        return try fetch(ids: ids, query: SearchQuery())
    }

    private func fetch(ids: [Int64], query: SearchQuery) throws -> [Int64: SearchResult] {
        let filter = FilterSQL(query: query, home: home)
        let idList = ids.map(String.init).joined(separator: ",")
        return try database.pool.read { db in
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
        guard result.matchedContent || result.matchedMeaning, !result.isDirectory, !result.isCloudOnly else { return nil }
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
        if let snippet = Snippet.make(from: text, terms: terms) { return snippet }
        return result.matchedMeaning ? Snippet.lead(of: text) : nil
    }

    private static func readHead(of path: String) throws -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: snippetReadBytes), !data.isEmpty else { return nil }
        return ContentExtractor.decodeText(data)
    }

    // MARK: - SQL helpers

    static let columns = "f.id, \(IndexDatabase.pathSQL) AS path, f.name, f.ext, f.kind, f.isDir, f.size, f.mtime, f.btime, f.isCloudOnly"

    static func result(from row: Row, name: Bool = false, content: Bool = false) -> SearchResult {
        // Snippets are built on demand by `snippet(for:query:)`.
        SearchResult(
            id: row["id"], path: row["path"], name: row["name"], ext: row["ext"],
            kind: FileKind(rawValue: row["kind"]) ?? .other, isDirectory: row["isDir"], size: row["size"],
            modified: Date(timeIntervalSince1970: row["mtime"]), created: Date(timeIntervalSince1970: row["btime"]),
            isCloudOnly: row["isCloudOnly"], matchedName: name, matchedContent: content, matchedMeaning: false,
            snippet: nil, score: 0
        )
    }

    /// FTS5 string literal.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A prefix query for one word (`"invo"*`), so results appear while typing.
    static func prefixTerm(_ term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return quote(trimmed) + "*"
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
    }

    var clause: String {
        conditions.isEmpty ? "1" : conditions.joined(separator: " AND ")
    }

    mutating func add(_ condition: String, _ value: some DatabaseValueConvertible) {
        add(condition, values: [value])
    }

    mutating func add(_ condition: String, values: [any DatabaseValueConvertible] = []) {
        conditions.append(condition)
        arguments += StatementArguments(values)
    }
}

/// Caches the in-memory vector index and reloads it when embeddings change.
actor VectorCache {
    private var cached: VectorIndex?

    func index(for database: IndexDatabase) throws -> VectorIndex {
        let version = try database.embeddingsVersion()
        if let cached, cached.version == version { return cached }
        let index = try VectorIndex(database: database)
        cached = index
        return index
    }
}
