import Foundation
import Synchronization

/// Runs a crawl on its own thread so filesystem traversal overlaps with database writes.
///
/// At most `maxQueuedBatches` batches wait for the consumer; the crawl thread blocks when the
/// queue is full, bounding memory on trees with millions of entries.
final class PipelinedCrawl: Sendable {
    let batches: AsyncThrowingStream<[FileMeta], any Error>
    private let slots: DispatchSemaphore
    private let cancelled = Atomic<Bool>(false)
    private let unreadable = Atomic<Int>(0)

    static let maxQueuedBatches = 8

    init(rules: CrawlRules, roots: [String]) {
        let (stream, continuation) = AsyncThrowingStream<[FileMeta], any Error>.makeStream()
        batches = stream
        let slots = DispatchSemaphore(value: Self.maxQueuedBatches)
        self.slots = slots
        let thread = Thread { [self] in
            var crawler = Crawler(rules: rules)
            do {
                for root in roots {
                    try crawler.crawl(root: root) { batch in
                        slots.wait()
                        if self.cancelled.load(ordering: .relaxed) { throw CancellationError() }
                        continuation.yield(batch)
                    }
                }
                self.unreadable.store(crawler.unreadableDirectories, ordering: .relaxed)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        thread.qualityOfService = .utility
        thread.name = "Moria crawl"
        thread.start()
    }

    /// Call after each batch is written, freeing a queue slot.
    func batchConsumed() {
        slots.signal()
    }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        // Wake the crawl thread if it is waiting for a slot.
        for _ in 0..<Self.maxQueuedBatches { slots.signal() }
    }

    /// Valid after `batches` finishes.
    var unreadableDirectories: Int {
        unreadable.load(ordering: .relaxed)
    }
}
