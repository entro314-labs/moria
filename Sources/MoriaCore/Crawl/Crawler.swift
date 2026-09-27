import Darwin
import Foundation

/// Metadata for one filesystem entry, as recorded in the `file` table.
public struct FileMeta: Sendable, Equatable {
    public var path: String
    public var name: String
    public var ext: String
    public var parent: String
    public var isDir: Bool
    public var size: Int64
    public var mtime: Double
    public var btime: Double
    public var kind: FileKind
    public var isHidden: Bool
    /// A cloud-provider placeholder (`SF_DATALESS`): metadata is local, content is not.
    public var isCloudOnly: Bool
}

/// Rules deciding which entries a crawl visits.
struct CrawlRules: Sendable {
    var excludedPaths: Set<String>
    var excludedNames: Set<String>
    var includeHidden: Bool
    var descendIntoPackages: Bool

    init(settings: MoriaSettings) {
        excludedPaths = Set(settings.excludedPaths.map { ($0 as NSString).standardizingPath })
        excludedNames = Set(settings.excludedNames)
        includeHidden = settings.includeHidden
        descendIntoPackages = settings.descendIntoPackages
    }

    func isExcluded(path: String, name: String) -> Bool {
        excludedNames.contains(name) || excludedPaths.contains(path)
    }

    /// True when `path` is inside (or equal to) an excluded path, or has an excluded name component.
    func isExcludedAnywhere(path: String) -> Bool {
        var current = path
        while current.count > 1 {
            let name = (current as NSString).lastPathComponent
            if isExcluded(path: current, name: name) { return true }
            if !includeHidden, name.hasPrefix(".") { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }
}

/// Walks a directory tree with `fts(3)`, which returns `stat` data with each entry and is
/// several times faster than `FileManager` enumeration on large trees.
///
/// Symlinks are recorded but never followed, and the walk does not cross into other volumes.
/// Unreadable directories (TCC-protected without Full Disk Access, or cloud-only folders whose
/// listing would trigger a download) are recorded and counted in `unreadableDirectories`.
struct Crawler {
    let rules: CrawlRules
    private(set) var unreadableDirectories = 0
    private var classifier = KindClassifier()

    init(rules: CrawlRules) {
        self.rules = rules
    }

    /// Crawls `root`, calling `visit` with batches of entries. `visit` may throw to stop the crawl.
    mutating func crawl(root: String, batchSize: Int = 2000, visit: ([FileMeta]) throws -> Void) throws {
        var batch: [FileMeta] = []
        batch.reserveCapacity(batchSize)
        let rootCopy = strdup(root)
        defer { free(rootCopy) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { fts_close(fts) }

        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP || info == FTS_DC { continue }
            let path = String(cString: entry.pointee.fts_path)
            let name = Self.lastComponent(of: path)
            let isRoot = entry.pointee.fts_level == FTS_ROOTLEVEL

            if !isRoot {
                let hidden = name.hasPrefix(".")
                if rules.isExcluded(path: path, name: name) || (hidden && !rules.includeHidden) {
                    if info == FTS_D { fts_set(fts, entry, FTS_SKIP) }
                    continue
                }
            }
            if info == FTS_NS || info == FTS_ERR { continue }
            if info == FTS_DNR { unreadableDirectories += 1 }
            guard let statp = entry.pointee.fts_statp else { continue }
            let st = statp.pointee

            let isDir = info == FTS_D || info == FTS_DNR
            let ext = Self.extensionOf(name)
            let (kind, isPackage) = classifier.classify(ext: ext, isDirectory: isDir)
            if isDir, isPackage, !rules.descendIntoPackages, !isRoot {
                fts_set(fts, entry, FTS_SKIP)
            }

            batch.append(FileMeta(
                path: path,
                name: name,
                ext: ext,
                parent: isRoot ? (path as NSString).deletingLastPathComponent : Self.parent(of: path, nameCount: name.utf8.count),
                isDir: isDir,
                size: isDir ? 0 : Int64(st.st_size),
                mtime: Self.seconds(st.st_mtimespec),
                btime: Self.seconds(st.st_birthtimespec),
                kind: kind,
                isHidden: name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0,
                isCloudOnly: (st.st_flags & UInt32(SF_DATALESS)) != 0
            ))
            if batch.count >= batchSize {
                try visit(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { try visit(batch) }
    }

    /// Stats a single path without following symlinks. Returns nil when it no longer exists.
    mutating func meta(forPath path: String) -> FileMeta? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let name = Self.lastComponent(of: path)
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let ext = Self.extensionOf(name)
        let kind = classifier.classify(ext: ext, isDirectory: isDir).kind
        return FileMeta(
            path: path, name: name, ext: ext, parent: (path as NSString).deletingLastPathComponent,
            isDir: isDir, size: isDir ? 0 : Int64(st.st_size),
            mtime: Self.seconds(st.st_mtimespec), btime: Self.seconds(st.st_birthtimespec),
            kind: kind, isHidden: name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0,
            isCloudOnly: (st.st_flags & UInt32(SF_DATALESS)) != 0
        )
    }

    /// Whether `path` is a package that the rules treat as a single item.
    mutating func isOpaquePackage(path: String) -> Bool {
        guard !rules.descendIntoPackages else { return false }
        let ext = Self.extensionOf(Self.lastComponent(of: path))
        return !ext.isEmpty && classifier.classify(ext: ext, isDirectory: true).isPackage
    }

    static func seconds(_ ts: timespec) -> Double {
        Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    static func lastComponent(of path: String) -> String {
        guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) else { return path }
        return String(path[path.utf8.index(after: slash)...])
    }

    static func parent(of path: String, nameCount: Int) -> String {
        let end = path.utf8.index(path.utf8.endIndex, offsetBy: -(nameCount + 1))
        return end == path.utf8.startIndex ? "/" : String(path[..<end])
    }

    /// Lowercased extension without the dot; empty for dotfiles like `.zshrc`.
    static func extensionOf(_ name: String) -> String {
        guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")), dot != name.utf8.startIndex else { return "" }
        let ext = name[name.utf8.index(after: dot)...]
        guard !ext.isEmpty, ext.utf8.count <= 16 else { return "" }
        return ext.lowercased()
    }
}
