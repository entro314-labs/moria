import Foundation
import GRDB

extension String {
    /// Case- and diacritic-insensitive form used for every indexed and queried token.
    ///
    /// SQLite's `unicode61 remove_diacritics` only folds Latin script; this also folds
    /// Greek tonos and other scripts, so "αποδειξη" matches "Απόδειξη".
    public var searchFolded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// `moria_fold(text)`: `searchFolded` as an SQL function, used to fill the filename index.
let foldFunction = DatabaseFunction("moria_fold", argumentCount: 1, pure: true) { values in
    String.fromDatabaseValue(values[0])?.searchFolded
}

/// `moria_regexp(pattern, text)`: case-insensitive ICU regex match, for `name:/…/` filters.
/// Compiled patterns are cached per connection thread.
let regexpFunction = DatabaseFunction("moria_regexp", argumentCount: 2, pure: true) { values in
    guard let pattern = String.fromDatabaseValue(values[0]), let text = String.fromDatabaseValue(values[1]) else { return false }
    guard let regex = RegexCache.regex(for: pattern) else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

enum RegexCache {
    // NSCache is thread-safe and NSRegularExpression is immutable, so sharing is safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSRegularExpression>()

    static func regex(for pattern: String) -> NSRegularExpression? {
        if let cached = cache.object(forKey: pattern as NSString) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        cache.setObject(regex, forKey: pattern as NSString)
        return regex
    }
}

/// FTS5 tokenizer that wraps `unicode61` and folds non-ASCII tokens with `searchFolded`.
///
/// Registered on every connection under the name `moria_fold`. Stored text keeps its
/// original form, so `snippet()` still shows accents and capitals.
final class FoldingTokenizer: FTS5WrapperTokenizer {
    static let name = "moria_fold"
    let wrappedTokenizer: any FTS5Tokenizer

    init(db: Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61())
    }

    func accept(
        token: String,
        flags: FTS5TokenFlags,
        for tokenization: FTS5Tokenization,
        tokenCallback: FTS5WrapperTokenCallback
    ) throws {
        // unicode61 already lowercases ASCII; only pay for folding when needed.
        if token.utf8.allSatisfy({ $0 < 0x80 }) {
            try tokenCallback(token, flags)
        } else {
            try tokenCallback(token.searchFolded, flags)
        }
    }
}
