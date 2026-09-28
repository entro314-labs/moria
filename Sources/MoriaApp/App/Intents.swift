import AppIntents
import Foundation
import MoriaCore

/// Shortcuts: open Moria on a search.
struct OpenSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in Moria"
    static let description = IntentDescription(
        "Opens Moria and shows a search. Words and filters use Moria's query syntax, for example “invoice ext:pdf modified:<30d”."
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Search", inputOptions: String.IntentInputOptions(keyboardType: .default, capitalizationType: .none, autocorrect: false))
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Moria for \(\.$query)")
    }

    func perform() async throws -> some IntentResult {
        await AppDelegate.showSearch(query)
        return .result()
    }
}

/// Shortcuts: find files with Moria's index and hand them to the next action (move, attach,
/// open…), without showing Moria.
struct FindFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Files with Moria"
    static let description = IntentDescription(
        "Finds files by name and contents, best matches first, and passes them on. Uses Moria's query syntax, for example “receipt kind:pdf modified:<7d” or “duplicates:yes size:>1mb”."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Search", inputOptions: String.IntentInputOptions(keyboardType: .default, capitalizationType: .none, autocorrect: false))
    var query: String

    @Parameter(title: "Maximum Results", default: 20, inclusiveRange: (1, 500))
    var limit: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Find files matching \(\.$query)") {
            \.$limit
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let database = try IndexDatabase(url: AppModel.indexURL(defaults: .standard))
        let files = try await Self.files(matching: query, limit: limit, database: database)
        return .result(value: files.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
    }

    /// The best matches that can be handed on (not on a drive that isn't connected).
    nonisolated static func files(matching query: String, limit: Int, database: IndexDatabase) async throws -> [URL] {
        let parsed = QueryParser().parse(query)
        guard !parsed.isEmpty else { throw FindFilesError.emptyQuery }
        let results = try await SearchEngine(database: database).search(parsed, limit: limit)
        return results.filter { !$0.isOffline }.map(\.url)
    }

    enum FindFilesError: Error, CustomLocalizedStringResourceConvertible {
        case emptyQuery

        var localizedStringResource: LocalizedStringResource {
            "Type words or filters to search for."
        }
    }
}

/// Offered in Shortcuts and Spotlight without setting anything up.
struct MoriaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSearchIntent(), phrases: ["Search in \(.applicationName)"],
                    shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: FindFilesIntent(), phrases: ["Find files with \(.applicationName)"],
                    shortTitle: "Find Files", systemImageName: "doc.text.magnifyingglass")
    }
}
