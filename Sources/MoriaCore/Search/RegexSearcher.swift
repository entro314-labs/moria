import Foundation
import GRDB

/// A file matching a regular expression, with the matching lines.
public struct RegexHit: Sendable, Identifiable, Hashable {
    public struct Line: Sendable, Hashable {
        public var number: Int
        public var text: String
    }

    public var id: Int64
    public var path: String
    public var nameMatched: Bool
    public var lines: [Line]
}

/// Regular-expression search over file names and contents.
///
/// - Text and code files are searched in full by ripgrep, fed with paths from the index, so
///   filters apply and cloud-only files are never opened (which would download them).
/// - PDFs, documents and OCR'd images have no searchable raw bytes; their extracted text is
///   matched from the index with `NSRegularExpression` instead.
/// - File names are matched from the index.
public struct RegexSearcher: Sendable {
    public let database: IndexDatabase
    public let ripgrep: URL

    public enum RegexError: Error, CustomStringConvertible {
        case ripgrepNotFound
        case invalidPattern(String)

        public var description: String {
            switch self {
            case .ripgrepNotFound: "ripgrep (rg) was not found in the app bundle or PATH."
            case let .invalidPattern(message): "Invalid regular expression: \(message)"
            }
        }
    }

    public init(database: IndexDatabase, ripgrep: URL? = nil) throws {
        self.database = database
        guard let located = ripgrep ?? Self.locateRipgrep() else { throw RegexError.ripgrepNotFound }
        self.ripgrep = located
    }

    /// `Contents/Resources/rg` in the app bundle, next to the executable (CLI install),
    /// then common Homebrew locations.
    public static func locateRipgrep() -> URL? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "rg", withExtension: nil) { candidates.append(bundled) }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appending(path: "rg"))
        }
        candidates += ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Paths passed to one ripgrep invocation (kept well under ARG_MAX).
    static let pathsPerBatch = 1500
    static let linesPerFile = 20

    /// Streams hits: name matches first, then extracted-text matches, then ripgrep matches.
    public func search(pattern: String, filters: SearchQuery, caseSensitive: Bool = false, maxFiles: Int = 2000) -> AsyncThrowingStream<RegexHit, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let regex: NSRegularExpression
                    do {
                        regex = try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
                    } catch {
                        throw RegexError.invalidPattern(error.localizedDescription)
                    }
                    var emitted = 0
                    var seen = Set<Int64>()
                    func emit(_ hit: RegexHit) -> Bool {
                        guard emitted < maxFiles else { return false }
                        if seen.insert(hit.id).inserted {
                            continuation.yield(hit)
                            emitted += 1
                        }
                        return emitted < maxFiles
                    }
                    for hit in try matchNames(regex, filters: filters) where !emit(hit) { break }
                    for hit in try matchExtractedText(regex, filters: filters) where !emit(hit) { break }
                    if emitted < maxFiles {
                        for try await hit in runRipgrep(pattern: pattern, filters: filters, caseSensitive: caseSensitive) {
                            if !emit(hit) { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func matchNames(_ regex: NSRegularExpression, filters: SearchQuery) throws -> [RegexHit] {
        let filter = FilterSQL(query: filters, home: NSHomeDirectory())
        return try database.pool.read { db in
            var hits: [RegexHit] = []
            let cursor = try Row.fetchCursor(db, sql: "SELECT f.id, f.path, f.name FROM file f WHERE \(filter.clause)", arguments: filter.arguments)
            while let row = try cursor.next() {
                let name: String = row["name"]
                if regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                    hits.append(RegexHit(id: row["id"], path: row["path"], nameMatched: true, lines: []))
                }
            }
            return hits
        }
    }

    private func matchExtractedText(_ regex: NSRegularExpression, filters: SearchQuery) throws -> [RegexHit] {
        let filter = FilterSQL(query: filters, home: NSHomeDirectory())
        return try database.pool.read { db in
            var hits: [RegexHit] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT f.id, f.path, c.body FROM file f JOIN content_fts c ON c.rowid = f.id
                WHERE f.kind IN ('pdf', 'document', 'image') AND \(filter.clause)
                """, arguments: filter.arguments)
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let body: String = row["body"]
                let lines = Self.matchingLines(regex, in: body)
                if !lines.isEmpty {
                    hits.append(RegexHit(id: row["id"], path: row["path"], nameMatched: false, lines: lines))
                }
            }
            return hits
        }
    }

    static func matchingLines(_ regex: NSRegularExpression, in text: String) -> [RegexHit.Line] {
        var lines: [RegexHit.Line] = []
        var number = 0
        text.enumerateLines { line, stop in
            number += 1
            if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                lines.append(RegexHit.Line(number: number, text: String(line.prefix(300))))
                if lines.count >= linesPerFile { stop = true }
            }
        }
        return lines
    }

    private func runRipgrep(pattern: String, filters: SearchQuery, caseSensitive: Bool) -> AsyncThrowingStream<RegexHit, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let filter = FilterSQL(query: filters, home: NSHomeDirectory())
                    let candidates = try await database.pool.read { db in
                        try Row.fetchAll(db, sql: """
                            SELECT f.id, f.path FROM file f
                            WHERE f.kind IN ('text', 'code', 'other') AND f.contentState = 1 AND \(filter.clause)
                            ORDER BY f.mtime DESC
                            """, arguments: filter.arguments).map { (id: $0["id"] as Int64, path: $0["path"] as String) }
                    }
                    let ids = Dictionary(candidates.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
                    var start = 0
                    while start < candidates.count {
                        try Task.checkCancellation()
                        let batch = candidates[start..<min(start + Self.pathsPerBatch, candidates.count)].map(\.path)
                        try await ripgrepBatch(pattern: pattern, paths: batch, caseSensitive: caseSensitive) { path, lines in
                            if let id = ids[path] {
                                continuation.yield(RegexHit(id: id, path: path, nameMatched: false, lines: lines))
                            }
                        }
                        start += Self.pathsPerBatch
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs ripgrep over explicit paths and reports matching lines per file as its JSON arrives.
    private func ripgrepBatch(
        pattern: String, paths: [String], caseSensitive: Bool,
        onFile: @escaping @Sendable (String, [RegexHit.Line]) -> Void
    ) async throws {
        var arguments = [
            "--json", "--no-config", "--no-ignore", "--hidden", "--no-messages",
            "--max-count", String(Self.linesPerFile), "--max-columns", "300", "--max-columns-preview",
        ]
        arguments.append(caseSensitive ? "--case-sensitive" : "--ignore-case")
        arguments += ["--regexp", pattern, "--"] + paths
        let process = Process()
        process.executableURL = ripgrep
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        try await withTaskCancellationHandler {
            var currentPath: String?
            var lines: [RegexHit.Line] = []
            for try await line in stdout.fileHandleForReading.bytes.lines {
                guard let event = try? JSONDecoder().decode(RipgrepEvent.self, from: Data(line.utf8)) else { continue }
                switch event.type {
                case "begin":
                    currentPath = event.data.path?.text
                    lines = []
                case "match":
                    if let number = event.data.lineNumber, let text = event.data.lines?.text {
                        lines.append(RegexHit.Line(number: number, text: text.trimmingCharacters(in: .newlines)))
                    }
                case "end":
                    if let currentPath, !lines.isEmpty { onFile(currentPath, lines) }
                    currentPath = nil
                default:
                    break
                }
            }
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()
        // Exit 1 means "no matches"; 2 with output means some files were unreadable.
        if process.terminationStatus == 2, !Task.isCancelled {
            let message = String(decoding: (try? stderr.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            if message.contains("regex parse error") || message.contains("error parsing") {
                throw RegexError.invalidPattern(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

/// The subset of ripgrep's `--json` output Moria reads.
private struct RipgrepEvent: Decodable {
    struct Text: Decodable { var text: String? }
    struct Payload: Decodable {
        var path: Text?
        var lines: Text?
        var lineNumber: Int?

        enum CodingKeys: String, CodingKey {
            case path, lines
            case lineNumber = "line_number"
        }
    }

    var type: String
    var data: Payload
}
