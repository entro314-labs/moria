import Foundation

/// Any JSON value, for JSON-RPC messages whose parameters are arbitrary.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var int: Int? {
        if case let .number(value) = self, value == value.rounded() { return Int(value) }
        return nil
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

/// A Model Context Protocol server over the index, for local AI agents (`moria mcp`).
///
/// Speaks JSON-RPC 2.0, one message per line, and offers read-only tools: `search` (the query
/// syntax, with a names/contents mode and meaning), `regex_search` and `index_status`. The
/// transport (stdin/stdout) lives in the CLI; this type only turns a request line into a
/// response line, so it can be tested without a process.
public struct MCPServer: Sendable {
    public let database: IndexDatabase
    let engine: SearchEngine
    let version: String
    let home: String

    /// Protocol revisions this server implements; a client asking for another gets the newest.
    static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    static let maxResults = 200

    public init(database: IndexDatabase, version: String, home: String = NSHomeDirectory()) {
        self.database = database
        engine = SearchEngine(database: database, home: home)
        self.version = version
        self.home = home
    }

    struct Request: Decodable {
        var id: JSONValue?
        var method: String
        var params: JSONValue?
    }

    struct Response: Encodable {
        var jsonrpc = "2.0"
        var id: JSONValue
        var result: JSONValue?
        var error: ErrorObject?
    }

    struct ErrorObject: Encodable {
        var code: Int
        var message: String
    }

    /// The response to one message, or nil for a notification (a message without an id).
    public func handle(_ line: Data) async -> Data? {
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: line)
        } catch {
            return encode(Response(id: .null, error: ErrorObject(code: -32700, message: "Parse error: \(error.localizedDescription)")))
        }
        guard let id = request.id else { return nil }
        do {
            let result = try await respond(to: request.method, params: request.params ?? .object([:]))
            return encode(Response(id: id, result: result))
        } catch let error as RPCError {
            return encode(Response(id: id, error: ErrorObject(code: error.code, message: error.message)))
        } catch {
            return encode(Response(id: id, error: ErrorObject(code: -32603, message: String(describing: error))))
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    private func respond(to method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.string
            let version = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions.last!
            return .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("moria"), "version": .string(self.version)]),
                "instructions": .string("""
                    Moria searches this Mac's own file index: every file and folder name, the text inside \
                    documents, PDFs, code and images, and (when turned on) meaning. Use `search` first; its \
                    query syntax combines words with filters. Results are local paths.
                    """),
            ])
        case "ping":
            return .object([:])
        case "tools/list":
            return .object(["tools": .array(Self.tools)])
        case "tools/call":
            guard let name = params["name"]?.string else { throw RPCError(code: -32602, message: "tools/call needs a tool name") }
            return await callTool(name, arguments: params["arguments"] ?? .object([:]))
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    static let tools: [JSONValue] = [
        .object([
            "name": .string("search"),
            "description": .string("""
                Search files on this Mac by name and contents, ranked by relevance. \
                The query uses Moria's syntax: words (all must match, in the name or the text), "exact phrases", \
                -exclude, name:report, content:lease, name:IMG* name:*.draft name:=README name:/regex/, \
                path:invoices, ext:pdf,docx, kind:document|pdf|image|audio|video|archive|text|code|folder|app, \
                size:>10mb, size:1mb..5mb, modified:<7d, modified:2026-03..2026-05, created:2025, \
                taken:2024-07 (photos), duration:>10m (audio, video), author:smith (PDFs, Office documents), \
                in:~/Documents, -in:~/Library, tag:red (Finder tags), hidden:no, cloud:no, similar:<path> (documents close in meaning \
                to a file). A query of only filters lists matching files, newest first.
                """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string"), "description": .string("Words and filters in Moria's query syntax.")]),
                    "mode": .object([
                        "type": .string("string"), "enum": .array([.string("everything"), .string("names"), .string("contents")]),
                        "description": .string("Match words against names and contents (default), names only, or contents only."),
                    ]),
                    "meaning": .object([
                        "type": .string("boolean"),
                        "description": .string("Also find documents related in meaning (needs Meaning turned on in Moria)."),
                    ]),
                    "limit": .object(["type": .string("integer"), "description": .string("Maximum results (default 20, at most 200).")]),
                ]),
                "required": .array([.string("query")]),
            ]),
        ]),
        .object([
            "name": .string("regex_search"),
            "description": .string("""
                Search file names and contents with a regular expression (ripgrep for text and code, the index's \
                extracted text for PDFs, documents and images). Returns each file with its matching lines. \
                Case-insensitive unless the pattern starts with (?-i).
                """),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "pattern": .object(["type": .string("string"), "description": .string("The regular expression.")]),
                    "filters": .object([
                        "type": .string("string"),
                        "description": .string("Optional filters in Moria's query syntax to narrow the files, e.g. ext:swift in:~/Code."),
                    ]),
                    "limit": .object(["type": .string("integer"), "description": .string("Maximum files (default 20, at most 200).")]),
                ]),
                "required": .array([.string("pattern")]),
            ]),
        ]),
        .object([
            "name": .string("index_status"),
            "description": .string("How many files and folders Moria has indexed, how many have searchable text, and what is still pending."),
            "inputSchema": .object(["type": .string("object"), "properties": .object([:])]),
        ]),
    ]

    /// Tool failures are results with `isError`, so the model sees them (protocol errors are for
    /// malformed requests).
    private func callTool(_ name: String, arguments: JSONValue) async -> JSONValue {
        do {
            let text: String
            switch name {
            case "search": text = try await search(arguments)
            case "regex_search": text = try await regexSearch(arguments)
            case "index_status": text = try status()
            default: return Self.toolResult("Unknown tool: \(name)", isError: true)
            }
            return Self.toolResult(text, isError: false)
        } catch {
            return Self.toolResult(String(describing: error), isError: true)
        }
    }

    private static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(isError)])
    }

    struct ToolError: Error, CustomStringConvertible {
        var description: String
    }

    private func limit(_ arguments: JSONValue) -> Int {
        min(max(arguments["limit"]?.int ?? 20, 1), Self.maxResults)
    }

    private func search(_ arguments: JSONValue) async throws -> String {
        guard let text = arguments["query"]?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError(description: "search needs a non-empty query")
        }
        var query = QueryParser(home: home).parse(text)
        switch arguments["mode"]?.string ?? "everything" {
        case "everything": break
        case "names": query.restrictToNames()
        case "contents": query.restrictToContents()
        case let other: throw ToolError(description: "Unknown mode \(other); use everything, names or contents")
        }
        let results = try await engine.search(query, limit: limit(arguments), semantic: arguments["meaning"]?.bool ?? false)
        var records: [ResultRecord] = []
        for result in results {
            records.append(ResultRecord(result, snippet: try await engine.snippet(for: result, query: query)))
        }
        return try Self.json(records)
    }

    struct RegexRecord: Encodable {
        struct Line: Encodable {
            var line: Int
            var text: String
        }

        var path: String
        var nameMatched: Bool
        var lines: [Line]
    }

    private func regexSearch(_ arguments: JSONValue) async throws -> String {
        guard let pattern = arguments["pattern"]?.string, !pattern.isEmpty else {
            throw ToolError(description: "regex_search needs a pattern")
        }
        let filters = QueryParser(home: home).parse(arguments["filters"]?.string ?? "")
        let searcher = try RegexSearcher(database: database)
        var records: [RegexRecord] = []
        for try await hit in searcher.search(pattern: pattern, filters: filters, maxFiles: limit(arguments)) {
            records.append(RegexRecord(path: hit.path, nameMatched: hit.nameMatched,
                                       lines: hit.lines.map { RegexRecord.Line(line: $0.number, text: $0.text) }))
        }
        return try Self.json(records)
    }

    private func status() throws -> String {
        let stats = try database.stats()
        return """
            \(stats.files) files and \(stats.folders) folders indexed by name.
            \(stats.contentIndexed) files have searchable text; \(stats.contentPending) are waiting to be read; \
            \(stats.namesOnly) are indexed by name only (Library, hidden and build folders); \(stats.cloudOnly) are cloud-only; \
            \(stats.failed) couldn't be read.
            \(stats.embeddedChunks) passages are in the meaning index.
            """
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func encode(_ response: Response) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        // Every field of a response is plain JSON; encoding cannot fail.
        return (try? encoder.encode(response)) ?? Data()
    }
}

/// One search result as JSON, for `moria search --json` and the MCP `search` tool.
public struct ResultRecord: Encodable, Sendable {
    public var path: String
    public var kind: String
    public var size: Int64
    public var modified: Date
    public var matchedName: Bool
    public var matchedContent: Bool
    public var matchedMeaning: Bool
    public var score: Double
    /// The excerpt without highlight markers.
    public var snippet: String?

    public init(_ result: SearchResult, snippet: String?) {
        path = result.path
        kind = result.kind.rawValue
        size = result.size
        modified = result.modified
        matchedName = result.matchedName
        matchedContent = result.matchedContent
        matchedMeaning = result.matchedMeaning
        score = result.score
        self.snippet = snippet?.filter { $0 != SearchResult.highlightStart && $0 != SearchResult.highlightEnd }
    }

    /// One line of JSON.
    public var json: String {
        get throws { try MCPServer.json(self) }
    }
}
