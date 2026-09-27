import Foundation
import UniformTypeIdentifiers

/// Coarse file category used for filtering (`kind:`) and for choosing an extractor.
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case folder, application, package, document, pdf, image, audio, video, archive, text, code, other

    public var displayName: String {
        switch self {
        case .folder: "Folder"
        case .application: "Application"
        case .package: "Package"
        case .document: "Document"
        case .pdf: "PDF"
        case .image: "Image"
        case .audio: "Audio"
        case .video: "Video"
        case .archive: "Archive"
        case .text: "Text"
        case .code: "Code"
        case .other: "Other"
        }
    }
}

/// Maps file extensions to `FileKind`, caching the Uniform Type lookup per extension.
///
/// Not thread-safe; create one per crawl.
struct KindClassifier {
    private var cache: [String: (kind: FileKind, isPackage: Bool)] = [:]

    private static let documentExtensions: Set<String> = [
        "doc", "docx", "rtf", "rtfd", "odt", "pages", "key", "numbers", "ppt", "pptx",
        "xls", "xlsx", "ods", "odp", "epub", "eml", "emlx", "wordml",
    ]
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "go", "py", "rb", "js", "mjs", "cjs",
        "ts", "tsx", "jsx", "java", "kt", "kts", "scala", "cs", "php", "pl", "lua", "sh", "zsh", "bash",
        "fish", "sql", "json", "jsonc", "yaml", "yml", "toml", "xml", "plist", "html", "htm", "css",
        "scss", "less", "vue", "svelte", "gradle", "cmake", "mk", "dart", "zig", "ex", "exs", "erl",
        "hs", "ml", "clj", "r", "jl", "ini", "cfg", "conf", "env", "graphql", "proto", "tf", "nix",
    ]

    /// Returns the kind for an entry and whether it is an opaque package (e.g. `.app`).
    mutating func classify(ext: String, isDirectory: Bool) -> (kind: FileKind, isPackage: Bool) {
        let key = isDirectory ? "/" + ext : ext
        if let hit = cache[key] { return hit }
        let result = Self.resolve(ext: ext, isDirectory: isDirectory)
        cache[key] = result
        return result
    }

    private static func resolve(ext: String, isDirectory: Bool) -> (kind: FileKind, isPackage: Bool) {
        if isDirectory {
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory), type.conforms(to: .package) else {
                return (.folder, false)
            }
            if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return (.application, true) }
            if documentExtensions.contains(ext) { return (.document, true) }
            return (.package, true)
        }
        if ext == "pdf" { return (.pdf, false) }
        if documentExtensions.contains(ext) { return (.document, false) }
        if codeExtensions.contains(ext) { return (.code, false) }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.isDeclared else { return (.other, false) }
        if type.conforms(to: .image) { return (.image, false) }
        if type.conforms(to: .audio) { return (.audio, false) }
        if type.conforms(to: .movie) { return (.video, false) }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return (.archive, false) }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return (.code, false) }
        if type.conforms(to: .text) { return (.text, false) }
        if type.conforms(to: .application) || type.conforms(to: .executable) { return (.application, false) }
        return (.other, false)
    }
}
