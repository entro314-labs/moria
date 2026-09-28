import Foundation
import Testing
@testable import MoriaApp

@MainActor
struct FileActionsTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "moria-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Trash"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Documents"), withIntermediateDirectories: true)
    }

    /// Moves `names` from Documents into the stand-in Trash, as `NSWorkspace.recycle` would.
    private func trash(_ names: [String]) throws -> [URL: URL] {
        var trashed: [URL: URL] = [:]
        for name in names {
            let original = root.appending(path: "Documents/\(name)")
            try Data(name.utf8).write(to: original)
            let inTrash = root.appending(path: "Trash/\(name)")
            try FileManager.default.moveItem(at: original, to: inTrash)
            trashed[original] = inTrash
        }
        return trashed
    }

    @Test func putBackRestoresEveryFile() throws {
        let trashed = try trash(["a.txt", "b.txt"])
        let restored = try FileActions.putBack(trashed)
        #expect(Set(restored) == Set(trashed.keys))
        for original in trashed.keys {
            #expect(FileManager.default.fileExists(atPath: original.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Trash").path).isEmpty)
    }

    @Test func putBackNeverOverwritesAFileThatTookItsPlace() throws {
        let trashed = try trash(["a.txt", "b.txt"])
        let taken = root.appending(path: "Documents/b.txt")
        try Data("new".utf8).write(to: taken)
        #expect {
            try FileActions.putBack(trashed)
        } throws: { error in
            guard let error = error as? FileActions.PutBackError else { return false }
            return error.file.lastPathComponent == "b.txt" && error.restored.map(\.lastPathComponent) == ["a.txt"]
        }
        #expect(try String(contentsOf: taken, encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "Trash/b.txt").path))
    }
}
