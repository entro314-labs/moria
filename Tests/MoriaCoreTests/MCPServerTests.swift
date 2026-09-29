import Foundation
import Testing
@testable import MoriaCore

@Suite(.serialized)
struct MCPServerTests {
    let root: URL

    init() throws {
        root = try TestSupport.makeTempDirectory()
        try FileManager.default.createDirectory(at: root.appending(path: "Documents"), withIntermediateDirectories: true)
        try Data("Monthly rent receipt for the apartment.".utf8).write(to: root.appending(path: "Documents/receipt.txt"))
        try Data("Lease agreement.".utf8).write(to: root.appending(path: "Documents/rent-lease.txt"))
    }

    private func server() async throws -> MCPServer {
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        return MCPServer(database: database, version: "1.2.3", home: root.path)
    }

    private func call(_ server: MCPServer, _ json: String) async throws -> JSONValue? {
        guard let data = await server.handle(Data(json.utf8)) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The text of a tool result, and whether it is an error.
    private func toolText(_ response: JSONValue?) -> (text: String, isError: Bool)? {
        guard case let .array(content)? = response?["result"]?["content"], let text = content.first?["text"]?.string,
              let isError = response?["result"]?["isError"]?.bool else { return nil }
        return (text, isError)
    }

    @Test func handshakeListsToolsAndIgnoresNotifications() async throws {
        let server = try await server()
        let initialized = try await call(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(initialized?["id"] == .number(1))
        #expect(initialized?["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(initialized?["result"]?["serverInfo"]?["version"] == .string("1.2.3"))
        // An unknown revision gets the newest one this server speaks.
        let future = try await call(server, #"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect(future?["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions.last!))

        #expect(try await call(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = try await call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case let .array(tools)? = list?["result"]?["tools"] else { Issue.record("no tools"); return }
        #expect(tools.compactMap { $0["name"]?.string } == ["search", "regex_search", "index_status"])
    }

    @Test func searchToolReturnsResultsWithSnippets() async throws {
        let server = try await server()
        let response = try await call(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"apartment kind:text"}}}"#)
        let result = try #require(toolText(response))
        #expect(!result.isError)
        let records = try JSONDecoder().decode([JSONValue].self, from: Data(result.text.utf8))
        #expect(records.count == 1)
        #expect(records.first?["path"]?.string == root.path + "/Documents/receipt.txt")
        #expect(records.first?["snippet"]?.string?.contains("apartment") == true)

        // Names mode: "rent" is in one file's name and both files' text.
        let names = try await call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search","arguments":{"query":"rent","mode":"names"}}}"#)
        let nameRecords = try JSONDecoder().decode([JSONValue].self, from: Data(try #require(toolText(names)).text.utf8))
        #expect(nameRecords.compactMap { $0["path"]?.string } == [root.path + "/Documents/rent-lease.txt"])
    }

    /// Clients from 2026-07-28 on name the protocol version in every request instead of opening
    /// with `initialize`, and probe with `server/discover` first.
    @Test func perRequestVersionsAreServedWithoutAHandshake() async throws {
        let server = try await server()
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        let discover = try await call(server, #"{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{\#(meta)}}"#)
        #expect(discover?["result"]?["supportedVersions"] == .array([.string("2026-07-28")]))
        #expect(discover?["result"]?["resultType"] == .string("complete"))
        #expect(discover?["result"]?["_meta"]?["io.modelcontextprotocol/serverInfo"]?["version"] == .string("1.2.3"))
        #expect(discover?["result"]?["capabilities"]?["tools"] != nil)

        let called = try await call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"index_status",\#(meta)}}"#)
        #expect(called?["result"]?["resultType"] == .string("complete"))
        #expect(toolText(called)?.text.contains("2 files") == true)
        let list = try await call(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{\#(meta)}}"#)
        #expect(list?["result"]?["ttlMs"] != nil && list?["result"]?["cacheScope"] == .string("public"))

        // A version this server doesn't speak is refused along with the ones it does.
        let unknown = try await call(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2030-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#)
        #expect(unknown?["error"]?["code"] == .number(-32022))
        #expect(unknown?["error"]?["data"]?["supported"] == .array([.string("2026-07-28")]))
        // The client's capabilities are required with the version.
        let bare = try await call(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#)
        #expect(bare?["error"]?["code"] == .number(-32602))
        // Handshake clients see the same responses as before.
        let legacy = try await call(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/list"}"#)
        #expect(legacy?["result"]?["resultType"] == nil && legacy?["result"]?["ttlMs"] == nil)
    }

    @Test func failuresAreReportedToTheClient() async throws {
        let server = try await server()
        let unknownTool = try await call(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"delete_everything","arguments":{}}}"#)
        #expect(toolText(unknownTool)?.isError == true)
        let emptyQuery = try await call(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"search","arguments":{"query":" "}}}"#)
        #expect(toolText(emptyQuery)?.isError == true)
        let unknownMethod = try await call(server, #"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        #expect(unknownMethod?["error"]?["code"] == .number(-32601))
        let garbage = try await call(server, "not json")
        #expect(garbage?["error"]?["code"] == .number(-32700))
        #expect(garbage?["id"] == .null)
        let status = try await call(server, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"index_status"}}"#)
        #expect(toolText(status)?.text.contains("2 files") == true)
    }
}
