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
    /// Paths whose files are indexed by name only (no text extraction).
    public var contentExcludedPaths: [String]
    /// Folder names whose files are indexed by name only: dependency and build output.
    public var contentExcludedNames: [String]
    /// Extract text inside hidden folders (`.cargo`, `.cache`, ...). Off: names only.
    public var extractHiddenContent: Bool
    /// Maximum extracted text stored per file.
    public var maxContentKilobytes: Int
    /// Files larger than this are indexed by name and metadata only.
    public var maxFileMegabytes: Int
    public var ocrImages: Bool
    public var ocrScannedPDFs: Bool
    /// Recognizes what photos show ("beach", "receipt") so those words find them.
    public var imageLabels: Bool
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
            contentExcludedPaths: ["\(home)/Library"],
            contentExcludedNames: [
                "venv", ".venv", "env", "site-packages", "__pycache__", "target", "dist", "build", "out",
                "Pods", "Carthage", "vendor", ".next", ".nuxt", "bower_components", "jspm_packages",
                ".gradle", ".m2", ".cargo", ".rustup", ".npm", ".pnpm-store", ".yarn",
            ],
            extractHiddenContent: false,
            maxContentKilobytes: 256,
            maxFileMegabytes: 100,
            ocrImages: true,
            ocrScannedPDFs: true,
            imageLabels: true,
            semanticSearchEnabled: false,
            naturalLanguageQueriesEnabled: false
        )
    }
}

extension MoriaSettings {
    /// Missing keys fall back to defaults, so settings saved by an older version still load
    /// after new settings are added.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MoriaSettings.defaults()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        roots = try value(.roots, defaults.roots)
        excludedPaths = try value(.excludedPaths, defaults.excludedPaths)
        excludedNames = try value(.excludedNames, defaults.excludedNames)
        includeHidden = try value(.includeHidden, defaults.includeHidden)
        descendIntoPackages = try value(.descendIntoPackages, defaults.descendIntoPackages)
        contentExcludedPaths = try value(.contentExcludedPaths, defaults.contentExcludedPaths)
        contentExcludedNames = try value(.contentExcludedNames, defaults.contentExcludedNames)
        extractHiddenContent = try value(.extractHiddenContent, defaults.extractHiddenContent)
        maxContentKilobytes = try value(.maxContentKilobytes, defaults.maxContentKilobytes)
        maxFileMegabytes = try value(.maxFileMegabytes, defaults.maxFileMegabytes)
        ocrImages = try value(.ocrImages, defaults.ocrImages)
        ocrScannedPDFs = try value(.ocrScannedPDFs, defaults.ocrScannedPDFs)
        imageLabels = try value(.imageLabels, defaults.imageLabels)
        semanticSearchEnabled = try value(.semanticSearchEnabled, defaults.semanticSearchEnabled)
        naturalLanguageQueriesEnabled = try value(.naturalLanguageQueriesEnabled, defaults.naturalLanguageQueriesEnabled)
    }
}
