import Darwin
import Foundation

/// Metadata for one filesystem entry, as recorded in the `file` table.
public struct FileMeta: Sendable, Equatable {
    public var path: String
    public var name: String
    public var ext: String
    public var isDir: Bool
    public var size: Int64
    public var mtime: Double
    public var btime: Double
    public var kind: FileKind
    public var isHidden: Bool
    /// A cloud-provider placeholder (`SF_DATALESS`): metadata is local, content is not.
    public var isCloudOnly: Bool
    /// False inside content-excluded locations: indexed by name only.
    public var contentEligible: Bool = true
    /// Symbolic links are indexed by name; their targets are never read through them.
    public var isSymlink: Bool = false
    /// Finder tag names.
    public var tags: [String] = []
}

/// Finder tags, read from the `com.apple.metadata:_kMDItemUserTags` extended attribute.
///
/// Reading an extended attribute costs ~25-40 µs per file even when it is absent, which would
/// double the time of a full crawl. So tags are read only where contents are read (not in
/// Library, hidden or dependency folders, which are indexed by name only), several files at a
/// time.
enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    /// Concurrent reads per batch; more gave no further speedup.
    static let readers = 4

    static func isRead(for meta: FileMeta) -> Bool {
        meta.contentEligible && !meta.isSymlink
    }

    /// Reads the tags of every entry in `batch` that gets them.
    static func fill(_ batch: inout [FileMeta]) {
        let count = batch.count
        batch.withUnsafeMutableBufferPointer { entries in
            nonisolated(unsafe) let entries = entries
            // Each reader writes only its own indices.
            DispatchQueue.concurrentPerform(iterations: readers) { reader in
                var index = reader
                while index < count {
                    if isRead(for: entries[index]) { entries[index].tags = read(path: entries[index].path) }
                    index += readers
                }
            }
        }
    }

    /// Tag names of the entry at `path` (not following symlinks); empty when untagged. Most
    /// files have no tags, so this is usually one failed `getxattr` call.
    static func read(path: UnsafePointer<CChar>) -> [String] {
        var buffer = [UInt8](repeating: 0, count: 1024)
        var length = getxattr(path, attribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        if length < 0, errno == ERANGE {
            // More tags than fit: ask for the size, then read again.
            length = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard length > 0 else { return [] }
            buffer = [UInt8](repeating: 0, count: length)
            length = getxattr(path, attribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        }
        guard length > 0 else { return [] }
        return parse(Data(buffer.prefix(length)))
    }

    /// The attribute is a property list of strings "Name" or "Name\n<color number>".
    static func parse(_ data: Data) -> [String] {
        guard let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return entries.compactMap { entry in
            let name = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return name.isEmpty ? nil : name
        }
    }

    /// The stored form: "\nRed\nWork\n", or nil when untagged.
    static func stored(_ tags: [String]) -> String? {
        tags.isEmpty ? nil : "\n" + tags.joined(separator: "\n") + "\n"
    }

    static func names(fromStored value: String?) -> [String] {
        value?.split(separator: "\n").map(String.init) ?? []
    }
}

/// Rules deciding which entries a crawl visits.
struct CrawlRules: Sendable {
    var excludedPaths: Set<String>
    var excludedNames: Set<String>
    var includeHidden: Bool
    var descendIntoPackages: Bool
    var contentExcludedPaths: Set<String>
    var contentExcludedNames: Set<String>
    var extractHiddenContent: Bool

    init(settings: MoriaSettings) {
        excludedPaths = Set(settings.excludedPaths.map { ($0 as NSString).standardizingPath })
        excludedNames = Set(settings.excludedNames)
        includeHidden = settings.includeHidden
        descendIntoPackages = settings.descendIntoPackages
        contentExcludedPaths = Set(settings.contentExcludedPaths.map { ($0 as NSString).standardizingPath })
        contentExcludedNames = Set(settings.contentExcludedNames)
        extractHiddenContent = settings.extractHiddenContent
    }

    /// Whether a folder (or file) itself turns off content extraction for its subtree.
    func excludesContent(path: String, name: String) -> Bool {
        contentExcludedNames.contains(name) || contentExcludedPaths.contains(path)
            || (!extractHiddenContent && name.hasPrefix("."))
    }

    /// Content eligibility of an arbitrary path, checking every ancestor below `/`.
    func isContentEligible(path: String) -> Bool {
        var current = path
        while current.count > 1 {
            if excludesContent(path: current, name: (current as NSString).lastPathComponent) { return false }
            current = (current as NSString).deletingLastPathComponent
        }
        return true
    }

    func isExcluded(path: String, name: String) -> Bool {
        excludedNames.contains(name) || excludedPaths.contains(path)
    }

    /// True when `path` is inside (or equal to) an excluded path, or has an excluded name
    /// component, below `root`. Folders above the location don't count, as in the crawl.
    func isExcludedAnywhere(path: String, below root: String) -> Bool {
        var current = path
        while current.count > root.count {
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
        // excludedAtLevel[n]: content is excluded for entries at depth n (inherited downward).
        var excludedAtLevel = [!rules.isContentEligible(path: (root as NSString).deletingLastPathComponent)]
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
            let level = Int(entry.pointee.fts_level)
            let inheritedExclusion = excludedAtLevel[min(level, excludedAtLevel.count - 1)]
            let contentExcluded = inheritedExclusion || rules.excludesContent(path: path, name: name)
            if isDir {
                if excludedAtLevel.count <= level + 1 { excludedAtLevel.append(contentExcluded) }
                else { excludedAtLevel[level + 1] = contentExcluded }
            }
            let ext = Self.extensionOf(name)
            let (kind, isPackage) = classifier.classify(ext: ext, isDirectory: isDir)
            if isDir, isPackage, !rules.descendIntoPackages, !isRoot {
                fts_set(fts, entry, FTS_SKIP)
            }

            batch.append(FileMeta(
                path: path,
                name: name,
                ext: ext,
                isDir: isDir,
                size: isDir ? 0 : Int64(st.st_size),
                mtime: Self.seconds(st.st_mtimespec),
                btime: Self.seconds(st.st_birthtimespec),
                kind: kind,
                isHidden: name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0,
                isCloudOnly: (st.st_flags & UInt32(SF_DATALESS)) != 0,
                contentEligible: !contentExcluded,
                isSymlink: info == FTS_SL || info == FTS_SLNONE
            ))
            if batch.count >= batchSize {
                FinderTags.fill(&batch)
                try visit(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            FinderTags.fill(&batch)
            try visit(batch)
        }
    }

    /// Stats a single path without following symlinks. Returns nil when it no longer exists.
    mutating func meta(forPath path: String) -> FileMeta? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let name = Self.lastComponent(of: path)
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let ext = Self.extensionOf(name)
        let kind = classifier.classify(ext: ext, isDirectory: isDir).kind
        var meta = FileMeta(
            path: path, name: name, ext: ext,
            isDir: isDir, size: isDir ? 0 : Int64(st.st_size),
            mtime: Self.seconds(st.st_mtimespec), btime: Self.seconds(st.st_birthtimespec),
            kind: kind, isHidden: name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0,
            isCloudOnly: (st.st_flags & UInt32(SF_DATALESS)) != 0,
            contentEligible: rules.isContentEligible(path: path),
            isSymlink: (st.st_mode & S_IFMT) == S_IFLNK
        )
        if FinderTags.isRead(for: meta) { meta.tags = FinderTags.read(path: path) }
        return meta
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

    /// Lowercased extension without the dot; empty for dotfiles like `.zshrc`.
    static func extensionOf(_ name: String) -> String {
        guard let dot = name.utf8.lastIndex(of: UInt8(ascii: ".")), dot != name.utf8.startIndex else { return "" }
        let ext = name[name.utf8.index(after: dot)...]
        guard !ext.isEmpty, ext.utf8.count <= 16 else { return "" }
        return ext.lowercased()
    }
}
