import Darwin
import Foundation

/// Where a location lived when it was last scanned: the mount point of its volume, and the
/// FSEvents database of that volume (whose event IDs the resume point refers to).
struct VolumeRecord: Codable, Sendable, Equatable {
    var mountPoint: String
    var eventDatabase: String?
}

/// Locations on external drives and network shares that aren't connected.
///
/// A location is offline when the volume it was last scanned on isn't mounted any more. Its
/// entries stay in the index (marked offline in results) instead of being deleted, and come
/// back up to date when the volume returns. A location whose volume is mounted but which no
/// longer exists is simply gone.
enum Volumes {
    /// The mount point of the volume holding `path`, or nil when `path` doesn't exist.
    static func mountPoint(of path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    static func isMounted(_ mountPoint: String) -> Bool {
        Self.mountPoint(of: mountPoint) == mountPoint
    }

    /// What to remember about `root` after scanning it.
    static func record(for root: String) -> VolumeRecord? {
        guard let mountPoint = mountPoint(of: root) else { return nil }
        return VolumeRecord(mountPoint: mountPoint, eventDatabase: FileWatcher.eventDatabaseUUID(forPath: root))
    }

    /// Mount points (other than the startup volume's) of recorded locations that aren't
    /// mounted now.
    static func offlineMountPoints(_ records: [String: VolumeRecord]) -> Set<String> {
        Set(records.values.map(\.mountPoint).filter { $0 != "/" && !isMounted($0) })
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }
}

extension IndexDatabase {
    /// Under `fsevents.` so a rebuild forgets it along with the resume point.
    private static let volumesKey = "fsevents.volumes"

    /// The volume each location was on at its last scan, keyed by location.
    func volumeRecords() throws -> [String: VolumeRecord] {
        guard let json = try meta(Self.volumesKey) else { return [:] }
        return try JSONDecoder().decode([String: VolumeRecord].self, from: Data(json.utf8))
    }

    func setVolumeRecords(_ records: [String: VolumeRecord]) throws {
        try setMeta(Self.volumesKey, String(decoding: try JSONEncoder().encode(records), as: UTF8.self))
    }

    /// Mount points of recorded locations whose volume isn't connected.
    public func offlineMountPoints() throws -> Set<String> {
        Volumes.offlineMountPoints(try volumeRecords())
    }
}
