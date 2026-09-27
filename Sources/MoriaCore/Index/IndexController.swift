import Darwin
import Foundation

/// Snapshot of indexing activity, published to the UI and CLI.
public struct IndexProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case idle, scanning, updating, extracting, embedding
    }

    public var phase: Phase = .idle
    public var scannedEntries = 0
    public var extractedFiles = 0
    public var embeddedFiles = 0
    /// Files still waiting for content extraction (refreshed per batch).
    public var remainingFiles = 0
    /// Folders that could not be listed: TCC-protected without Full Disk Access, or cloud-only.
    public var unreadableDirectories = 0
    public var lastScanDate: Date?
    public var lastError: String?
}

/// Owns the index lifecycle: full scans, FSEvents-driven incremental updates, content
/// extraction and embedding. All work is serialized through one background loop.
public actor IndexController {
    public let database: IndexDatabase
    public nonisolated let progress: AsyncStream<IndexProgress>
    private let progressContinuation: AsyncStream<IndexProgress>.Continuation

    public private(set) var settings: MoriaSettings
    private var state = IndexProgress()
    private var watcher: FileWatcher?
    private var queuedChanges: [FileChange] = []
    private var queuedEventID: UInt64?
    private var fullScanRequested = false
    private var wake: AsyncStream<Void>.Continuation?
    private var loop: Task<Void, Never>?
    private let ocrLimiter = AsyncLimiter(limit: 2)
    private let embedder: Embedder

    private enum MetaKey {
        static let generation = "scan.generation"
        static let lastScan = "scan.date"
        static let eventID = "fsevents.lastID"
        static let eventDatabase = "fsevents.uuid"
    }

    public init(database: IndexDatabase) throws {
        self.database = database
        settings = try database.loadSettings()
        embedder = Embedder()
        (progress, progressContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        if let date = try database.meta(MetaKey.lastScan).flatMap(Double.init) {
            state.lastScanDate = Date(timeIntervalSince1970: date)
        }
    }

    // MARK: - Lifecycle

    /// Starts watching the roots and processing work in the background.
    ///
    /// Resumes from the last FSEvents ID when possible; otherwise schedules a full scan.
    public func start() throws {
        guard loop == nil else { return }
        let resumeID = try resumableEventID()
        if resumeID == nil { fullScanRequested = true }
        try startWatcher(since: resumeID)
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        loop = Task(priority: .utility) { [weak self] in
            for await _ in stream {
                await self?.drainWork()
            }
        }
        continuation.yield()
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        loop?.cancel()
        loop = nil
        wake?.finish()
        wake = nil
    }

    public func requestFullScan() {
        fullScanRequested = true
        wake?.yield()
    }

    /// Runs a scan (full if never scanned or `full`), then extracts and embeds until nothing is
    /// pending. Used by the CLI; the app uses `start()`.
    public func indexNow(full: Bool) async throws {
        if try full || resumableEventID() == nil {
            try await fullScan()
        }
        while try await extractBatch() {}
        if settings.semanticSearchEnabled {
            while try await embedBatch() {}
        }
        publish(phase: .idle)
    }

    /// Crawls metadata only (no content extraction).
    public func scanOnly() async throws {
        try await fullScan()
        publish(phase: .idle)
    }

    /// Saves settings and schedules whatever work the change requires.
    public func updateSettings(_ new: MoriaSettings) throws {
        var new = new
        // FSEvents reports resolved paths (/private/var/..., not /var/...).
        new.roots = new.roots.map { ($0 as NSString).resolvingSymlinksInPath }
        let old = settings
        settings = new
        try database.saveSettings(new)
        let crawlChanged = old.roots != new.roots || old.excludedPaths != new.excludedPaths
            || old.excludedNames != new.excludedNames || old.includeHidden != new.includeHidden
            || old.descendIntoPackages != new.descendIntoPackages
        let extractionChanged = old.maxContentKilobytes != new.maxContentKilobytes
            || old.maxFileMegabytes != new.maxFileMegabytes
            || old.ocrImages != new.ocrImages || old.ocrScannedPDFs != new.ocrScannedPDFs
        if crawlChanged {
            fullScanRequested = true
            if watcher != nil { try startWatcher(since: nil) }
        }
        if extractionChanged {
            try database.requeueContent()
        }
        if old.semanticSearchEnabled, !new.semanticSearchEnabled {
            try database.clearEmbeddings()
        }
        wake?.yield()
    }

    public func currentProgress() -> IndexProgress {
        state
    }

    // MARK: - Work loop

    private func drainWork() async {
        while !Task.isCancelled {
            do {
                if fullScanRequested {
                    fullScanRequested = false
                    try await fullScan()
                } else if !queuedChanges.isEmpty {
                    try applyQueuedChanges()
                } else if try await extractBatch() {
                    continue
                } else if settings.semanticSearchEnabled, try await embedBatch() {
                    continue
                } else {
                    break
                }
            } catch is CancellationError {
                return
            } catch {
                state.lastError = String(describing: error)
                break
            }
        }
        publish(phase: .idle)
    }

    private func receive(_ event: WatchEvent) {
        switch event {
        case let .changes(changes, lastEventID):
            queuedChanges.append(contentsOf: changes)
            queuedEventID = max(queuedEventID ?? 0, lastEventID)
        case let .fullRescanNeeded(lastEventID):
            fullScanRequested = true
            queuedEventID = max(queuedEventID ?? 0, lastEventID)
        }
        wake?.yield()
    }

    private func startWatcher(since eventID: UInt64?) throws {
        watcher?.stop()
        let watcher = FileWatcher { [weak self] event in
            Task { await self?.receive(event) }
        }
        let exclusions = settings.excludedPaths.filter { path in
            settings.roots.contains { path.hasPrefix($0 + "/") }
        }
        try watcher.start(paths: settings.roots, excluding: exclusions, since: eventID)
        self.watcher = watcher
    }

    /// The stored FSEvents ID if it is still valid for this volume, else nil (full scan needed).
    private func resumableEventID() throws -> UInt64? {
        guard try database.meta(MetaKey.generation) != nil,
              let stored = try database.meta(MetaKey.eventID).flatMap(UInt64.init),
              let root = settings.roots.first,
              try database.meta(MetaKey.eventDatabase) == FileWatcher.eventDatabaseUUID(forPath: root)
        else { return nil }
        return stored
    }

    private func nextGeneration() throws -> Int {
        let next = (try database.meta(MetaKey.generation).flatMap(Int.init) ?? 0) + 1
        try database.setMeta(MetaKey.generation, String(next))
        return next
    }

    private var currentGeneration: Int {
        get throws { try database.meta(MetaKey.generation).flatMap(Int.init) ?? 0 }
    }

    private var maxFileBytes: Int64 {
        Int64(settings.maxFileMegabytes) * 1024 * 1024
    }

    // MARK: - Scanning

    private func fullScan() async throws {
        state.scannedEntries = 0
        state.unreadableDirectories = 0
        publish(phase: .scanning)
        let eventID = FileWatcher.currentEventID
        let generation = try nextGeneration()
        var crawler = Crawler(rules: CrawlRules(settings: settings))
        for root in settings.roots {
            try crawler.crawl(root: root) { batch in
                try Task.checkCancellation()
                try database.upsert(batch, generation: generation, maxFileBytes: maxFileBytes)
                state.scannedEntries += batch.count
                if state.scannedEntries % 20000 < batch.count { publish(phase: .scanning) }
            }
        }
        state.unreadableDirectories = crawler.unreadableDirectories
        _ = try database.pruneUnseen(before: generation)
        let now = Date()
        state.lastScanDate = now
        try database.setMeta(MetaKey.lastScan, String(now.timeIntervalSince1970))
        try persistEventID(max(eventID, queuedEventID ?? 0))
        publish(phase: .scanning)
    }

    private func persistEventID(_ eventID: UInt64) throws {
        try database.setMeta(MetaKey.eventID, String(eventID))
        if let root = settings.roots.first {
            try database.setMeta(MetaKey.eventDatabase, FileWatcher.eventDatabaseUUID(forPath: root))
        }
    }

    private func applyQueuedChanges() throws {
        let changes = queuedChanges
        let eventID = queuedEventID
        queuedChanges.removeAll()
        publish(phase: .updating)
        try apply(changes)
        if let eventID { try persistEventID(eventID) }
    }

    /// Re-stats changed paths: upserts what exists, deletes what's gone, re-crawls subtrees
    /// flagged by FSEvents. Idempotent, so duplicated or reordered events are harmless.
    func apply(_ changes: [FileChange]) throws {
        let rules = CrawlRules(settings: settings)
        var crawler = Crawler(rules: rules)
        var merged: [String: Bool] = [:]
        for change in changes { merged[change.path, default: false] = merged[change.path, default: false] || change.rescanSubtree }
        let generation = try currentGeneration
        var metas: [FileMeta] = []
        for (path, rescan) in merged.sorted(by: { $0.key < $1.key }) {
            guard isUnderRoots(path), !rules.isExcludedAnywhere(path: path),
                  !isInsideOpaquePackage(path, crawler: &crawler) else { continue }
            guard let meta = crawler.meta(forPath: path) else {
                try database.deleteSubtree(path)
                continue
            }
            if rescan, meta.isDir, !crawler.isOpaquePackage(path: path) {
                let subtreeGeneration = try nextGeneration()
                try crawler.crawl(root: path) { batch in
                    try database.upsert(batch, generation: subtreeGeneration, maxFileBytes: maxFileBytes)
                }
                try database.pruneUnseen(under: path, before: subtreeGeneration)
            } else {
                metas.append(meta)
            }
        }
        if !metas.isEmpty {
            try database.upsert(metas, generation: generation, maxFileBytes: maxFileBytes)
        }
    }

    private func isUnderRoots(_ path: String) -> Bool {
        settings.roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    private func isInsideOpaquePackage(_ path: String, crawler: inout Crawler) -> Bool {
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor.count > 1, isUnderRoots(ancestor) {
            if crawler.isOpaquePackage(path: ancestor) { return true }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return false
    }

    // MARK: - Extraction

    private enum Outcome: Sendable {
        case result(ExtractionResult)
        /// The file changed or vanished since it was listed; re-stat it.
        case changed(String)
    }

    /// Extracts one batch of pending files. Returns false when nothing is pending.
    private func extractBatch() async throws -> Bool {
        let batch = try database.pendingFiles(limit: 128)
        guard !batch.isEmpty else { return false }
        state.remainingFiles = try database.pendingCount()
        publish(phase: .extracting)

        let extractor = ContentExtractor(settings: settings, ocrLimiter: ocrLimiter)
        let maxFileBytes = maxFileBytes
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        var results: [ExtractionResult] = []
        var changed: [FileChange] = []
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var iterator = batch.makeIterator()
            for _ in 0..<width {
                guard let file = iterator.next() else { break }
                group.addTask { try await Self.process(file, extractor: extractor, maxFileBytes: maxFileBytes) }
            }
            while let outcome = try await group.next() {
                switch outcome {
                case let .result(result): results.append(result)
                case let .changed(path): changed.append(FileChange(path: path, rescanSubtree: false))
                }
                if let file = iterator.next() {
                    group.addTask { try await Self.process(file, extractor: extractor, maxFileBytes: maxFileBytes) }
                }
            }
        }
        try database.store(results)
        try apply(changed)
        state.extractedFiles += results.count
        state.remainingFiles = max(0, state.remainingFiles - results.count)
        publish(phase: .extracting)
        return true
    }

    private static func process(_ file: PendingFile, extractor: ContentExtractor, maxFileBytes: Int64) async throws -> Outcome {
        var st = stat()
        guard lstat(file.path, &st) == 0,
              Crawler.seconds(st.st_mtimespec) == file.mtime, Int64(st.st_size) == file.size
        else { return .changed(file.path) }
        guard file.size <= maxFileBytes else {
            return .result(ExtractionResult(id: file.id, mtime: file.mtime, state: .none, text: nil))
        }
        do {
            let text = try await extractor.extract(path: file.path, ext: file.ext, kind: file.kind, size: file.size)
            return .result(ExtractionResult(id: file.id, mtime: file.mtime, state: text == nil ? .none : .indexed, text: text))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .result(ExtractionResult(id: file.id, mtime: file.mtime, state: .failed, text: nil))
        }
    }

    // MARK: - Embeddings

    /// Embeds one batch of indexed files. Returns false when nothing is left.
    private func embedBatch() async throws -> Bool {
        let batch = try database.filesNeedingEmbedding(limit: 64)
        guard !batch.isEmpty else { return false }
        publish(phase: .embedding)
        var vectors: [(id: Int64, chunks: [[Float]])] = []
        for (id, text) in batch {
            try Task.checkCancellation()
            vectors.append((id, try await embedder.embedDocument(text)))
        }
        try database.storeEmbeddings(vectors)
        state.embeddedFiles += batch.count
        publish(phase: .embedding)
        return true
    }

    // MARK: - Progress

    private func publish(phase: IndexProgress.Phase) {
        state.phase = phase
        progressContinuation.yield(state)
    }
}
