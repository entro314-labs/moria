import Foundation
import MoriaCore
import Testing
@testable import MoriaApp

@MainActor
struct IntentTests {
    @Test func findFilesReturnsTheBestMatches() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "moria-intent-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("quarterly invoice".utf8).write(to: root.appending(path: "invoice.txt"))
        try Data("holiday plans".utf8).write(to: root.appending(path: "notes.txt"))
        let database = try IndexDatabase(url: root.deletingLastPathComponent().appending(path: root.lastPathComponent + ".sqlite"))
        let controller = try IndexController(database: database)
        var settings = MoriaSettings.defaults(home: root.path)
        settings.roots = [root.path]
        try await controller.updateSettings(settings)
        try await controller.indexNow(full: true)

        let files = try await FindFilesIntent.files(matching: "invoice", limit: 5, database: database)
        #expect(files.map(\.lastPathComponent) == ["invoice.txt"])
        await #expect(throws: FindFilesIntent.FindFilesError.self) {
            try await FindFilesIntent.files(matching: "  ", limit: 5, database: database)
        }
    }
}
