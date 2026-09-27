import CoreServices
import Foundation

/// One path reported by FSEvents.
public struct FileChange: Sendable, Equatable {
    public var path: String
    /// The whole subtree must be re-crawled: a folder was created or moved in (FSEvents reports
    /// only the folder, not its children), or events below it were coalesced.
    public var rescanSubtree: Bool
}

/// A batch delivered by `FileWatcher`.
public enum WatchEvent: Sendable {
    case changes([FileChange], lastEventID: UInt64)
    /// Events were dropped or event IDs wrapped; the index must be rebuilt from a full scan.
    case fullRescanNeeded(lastEventID: UInt64)
}

/// FSEvents stream over the index roots, with file-level events.
///
/// Started with `since:` set to the last persisted event ID, FSEvents replays everything that
/// changed while Moria was not running, so no full scan is needed at launch.
public final class FileWatcher: @unchecked Sendable {
    // Mutated only from `start()`/`stop()`, which callers serialize (IndexController actor).
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.entro314labs.moria.fsevents", qos: .utility)
    private let handler: @Sendable (WatchEvent) -> Void

    public init(handler: @escaping @Sendable (WatchEvent) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Current FSEvents ID; persist it as the resume point after a full scan.
    public static var currentEventID: UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// UUID of the FSEvents database for the volume holding `path`. When it changes, stored
    /// event IDs are meaningless and a full scan is needed.
    public static func eventDatabaseUUID(forPath path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let uuid = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public func start(paths: [String], excluding exclusions: [String], since eventID: UInt64?) throws {
        stop()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, paths as CFArray,
            eventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags
        ) else {
            throw WatcherError.createFailed
        }
        // FSEvents accepts at most 8 exclusion paths; the rest are filtered by the index rules.
        FSEventStreamSetExclusionPaths(stream, Array(exclusions.prefix(8)) as CFArray)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw WatcherError.startFailed
        }
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    public enum WatcherError: Error {
        case createFailed, startFailed
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let pathArray = unsafeBitCast(paths, to: NSArray.self)
        var changes: [FileChange] = []
        var lastID: UInt64 = 0
        var needsFullRescan = false
        for index in 0..<count {
            guard let path = pathArray[index] as? String else { continue }
            let flag = Int(flags[index])
            lastID = max(lastID, ids[index])
            func has(_ value: Int) -> Bool { flag & value != 0 }

            if has(kFSEventStreamEventFlagHistoryDone) { continue }
            if has(kFSEventStreamEventFlagEventIdsWrapped) || has(kFSEventStreamEventFlagRootChanged) {
                needsFullRescan = true
                continue
            }
            let coalesced = has(kFSEventStreamEventFlagMustScanSubDirs)
                || has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
            let movedOrCreatedDirectory = has(kFSEventStreamEventFlagItemIsDir)
                && (has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRenamed))
            changes.append(FileChange(path: path, rescanSubtree: coalesced || movedOrCreatedDirectory))
        }
        if needsFullRescan {
            watcher.handler(.fullRescanNeeded(lastEventID: lastID))
        } else if !changes.isEmpty {
            watcher.handler(.changes(changes, lastEventID: lastID))
        }
    }
}
