import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MoriaCore

@Suite(.serialized)
struct MediaTests {
    let root: URL

    init() throws {
        root = try TestSupport.makeTempDirectory()
        try FileManager.default.createDirectory(at: root.appending(path: "Media"), withIntermediateDirectories: true)
        try Self.writePhoto(taken: "2024:07:15 18:22:01", offset: "+03:00", to: root.appending(path: "Media/beach.jpg"))
        try Self.writeSilence(seconds: 1.5, to: root.appending(path: "Media/memo.wav"))
        try Self.writePDF(author: "Maria Papadopoulou", to: root.appending(path: "Media/report.pdf"))
        try Self.writeDocx(creator: "John Smith", to: root.appending(path: "Media/letter.docx"))
    }

    static func writePhoto(taken: String, offset: String, to url: URL) throws {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: taken, kCGImagePropertyExifOffsetTimeOriginal: offset]
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func writeSilence(seconds: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 8000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    static func writePDF(author: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        let info = [kCGPDFContextAuthor: author] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &box, info) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
    }

    static func writeDocx(creator: String, to url: URL) throws {
        let staging = url.deletingLastPathComponent().appending(path: "docx-staging")
        try FileManager.default.createDirectory(at: staging.appending(path: "docProps"), withIntermediateDirectories: true)
        let core = #"<?xml version="1.0"?><cp:coreProperties xmlns:cp="x" xmlns:dc="y"><dc:creator>\#(creator)</dc:creator></cp:coreProperties>"#
        try Data(core.utf8).write(to: staging.appending(path: "docProps/core.xml"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-q", "-r", url.path, "docProps"]
        try zip.run()
        zip.waitUntilExit()
        try FileManager.default.removeItem(at: staging)
    }

    private func search(_ engine: SearchEngine, _ text: String) async throws -> [String] {
        try await engine.search(QueryParser(home: root.path).parse(text)).map(\.name).sorted()
    }

    @Test func detailsAreReadAndSearchable() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        #expect(try await search(engine, "taken:2024-07") == ["beach.jpg"])
        #expect(try await search(engine, "taken:2023").isEmpty)
        #expect(try await search(engine, "duration:>1s") == ["memo.wav"])
        #expect(try await search(engine, "duration:<1s").isEmpty)
        #expect(try await search(engine, "author:papadopoulou") == ["report.pdf"])
        #expect(try await search(engine, "author:smith") == ["letter.docx"])

        let photo = try #require(try await engine.search(QueryParser(home: root.path).parse("taken:2024")).first)
        // 18:22:01 at +03:00.
        #expect(photo.taken == Date(timeIntervalSince1970: 1_721_056_921))
        let memo = try #require(try await engine.search(QueryParser(home: root.path).parse("duration:>1s")).first)
        #expect(abs((memo.duration ?? 0) - 1.5) < 0.05)

        // A changed file loses its details until they are read again.
        try Self.writePDF(author: "Someone Else", to: root.appending(path: "Media/report.pdf"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: root.appending(path: "Media/report.pdf").path)
        try await controller.apply([FileChange(path: root.appending(path: "Media/report.pdf").path, rescanSubtree: false)])
        #expect(try await search(engine, "author:papadopoulou").isEmpty)
        try await controller.indexNow(full: false)
        #expect(try await search(engine, "author:else") == ["report.pdf"])
    }

    @Test func existingIndexesAreBackfilledOnce() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        // As an index from before details: every row "not applicable", nothing read.
        try await database.pool.write { db in
            try db.execute(sql: "UPDATE file SET mediaState = 2, taken = NULL, duration = NULL, author = NULL")
            try db.execute(sql: "DELETE FROM meta WHERE key = 'media.backfilled'")
        }
        try await controller.indexNow(full: false)
        let engine = SearchEngine(database: database, home: root.path)
        #expect(try await search(engine, "author:smith") == ["letter.docx"])
        #expect(try await search(engine, "taken:2024") == ["beach.jpg"])
        #expect(try database.pendingMediaCount() == 0)
    }

    @Test func exifDatesUseTheirOffsetOrLocalTime() {
        let athens = TimeZone(identifier: "Europe/Athens")!
        #expect(MediaReader.exifDate("2024:07:15 18:22:01", offset: "+03:00") == Date(timeIntervalSince1970: 1_721_056_921))
        #expect(MediaReader.exifDate("2024:07:15 18:22:01", offset: nil, timeZone: athens) == Date(timeIntervalSince1970: 1_721_056_921))
        #expect(MediaReader.exifDate("not a date", offset: nil) == nil)
    }

    @Test func photosAreFoundByWhatTheyShow() async throws {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)
        // What Vision recognizes depends on the photo; the test photo is a plain color, so its
        // labels are stored as the details pass would store them.
        let photo = try #require(try await engine.search(QueryParser(home: root.path).parse("name:beach.jpg")).first)
        #expect(photo.labels == [])  // 64×48: too small to be worth recognizing
        try await database.pool.write { db in try db.execute(sql: "UPDATE file SET mediaState = 0 WHERE id = ?", arguments: [photo.id]) }
        try database.storeMedia([(photo.id, photo.modified.timeIntervalSince1970, MediaDetails(labels: ["beach", "sea", "sky"]))])

        let hit = try #require(try await engine.search(QueryParser(home: root.path).parse("sea")).first)
        #expect(hit.name == "beach.jpg" && hit.matchedLabel && !hit.matchedContent)
        #expect(hit.labels == ["beach", "sea", "sky"])
        #expect(try await engine.snippet(for: hit, query: QueryParser().parse("sea")) == "Shows beach, \u{1}sea\u{2}, sky")
        #expect(try await search(engine, "sky -sea").isEmpty)
        #expect(try await search(engine, "content:sky") == ["beach.jpg"])
        #expect(try await search(engine, "name:sky").isEmpty)

        // Turned off, labels are forgotten; turned on, photos are queued to be read again.
        var settings = await controller.settings
        settings.imageLabels = false
        try await controller.updateSettings(settings)
        #expect(try await search(engine, "sea").isEmpty)
        settings.imageLabels = true
        try await controller.updateSettings(settings)
        #expect(try database.pendingMediaCount() == 1)
    }
}
