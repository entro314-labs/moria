import Foundation
import NaturalLanguage

/// Sentence embeddings from Apple's on-device contextual embedding model (Latin script).
///
/// Token vectors are mean-pooled and L2-normalized, so a dot product is cosine similarity.
/// There is no on-device model for Greek or other non-Latin scripts; text whose dominant
/// language the model does not support is skipped rather than embedded as noise.
public actor Embedder {
    private var model: NLContextualEmbedding?
    private var supportedLanguages: Set<NLLanguage> = []

    /// Characters per chunk (~200 tokens, below the model's sequence limit).
    static let chunkCharacters = 900
    /// Only the start of each document is embedded; full text is still covered by FTS.
    static let maxChunksPerDocument = 4

    public init() {}

    public enum EmbedderError: Error, CustomStringConvertible {
        case modelUnavailable
        case assetsUnavailable

        public var description: String {
            switch self {
            case .modelUnavailable: "No on-device embedding model for Latin script on this Mac."
            case .assetsUnavailable: "The embedding model assets could not be downloaded."
            }
        }
    }

    private func loadedModel() async throws -> NLContextualEmbedding {
        if let model { return model }
        guard let model = NLContextualEmbedding(script: .latin) else { throw EmbedderError.modelUnavailable }
        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else { throw EmbedderError.assetsUnavailable }
        }
        try model.load()
        self.model = model
        supportedLanguages = Set(model.languages)
        return model
    }

    public var dimension: Int {
        get async throws { try await loadedModel().dimension }
    }

    /// Embeds a query. Returns nil when the query's language is not covered by the model.
    public func embedQuery(_ text: String) async throws -> [Float]? {
        let model = try await loadedModel()
        return try embed(text, model: model)
    }

    /// Embeds up to `maxChunksPerDocument` chunks of a document; empty if none are Latin-script.
    public func embedDocument(_ text: String) async throws -> [[Float]] {
        let model = try await loadedModel()
        return try Self.chunks(of: text).compactMap { try embed($0, model: model) }
    }

    private func embed(_ text: String, model: NLContextualEmbedding) throws -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage, supportedLanguages.contains(language) else { return nil }
        let result = try model.embeddingResult(for: trimmed, language: language)
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for index in 0..<min(vector.count, sum.count) { sum[index] += vector[index] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return sum.map { Float($0 / norm) }
    }

    /// Splits text into paragraph-aligned chunks of about `chunkCharacters`.
    static func chunks(of text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for paragraph in text.split(whereSeparator: \.isNewline) where !paragraph.allSatisfy(\.isWhitespace) {
            if current.count + paragraph.count > chunkCharacters, !current.isEmpty {
                chunks.append(current)
                if chunks.count == maxChunksPerDocument { return chunks }
                current = ""
            }
            current += current.isEmpty ? String(paragraph.prefix(chunkCharacters)) : "\n" + paragraph.prefix(chunkCharacters)
        }
        if !current.isEmpty, chunks.count < maxChunksPerDocument { chunks.append(current) }
        return chunks
    }
}
