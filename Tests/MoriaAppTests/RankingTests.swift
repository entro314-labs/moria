import Foundation
import Testing
@testable import MoriaApp

@MainActor
struct FrecencyTests {
    private func makeFrecency() -> Frecency {
        Frecency(defaults: UserDefaults(suiteName: "moria-frecency-\(UUID().uuidString)")!)
    }

    @Test func usesCountFullyWhenRecentAndHalveEveryTenDays() {
        let frecency = makeFrecency()
        let now = Date()
        frecency.record(query: "Invoice ", path: "/a", now: now)
        frecency.record(query: "invoice", path: "/a", now: now)
        #expect(frecency.weight(query: "invoice", path: "/a", now: now) == 2)
        #expect(frecency.weight(query: "invoice", path: "/a", now: now.addingTimeInterval(Frecency.halfLife)) == 1)
        #expect(frecency.weight(query: "invoice", path: "/b", now: now) == 0)
        #expect(frecency.weight(query: "receipt", path: "/a", now: now) == 0)
        // A search that begins the remembered one, or that it begins, counts for less.
        #expect(frecency.weight(query: "inv", path: "/a", now: now) == 2 * Frecency.partialWeight)
        #expect(frecency.weight(query: "invoice 2026", path: "/a", now: now) == 2 * Frecency.partialWeight)
        #expect(frecency.weight(query: "i", path: "/a", now: now) == 0)
    }

    @Test func keepsTheMostRecentUsesAndPersists() {
        let defaults = UserDefaults(suiteName: "moria-frecency-\(UUID().uuidString)")!
        let frecency = Frecency(defaults: defaults)
        let start = Date()
        for index in 0..<(Frecency.maxUses + 20) {
            frecency.record(query: "q\(index)", path: "/p\(index)", now: start.addingTimeInterval(Double(index)))
        }
        #expect(frecency.uses.count == Frecency.maxUses)
        #expect(frecency.weight(query: "q0", path: "/p0", now: start) == 0)
        #expect(Frecency(defaults: defaults).weight(query: "q519", path: "/p519", now: start.addingTimeInterval(519)) == 1)
    }
}

@MainActor
struct ApplicationsTests {
    private let apps = ["Safari", "Safari Technology Preview", "Final Cut Pro", "Pages", "Xcode"].map {
        Applications.App(name: $0, path: "/Applications/\($0).app", modified: .now)
    }

    /// Each word must begin a word of the name; the name that begins with the whole text comes
    /// first, then shorter names.
    @Test func wordsMustBeginWordsOfTheName() {
        #expect(Applications.match("saf", in: apps).map(\.name) == ["Safari", "Safari Technology Preview"])
        #expect(Applications.match("cut", in: apps).map(\.name) == ["Final Cut Pro"])
        #expect(Applications.match("final cut", in: apps).map(\.name) == ["Final Cut Pro"])
        #expect(Applications.match("Safari tech", in: apps).map(\.name) == ["Safari Technology Preview"])
        #expect(Applications.match("ari", in: apps).isEmpty)
        #expect(Applications.match("", in: apps).isEmpty)
    }
}

@MainActor
struct RankingTests {
    /// What was opened for a search comes first the next time it is typed.
    @Test func openedFilesComeFirstForTheSameSearch() async throws {
        let model = try await indexedModel()
        model.scope = .names
        model.text = "txt"
        try await settle(model)
        #expect(model.items.count == 2)
        let last = try #require(model.items.last)
        model.selection = [last.id]
        model.noteUse()
        model.search(debounce: false)
        try await settle(model)
        #expect(model.items.first?.id == last.id)
        // Other searches are not affected.
        model.text = "invoice"
        try await settle(model)
        #expect(model.items.map(\.result.name) == ["invoice.txt"])
    }

    /// An app whose name starts with the words comes first; never with filters or in a mode
    /// that isn't plain words.
    @Test func appsComeFirstForPlainWords() async throws {
        let model = try await indexedModel()
        model.text = "safari"
        try await settle(model)
        let first = try #require(model.items.first)
        #expect(first.id < 0 && first.result.kind == .application && first.result.name == "Safari.app")
        model.text = "safari ext:txt"
        try await settle(model)
        #expect(model.items.allSatisfy { $0.id > 0 })
        model.text = "safari"
        model.scope = .contents
        try await settle(model)
        #expect(model.items.allSatisfy { $0.id > 0 })
    }
}
