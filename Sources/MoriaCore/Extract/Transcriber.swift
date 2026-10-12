import AVFoundation
import Foundation
import Speech

/// Speech-to-text for audio and video files with Apple's on-device speech analyzer.
///
/// The transcript is one line per spoken phrase, `[m:ss] words`, so a match carries the time
/// it was said at. The analyzer takes one language and can't detect it, so recordings are
/// transcribed in the system language (or English when it has no model), with the language's
/// assets installed on first use. Recordings longer than `maxDuration` are skipped: an hour
/// of speech takes minutes to transcribe.
public actor Transcriber {
    public static let maxDuration: TimeInterval = 3 * 3600

    private var locale: Locale?

    enum TranscriptionError: Error, CustomStringConvertible {
        case unavailable
        case unsupportedLanguage
        case assetsUnavailable(String)

        var description: String {
            switch self {
            case .unavailable: "Speech transcription isn't available on this Mac."
            case .unsupportedLanguage: "Speech transcription has no model for the system language or for English."
            case let .assetsUnavailable(reason): "The speech model couldn't be installed: \(reason)"
            }
        }
    }

    /// Checks that transcription can run, choosing the language and installing its assets
    /// once. Throws when it can't; recordings then stay pending for a later try.
    func prepare() async throws -> Locale {
        if let locale { return locale }
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        var chosen = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if chosen == nil { chosen = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) }
        guard let chosen else { throw TranscriptionError.unsupportedLanguage }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.module(for: chosen)]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.assetsUnavailable(String(describing: error))
        }
        locale = chosen
        return chosen
    }

    /// Whether the language's assets are installed, without installing them (tests).
    static func isReady(for locale: Locale = .current) async -> Bool {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier == supported.identifier }
    }

    private static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

    /// The transcript of the recording at `url`, or nil when it has no readable audio, is
    /// silent, or is longer than `maxDuration`. Cancelling the task stops the analyzer.
    func transcribe(_ url: URL) async throws -> String? {
        let locale = try await prepare()
        // A video without an audio track, or a format AVFoundation can't read: nothing to say.
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.fileFormat.sampleRate > 0 else { return nil }
        guard Double(file.length) / file.fileFormat.sampleRate <= Self.maxDuration else { return nil }
        let transcriber = Self.module(for: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let lines = Task {
            var lines: [String] = []
            for try await result in transcriber.results {
                let words = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else { continue }
                lines.append("[\(Self.stamp(result.range.start.seconds))] \(words)")
            }
            return lines
        }
        try await withTaskCancellationHandler {
            let last = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinish(through: last ?? .zero)
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
        let text = try await lines.value.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// "1:05:12", "3:07", "0:42": the form `duration:` and the Duration column use.
    public static func stamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The time a transcript line starts at, from its `[m:ss]` prefix (highlight markers allowed).
    public static func time(of line: String) -> TimeInterval? {
        let plain = line.filter { $0 != SearchResult.highlightStart && $0 != SearchResult.highlightEnd }
        guard plain.hasPrefix("["), let close = plain.firstIndex(of: "]") else { return nil }
        let parts = plain[plain.index(after: plain.startIndex)..<close].split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }), (2...3).contains(parts.count) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + Double($1) }
    }
}
