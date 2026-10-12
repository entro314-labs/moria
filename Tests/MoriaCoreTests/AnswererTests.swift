import Foundation
import Testing
@testable import MoriaCore

struct AnswererTests {
    @Test func distinctiveWordsDropFillerAndPunctuation() {
        #expect(Answerer.distinctiveWords(in: "What does the lease say about pets?") == ["lease", "pets"])
        #expect(Answerer.distinctiveWords(in: "How much is the deposit, and when is it due?") == ["deposit", "due"])
        #expect(Answerer.distinctiveWords(in: "Q3 budget: who approved it?") == ["q3", "budget", "approved"])
    }

    /// The passage is the window of lines with the most term hits, cut at line boundaries and
    /// never longer than the passage size.
    @Test func bestPassageIsTheDensestWindow() throws {
        let filler = Array(repeating: "Nothing relevant here, just words and more words.", count: 20)
        let text = (filler + ["Pets are allowed with a deposit of 300 euros.", "Dogs must be leashed in the garden."] + filler)
            .joined(separator: "\n")
        let passage = try #require(Answerer.bestPassage(of: text, terms: ["pets", "deposit"], meaningChunk: nil))
        #expect(passage.contains("Pets are allowed") && passage.count <= Answerer.passageCharacters)
        // Stems match as the search did: "leashed" by "leash".
        #expect(Answerer.bestPassage(of: text, terms: ["leashing"], meaningChunk: nil)?.contains("leashed") == true)
        // No term in the text and no meaning match: nothing to quote.
        #expect(Answerer.bestPassage(of: text, terms: ["zebra"], meaningChunk: nil) == nil)
        // A meaning match quotes the chunk the vectors found.
        #expect(Answerer.bestPassage(of: text, terms: ["zebra"], meaningChunk: 0)?.hasPrefix("Nothing relevant") == true)
    }

    @Test func citationsAreNumberedInOrderOfMention() {
        #expect(Answerer.citations(in: "Pets are allowed [2], with a deposit [1][2]. See [3].") == [2, 1, 3])
        #expect(Answerer.citations(in: "No sources say [x] anything.").isEmpty)
    }

    @Test func promptNumbersTheSources() {
        var result = SearchResult(id: 7, path: "/x/lease.pdf", name: "lease.pdf", ext: "pdf", kind: .pdf, isDirectory: false, size: 1,
                                  modified: .now, created: .now, isCloudOnly: false, matchedName: false, matchedContent: true,
                                  matchedMeaning: false, meaningChunk: nil, snippet: nil, score: 1)
        result.labels = []
        let prompt = Answerer.prompt("pets?", sources: [Answerer.Source(result: result, passage: "Pets are allowed.")])
        #expect(prompt == "Question: pets?\n\nSources:\n[1] lease.pdf (PDF)\nPets are allowed.\n\n")
    }

    /// With the on-device model available: the lease is found, quoted and cited.
    @Test func answersFromTheFilesWithCitations() async throws {
        guard Answerer.isAvailable else { return }
        let root = try TestSupport.makeTempDirectory()
        try Data("Lease agreement for the apartment at 12 Elm Street.\nPets are allowed with a deposit of 300 euros, dogs must be leashed in the garden.\nRent is due on the first of the month.".utf8)
            .write(to: root.appending(path: "lease.txt"))
        try Data("Shopping: milk, eggs, bread. Call the dentist on Monday.".utf8).write(to: root.appending(path: "notes.txt"))
        let (database, controller) = try await TestSupport.makeIndex(root: root)
        try await controller.indexNow(full: true)
        let engine = SearchEngine(database: database, home: root.path)

        var sources: [Answerer.Source] = []
        var answer = ""
        for try await event in Answerer().answer("Are pets allowed under the lease?", engine: engine, semantic: false) {
            switch event {
            case let .sources(found, _): sources = found
            case let .text(text): answer = text
            }
        }
        #expect(sources.map(\.result.name) == ["lease.txt"], "sources: \(sources.map(\.result.name))")
        #expect(sources.first?.passage.contains("Pets are allowed") == true)
        #expect(!answer.isEmpty)
        #expect(Answerer.citations(in: answer).contains(1), "answer: \(answer)")
    }
}
