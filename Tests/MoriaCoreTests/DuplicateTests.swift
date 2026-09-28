import Foundation
import Testing
@testable import MoriaCore

@Suite(.serialized)
struct DuplicateTests {
    let root: URL

    init() throws {
        root = try TestSupport.makeTempDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "A"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "B"), withIntermediateDirectories: true)
        var big = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try big.write(to: root.appending(path: "A/movie.bin"))
        try big.write(to: root.appending(path: "B/movie copy.bin"))
        // Another name for A/movie.bin, not another copy.
        try fm.linkItem(at: root.appending(path: "A/movie.bin"), to: root.appending(path: "A/movie link.bin"))
        // Same size and same first 64 KB, different end: not a duplicate.
        big[199_999] ^= 0xFF
        try big.write(to: root.appending(path: "B/movie edited.bin"))
        try Data("hello duplicate world".utf8).write(to: root.appending(path: "A/note.txt"))
        try Data("hello duplicate world".utf8).write(to: root.appending(path: "B/note.txt"))
        try Data("unique".utf8).write(to: root.appending(path: "A/unique.txt"))
    }

    private func names(_ results: [SearchResult]) -> [[String]] {
        Dictionary(grouping: results, by: { $0.duplicateGroup ?? 0 }).sorted { $0.key < $1.key }
            .map { $0.value.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }.sorted() }
    }

    @Test func groupsIdenticalFilesMostWastedSpaceFirst() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)
        func search(_ text: String) async throws -> [SearchResult] {
            try await engine.search(QueryParser(home: root.path).parse(text))
        }

        let all = try await search("duplicates:yes")
        let groups = names(all)
        try #require(groups.count == 2)
        #expect(groups.count == 2)
        #expect(groups[0].count == 2 && groups[0].contains("B/movie copy.bin") && !groups[0].contains("B/movie edited.bin"))
        #expect(groups[1] == ["A/note.txt", "B/note.txt"])
        #expect(all.first?.copies == 2)

        // Filters and words narrow the files compared.
        #expect(names(try await search("duplicates:yes size:>1kb")).count == 1)
        #expect(names(try await search("duplicates:yes ext:txt")) == [["A/note.txt", "B/note.txt"]])
        #expect(names(try await search("hello duplicates:yes")) == [["A/note.txt", "B/note.txt"]])
        #expect(try await search("duplicates:yes in:\(root.path)/A").isEmpty)

        // Hashes are kept for the next search, and dropped when a file changes.
        let stored = try await database.pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM file_hash") ?? 0 }
        #expect(stored >= 5)
        try Data("hello other world!!!!".utf8).write(to: root.appending(path: "B/note.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: root.appending(path: "B/note.txt").path)
        try await controller.apply([FileChange(path: root.appending(path: "B/note.txt").path, rescanSubtree: false)])
        #expect(names(try await search("duplicates:yes ext:txt")).isEmpty)
    }
}
