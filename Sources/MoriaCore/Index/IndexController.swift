import Darwin
import Foundation

/// Snapshot of indexing activity, published to the UI and CLI.
public struct IndexProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case idle, scanning, updating, extracting, recognizingText, readingDetails, embedding
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
    /// Indexing is paused by the user; file changes are still collected and applied on resume.
    public var isPaused = false

    public init() {}
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
    /// Erase the index before the next full scan (see `rebuild()`).
    private var rebuildRequested = false
    /// `markNotEmbeddable` ran in this session (it only needs to once).
    private var embedBacklogCleaned = false
    /// How often each file changed between being listed and being read, this session.
    private var changedWhileReading: [Int64: Int] = [:]
    /// A file that changed this many times while waiting to be read is given up on until it
    /// next changes: it is being written continuously (a log, or the index database itself
    /// inside an indexed folder), and would otherwise be read again forever.
    static let maxChangesWhileReading = 3
    private var wake: AsyncStream<Void>.Continuation?
    private var loop: Task<Void, Never>?
    private let ocrLimiter = AsyncLimiter(limit: 2)
    private let embedder: Embedder

    private enum MetaKey {
        static let generation = "scan.generation"
        static let lastScan = "scan.date"
        static let eventID = "fsevents.lastID"
        /// Before per-location volume records: the FSEvents database of the first location.
        static let legacyEventDatabase = "fsevents.uuid"
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
        if resumeID == nil {
            fullScanRequested = true
        } else {
            // A drive may have been changed on another Mac while it was away, which this Mac's
            // event history doesn't show: connected locations on other volumes are crawled again.
            let records = try database.volumeRecords()
            for root in settings.roots {
                guard let record = records[root], record.mountPoint != "/", Volumes.isMounted(record.mountPoint) else { continue }
                queuedChanges.append(FileChange(path: root, rescanSubtree: true))
            }
        }
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

    /// Pauses or resumes background work. The current batch finishes first.
    public func setPaused(_ paused: Bool) {
        state.isPaused = paused
        publish(phase: state.phase)
        if !paused { wake?.yield() }
    }

    /// Deletes the whole index and rebuilds it from a full scan, resuming indexing if it was
    /// paused (asking for a rebuild means now).
    ///
    /// The erase happens when the next full scan starts, never while one is running: a scan in
    /// progress would keep writing under folder ids the erase deleted.
    public func rebuild() {
        rebuildRequested = true
        fullScanRequested = true
        state.isPaused = false
        publish(phase: state.phase)
        wake?.yield()
    }

    /// Runs a scan (full if never scanned or `full`), then extracts and embeds until nothing is
    /// pending. Used by the CLI; the app uses `start()`.
    public func indexNow(full: Bool) async throws {
        if try full || fullScanRequested || resumableEventID() == nil {
            fullScanRequested = false
            try await fullScan()
        }
        while try await extractBatch() {}
        try database.backfillMediaIfNeeded()
        try database.backfillLabelsIfNeeded()
        while try await mediaBatch() {}
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
        // FSEvents reports canonical paths (/private/tmp/..., not /tmp/...). NSString and URL
        // symlink resolution strip "/private", so events under such roots would be dropped.
        new.roots = new.roots.map { Volumes.canonicalPath($0) ?? $0 }
        let old = settings
        if Self.needsFullScan(from: old, to: new) {
            // Forget the resume point until that scan completes, so any controller (the app at
            // its next launch, after a change made by the CLI) scans instead of resuming. In the
            // same transaction as the settings: new crawl rules with an old resume point would
            // miss what the rules now include until the next full scan.
            try database.setMeta([("settings", try IndexDatabase.json(new)), (MetaKey.eventID, nil)])
        } else {
            try database.saveSettings(new)
        }
        try adopt(new)
        let limitsChanged = old.maxContentKilobytes != new.maxContentKilobytes
            || old.maxFileMegabytes != new.maxFileMegabytes
        var requeueKinds: Set<FileKind> = []
        if old.ocrImages != new.ocrImages { requeueKinds.insert(.image) }
        if old.ocrScannedPDFs != new.ocrScannedPDFs { requeueKinds.insert(.pdf) }
        // Scope changes are applied by the full scan, which re-marks excluded files.
        if limitsChanged {
            try database.requeueContent()
        } else if !requeueKinds.isEmpty {
            try database.requeueContent(kinds: requeueKinds)
        }
        if old.imageLabels != new.imageLabels {
            try new.imageLabels ? database.requeueLabels() : database.clearLabels()
        }
        if old.semanticSearchEnabled, !new.semanticSearchEnabled {
            try database.clearEmbeddings()
        }
        wake?.yield()
    }

    /// Adopts settings another process (`moria config`) saved, so the running app neither
    /// ignores them nor later overwrites them. That process already made the database-side
    /// changes (resume point, requeued files, cleared embeddings).
    @discardableResult
    public func reloadSettings() throws -> MoriaSettings {
        let stored = try database.loadSettings()
        guard stored != settings else { return settings }
        try adopt(stored)
        wake?.yield()
        return settings
    }

    /// The in-memory side of a settings change: a full scan, with a restarted watcher, when
    /// what is crawled or read changed.
    private func adopt(_ new: MoriaSettings) throws {
        let old = settings
        settings = new
        if Self.needsFullScan(from: old, to: new) {
            fullScanRequested = true
            if watcher != nil { try startWatcher(since: nil) }
        }
    }

    /// Crawl rules or content scope changed; the full scan re-marks excluded files.
    private static func needsFullScan(from old: MoriaSettings, to new: MoriaSettings) -> Bool {
        old.roots != new.roots || old.excludedPaths != new.excludedPaths
            || old.excludedNames != new.excludedNames || old.includeHidden != new.includeHidden
            || old.descendIntoPackages != new.descendIntoPackages
            || old.contentExcludedPaths != new.contentExcludedPaths
            || old.contentExcludedNames != new.contentExcludedNames
            || old.extractHiddenContent != new.extractHiddenContent
    }

    public func currentProgress() -> IndexProgress {
        state
    }

    // MARK: - Work loop

    private func drainWork() async {
        do {
            try reloadSettings()
            try database.backfillMediaIfNeeded()
            try database.backfillLabelsIfNeeded()
        } catch {
            state.lastError = String(describing: error)
        }
        while !Task.isCancelled, !state.isPaused {
            do {
                if fullScanRequested {
                    fullScanRequested = false
                    do {
                        try await fullScan()
                    } catch {
                        // Retried at the next wake-up; the error stays shown until a pass succeeds.
                        if !(error is CancellationError) { fullScanRequested = true }
                        throw error
                    }
                } else if !queuedChanges.isEmpty {
                    try applyQueuedChanges()
                } else if try await extractBatch() {
                    continue
                } else if try await mediaBatch() {
                    continue
                } else if settings.semanticSearchEnabled, try await embedBatch() {
                    continue
                } else {
                    // Everything is done: an earlier error no longer applies.
                    state.lastError = nil
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

    /// The stored FSEvents ID if it is still valid, else nil (full scan needed): every connected
    /// location must have been scanned and still be on the FSEvents database the ID refers to.
    /// Locations whose drive is away are checked when it returns (see `FileWatcher`).
    private func resumableEventID() throws -> UInt64? {
        guard try database.meta(MetaKey.generation) != nil,
              let stored = try database.meta(MetaKey.eventID).flatMap(UInt64.init) else { return nil }
        let records = try database.volumeRecords()
        let offline = Volumes.offlineMountPoints(records)
        for root in settings.roots {
            guard let record = records[root] else {
                // Never scanned while it existed: nothing to resume there, unless it exists now.
                if Volumes.mountPoint(of: root) == nil { continue }
                return nil
            }
            if offline.contains(record.mountPoint) { continue }
            guard record.eventDatabase == FileWatcher.eventDatabaseUUID(forPath: root) else { return nil }
        }
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
        if rebuildRequested {
            rebuildRequested = false
            try database.eraseIndex()
            state.extractedFiles = 0
            state.embeddedFiles = 0
        }
        state.scannedEntries = 0
        state.unreadableDirectories = 0
        publish(phase: .scanning)
        let eventID = FileWatcher.currentEventID
        let generation = try nextGeneration()
        var writer = MetadataWriter(generation: generation, maxFileBytes: maxFileBytes)
        // Locations on drives that aren't connected keep their entries until the drive returns.
        let offline = try database.offlineMountPoints()
        let roots = settings.roots.filter { root in !offline.contains { Volumes.isInside(root, $0) } }
        let crawl = PipelinedCrawl(rules: CrawlRules(settings: settings), roots: roots)
        do {
            for try await batch in crawl.batches {
                try Task.checkCancellation()
                try writer.write(batch, to: database)
                state.scannedEntries += batch.count
                crawl.batchConsumed()
                if state.scannedEntries % 20000 < batch.count { publish(phase: .scanning) }
            }
        } catch {
            crawl.cancel()
            throw error
        }
        // Cancellation ends the stream without an error. A partial crawl must not prune, and
        // the crawl thread must be released.
        if Task.isCancelled {
            crawl.cancel()
            throw CancellationError()
        }
        state.unreadableDirectories = crawl.unreadableDirectories
        try database.pruneUnseen(before: generation, keeping: offline)
        let now = Date()
        state.lastScanDate = now
        try database.setMeta(MetaKey.lastScan, String(now.timeIntervalSince1970))
        // Not past `queuedEventID`: changes that arrived during the scan persist their own ID once
        // applied, so quitting before then replays them.
        try persistEventID(eventID)
        publish(phase: .scanning)
    }

    private func persistEventID(_ eventID: UInt64) throws {
        try database.setMeta(MetaKey.eventID, String(eventID))
        try recordVolumes()
    }

    /// Remembers the volume of every location that is there now. An offline location keeps
    /// what was recorded, so it is still recognized as offline: its folder may be left behind,
    /// empty, on the startup volume.
    private func recordVolumes() throws {
        let old = try database.volumeRecords()
        let offline = Volumes.offlineMountPoints(old)
        var records: [String: VolumeRecord] = [:]
        for root in settings.roots {
            if let record = old[root], offline.contains(record.mountPoint) {
                records[root] = record
            } else {
                records[root] = Volumes.record(for: root) ?? old[root]
            }
        }
        if records != old { try database.setVolumeRecords(records) }
        try database.setMeta(MetaKey.legacyEventDatabase, nil)
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
    /// Also used by the app after it changes files itself (Move to Trash), since the event
    /// stream ignores this process's own changes.
    public func apply(_ changes: [FileChange]) throws {
        let rules = CrawlRules(settings: settings)
        var crawler = Crawler(rules: rules)
        var merged: [String: Bool] = [:]
        for change in changes { merged[change.path, default: false] = merged[change.path, default: false] || change.rescanSubtree }
        var writer = try MetadataWriter(generation: currentGeneration, maxFileBytes: maxFileBytes)
        var metas: [FileMeta] = []
        // A drive being ejected reports its files as gone; they stay, marked offline.
        let offline = try database.offlineMountPoints()
        for (path, rescan) in merged.sorted(by: { $0.key < $1.key }) {
            if offline.contains(where: { Volumes.isInside(path, $0) }) { continue }
            guard let root = root(containing: path), !rules.isExcludedAnywhere(path: path, below: root),
                  !isInsideOpaquePackage(path, below: root, crawler: &crawler) else { continue }
            guard let meta = crawler.meta(forPath: path) else {
                try database.deleteSubtree(path)
                continue
            }
            // A location is crawled even when it is a package (a photo library added on purpose).
            if rescan, meta.isDir, path == root || !crawler.isOpaquePackage(path: path) {
                let subtreeGeneration = try nextGeneration()
                var subtreeWriter = MetadataWriter(generation: subtreeGeneration, maxFileBytes: maxFileBytes)
                try crawler.crawl(root: path) { batch in
                    try subtreeWriter.write(batch, to: database)
                }
                try database.pruneUnseen(under: path, before: subtreeGeneration)
            } else {
                metas.append(meta)
            }
        }
        if !metas.isEmpty {
            try writer.write(metas, to: database)
        }
    }

    /// The location that contains `path`, or is it.
    private func root(containing path: String) -> String? {
        settings.roots.first { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    /// Whether a folder between `root` and `path` is a package indexed as one item. The root
    /// itself doesn't count: the crawl always descends into a location.
    private func isInsideOpaquePackage(_ path: String, below root: String, crawler: inout Crawler) -> Bool {
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor.count > root.count {
            if crawler.isOpaquePackage(path: ancestor) { return true }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        return false
    }

    // MARK: - Extraction

    private enum Outcome: Sendable {
        case result(ExtractionResult)
        /// The file changed or vanished since it was listed; re-stat it.
        case changed(PendingFile)
    }

    /// Extracts one batch of pending files: text formats first, then images (OCR, ~10x
    /// slower per file). Returns false when nothing is pending.
    private func extractBatch() async throws -> Bool {
        var phase = IndexProgress.Phase.extracting
        // Files on drives that aren't connected wait for them.
        let offline = try database.offlineMountPoints()
        var batch = try database.pendingFiles(limit: 128, images: false, outside: offline)
        if batch.isEmpty {
            phase = .recognizingText
            batch = try database.pendingFiles(limit: 32, images: true, outside: offline)
        }
        guard !batch.isEmpty else { return false }
        state.remainingFiles = try database.pendingCount()
        publish(phase: phase)

        let extractor = ContentExtractor(settings: settings, ocrLimiter: ocrLimiter)
        let maxFileBytes = maxFileBytes
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        var results: [ExtractionResult] = []
        var changed: [PendingFile] = []
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var iterator = batch.makeIterator()
            for _ in 0..<width {
                guard let file = iterator.next() else { break }
                group.addTask { try await Self.process(file, extractor: extractor, maxFileBytes: maxFileBytes) }
            }
            while let outcome = try await group.next() {
                switch outcome {
                case let .result(result): results.append(result)
                case let .changed(file): changed.append(file)
                }
                if let file = iterator.next() {
                    group.addTask { try await Self.process(file, extractor: extractor, maxFileBytes: maxFileBytes) }
                }
            }
        }
        try database.store(results)
        try apply(changed.map { FileChange(path: $0.path, rescanSubtree: false) })
        var unstable: [Int64] = []
        for file in changed {
            changedWhileReading[file.id, default: 0] += 1
            if changedWhileReading[file.id]! >= Self.maxChangesWhileReading { unstable.append(file.id) }
        }
        // Marked unreadable at whatever state it is in now; its next change (seen by the watcher
        // or a scan) queues it again, and one more change gives up on it again.
        try database.markUnreadable(unstable)
        state.extractedFiles += results.count
        state.remainingFiles = max(0, state.remainingFiles - results.count)
        publish(phase: phase)
        return true
    }

    private static func process(_ file: PendingFile, extractor: ContentExtractor, maxFileBytes: Int64) async throws -> Outcome {
        var st = stat()
        guard lstat(file.path, &st) == 0,
              Crawler.seconds(st.st_mtimespec) == file.mtime, Int64(st.st_size) == file.size
        else { return .changed(file) }
        guard file.size <= maxFileBytes else {
            return .result(ExtractionResult(id: file.id, mtime: file.mtime, state: .none, text: nil, storeText: false))
        }
        let storeText = ContentExtractor.keepsExtractedText(file.kind)
        do {
            let text = try await extractor.extract(path: file.path, ext: file.ext, kind: file.kind, size: file.size)
            return .result(ExtractionResult(
                id: file.id, mtime: file.mtime, state: text == nil ? .none : .indexed, text: text, storeText: storeText
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .result(ExtractionResult(id: file.id, mtime: file.mtime, state: .failed, text: nil, storeText: false))
        }
    }

    // MARK: - Media details

    /// Reads the details (date taken, duration, author) of one batch of files. Returns false
    /// when nothing is pending.
    private func mediaBatch() async throws -> Bool {
        let batch = try database.pendingMedia(limit: 64, outside: try database.offlineMountPoints())
        guard !batch.isEmpty else { return false }
        publish(phase: .readingDetails)
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        let labels = settings.imageLabels
        let results = try await withThrowingTaskGroup(of: (id: Int64, mtime: Double, details: MediaDetails).self) { group in
            var iterator = batch.makeIterator()
            func addNext() {
                guard let file = iterator.next() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    return (file.id, file.mtime, await MediaReader.read(file, labels: labels))
                }
            }
            for _ in 0..<width { addNext() }
            var results: [(id: Int64, mtime: Double, details: MediaDetails)] = []
            while let result = try await group.next() {
                results.append(result)
                addNext()
            }
            return results
        }
        try database.storeMedia(results)
        return true
    }

    // MARK: - Embeddings

    /// Embeds one batch of indexed files. Returns false when nothing is left.
    private func embedBatch() async throws -> Bool {
        if !embedBacklogCleaned {
            try database.markNotEmbeddable()
            embedBacklogCleaned = true
        }
        let batch = try database.filesNeedingEmbedding(limit: 64, outside: try database.offlineMountPoints())
        guard !batch.isEmpty else { return false }
        publish(phase: .embedding)
        let extractor = ContentExtractor(settings: settings, ocrLimiter: ocrLimiter)
        var vectors: [(id: Int64, chunks: [(chunk: Int, vector: [Float])])] = []
        for file in batch {
            try Task.checkCancellation()
            // Documents keep their extracted text; plain text is re-read from the file.
            let text = try ContentExtractor.keepsExtractedText(file.kind)
                ? database.storedText(fileID: file.id)
                : extractor.readText(URL(fileURLWithPath: file.path))
            let chunks = if let text { try await embedder.embedDocument(text) } else { [(chunk: Int, vector: [Float])]() }
            vectors.append((file.id, chunks))
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
