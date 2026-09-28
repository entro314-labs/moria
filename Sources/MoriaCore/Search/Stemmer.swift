import CSnowball
import Foundation

/// Stems query words in scripts where one language dominates, so a search for one form of a
/// word finds the others ("αποδείξεις" finds "απόδειξη", "договора" finds "договоры").
///
/// The content index stores folded word forms, and content search already matches word
/// prefixes; searching for the stem as a prefix therefore needs no change to the index. Latin
/// script is left alone: the index stems it with Porter (English), and a Latin word's
/// language can't be told from the word.
enum Stemmer {
    private enum Language {
        case greek, russian
    }

    /// Stems shorter than this match too many unrelated words as a prefix.
    static let minimumStemLength = 3

    /// The stem of `word` (folded: lowercase, no accents) when it is Greek or Cyrillic and
    /// stemming shortens it usefully; nil otherwise.
    static func stem(_ word: String) -> String? {
        guard let language = language(of: word) else { return nil }
        let bytes = Array(word.utf8)
        let stemmed: String? = bytes.withUnsafeBufferPointer { buffer in
            guard let env = create(language) else { return nil }
            defer { close(language, env) }
            guard SN_set_current(env, Int32(buffer.count), buffer.baseAddress) == 0, run(language, env) >= 0 else { return nil }
            return String(decoding: UnsafeBufferPointer(start: env.pointee.p, count: Int(env.pointee.l)), as: UTF8.self)
        }
        guard let stemmed, stemmed != word, stemmed.count >= minimumStemLength else { return nil }
        return stemmed
    }

    /// Greek or Cyrillic when every letter is; nil for anything else or a mix.
    private static func language(of word: String) -> Language? {
        var found: Language?
        for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
            let script: Language? = switch scalar.value {
            case 0x0370...0x03FF, 0x1F00...0x1FFF: .greek
            case 0x0400...0x04FF: .russian
            default: nil
            }
            guard let script, found == nil || found == script else { return nil }
            found = script
        }
        return found
    }

    private static func create(_ language: Language) -> UnsafeMutablePointer<SN_env>? {
        switch language {
        case .greek: greek_UTF_8_create_env()
        case .russian: russian_UTF_8_create_env()
        }
    }

    private static func run(_ language: Language, _ env: UnsafeMutablePointer<SN_env>) -> Int32 {
        switch language {
        case .greek: greek_UTF_8_stem(env)
        case .russian: russian_UTF_8_stem(env)
        }
    }

    private static func close(_ language: Language, _ env: UnsafeMutablePointer<SN_env>) {
        switch language {
        case .greek: greek_UTF_8_close_env(env)
        case .russian: russian_UTF_8_close_env(env)
        }
    }
}
