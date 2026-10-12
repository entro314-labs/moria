import AppKit
import Foundation
import MoriaCore

/// The apps on this Mac, for searches that name one. A short search most often wants an app
/// to launch, and apps live outside the indexed locations, so they are listed from their
/// folders and put first when their name starts with the words typed, as Spotlight does.
@MainActor
final class Applications {
    struct App: Equatable {
        var name: String
        var path: String
        var modified: Date
    }

    static let folders = [
        "/Applications", "/System/Applications", "/System/Applications/Utilities",
        "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications",
    ]
    static let maxMatches = 3
    static let refreshInterval: TimeInterval = 5 * 60

    private var apps: [App] = []
    private var listedAt = Date.distantPast

    /// Apps whose name starts with the words of `text`, best first.
    func matching(_ text: String) -> [App] {
        if Date().timeIntervalSince(listedAt) > Self.refreshInterval {
            apps = Self.list()
            listedAt = Date()
        }
        return Self.match(text, in: apps)
    }

    /// Each word typed must begin a word of the app's name ("saf" finds Safari, "cut" finds
    /// Final Cut Pro, "ari" finds nothing); names that begin with the whole text come first,
    /// then shorter names.
    static func match(_ text: String, in apps: [App]) -> [App] {
        let words = text.searchFolded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        let whole = words.joined(separator: " ")
        func nameWords(_ app: App) -> [String] {
            app.name.searchFolded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        return apps.filter { app in
            let parts = nameWords(app)
            return words.allSatisfy { word in parts.contains { $0.hasPrefix(word) } }
        }
        .sorted { a, b in
            let aWhole = a.name.searchFolded.hasPrefix(whole), bWhole = b.name.searchFolded.hasPrefix(whole)
            if aWhole != bWhole { return aWhole }
            return a.name.count != b.name.count ? a.name.count < b.name.count : a.name < b.name
        }
        .prefix(maxMatches).map { $0 }
    }

    /// The `.app` bundles in the standard folders (one level of subfolders too, for suites).
    static func list() -> [App] {
        let fm = FileManager.default
        var apps: [App] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard url.pathExtension == "app", seen.insert(url.path).inserted else { return }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            apps.append(App(name: fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), path: url.path, modified: modified))
        }
        // Not skipping hidden entries: Safari is a hidden link in /Applications (to a cryptex).
        for folder in folders {
            guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
                if entry.pathExtension == "app" {
                    add(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let inner = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                    inner.filter { !$0.lastPathComponent.hasPrefix(".") }.forEach(add)
                }
            }
        }
        return apps
    }

    /// A row for the results list. Ids are negative so they never collide with the index's.
    static func result(for app: App, number: Int) -> SearchResult {
        SearchResult(
            id: -Int64(number), path: app.path, name: (app.path as NSString).lastPathComponent, ext: "app", kind: .application,
            isDirectory: true, size: 0, modified: app.modified, created: app.modified, isCloudOnly: false,
            matchedName: true, matchedContent: false, matchedMeaning: false, meaningChunk: nil, snippet: nil, score: 0
        )
    }
}
