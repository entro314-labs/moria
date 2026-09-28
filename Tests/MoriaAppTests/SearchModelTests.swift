import Foundation
import Testing
@testable import MoriaApp

@MainActor
struct SearchModelTests {
    @Test func droppedFolderIsSearchedInside() throws {
        let (app, _) = try makeAppModel()
        let model = SearchModel(app: app)
        let root = FileManager.default.temporaryDirectory.appending(path: "moria-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "Projects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = root.appending(path: "notes.txt")
        try Data("x".utf8).write(to: file)

        #expect(!model.searchInside([file]))
        #expect(model.filters.folder == nil)
        #expect(model.searchInside([file, folder]))
        // Canonical, as the index stores it: the temporary folder is under /private.
        #expect(model.filters.folder == "/private" + folder.path(percentEncoded: false).dropLast())
    }
}
