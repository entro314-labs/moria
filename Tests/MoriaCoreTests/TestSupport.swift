import AppKit
import Foundation
@testable import MoriaCore

enum TestSupport {
    /// A fresh directory with symlinks resolved (FSEvents reports `/private/var/...` paths).
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "moria-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    static func writePDF(text: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)])
            .draw(at: CGPoint(x: 72, y: 700))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
    }

    /// An index over `root` only, with nothing excluded.
    static func makeIndex(root: URL) async throws -> (IndexDatabase, IndexController) {
        let database = try IndexDatabase(url: root.deletingLastPathComponent().appending(path: root.lastPathComponent + ".sqlite"))
        let controller = try IndexController(database: database)
        var settings = MoriaSettings.defaults(home: root.path)
        settings.roots = [root.path]
        settings.excludedPaths = []
        settings.ocrImages = false
        try await controller.updateSettings(settings)
        return (database, controller)
    }
}
