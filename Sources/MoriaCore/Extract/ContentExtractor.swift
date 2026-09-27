import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

/// Turns a file into plain text for the content index.
///
/// Returns `nil` when a file has no indexable text (binary data, unsupported format, image that
/// is too small or lives in a system location). Text is capped at `maxBytes` UTF-8 bytes.
struct ContentExtractor: Sendable {
    let maxBytes: Int
    let ocrImages: Bool
    let ocrScannedPDFs: Bool
    let home: String
    let ocrLimiter: AsyncLimiter

    init(settings: MoriaSettings, home: String = NSHomeDirectory(), ocrLimiter: AsyncLimiter) {
        maxBytes = max(4, settings.maxContentKilobytes) * 1024
        ocrImages = settings.ocrImages
        ocrScannedPDFs = settings.ocrScannedPDFs
        self.home = home
        self.ocrLimiter = ocrLimiter
    }

    /// Formats whose extracted text is stored (`doc_text`): re-extracting them for snippets,
    /// regex or embeddings is slow. Text and code are simply re-read from disk.
    static func keepsExtractedText(_ kind: FileKind) -> Bool {
        kind == .pdf || kind == .document || kind == .image
    }

    /// Unknown-format files above this size are not sniffed for text.
    static let maxSniffBytes: Int64 = 4 * 1024 * 1024
    /// Pages OCR'd per scanned PDF.
    static let maxOCRPages = 10

    func extract(path: String, ext: String, kind: FileKind, size: Int64) async throws -> String? {
        let url = URL(fileURLWithPath: path)
        let raw: String? = switch kind {
        case .text, .code:
            try Self.isMarkup(ext) ? readText(url).map(Markup.stripHTML) : readText(url)
        case .other:
            size <= Self.maxSniffBytes ? try readText(url) : nil
        case .pdf:
            try await extractPDF(url)
        case .document:
            try await extractDocument(url, ext: ext)
        case .image:
            try await ocrImageIfEligible(url, path: path)
        case .folder, .application, .package, .audio, .video, .archive:
            nil
        }
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.utf8.count > maxBytes ? Self.truncate(text, toUTF8Bytes: maxBytes) : text
    }

    // MARK: - Text

    private static func isMarkup(_ ext: String) -> Bool {
        ["html", "htm", "xhtml"].contains(ext)
    }

    /// Reads up to `maxBytes` and decodes it, returning nil for binary data.
    func readText(_ url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Sniff the head first so binary files cost one small read.
        guard var data = try handle.read(upToCount: 8192), !data.isEmpty else { return nil }
        if Self.looksBinary(data) { return nil }
        if data.count == 8192, let rest = try handle.read(upToCount: maxBytes - 8192) {
            data.append(rest)
        }
        return Self.decodeText(data)
    }

    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if looksBinary(data) { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // A read cut off mid-character: retry without the partial trailing sequence.
        for trim in 1...3 where data.count > trim {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) { return text }
        }
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.windowsCP1253.rawValue, String.Encoding.windowsCP1252.rawValue,
                    String.Encoding.isoLatin1.rawValue,
                ],
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        return encoding != 0 ? converted as String? : nil
    }

    static func looksBinary(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        return !head.starts(with: [0xFF, 0xFE]) && !head.starts(with: [0xFE, 0xFF]) && head.contains(0)
    }

    static func truncate(_ text: String, toUTF8Bytes limit: Int) -> String {
        // Decoding a byte prefix turns a split trailing character into U+FFFD; drop it.
        var prefix = String(decoding: text.utf8.prefix(limit), as: UTF8.self)
        while prefix.hasSuffix("\u{FFFD}") { prefix.removeLast() }
        return prefix
    }

    // MARK: - PDF

    private func extractPDF(_ url: URL) async throws -> String? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        var text = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let pageText = page.string else { continue }
            text += pageText + "\n"
            if text.utf8.count >= maxBytes { break }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 || !ocrScannedPDFs {
            return text
        }
        // Image-only (scanned) PDF: OCR the first pages.
        var recognized: [String] = []
        for index in 0..<min(document.pageCount, Self.maxOCRPages) {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let image = Self.render(page) else { continue }
            if let pageText = try await ocrLimiter.run({ try await OCR.recognize(image) }) {
                recognized.append(pageText)
            }
        }
        return recognized.joined(separator: "\n")
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2.0, 2000 / max(bounds.width, bounds.height))
        let thumbnail = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Documents

    private func extractDocument(_ url: URL, ext: String) async throws -> String? {
        switch ext {
        case "rtf", "doc", "docx", "odt", "wordml":
            let types: [String: NSAttributedString.DocumentType] = [
                "rtf": .rtf, "doc": .docFormat, "docx": .officeOpenXML, "odt": .openDocument, "wordml": .wordML,
            ]
            let string = try NSAttributedString(
                url: url, options: [.documentType: types[ext]!], documentAttributes: nil
            )
            return string.string
        case "pptx":
            return try await Zip.text(of: url, members: ["ppt/slides/*.xml", "ppt/notesSlides/*.xml"], maxBytes: maxBytes * 4)
                .map(Markup.stripXML)
        case "xlsx":
            return try await Zip.text(of: url, members: ["xl/sharedStrings.xml", "xl/worksheets/*.xml"], maxBytes: maxBytes * 4)
                .map(Markup.stripXML)
        case "ods", "odp":
            return try await Zip.text(of: url, members: ["content.xml"], maxBytes: maxBytes * 4)
                .map(Markup.stripXML)
        case "epub":
            return try await Zip.text(of: url, members: ["*.xhtml", "*.html", "*.htm"], maxBytes: maxBytes * 4)
                .map(Markup.stripHTML)
        case "eml", "emlx":
            return try readText(url)
        default:
            // pages/key/numbers store text in compressed protobuf; ppt/xls are legacy binary.
            return nil
        }
    }

    // MARK: - Images

    private func ocrImageIfEligible(_ url: URL, path: String) async throws -> String? {
        guard ocrImages, isUserLocation(path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              min(width, height) >= 200, max(width, height) >= 400
        else { return nil }
        return try await ocrLimiter.run { try await OCR.recognize(url) }
    }

    /// OCR is skipped for images under `~/Library` and hidden folders: those are app assets
    /// and icons, and OCR costs ~100 ms per image.
    private func isUserLocation(_ path: String) -> Bool {
        if path.hasPrefix(home + "/Library/") { return false }
        return !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// Text recognition through Vision.
enum OCR {
    static func recognize(_ image: CGImage) async throws -> String? {
        let observations = try await request().perform(on: image)
        return join(observations)
    }

    static func recognize(_ url: URL) async throws -> String? {
        let observations = try await request().perform(on: url)
        return join(observations)
    }

    private static func request() -> RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        return request
    }

    private static func join(_ observations: [RecognizedTextObservation]) -> String? {
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Tag stripping for HTML and Office XML.
enum Markup {
    private static let scriptOrStyle = try! NSRegularExpression(
        pattern: "<(script|style)\\b[^>]*>.*?</\\1\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let tag = try! NSRegularExpression(pattern: "<[^>]*>")
    private static let whitespace = try! NSRegularExpression(pattern: "[ \\t\\r\\f]+")
    private static let blankLines = try! NSRegularExpression(pattern: "\\n\\s*\\n+")

    static func stripHTML(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        let withoutScripts = scriptOrStyle.stringByReplacingMatches(in: html, range: range, withTemplate: " ")
        return stripXML(withoutScripts)
    }

    static func stripXML(_ xml: String) -> String {
        var text = replace(tag, in: xml, with: " ")
        text = decodeEntities(text)
        text = replace(whitespace, in: text, with: " ")
        return replace(blankLines, in: text, with: "\n")
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            guard char == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(char)
                index = text.index(after: index)
                continue
            }
            let entity = text[text.index(after: index)..<semicolon]
            if let decoded = decode(entity) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(char)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decode(_ entity: Substring) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            guard entity.hasPrefix("#") else { return nil }
            let digits = entity.dropFirst()
            let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}

/// Reads members of zip-based formats (OOXML, OpenDocument, EPUB) with the system `unzip`.
enum Zip {
    static func text(of url: URL, members: [String], maxBytes: Int) async throws -> String? {
        let data = try await ProcessRunner.output(
            executable: "/usr/bin/unzip", arguments: ["-p", "-qq", url.path] + members, maxBytes: maxBytes,
            acceptedStatuses: [0, 11]  // 11: some member patterns matched nothing (e.g. no slide notes)
        )
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }
}
