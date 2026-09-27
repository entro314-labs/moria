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
