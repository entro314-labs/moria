import AVFoundation
import Foundation
import ImageIO
import Vision

/// Details read from a photo, recording, PDF or document, for the `taken:`, `duration:` and
/// `author:` filters.
struct MediaDetails: Sendable, Equatable {
    /// When a photo was taken (EXIF).
    var taken: Date?
    /// Length of audio or video, in seconds.
    var duration: Double?
    /// A PDF's or document's author.
    var author: String?
    /// What a photo shows ("beach", "screenshot").
    var labels: [String] = []
}

/// Reads `MediaDetails` from the headers of a file, never its whole contents. Failures leave the
/// detail empty: a damaged file is still a file.
enum MediaReader {
    static let kinds: Set<FileKind> = [.image, .audio, .video, .pdf, .document]

    /// Details of `file`; with `labels`, also what a photo shows.
    static func read(_ file: PendingFile, labels: Bool, home: String = NSHomeDirectory()) async -> MediaDetails {
        let url = URL(fileURLWithPath: file.path)
        var details = MediaDetails()
        switch file.kind {
        case .image:
            details.taken = dateTaken(url)
            if labels, ContentExtractor.isWorthRecognizing(url, path: file.path, size: file.size, home: home) {
                details.labels = await Self.labels(url)
            }
        case .audio, .video:
            details.duration = await duration(url)
        case .pdf:
            details.author = pdfAuthor(url)
        case .document:
            details.author = await documentAuthor(url, ext: file.ext)
        case .folder, .application, .package, .archive, .text, .code, .other:
            break
        }
        return details
    }

    // MARK: - Photos

    /// EXIF `DateTimeOriginal` ("2024:07:15 18:22:01"), in the offset recorded with it or, as
    /// cameras usually record it, local time.
    static func dateTaken(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return exifDate(original, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }

    static func exifDate(_ text: String, offset: String?, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, let zone = zone(offset) {
            formatter.timeZone = zone
        } else {
            formatter.timeZone = timeZone
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// "+03:00" / "-05:30"
    private static func zone(_ offset: String) -> TimeZone? {
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60))
    }

    /// Vision's classifications that are right at least 90% of the time (Apple's suggested
    /// high-precision cut), as words: "consumer_electronics" becomes "consumer electronics".
    private static func labels(_ url: URL) async -> [String] {
        guard let observations = try? await ClassifyImageRequest().perform(on: url) else { return [] }
        return observations
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(10)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    // MARK: - Audio and video

    private static func duration(_ url: URL) async -> Double? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    // MARK: - Documents

    private static func pdfAuthor(_ url: URL) -> String? {
        guard let document = CGPDFDocument(url as CFURL), let info = document.info else { return nil }
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "Author", &value), let value,
              let text = CGPDFStringCopyTextString(value) as String? else { return nil }
        return cleaned(text)
    }

    /// The creator recorded by Office (`docProps/core.xml`) or OpenDocument (`meta.xml`).
    private static func documentAuthor(_ url: URL, ext: String) async -> String? {
        let member: String
        let elements: [String]
        switch ext {
        case "docx", "xlsx", "pptx":
            (member, elements) = ("docProps/core.xml", ["dc:creator"])
        case "odt", "ods", "odp":
            (member, elements) = ("meta.xml", ["meta:initial-creator", "dc:creator"])
        default:
            return nil
        }
        guard let xml = try? await Zip.text(of: url, members: [member], maxBytes: 64 * 1024) else { return nil }
        for element in elements {
            if let start = xml.range(of: "<\(element)>"), let end = xml.range(of: "</\(element)>", range: start.upperBound..<xml.endIndex) {
                if let author = cleaned(Markup.decodeEntities(String(xml[start.upperBound..<end.lowerBound]))) { return author }
            }
        }
        return nil
    }

    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
