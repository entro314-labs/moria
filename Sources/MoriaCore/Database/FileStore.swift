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
                                  isHidden, isCloudOnly, contentState, seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(dirId, name) DO UPDATE SET
                    ext = excluded.ext, isDir = excluded.isDir, size = excluded.size,
                    mtime = excluded.mtime, btime = excluded.btime, kind = excluded.kind,
                    isHidden = excluded.isHidden, isCloudOnly = excluded.isCloudOnly,
                    seen = excluded.seen,
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

    private func initialState(_ meta: FileMeta) -> ContentState {
        if meta.isDir { return .none }
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

    /// Deletes rows not seen by the scan with `generation` (removed or newly excluded entries).
    func pruneUnseen(before generation: Int) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM file WHERE seen < ?", arguments: [generation])
            try db.execute(sql: "DELETE FROM dir WHERE seen < ?", arguments: [generation])
        }
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

    /// Next files to extract, newest first. `images: false` returns everything except images,
    /// so fast text extraction finishes before the slow OCR pass (`images: true`) starts.
    func pendingFiles(limit: Int, images: Bool) throws -> [PendingFile] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, \(Self.pathSQL) AS path, f.ext, f.kind, f.size, f.mtime
                FROM file f JOIN dir d ON d.id = f.dirId
                WHERE f.contentState = 0 AND (f.kind = 'image') = ? ORDER BY f.mtime DESC LIMIT ?
                """, arguments: [images, limit]).map { row in
                PendingFile(
                    id: row["id"], path: row["path"], ext: row["ext"],
                    kind: FileKind(rawValue: row["kind"]) ?? .other, size: row["size"], mtime: row["mtime"]
                )
            }
        }
    }

    func pendingCount() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM file WHERE contentState = 0") ?? 0 }
    }

    /// Writes extraction results. A result is dropped if the file changed since it was read
    /// (its mtime no longer matches), leaving it pending for the next pass.
    func store(_ results: [ExtractionResult]) throws {
        try pool.write { db in
            let update = try db.cachedStatement(sql: """
                UPDATE file SET contentState = ?, embedState = 0 WHERE id = ? AND mtime = ? AND contentState = 0
                """)
            let deleteContent = try db.cachedStatement(sql: "DELETE FROM content_fts WHERE rowid = ?")
            let insertContent = try db.cachedStatement(sql: "INSERT INTO content_fts(rowid, body) VALUES (?, ?)")
            let storeText = try db.cachedStatement(sql: "INSERT OR REPLACE INTO doc_text(fileId, body) VALUES (?, ?)")
            for result in results {
                try update.execute(arguments: [result.state.rawValue, result.id, result.mtime])
                guard db.changesCount == 1, result.state == .indexed, let text = result.text else { continue }
                try deleteContent.execute(arguments: [result.id])
                try insertContent.execute(arguments: [result.id, text])
                if result.storeText {
                    try storeText.execute(arguments: [result.id, text])
                }
            }
        }
    }

    /// Resets eligible files (indexed, skipped or failed) to pending after extraction settings
    /// changed; `kinds` limits it to the affected formats. Excluded and cloud-only files stay put.
    public func requeueContent(kinds: Set<FileKind>? = nil) throws {
        try pool.write { db in
            var sql = "UPDATE file SET contentState = 0 WHERE contentState IN (1, 2, 3) AND isDir = 0 AND size > 0"
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

    /// Indexed documents without embeddings. Code, `~/Library` and hidden paths are excluded:
    /// the sentence model is trained on prose, and those files dominate counts without helping.
    func filesNeedingEmbedding(limit: Int, home: String = NSHomeDirectory()) throws -> [(id: Int64, path: String, kind: FileKind)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, \(Self.pathSQL) AS path, f.kind FROM file f JOIN dir d ON d.id = f.dirId
                WHERE f.embedState = 0 AND f.contentState = 1
                  AND f.kind IN ('document', 'pdf', 'text', 'image')
                  AND NOT (d.path = ? OR (d.path >= ? AND d.path < ?)) AND d.path NOT LIKE '%/.%'
                LIMIT ?
                """, arguments: [home + "/Library", home + "/Library/", home + "/Library0", limit]
            ).map { (id: $0["id"], path: $0["path"], kind: FileKind(rawValue: $0["kind"]) ?? .other) }
        }
    }

    /// Documents the semantic index would cover (shown before it is turned on).
    public func embeddableCount(home: String = NSHomeDirectory()) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM file f JOIN dir d ON d.id = f.dirId
                WHERE f.contentState = 1 AND f.kind IN ('document', 'pdf', 'text', 'image')
                  AND NOT (d.path = ? OR (d.path >= ? AND d.path < ?)) AND d.path NOT LIKE '%/.%'
                """, arguments: [home + "/Library", home + "/Library/", home + "/Library0"]) ?? 0
        }
    }

    /// Replaces the chunk vectors of each file and marks it embedded (1) or not embeddable (2).
    func storeEmbeddings(_ items: [(id: Int64, chunks: [[Float]])]) throws {
        try pool.write { db in
            let delete = try db.cachedStatement(sql: "DELETE FROM chunk_vec WHERE fileId = ?")
            let insert = try db.cachedStatement(sql: "INSERT INTO chunk_vec(fileId, chunk, vec) VALUES (?, ?, ?)")
            let mark = try db.cachedStatement(sql: "UPDATE file SET embedState = ? WHERE id = ?")
            for item in items {
                try delete.execute(arguments: [item.id])
                for (index, vector) in item.chunks.enumerated() {
                    try insert.execute(arguments: [item.id, index, VectorCodec.encode(vector)])
                }
                try mark.execute(arguments: [item.chunks.isEmpty ? 2 : 1, item.id])
            }
            try Self.bumpEmbeddingsVersion(db)
        }
    }

    public func clearEmbeddings() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM chunk_vec; UPDATE file SET embedState = 0 WHERE embedState != 0")
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
