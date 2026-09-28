import Foundation
import Testing
@testable import MoriaCore

/// A location on a disk image that is ejected and reattached, as an external drive would be.
@Suite(.serialized)
struct VolumeTests {
    let base: URL
    let mountPoint: URL
    let image: URL

    init() throws {
        base = try TestSupport.makeTempDirectory()
        mountPoint = base.appending(path: "Drive", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        image = base.appending(path: "drive")
        try Self.hdiutil(["create", "-size", "20m", "-fs", "APFS", "-volname", "MoriaTest", "-type", "SPARSE", image.path, "-quiet"])
        try attach()
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = try Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: arguments)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func attach() throws {
        try Self.hdiutil(["attach", image.path + ".sparseimage", "-mountpoint", mountPoint.path, "-nobrowse", "-quiet"])
    }

    private func eject() throws {
        try Self.hdiutil(["detach", mountPoint.path, "-quiet"])
    }

    @Test func entriesOnAnEjectedDriveAreKeptAndMarkedOffline() async throws {
        defer { try? eject() }
        try Data("zebra crossing survey".utf8).write(to: mountPoint.appending(path: "survey.txt"))
        let database = try IndexDatabase(url: base.appending(path: "index.sqlite"))
        let controller = try IndexController(database: database)
        var settings = MoriaSettings.defaults(home: base.path)
        settings.roots = [mountPoint.path]
        settings.excludedPaths = []
        try await controller.updateSettings(settings)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: base.path)
        func search(_ text: String) async throws -> [SearchResult] {
            try await engine.search(QueryParser(home: base.path).parse(text))
        }
        #expect(try await search("zebra").map(\.name) == ["survey.txt"])
        #expect(try await search("zebra").first?.isOffline == false)

        // Ejected: the folder is still there, but empty and not a mount point.
        try eject()
        try await controller.indexNow(full: true)
        try await controller.apply([
            FileChange(path: mountPoint.path, rescanSubtree: true),  // the watcher's "root changed"
            FileChange(path: mountPoint.appending(path: "survey.txt").path, rescanSubtree: false),
        ])
        let offline = try await search("zebra")
        #expect(offline.map(\.name) == ["survey.txt"])
        #expect(offline.first?.isOffline == true)
        #expect(try await search("name:Drive").map(\.name) == ["Drive"])

        // Reattached with a change made elsewhere: the location is read again.
        try attach()
        try Data("quokka count".utf8).write(to: mountPoint.appending(path: "count.txt"))
        try await controller.apply([FileChange(path: mountPoint.path, rescanSubtree: true)])
        try await controller.indexNow(full: false)
        #expect(try await search("quokka").map(\.name) == ["count.txt"])
        #expect(try await search("zebra").first?.isOffline == false)
    }

    @Test func aLocationDeletedFromAConnectedVolumeIsRemoved() async throws {
        defer { try? eject() }
        let folder = mountPoint.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("zebra".utf8).write(to: folder.appending(path: "notes.txt"))
        let database = try IndexDatabase(url: base.appending(path: "index.sqlite"))
        let controller = try IndexController(database: database)
        var settings = MoriaSettings.defaults(home: base.path)
        settings.roots = [folder.path]
        settings.excludedPaths = []
        try await controller.updateSettings(settings)
        try await controller.indexNow(full: true)
        try FileManager.default.removeItem(at: folder)
        try await controller.indexNow(full: true)
        #expect(try await SearchEngine(database: database, home: base.path).search(QueryParser().parse("zebra")).isEmpty)
    }

    @Test func filesWaitingOnAnEjectedDriveWaitForIt() async throws {
        defer { try? eject() }
        try Data("pangolin".utf8).write(to: mountPoint.appending(path: "later.txt"))
        let database = try IndexDatabase(url: base.appending(path: "index.sqlite"))
        let controller = try IndexController(database: database)
        var settings = MoriaSettings.defaults(home: base.path)
        settings.roots = [mountPoint.path]
        settings.excludedPaths = []
        try await controller.updateSettings(settings)
        try await controller.scanOnly()
        try eject()
        // Returns (rather than retrying the unreadable file forever) and keeps it pending.
        try await controller.indexNow(full: false)
        #expect(try database.pendingCount() == 1)
        try attach()
        try await controller.indexNow(full: false)
        #expect(try await SearchEngine(database: database, home: base.path).search(QueryParser().parse("pangolin")).map(\.name) == ["later.txt"])
    }
}
