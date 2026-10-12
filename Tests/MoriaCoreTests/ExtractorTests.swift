import AppKit
import Foundation
import PDFKit
import Testing
@testable import MoriaCore

struct ExtractorTests {
    let dir: URL
    let extractor: ContentExtractor

    init() throws {
        dir = try TestSupport.makeTempDirectory()
        var settings = MoriaSettings.defaults(home: "/nonexistent-home")
        settings.maxContentKilobytes = 64
        extractor = ContentExtractor(settings: settings, home: "/nonexistent-home", ocrLimiter: AsyncLimiter(limit: 1), transcriber: Transcriber())
    }

    func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appending(path: name)
        try data.write(to: url)
        return url
    }

    func extract(_ url: URL, kind: FileKind) async throws -> String? {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        return try await extractor.extract(path: url.path, ext: url.pathExtension.lowercased(), kind: kind, size: size)
    }

    @Test func decodesUTF8UTF16AndLegacyGreek() throws {
        #expect(ContentExtractor.decodeText(Data("héllo".utf8)) == "héllo")
        #expect(ContentExtractor.decodeText("γειά".data(using: .utf16)!) == "γειά")
        let greek = "Απόδειξη ενοικίου για το διαμέρισμα".data(using: .windowsCP1253)!
        #expect(ContentExtractor.decodeText(greek) == "Απόδειξη ενοικίου για το διαμέρισμα")
        #expect(ContentExtractor.decodeText(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) == nil)
    }

    @Test func smallTextLimitsReadOnlyThatMuch() throws {
        var settings = MoriaSettings.defaults()
        settings.maxContentKilobytes = 1  // the CLI accepts any positive number; 4 KB minimum
        let extractor = ContentExtractor(settings: settings, ocrLimiter: AsyncLimiter(limit: 1), transcriber: Transcriber())
        let url = try write("long.txt", Data(repeating: UInt8(ascii: "a"), count: 20000))
        #expect(try extractor.readText(url)?.utf8.count == 4096)
    }

    // MARK: Subprocesses (unzip for Office and EPUB text)

    @Test(.timeLimit(.minutes(1))) func subprocessWithNoisyStandardErrorFinishes() async throws {
        // 200 KB on stderr before any stdout: more than a pipe holds, so stderr must be read
        // while stdout is, or the child blocks forever.
        let data = try await ProcessRunner.output(
            executable: "/bin/sh", arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo done"], maxBytes: 1024
        )
        #expect(String(decoding: data, as: UTF8.self) == "done\n")
    }

    @Test(.timeLimit(.minutes(1))) func subprocessOutputStopsAtTheLimit() async throws {
        let data = try await ProcessRunner.output(executable: "/usr/bin/yes", arguments: [], maxBytes: 1000)
        #expect(data.count == 1000)
    }

    @Test func subprocessFailureReportsStatusAndStandardError() async throws {
        await #expect(throws: ProcessFailure.self) {
            try await ProcessRunner.output(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"], maxBytes: 1024)
        }
        do {
            _ = try await ProcessRunner.output(executable: "/bin/sh", arguments: ["-c", "echo oops >&2; exit 3"], maxBytes: 1024)
        } catch let failure as ProcessFailure {
            #expect(failure.description.contains("3") && failure.stderr == "oops\n")
        }
        let accepted = try await ProcessRunner.output(
            executable: "/bin/sh", arguments: ["-c", "echo partial; exit 11"], maxBytes: 1024, acceptedStatuses: [0, 11]
        )
        #expect(String(decoding: accepted, as: UTF8.self) == "partial\n")
    }

    @Test(.timeLimit(.minutes(1))) func cancellingASubprocessStopsIt() async throws {
        let started = ContinuousClock.now
        let run = Task { try await ProcessRunner.output(executable: "/bin/sleep", arguments: ["30"], maxBytes: 1024) }
        try await Task.sleep(for: .milliseconds(200))
        run.cancel()
        _ = await run.result
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func transcriptTimesRoundTrip() {
        #expect(Transcriber.stamp(42) == "0:42" && Transcriber.stamp(187) == "3:07" && Transcriber.stamp(3912) == "1:05:12")
        #expect(Transcriber.time(of: "[3:07] hello") == 187 && Transcriber.time(of: "[1:05:12] hello") == 3912)
        #expect(Transcriber.time(of: "\u{1}[0:42]\u{2} hello") == 42)
        #expect(Transcriber.time(of: "no stamp") == nil && Transcriber.time(of: "[x:y] no") == nil)
    }

    @Test func truncatesOnCharacterBoundary() {
        let text = String(repeating: "α", count: 10)  // 2 bytes each
        #expect(ContentExtractor.truncate(text, toUTF8Bytes: 5) == "αα")
    }

    @Test func extractsExtensionlessTextAndSkipsBinary() async throws {
        let dotfile = try write("zshrc", Data("export PATH=/opt/bin\n".utf8))
        #expect(try await extract(dotfile, kind: .other) == "export PATH=/opt/bin")
        let binary = try write("blob", Data([0x00, 0x01, 0x02, 0x41]))
        #expect(try await extract(binary, kind: .other) == nil)
    }

    @Test func stripsHTML() async throws {
        let html = try write("page.html", Data("<html><head><style>p{}</style><script>var x=1</script></head><body><p>Tom &amp; Jerry&#39;s &#x3B1;</p></body></html>".utf8))
        #expect(try await extract(html, kind: .code) == "Tom & Jerry's α")
    }

    @Test func extractsDocx() async throws {
        let attributed = NSAttributedString(string: "Lease agreement for the flat in Athens")
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let url = try write("lease.docx", data)
        #expect(try await extract(url, kind: .document)?.contains("Lease agreement") == true)
    }

    @Test func extractsPptxViaZip() async throws {
        let staging = dir.appending(path: "pptx")
        let slides = staging.appending(path: "ppt/slides")
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        try Data(#"<p:sld><a:t>Quarterly revenue</a:t><a:t>up 12%</a:t></p:sld>"#.utf8).write(to: slides.appending(path: "slide1.xml"))
        let output = dir.appending(path: "deck.pptx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-qr", output.path, "ppt"]
        try zip.run()
        zip.waitUntilExit()
        let text = try await extract(output, kind: .document)
        #expect(text == "Quarterly revenue up 12%")
    }

    @Test func extractsTextPDF() async throws {
        let url = dir.appending(path: "doc.pdf")
        try TestSupport.writePDF(text: "Energy bill for September", to: url)
        let text = try await extract(url, kind: .pdf)
        #expect(text?.contains("Energy bill for September") == true)
    }

    @Test func chunksDocumentsForEmbedding() {
        let paragraph = String(repeating: "word ", count: 100)  // 500 chars
        let text = Array(repeating: paragraph, count: 12).joined(separator: "\n")
        let chunks = Embedder.chunks(of: text)
        #expect(chunks.count == Embedder.maxChunksPerDocument)
        #expect(chunks.allSatisfy { $0.count <= Embedder.chunkCharacters + 1 })
    }
}

struct SnippetTests {
    @Test func highlightsFoldedMatchesInAWindow() {
        let text = String(repeating: "filler ", count: 40) + "Η Απόδειξη ενοικίου για τον Σεπτέμβριο.\nNext line" + String(repeating: " tail", count: 40)
        let snippet = Snippet.make(from: text, terms: ["αποδειξη", "ενοικιου"])!
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.contains("\u{1}Απόδειξη\u{2} \u{1}ενοικίου\u{2}"))
        #expect(!snippet.contains("\n"))
        #expect(Snippet.make(from: text, terms: ["missing"]) == nil)
    }
}
