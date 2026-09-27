import Foundation

/// User-configurable index and search settings.
///
/// Persisted as JSON in the index database's `meta` table so the app and the
/// `moria` CLI always agree on what is indexed.
public struct MoriaSettings: Codable, Sendable, Equatable {
    /// Absolute paths crawled recursively.
    public var roots: [String]
    /// Absolute paths whose whole subtree is skipped.
    public var excludedPaths: [String]
    /// File or folder names skipped wherever they appear (exact match).
    public var excludedNames: [String]
    public var includeHidden: Bool
    /// When false, bundles such as `.app` or `.photoslibrary` are indexed as a single item.
    public var descendIntoPackages: Bool
    /// Maximum extracted text stored per file.
    public var maxContentKilobytes: Int
    /// Files larger than this are indexed by name and metadata only.
    public var maxFileMegabytes: Int
    public var ocrImages: Bool
    public var ocrScannedPDFs: Bool
    /// Builds sentence embeddings for documents and enables semantic ranking.
    public var semanticSearchEnabled: Bool
    /// Lets the on-device language model turn plain-language requests into filters.
    public var naturalLanguageQueriesEnabled: Bool

    public static func defaults(home: String = NSHomeDirectory()) -> MoriaSettings {
        MoriaSettings(
            roots: [home],
            excludedPaths: [
                "\(home)/Library/Caches",
                "\(home)/.Trash",
                "\(home)/Library/Application Support/Moria",
                "\(home)/Library/Developer/CoreSimulator",
                "\(home)/Library/Developer/Xcode/DerivedData",
                "\(home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
            ],
            excludedNames: [
                ".git", "node_modules", ".Spotlight-V100", ".fseventsd",
                ".DocumentRevisions-V100", ".TemporaryItems", ".build", "DerivedData",
            ],
            includeHidden: true,
            descendIntoPackages: false,
            maxContentKilobytes: 256,
            maxFileMegabytes: 100,
            ocrImages: true,
            ocrScannedPDFs: true,
            semanticSearchEnabled: false,
            naturalLanguageQueriesEnabled: false
        )
    }
}
