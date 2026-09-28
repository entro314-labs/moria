import Foundation
import GRDB

/// Extraction state of a file's content, stored in `file.contentState`.
public enum ContentState: Int, Sendable, Codable {
    /// Waiting for extraction.
    case pending = 0
    /// Text is in `content_fts`.
    case indexed = 1
    /// Not a text-bearing format, too large, or empty.
    case none = 2
    /// Extraction threw; retried when the file's mtime changes.
    case failed = 3
    /// Cloud placeholder that is not downloaded; content is never fetched.
    case cloudOnly = 4
    /// In a content-excluded location (settings): indexed by name only.
    case excluded = 5
    /// Indexed text kept searchable while the file waits to be read again because extraction
    /// settings changed (the file itself did not).
    case stale = 6
    /// A symbolic link: indexed by name only. Its target is read where it lives, if at all.
    case link = 7
}

/// The on-disk index: file metadata, filename and content full-text tables, embeddings and settings.
///
/// Uses a WAL `DatabasePool` so searches run concurrently with indexing, and the app and
/// CLI can share one file.
public final class IndexDatabase: Sendable {
    public let pool: DatabasePool
    public let url: URL

    /// `~/Library/Application Support/Moria/index.sqlite`
    public static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Moria", directoryHint: .isDirectory)
            .appending(path: "index.sqlite")
    }

    public init(url: URL = IndexDatabase.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        // The app and the CLI may write at the same time; wait for the lock instead of failing.
        config.busyMode = .timeout(15)
        config.prepareDatabase { db in
            db.add(tokenizer: FoldingTokenizer.self)
            db.add(function: foldFunction)
            db.add(function: regexpFunction)
            // Checkpoint every ~80 MB of WAL instead of 4 MB: bulk scans write millions of rows.
            try db.execute(sql: """
                PRAGMA synchronous = NORMAL; PRAGMA journal_size_limit = 67108864;
                PRAGMA cache_size = -65536; PRAGMA wal_autocheckpoint = 20000
                """)
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                -- Folders keep their full path; files store only (dirId, name). Paths are the
                -- bulk of an index of millions of entries, and there are ~5x more files than
                -- folders. Path-range queries on `dir.path` give fast subtree operations.
                CREATE TABLE dir (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    seen INTEGER NOT NULL
                );
                CREATE TABLE file (
                    id INTEGER PRIMARY KEY,
                    dirId INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    ext TEXT NOT NULL,
                    isDir INTEGER NOT NULL,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    btime REAL NOT NULL,
                    kind TEXT NOT NULL,
                    isHidden INTEGER NOT NULL,
                    isCloudOnly INTEGER NOT NULL,
                    contentState INTEGER NOT NULL,
                    embedState INTEGER NOT NULL DEFAULT 0,
                    seen INTEGER NOT NULL,
                    UNIQUE (dirId, name)
                );
                CREATE INDEX file_mtime ON file(mtime);
                -- Partial indexes stay tiny once the backlog is processed.
                CREATE INDEX file_pending ON file(mtime) WHERE contentState = 0;
                CREATE INDEX file_embed_pending ON file(id) WHERE embedState = 0 AND contentState = 1;

                -- Both FTS tables are contentless: they keep only the inverted index (about a
                -- quarter of the raw text size, versus 1.4x when the text is stored as well).
                CREATE VIRTUAL TABLE name_fts USING fts5(
                    nameKey, content='', contentless_delete=1, tokenize='trigram'
                );
                -- porter: English stemming ("invoices" finds "invoice"); non-English words pass
                -- through to the folding tokenizer unchanged.
                CREATE VIRTUAL TABLE content_fts USING fts5(
                    body, content='', contentless_delete=1, tokenize='porter moria_fold'
                );
                -- Extracted text is stored only where re-extracting it is expensive (PDF, Office,
                -- OCR). Snippets for text and code files are read from the file itself.
                CREATE TABLE doc_text (fileId INTEGER PRIMARY KEY, body TEXT NOT NULL);
                CREATE TABLE chunk_vec (
                    fileId INTEGER NOT NULL,
                    chunk INTEGER NOT NULL,
                    vec BLOB NOT NULL,
                    PRIMARY KEY (fileId, chunk)
                ) WITHOUT ROWID;
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

                CREATE TRIGGER file_ai AFTER INSERT ON file BEGIN
                    INSERT INTO name_fts(rowid, nameKey) VALUES (new.id, moria_fold(new.name));
                END;
                CREATE TRIGGER file_ad AFTER DELETE ON file BEGIN
                    DELETE FROM name_fts WHERE rowid = old.id;
                    DELETE FROM content_fts WHERE rowid = old.id;
                    DELETE FROM doc_text WHERE fileId = old.id;
                    DELETE FROM chunk_vec WHERE fileId = old.id;
                END;
                -- Content is dropped as soon as a file leaves the indexed state (modified, became
                -- cloud-only, ...) so results never show text that no longer matches the file.
                CREATE TRIGGER file_content_invalidated AFTER UPDATE OF contentState ON file
                WHEN old.contentState = 1 AND new.contentState != 1 BEGIN
                    DELETE FROM content_fts WHERE rowid = old.id;
                    DELETE FROM doc_text WHERE fileId = old.id;
                    DELETE FROM chunk_vec WHERE fileId = old.id;
                END;
                """)
        }
        // Filter indexes. Without them a filter such as `kind:pdf modified:<30d` walks every
        // recently modified file (over a million on a developer's Mac) to find a few PDFs.
        migrator.registerMigration("v2-filter-indexes") { db in
            try db.execute(sql: """
                CREATE INDEX file_kind_mtime ON file(kind, mtime);
                CREATE INDEX file_ext_mtime ON file(ext, mtime);
                CREATE INDEX file_size ON file(size);
                -- NOCASE lets LIKE 'ab%' (short queries, name:foo*) and name = ? COLLATE NOCASE use it.
                CREATE INDEX file_name_nocase ON file(name COLLATE NOCASE);
                ANALYZE;
                """)
        }
        // Stale content (6): re-reading after a settings change keeps the old text searchable,
        // so the invalidation trigger treats 1 and 6 alike.
        migrator.registerMigration("v3-stale-content") { db in
            try db.execute(sql: """
                DROP TRIGGER file_content_invalidated;
                CREATE TRIGGER file_content_invalidated AFTER UPDATE OF contentState ON file
                WHEN old.contentState IN (1, 6) AND new.contentState NOT IN (1, 6) BEGIN
                    DELETE FROM content_fts WHERE rowid = old.id;
                    DELETE FROM doc_text WHERE fileId = old.id;
                    DELETE FROM chunk_vec WHERE fileId = old.id;
                END;
                CREATE INDEX file_stale ON file(mtime) WHERE contentState = 6;
                """)
        }
        // Finder tags, newline-separated with a newline at each end ("\nRed\nWork\n") so a
        // whole tag can be matched with LIKE; NULL when untagged. Tags are read during the crawl,
        // so the resume point is dropped: the next start runs a full scan that fills them in.
        migrator.registerMigration("v4-tags") { db in
            try db.execute(sql: """
                ALTER TABLE file ADD COLUMN tags TEXT;
                CREATE INDEX file_tagged ON file(id) WHERE tags IS NOT NULL;
                DELETE FROM meta WHERE key = 'fsevents.lastID';
                """)
        }
        return migrator
    }

    // MARK: - Meta

    public func meta(_ key: String) throws -> String? {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String?) throws {
        try pool.write { db in
            if let value {
                try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM meta WHERE key = ?", arguments: [key])
            }
        }
    }

    public func loadSettings() throws -> MoriaSettings {
        guard let json = try meta("settings") else { return .defaults() }
        return try JSONDecoder().decode(MoriaSettings.self, from: Data(json.utf8))
    }

    public func saveSettings(_ settings: MoriaSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try setMeta("settings", String(decoding: data, as: UTF8.self))
    }

    // MARK: - Stats

    /// SQL expression for an entry's full path (`f` = file, `d` = its dir).
    static let pathSQL = "(CASE d.path WHEN '/' THEN '/' || f.name ELSE d.path || '/' || f.name END)"

    public struct Stats: Sendable, Equatable {
        public var files: Int
        public var folders: Int
        public var contentIndexed: Int
        public var contentPending: Int
        public var cloudOnly: Int
        /// Files indexed by name only because of the content-scope settings.
        public var namesOnly: Int
        /// Files whose text could not be read (damaged, password-protected, unsupported variant).
        public var failed: Int
        public var embeddedChunks: Int
        public var databaseBytes: Int64
    }

    public func stats() throws -> Stats {
        let counts = try pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(isDir = 0), 0) AS files,
                    COALESCE(SUM(isDir = 1), 0) AS folders,
                    COALESCE(SUM(contentState IN (1, 6)), 0) AS indexed,
                    COALESCE(SUM(contentState IN (0, 6)), 0) AS pending,
                    COALESCE(SUM(isCloudOnly = 1), 0) AS cloud,
                    COALESCE(SUM(contentState = 5), 0) AS namesOnly,
                    COALESCE(SUM(contentState = 3), 0) AS failed
                FROM file
                """)!
            let chunks = try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_vec") ?? 0
            return (row, chunks)
        }
        let dir = url.deletingLastPathComponent()
        let bytes = ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            let path = dir.appending(path: url.lastPathComponent + suffix).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return sum + size
        }
        return Stats(
            files: counts.0["files"], folders: counts.0["folders"],
            contentIndexed: counts.0["indexed"], contentPending: counts.0["pending"],
            cloudOnly: counts.0["cloud"], namesOnly: counts.0["namesOnly"], failed: counts.0["failed"],
            embeddedChunks: counts.1, databaseBytes: bytes
        )
    }
}
