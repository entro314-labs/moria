import Foundation
import GRDB

/// A file whose content is waiting for extraction.
struct PendingFile: Sendable {
    var id: Int64
    var path: String
    var ext: String
    var kind: FileKind
    var size: Int64
    var mtime: Double
}

/// The outcome of extracting one file, ready to be written.
struct ExtractionResult: Sendable {
    var id: Int64
    var mtime: Double
    var state: ContentState
    var text: String?
    /// Keep the text in `doc_text` (formats that are expensive to re-extract).
    var storeText: Bool
}

/// Writes metadata rows, resolving folder paths to `dir` ids.
///
/// Holds a path-to-id cache for the lifetime of one scan: crawls visit a folder before its
/// children, so every parent lookup after the first is a dictionary hit.
struct MetadataWriter {
    let generation: Int
    let maxFileBytes: Int64
    private var dirIDs: [String: Int64] = [:]

    init(generation: Int, maxFileBytes: Int64) {
        self.generation = generation
        self.maxFileBytes = maxFileBytes
    }

    mutating func write(_ batch: [FileMeta], to database: IndexDatabase) throws {
        try database.pool.write { db in
            let upsertFile = try db.cachedStatement(sql: """
                INSERT INTO file (dirId, name, ext, isDir, size, mtime, btime, kind,
                                  isHidden, isCloudOnly, contentState, seen, tags, mediaState)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(dirId, name) DO UPDATE SET
                    ext = excluded.ext, isDir = excluded.isDir, size = excluded.size,
                    mtime = excluded.mtime, btime = excluded.btime, kind = excluded.kind,
                    isHidden = excluded.isHidden, isCloudOnly = excluded.isCloudOnly,
                    seen = excluded.seen,
                    -- Tagging changes neither mtime nor size, so tags are always taken as read.
                    tags = excluded.tags,
                    mediaState = CASE
                        WHEN file.mtime != excluded.mtime OR file.size != excluded.size
                             OR file.isCloudOnly != excluded.isCloudOnly
                             OR (excluded.mediaState = 2) != (file.mediaState = 2)
                        THEN excluded.mediaState ELSE file.mediaState END,
                    contentState = CASE
                        WHEN file.mtime != excluded.mtime OR file.size != excluded.size
                             OR file.isCloudOnly != excluded.isCloudOnly
                        THEN excluded.contentState
                        -- Moved into or out of a content-excluded location, or scope settings changed.
                        WHEN (excluded.contentState = 5) != (file.contentState = 5) THEN excluded.contentState
                        ELSE file.contentState END
                """)
            for meta in batch {
                let parentID = try dirID(for: (meta.path as NSString).deletingLastPathComponent, db: db)
                if meta.isDir { _ = try dirID(for: meta.path, db: db) }
                try upsertFile.execute(arguments: [
                    parentID, meta.name, meta.ext, meta.isDir, meta.size, meta.mtime, meta.btime,
                    meta.kind.rawValue, meta.isHidden, meta.isCloudOnly, initialState(meta).rawValue, generation,
                    FinderTags.stored(meta.tags), initialMediaState(meta).rawValue,
                ])
            }
        }
    }

    private mutating func dirID(for path: String, db: Database) throws -> Int64 {
        if let cached = dirIDs[path] { return cached }
        let id = try Int64.fetchOne(db, sql: """
            INSERT INTO dir(path, seen) VALUES (?, ?)
            ON CONFLICT(path) DO UPDATE SET seen = max(dir.seen, excluded.seen)
            RETURNING id
            """, arguments: [path, generation])!
        dirIDs[path] = id
        return id
    }

    /// Details are read for photos, audio, video, PDFs and documents where contents are read.
    private func initialMediaState(_ meta: FileMeta) -> MediaState {
        guard !meta.isDir, !meta.isSymlink, !meta.isCloudOnly, meta.contentEligible, meta.size > 0,
              MediaReader.kinds.contains(meta.kind) else { return .none }
        return .pending
    }

    private func initialState(_ meta: FileMeta) -> ContentState {
        if meta.isDir { return .none }
        if meta.isSymlink { return .link }
        if !meta.contentEligible { return .excluded }
        if meta.size == 0 || meta.size > maxFileBytes { return .none }
        if meta.isCloudOnly { return .cloudOnly }
        switch meta.kind {
        case .folder, .application, .package, .audio, .video, .archive: return .none
        case .document, .pdf, .image, .text, .code, .other: return .pending
        }
    }
}

extension IndexDatabase {
    /// Deletes `path` and everything below it.
    func deleteSubtree(_ path: String) throws {
        try pool.write { db in
            let range: StatementArguments = [path, path + "/", path + "0"]  // "0" sorts right after "/"
            try db.execute(sql: """
                DELETE FROM file WHERE dirId IN (SELECT id FROM dir WHERE path = ? OR (path >= ? AND path < ?))
                """, arguments: range)
            try db.execute(sql: "DELETE FROM dir WHERE path = ? OR (path >= ? AND path < ?)", arguments: range)
            try db.execute(sql: """
                DELETE FROM file WHERE dirId = (SELECT id FROM dir WHERE path = ?) AND name = ?
                """, arguments: [(path as NSString).deletingLastPathComponent, (path as NSString).lastPathComponent])
        }
    }

    /// Deletes rows not seen by the scan with `generation` (removed or newly excluded entries),
    /// except those inside `kept` folders (drives that weren't connected) and the folders
    /// themselves.
    func pruneUnseen(before generation: Int, keeping kept: Set<String> = []) throws {
        let keep = Self.outside(kept, alias: "d")
        try pool.write { db in
            var fileSQL = "DELETE FROM file WHERE seen < ?"
            var fileArguments: StatementArguments = [generation]
            if !kept.isEmpty {
                fileSQL += " AND id NOT IN (SELECT f.id FROM file f JOIN dir d ON d.id = f.dirId WHERE NOT (\(keep.sql)) OR \(Self.entries(kept).sql))"
                fileArguments += keep.arguments + Self.entries(kept).arguments
            }
            try db.execute(sql: fileSQL, arguments: fileArguments)
            // The folders holding the kept folders' own entries stay too.
            let parents = Set(kept.map { ($0 as NSString).deletingLastPathComponent }).sorted()
            let parentSQL = parents.isEmpty ? "" : " AND d.path NOT IN (\(parents.map { _ in "?" }.joined(separator: ",")))"
            try db.execute(sql: "DELETE FROM dir AS d WHERE seen < ? AND \(keep.sql)\(parentSQL)",
                           arguments: [generation] + keep.arguments + StatementArguments(parents))
        }
    }

    /// A condition that `alias.path` is outside every folder in `folders` ("1" when empty).
    static func outside(_ folders: Set<String>, alias: String) -> (sql: String, arguments: StatementArguments) {
        guard !folders.isEmpty else { return ("1", []) }
        let sorted = folders.sorted()
        let sql = sorted.map { _ in "NOT (\(alias).path = ? OR (\(alias).path >= ? AND \(alias).path < ?))" }.joined(separator: " AND ")
        return (sql, StatementArguments(sorted.flatMap { [$0, $0 + "/", $0 + "0"] }))
    }

    /// A condition matching the entries for `folders` themselves (`f` in `d`), which live in
    /// their parent folders.
    private static func entries(_ folders: Set<String>) -> (sql: String, arguments: StatementArguments) {
        let sorted = folders.sorted()
        let sql = sorted.map { _ in "(d.path = ? AND f.name = ?)" }.joined(separator: " OR ")
        return ("(\(sql))", StatementArguments(sorted.flatMap { [($0 as NSString).deletingLastPathComponent, ($0 as NSString).lastPathComponent] }))
    }

    /// Deletes rows below `path` that were not seen by `generation` (after a subtree rescan).
    func pruneUnseen(under path: String, before generation: Int) throws {
        try pool.write { db in
            let arguments: StatementArguments = [generation, path, path + "/", path + "0"]
            try db.execute(sql: """
                DELETE FROM file WHERE seen < ?
                  AND dirId IN (SELECT id FROM dir WHERE path = ? OR (path >= ? AND path < ?))
                """, arguments: arguments)
            try db.execute(sql: """
                DELETE FROM dir WHERE seen < ? AND (path = ? OR (path >= ? AND path < ?))
                """, arguments: arguments)
        }
    }

    /// Next files to extract, newest first: files never read before stale ones, whose old text
    /// is still searchable. `images: false` returns everything except images, so fast text
    /// extraction finishes before the slow OCR pass (`images: true`) starts.
    func pendingFiles(limit: Int, images: Bool, outside offline: Set<String> = []) throws -> [PendingFile] {
        let outside = Self.outside(offline, alias: "d")
        return try pool.read { db in
            var files: [PendingFile] = []
            // One query per state, so each uses its partial index.
            for state in [ContentState.pending, .stale] where files.count < limit {
                files += try Row.fetchAll(db, sql: """
                    SELECT f.id, \(Self.pathSQL) AS path, f.ext, f.kind, f.size, f.mtime
                    FROM file f JOIN dir d ON d.id = f.dirId
                    WHERE f.contentState = ? AND (f.kind = 'image') = ? AND \(outside.sql) ORDER BY f.mtime DESC LIMIT ?
                    """, arguments: [state.rawValue, images] + outside.arguments + [limit - files.count]).map { row in
                    PendingFile(
                        id: row["id"], path: row["path"], ext: row["ext"],
                        kind: FileKind(rawValue: row["kind"]) ?? .other, size: row["size"], mtime: row["mtime"]
                    )
                }
            }
            return files
        }
    }

    func pendingCount() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT (SELECT count(*) FROM file WHERE contentState = 0) + (SELECT count(*) FROM file WHERE contentState = 6)
                """) ?? 0
        }
    }

    /// Writes extraction results. A result is dropped if the file changed since it was read
    /// (its mtime no longer matches), leaving it pending for the next pass. A stale file that no
    /// longer yields text loses its old text through the invalidation trigger. Indexed files
    /// the semantic index doesn't cover are marked so they never wait for embedding.
    func store(_ results: [ExtractionResult], home: String = NSHomeDirectory()) throws {
        let embeddable = Self.embeddable(home: home)
        try pool.write { db in
            let update = try db.cachedStatement(sql: """
                UPDATE file SET contentState = ?, embedState = 0 WHERE id = ? AND mtime = ? AND contentState IN (0, 6)
                """)
            let markNotEmbeddable = try db.cachedStatement(sql: """
                UPDATE file SET embedState = 2 WHERE id = ? AND NOT EXISTS (
                    SELECT 1 FROM file f JOIN dir d ON d.id = f.dirId WHERE f.id = ? AND \(embeddable.sql))
                """)
            let deleteContent = try db.cachedStatement(sql: "DELETE FROM content_fts WHERE rowid = ?")
            let insertContent = try db.cachedStatement(sql: "INSERT INTO content_fts(rowid, body) VALUES (?, ?)")
            let storeText = try db.cachedStatement(sql: "INSERT OR REPLACE INTO doc_text(fileId, body) VALUES (?, ?)")
            for result in results {
                try update.execute(arguments: [result.state.rawValue, result.id, result.mtime])
                guard db.changesCount == 1, result.state == .indexed, let text = result.text else { continue }
                try markNotEmbeddable.execute(arguments: [result.id, result.id] + embeddable.arguments)
                try deleteContent.execute(arguments: [result.id])
                try insertContent.execute(arguments: [result.id, text])
                if result.storeText {
                    try storeText.execute(arguments: [result.id, text])
                }
            }
        }
    }

    // MARK: - Media details

    /// Files whose details are waiting to be read, outside `offline` folders.
    func pendingMedia(limit: Int, outside offline: Set<String> = []) throws -> [PendingFile] {
        let outside = Self.outside(offline, alias: "d")
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, \(Self.pathSQL) AS path, f.ext, f.kind, f.size, f.mtime
                FROM file f JOIN dir d ON d.id = f.dirId
                WHERE f.mediaState = 0 AND \(outside.sql) ORDER BY f.id LIMIT ?
                """, arguments: outside.arguments + [limit]).map { row in
                PendingFile(id: row["id"], path: row["path"], ext: row["ext"],
                            kind: FileKind(rawValue: row["kind"]) ?? .other, size: row["size"], mtime: row["mtime"])
            }
        }
    }

    /// Writes details read; a file that changed since (mtime) stays pending.
    func storeMedia(_ results: [(id: Int64, mtime: Double, details: MediaDetails)]) throws {
        try pool.write { db in
            let update = try db.cachedStatement(sql: """
                UPDATE file SET mediaState = 1, taken = ?, duration = ?, author = ?
                WHERE id = ? AND mtime = ? AND mediaState = 0
                """)
            for (id, mtime, details) in results {
                try update.execute(arguments: [details.taken?.timeIntervalSince1970, details.duration, details.author, id, mtime])
            }
        }
    }

    /// Queues the details of every eligible file that hasn't been read, for indexes that
    /// predate them (their rows start as "not applicable"). Runs once per index.
    func backfillMediaIfNeeded(home: String = NSHomeDirectory()) throws {
        guard try meta("media.backfilled") == nil else { return }
        try pool.write { db in
            let kinds = MediaReader.kinds.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
            // Same eligibility as `initialMediaState`; contentState 4, 5 and 7 are cloud-only,
            // names-only and links.
            try db.execute(sql: """
                UPDATE file SET mediaState = 0
                WHERE kind IN (\(kinds)) AND isDir = 0 AND isCloudOnly = 0 AND size > 0
                  AND contentState NOT IN (4, 5, 7) AND mediaState = 2
                """)
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES ('media.backfilled', '1')")
        }
    }

    func pendingMediaCount() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM file WHERE mediaState = 0") ?? 0 }
    }

    /// Queues eligible files to be read again after extraction settings changed; `kinds` limits
    /// it to the affected formats. Indexed files become stale, keeping their text searchable
    /// until they are read again; skipped and failed ones become pending. Excluded, cloud-only
    /// and link entries stay put.
    public func requeueContent(kinds: Set<FileKind>? = nil) throws {
        try pool.write { db in
            var sql = """
                UPDATE file SET contentState = CASE contentState WHEN 1 THEN 6 ELSE 0 END
                WHERE contentState IN (1, 2, 3) AND isDir = 0 AND size > 0
                """
            if let kinds {
                guard !kinds.isEmpty else { return }
                sql += " AND kind IN (\(kinds.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")))"
            }
            try db.execute(sql: sql)
        }
    }

    /// Removes every indexed entry (settings are kept).
    func eraseIndex() throws {
        try pool.write { db in
            // Empty the FTS tables in one step so the per-row delete trigger has nothing to do.
            try db.execute(sql: """
                INSERT INTO name_fts(name_fts) VALUES ('delete-all');
                INSERT INTO content_fts(content_fts) VALUES ('delete-all');
                DELETE FROM doc_text; DELETE FROM chunk_vec;
                DELETE FROM file; DELETE FROM dir;
                DELETE FROM meta WHERE key LIKE 'scan.%' OR key LIKE 'fsevents.%';
                """)
        }
        try pool.writeWithoutTransaction { db in try db.execute(sql: "VACUUM") }
    }

    /// Stored text for a file, if its format keeps one (PDF, Office, OCR'd images).
    public func storedText(fileID: Int64) throws -> String? {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT body FROM doc_text WHERE fileId = ?", arguments: [fileID]) }
    }

    // MARK: - Embeddings
    //
    // embedState: 0 waiting, 1 embedded, 2 not embedded (no text in a supported language, or a
    // file the semantic index doesn't cover). Only 0 is in the `file_embed_pending` index.

    /// Files the semantic index covers (`f` = file, `d` = its dir): documents, PDFs, text and
    /// recognized images outside `~/Library` and hidden folders. The sentence model is trained
    /// on prose; code and support files dominate counts without helping.
    static func embeddable(home: String) -> (sql: String, arguments: StatementArguments) {
        ("f.kind IN ('document', 'pdf', 'text', 'image') AND NOT (d.path = ? OR (d.path >= ? AND d.path < ?)) AND d.path NOT LIKE '%/.%'",
         [home + "/Library", home + "/Library/", home + "/Library0"])
    }

    /// Indexed documents without embeddings.
    func filesNeedingEmbedding(limit: Int, outside offline: Set<String> = [], home: String = NSHomeDirectory()) throws -> [(id: Int64, path: String, kind: FileKind)] {
        let embeddable = Self.embeddable(home: home)
        let outside = Self.outside(offline, alias: "d")
        return try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, \(Self.pathSQL) AS path, f.kind FROM file f JOIN dir d ON d.id = f.dirId
                WHERE f.embedState = 0 AND f.contentState = 1 AND \(embeddable.sql) AND \(outside.sql)
                LIMIT ?
                """, arguments: embeddable.arguments + outside.arguments + [limit]
            ).map { (id: $0["id"], path: $0["path"], kind: FileKind(rawValue: $0["kind"]) ?? .other) }
        }
    }

    /// Takes files the semantic index doesn't cover out of the embedding backlog. Indexes built
    /// before `store` marked them hold them at 0 (on a large home folder, most of the backlog:
    /// code), and every batch would scan past them again.
    func markNotEmbeddable(home: String = NSHomeDirectory()) throws {
        let embeddable = Self.embeddable(home: home)
        try pool.write { db in
            try db.execute(sql: """
                UPDATE file SET embedState = 2 WHERE embedState = 0 AND contentState = 1 AND id NOT IN (
                    SELECT f.id FROM file f JOIN dir d ON d.id = f.dirId
                    WHERE f.embedState = 0 AND f.contentState = 1 AND \(embeddable.sql))
                """, arguments: embeddable.arguments)
        }
    }

    /// Documents the semantic index would cover (shown before it is turned on).
    public func embeddableCount(home: String = NSHomeDirectory()) throws -> Int {
        let embeddable = Self.embeddable(home: home)
        return try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM file f JOIN dir d ON d.id = f.dirId
                WHERE f.contentState IN (1, 6) AND \(embeddable.sql)
                """, arguments: embeddable.arguments) ?? 0
        }
    }

    /// Replaces the chunk vectors of each file and marks it embedded (1) or not embeddable (2).
    /// Chunks keep their position in the document so the closest passage can be shown.
    func storeEmbeddings(_ items: [(id: Int64, chunks: [(chunk: Int, vector: [Float])])]) throws {
        try pool.write { db in
            let delete = try db.cachedStatement(sql: "DELETE FROM chunk_vec WHERE fileId = ?")
            let insert = try db.cachedStatement(sql: "INSERT INTO chunk_vec(fileId, chunk, vec) VALUES (?, ?, ?)")
            let mark = try db.cachedStatement(sql: "UPDATE file SET embedState = ? WHERE id = ?")
            for item in items {
                try delete.execute(arguments: [item.id])
                for (chunk, vector) in item.chunks {
                    try insert.execute(arguments: [item.id, chunk, VectorCodec.encode(vector)])
                }
                try mark.execute(arguments: [item.chunks.isEmpty ? 2 : 1, item.id])
            }
            try Self.bumpEmbeddingsVersion(db)
        }
    }

    public func clearEmbeddings() throws {
        try pool.write { db in
            // Files marked 2 stay out: whether they can be embedded doesn't change.
            try db.execute(sql: "DELETE FROM chunk_vec; UPDATE file SET embedState = 0 WHERE embedState = 1")
            try Self.bumpEmbeddingsVersion(db)
        }
    }

    private static func bumpEmbeddingsVersion(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO meta(key, value) VALUES ('embeddings.version', '1')
            ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
            """)
    }

    func embeddingsVersion() throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'embeddings.version'") ?? 0
        }
    }
}
