import Foundation
import FoundationModels

/// Answers a question from the files in the index: finds the files most likely to hold the
/// answer, takes the passage of each that fits the question best, and asks Apple's on-device
/// model to answer from those passages only, citing them as `[1]`, `[2]`, …
///
/// Retrieval is the same search as the search field (words the model picks out of the
/// question, or the question's distinctive words, plus meaning when Meaning is on); the
/// passages are a few hundred characters each because the on-device context window is small.
public struct Answerer: Sendable {
    /// A file an answer may cite, with the passage shown to the model.
    public struct Source: Sendable, Equatable, Identifiable {
        public var result: SearchResult
        public var passage: String
        public var id: Int64 { result.id }
    }

    public enum Event: Sendable {
        /// The files found, in citation order, before the answer starts, and the query that
        /// found them (its words are what the passages and excerpts highlight).
        case sources([Source], query: SearchQuery)
        /// The answer so far (the whole text, not a delta).
        case text(String)
    }

    public enum AnswerError: Error, CustomStringConvertible, LocalizedError {
        case modelUnavailable(String)
        case nothingFound
        case refused

        public var description: String {
            switch self {
            case let .modelUnavailable(reason): "The on-device language model is unavailable: \(reason)"
            case .nothingFound: "No file in the index seems to be about this. Try other words, or check that the files' contents are indexed."
            case .refused: "The on-device model declined to answer this question."
            }
        }

        public var errorDescription: String? { description }
    }

    public static var isAvailable: Bool { NaturalLanguageQuery.isAvailable }

    /// Files considered.
    static let candidateLimit = 40

    /// How many passages, and how long, the model on this Mac is given. Well under the context
    /// window (a token is about three and a half characters): the small model answers best
    /// from a few focused passages, and the question and answer need room too.
    struct Budget: Equatable {
        var sources: Int
        var passageCharacters: Int

        /// The 4096-token model of macOS 26 gets six passages of 600 characters (about a
        /// third of its window); the 8192-token model of macOS 27 gets ten of 900.
        init(contextSize: Int) {
            switch contextSize {
            case ..<3000: (sources, passageCharacters) = (2, 600)
            case ..<8000: (sources, passageCharacters) = (6, 600)
            default: (sources, passageCharacters) = (10, 900)
            }
        }
    }

    static var budget: Budget { Budget(contextSize: SystemLanguageModel.default.contextSize) }

    public init() {}

    /// Streams the sources, then the growing answer. Cancelling the consumer stops the model.
    public func answer(_ question: String, engine: SearchEngine, semantic: Bool) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let availability = SystemLanguageModel.default.availability
                    guard case .available = availability else {
                        throw AnswerError.modelUnavailable(String(describing: availability))
                    }
                    let (sources, query) = try await retrieve(question, engine: engine, semantic: semantic)
                    try Task.checkCancellation()
                    continuation.yield(.sources(sources, query: query))
                    guard !sources.isEmpty else { throw AnswerError.nothingFound }
                    try await generate(question, from: sources) { continuation.yield(.text($0)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Retrieval

    /// The files most likely to answer, each with its best passage, in citation order, and
    /// the query that found them.
    func retrieve(_ question: String, engine: SearchEngine, semantic: Bool) async throws -> ([Source], SearchQuery) {
        var query = try await searchQuery(for: question)
        let terms = query.terms
        var results = try await engine.search(query, limit: Self.candidateLimit, semantic: semantic)
        // Every word must match; when that finds nothing, the longest words alone usually do.
        if results.isEmpty, terms.count > 1 {
            let longest = terms.sorted { $0.count > $1.count }
            for keep in [2, 1] where results.isEmpty && longest.count >= keep {
                query.terms = Array(longest.prefix(keep))
                results = try await engine.search(query, limit: Self.candidateLimit, semantic: semantic)
            }
        }
        let budget = Self.budget
        var sources: [Source] = []
        for result in results where Self.canQuote(result) {
            try Task.checkCancellation()
            guard let text = try await engine.text(of: result) else { continue }
            if let passage = Self.bestPassage(of: text, terms: terms, meaningChunk: result.meaningChunk, characters: budget.passageCharacters) {
                sources.append(Source(result: result, passage: passage))
            }
            if sources.count == budget.sources { break }
        }
        return (sources, query)
    }

    /// The words to search for: the ones the model picks out of the question (as Ask does),
    /// or the question's own distinctive words when the model can't. Only the words: the
    /// kinds and dates Ask would add are guesses that hide the file with the answer.
    func searchQuery(for question: String) async throws -> SearchQuery {
        var query = SearchQuery()
        if let interpreted = try? await NaturalLanguageQuery().interpret(question), !interpreted.query.terms.isEmpty {
            query.terms = interpreted.query.terms
        } else {
            query.terms = Self.distinctiveWords(in: question)
        }
        return query
    }

    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "from", "by", "with", "about", "is",
        "are", "was", "were", "be", "been", "do", "does", "did", "what", "which", "who", "whom", "when", "where",
        "why", "how", "much", "many", "my", "me", "i", "we", "our", "you", "your", "it", "its", "this", "that",
        "these", "those", "there", "here", "any", "all", "some", "have", "has", "had", "can", "could", "would",
        "should", "will", "did", "say", "says", "said", "tell", "find", "show", "give", "get", "know", "file",
        "files", "document", "documents", "please", "last", "latest", "into", "than", "then", "so", "if", "not",
    ]

    /// The question's words that carry meaning: no stop words, no punctuation, at least two letters.
    static func distinctiveWords(in question: String) -> [String] {
        question.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    /// Folders, apps and archives have no text to quote; cloud-only and offline files can't be read.
    static func canQuote(_ result: SearchResult) -> Bool {
        guard !result.isDirectory, !result.isCloudOnly, !result.isOffline else { return false }
        switch result.kind {
        case .folder, .application, .package, .archive: return false
        case .document, .pdf, .image, .text, .code, .audio, .video, .other: return true
        }
    }

    /// The window of `characters` around the text's densest cluster of the terms (or the
    /// chunk Meaning matched, when no term appears), cut at line boundaries.
    static func bestPassage(of text: String, terms: [String], meaningChunk: Int?, characters passageCharacters: Int = 600) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let stems = terms.map(Snippet.stem)
        func hits(_ line: String) -> Int {
            stems.reduce(0) { $0 + (line.range(of: $1, options: options) != nil ? 1 : 0) }
        }
        // Score each window of lines up to the passage size by distinct term hits; best wins.
        var best: (score: Int, text: String)?
        var start = 0
        while start < lines.count {
            var end = start
            var length = 0
            var window: [String] = []
            while end < lines.count, length + lines[end].count + 1 <= passageCharacters || window.isEmpty {
                window.append(String(lines[end].prefix(passageCharacters)))
                length += lines[end].count + 1
                end += 1
            }
            let score = window.reduce(0) { $0 + hits($1) }
            if best == nil || score > best!.score {
                best = (score, window.joined(separator: "\n"))
            }
            start = end
        }
        if let best, best.score > 0 { return best.text }
        // No term in the text (a meaning match): the chunk the vectors found, or the opening.
        if meaningChunk != nil || terms.isEmpty {
            let chunks = Embedder.chunks(of: text)
            let chunk = meaningChunk.flatMap { chunks.indices.contains($0) ? chunks[$0] : nil } ?? chunks.first
            return chunk.map { String($0.prefix(passageCharacters)) }
        }
        return nil
    }

    // MARK: - Generation

    static let instructions = """
        You answer a person's question about their own files. You are given numbered sources: \
        passages from files on their Mac. Answer from the sources only, in a few plain sentences, \
        and cite the source of each fact with its number in square brackets, like [2]. \
        If the sources don't contain the answer, say so in one sentence instead of guessing.
        """

    /// Streams the answer, retrying with fewer sources if the context window overflows.
    func generate(_ question: String, from sources: [Source], onText: (String) -> Void) async throws {
        var count = sources.count
        while true {
            do {
                let session = LanguageModelSession(instructions: Self.instructions)
                let stream = session.streamResponse(to: Self.prompt(question, sources: Array(sources.prefix(count))))
                for try await snapshot in stream {
                    try Task.checkCancellation()
                    onText(snapshot.content)
                }
                return
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize where count > 1 {
                count = max(1, count / 2)
            } catch LanguageModelSession.GenerationError.guardrailViolation {
                throw AnswerError.refused
            }
        }
    }

    static func prompt(_ question: String, sources: [Source]) -> String {
        var prompt = "Question: \(question)\n\nSources:\n"
        for (index, source) in sources.enumerated() {
            prompt += "[\(index + 1)] \(source.result.name) (\(source.result.kind.displayName))\n\(source.passage)\n\n"
        }
        return prompt
    }

    /// The source numbers an answer cites, in order of first mention.
    public static func citations(in answer: String) -> [Int] {
        var seen: [Int] = []
        var rest = answer[...]
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            if let number = Int(rest[rest.index(after: open)..<close]), !seen.contains(number) { seen.append(number) }
            rest = rest[rest.index(after: close)...]
        }
        return seen
    }
}
