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
}

extension IndexDatabase {
    /// Inserts or updates metadata rows. A row whose size, mtime or cloud state changed goes
    /// back to `pending` (or `none`/`cloudOnly`), which drops its old content via trigger.
    func upsert(_ batch: [FileMeta], generation: Int, maxFileBytes: Int64) throws {
        try pool.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO file (path, name, nameKey, ext, parent, isDir, size, mtime, btime, kind,
                                  isHidden, isCloudOnly, contentState, seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    size = excluded.size, mtime = excluded.mtime, btime = excluded.btime,
                    kind = excluded.kind, isHidden = excluded.isHidden, isCloudOnly = excluded.isCloudOnly,
                    seen = excluded.seen,
                    contentState = CASE
                        WHEN file.mtime != excluded.mtime OR file.size != excluded.size
                             OR file.isCloudOnly != excluded.isCloudOnly
                        THEN excluded.contentState ELSE file.contentState END
                """)
            for meta in batch {
                let state: ContentState = if meta.isDir || meta.size == 0 || meta.size > maxFileBytes {
                    .none
                } else if meta.isCloudOnly {
                    .cloudOnly
                } else if Self.neverHasText(meta.kind) {
                    .none
                } else {
                    .pending
                }
                try statement.execute(arguments: [
                    meta.path, meta.name, meta.name.searchFolded, meta.ext, meta.parent, meta.isDir,
                    meta.size, meta.mtime, meta.btime, meta.kind.rawValue, meta.isHidden,
                    meta.isCloudOnly, state.rawValue, generation,
                ])
            }
        }
    }

    private static func neverHasText(_ kind: FileKind) -> Bool {
        switch kind {
        case .folder, .application, .package, .audio, .video, .archive: true
        case .document, .pdf, .image, .text, .code, .other: false
        }
    }

    /// Deletes `path` and everything below it.
    func deleteSubtree(_ path: String) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM file WHERE path = ? OR (path >= ? AND path < ?)",
                arguments: [path, path + "/", path + "0"]  // "0" sorts right after "/"
            )
        }
    }

    /// Deletes rows not seen by the scan with `generation` (removed or newly excluded files).
    func pruneUnseen(before generation: Int) throws -> Int {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM file WHERE seen < ?", arguments: [generation])
            return db.changesCount
        }
    }

    /// Deletes rows below `path` that were not seen by `generation` (used after a subtree rescan).
    func pruneUnseen(under path: String, before generation: Int) throws {
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM file WHERE seen < ? AND (path = ? OR (path >= ? AND path < ?))",
                arguments: [generation, path, path + "/", path + "0"]
            )
        }
    }

    func pendingFiles(limit: Int) throws -> [PendingFile] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, path, ext, kind, size, mtime FROM file
                WHERE contentState = 0 ORDER BY mtime DESC LIMIT ?
                """, arguments: [limit]).map { row in
                PendingFile(
                    id: row["id"], path: row["path"], ext: row["ext"],
                    kind: FileKind(rawValue: row["kind"]) ?? .other, size: row["size"], mtime: row["mtime"]
                )
            }
        }
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
            for result in results {
                try update.execute(arguments: [result.state.rawValue, result.id, result.mtime])
                guard db.changesCount == 1, result.state == .indexed else { continue }
                try deleteContent.execute(arguments: [result.id])
                if let text = result.text {
                    try insertContent.execute(arguments: [result.id, text])
                }
            }
        }
    }

    /// Resets every file with extracted content (or failures) to pending, e.g. after
    /// extraction settings changed.
    public func requeueContent() throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE file SET contentState = 0 WHERE contentState IN (1, 2, 3) AND isDir = 0 AND isCloudOnly = 0 AND size > 0")
        }
    }
}

extension IndexDatabase {
    func pendingCount() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM file WHERE contentState = 0") ?? 0 }
    }

    /// Indexed documents without embeddings. Code, `~/Library` and hidden paths are excluded:
    /// the sentence model is trained on prose, and those files dominate counts without helping.
    func filesNeedingEmbedding(limit: Int, home: String = NSHomeDirectory()) throws -> [(Int64, String)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, c.body FROM file f JOIN content_fts c ON c.rowid = f.id
                WHERE f.embedState = 0 AND f.contentState = 1
                  AND f.kind IN ('document', 'pdf', 'text', 'image')
                  AND NOT (f.path >= ? AND f.path < ?) AND f.path NOT LIKE '%/.%'
                LIMIT ?
                """, arguments: [home + "/Library/", home + "/Library0", limit]
            ).map { ($0[0], $0[1]) }
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
