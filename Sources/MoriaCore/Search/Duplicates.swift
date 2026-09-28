import CryptoKit
import Darwin
import Foundation
import GRDB

/// Finding identical files (`duplicates:yes`).
///
/// Files can only be identical if their sizes are equal, so candidates are grouped by size in
/// SQL first. Within a size group, a hash of the first 64 KB separates most files after one
/// small read each; only files whose heads match are hashed in full. Hashes are cached in
/// `file_hash` while a file's size and mtime are unchanged, so repeating a search reads nothing.
/// Cloud-only files are never read (that would download them), and hard links to one file
/// count once.
extension SearchEngine {
    static let duplicateHeadBytes = 64 * 1024
    /// Size groups considered, largest first: the rest of a big index can't be hashed in one
    /// search anyway, and large copies waste the most space.
    static let duplicateSizeGroups = 5000
    /// Candidates taken from a word search before grouping.
    static let duplicateWordCandidates = 5000

    /// Files matching the rest of `query` that have an identical copy among them, in groups
    /// (most space wasted first), with `duplicateGroup` and `copies` set.
    func duplicates(_ query: SearchQuery, limit: Int, semantic: Bool) async throws -> [SearchResult] {
        var rest = query
        rest.duplicatesOnly = false
        let candidates = if rest.hasTextCriteria || rest.similarTo != nil {
            try await search(rest, limit: Self.duplicateWordCandidates, semantic: semantic)
        } else {
            try await sameSizeFiles(rest)
        }
        let bySize = Dictionary(grouping: candidates.filter { !$0.isDirectory && !$0.isCloudOnly && $0.size > 0 }, by: \.size)
            .filter { $0.value.count > 1 }
        let cached = try await cachedHashes(for: bySize.values.flatMap { $0.map(\.id) })
        var computed: [Int64: (head: Data, full: Data?)] = [:]

        var groups: [[SearchResult]] = []
        for (size, files) in bySize.sorted(by: { $0.key > $1.key }) {
            try Task.checkCancellation()
            var byHead: [Data: [SearchResult]] = [:]
            var inodes = Set<[UInt64]>()
            for file in files {
                // Gone, unreadable, or another name for a file already counted.
                guard let inode = Self.inode(file.path), inodes.insert(inode).inserted else { continue }
                if let known = cached[file.id] ?? computed[file.id] {
                    byHead[known.head, default: []].append(file)
                } else if let head = Self.hashHead(file.path) {
                    computed[file.id] = (head, size <= Self.duplicateHeadBytes ? head : nil)
                    byHead[head, default: []].append(file)
                }
            }
            for same in byHead.values where same.count > 1 {
                // The head is the whole file: equal heads are equal files.
                if size <= Int64(Self.duplicateHeadBytes) {
                    groups.append(same)
                    continue
                }
                var byContent: [Data: [SearchResult]] = [:]
                for file in same {
                    try Task.checkCancellation()
                    let full: Data?
                    if let known = cached[file.id]?.full ?? computed[file.id]?.full {
                        full = known
                    } else {
                        full = Self.hashWhole(file.path)
                        if let full, let head = computed[file.id]?.head ?? cached[file.id]?.head { computed[file.id] = (head, full) }
                    }
                    if let full { byContent[full, default: []].append(file) }
                }
                groups += byContent.values.filter { $0.count > 1 }
            }
        }
        try storeHashes(computed)

        // Most space wasted first; within a group, the oldest copy (likely the original) first.
        func wasted(_ group: [SearchResult]) -> Int64 { Int64(group.count - 1) * group[0].size }
        let ordered = groups
            .map { group in group.sorted { $0.created < $1.created } }
            .sorted { wasted($0) > wasted($1) }
        var results: [SearchResult] = []
        for (index, group) in ordered.enumerated() where results.count < limit {
            for var file in group {
                file.duplicateGroup = index + 1
                file.copies = group.count
                file.score = Double(ordered.count - index)
                results.append(file)
            }
        }
        return results
    }

    /// Files passing the query's filters whose size another such file shares, largest sizes
    /// first. Symbolic links and cloud-only files are left out.
    private func sameSizeFiles(_ query: SearchQuery) async throws -> [SearchResult] {
        let filter = FilterSQL(query: query, home: home)
        let eligible = "f.isDir = 0 AND f.isCloudOnly = 0 AND f.size > 0 AND f.contentState != 7 AND \(filter.clause)"
        return try await database.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT \(Self.columns) FROM file f JOIN dir d ON d.id = f.dirId
                WHERE \(eligible) AND f.size IN (
                    SELECT f.size FROM file f JOIN dir d ON d.id = f.dirId WHERE \(eligible)
                    GROUP BY f.size HAVING count(*) > 1 ORDER BY f.size DESC LIMIT ?)
                """, arguments: filter.arguments + filter.arguments + [Self.duplicateSizeGroups]).map { Self.result(from: $0) }
        }
    }

    // MARK: - Hashes

    /// Stored hashes still valid for the file as indexed (same size and mtime).
    private func cachedHashes(for ids: [Int64]) async throws -> [Int64: (head: Data, full: Data?)] {
        guard !ids.isEmpty else { return [:] }
        return try await database.pool.read { db in
            var hashes: [Int64: (head: Data, full: Data?)] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT h.fileId, h.head, h.full FROM file_hash h JOIN file f ON f.id = h.fileId
                    WHERE h.fileId IN (\(chunk.map(String.init).joined(separator: ","))) AND h.size = f.size AND h.mtime = f.mtime
                    """)
                for row in rows { hashes[row["fileId"]] = (row["head"], row["full"]) }
            }
            return hashes
        }
    }

    /// Saves hashes against the file's size and mtime as indexed.
    private func storeHashes(_ hashes: [Int64: (head: Data, full: Data?)]) throws {
        guard !hashes.isEmpty else { return }
        try database.pool.write { db in
            let store = try db.cachedStatement(sql: """
                INSERT OR REPLACE INTO file_hash(fileId, size, mtime, head, full)
                SELECT id, size, mtime, ?, ? FROM file WHERE id = ?
                """)
            for (id, hash) in hashes { try store.execute(arguments: [hash.head, hash.full, id]) }
        }
    }

    /// The file's device and inode, which hard links share.
    static func inode(_ path: String) -> [UInt64]? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return [UInt64(bitPattern: Int64(st.st_dev)), st.st_ino]
    }

    /// SHA-256 of the first 64 KB. Nil when the file can't be read.
    static func hashHead(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path), let data = try? handle.read(upToCount: duplicateHeadBytes) else { return nil }
        try? handle.close()
        return Data(SHA256.hash(data: data))
    }

    /// SHA-256 of the whole file, read 1 MB at a time. Nil when it can't be read or the search
    /// was cancelled.
    static func hashWhole(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // `read(upToCount:)` returns nil (or empty data) at the end of the file.
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                if Task.isCancelled { return nil }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return Data(hasher.finalize())
    }
}
