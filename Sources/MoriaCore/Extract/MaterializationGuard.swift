import Darwin

/// Prevents this process from downloading cloud-only (dataless) files.
///
/// Reading a OneDrive/Dropbox/iCloud placeholder normally makes the File Provider download it.
/// With this policy, reads fail with `EDEADLK` instead and directory listings of cloud-only
/// folders fail rather than enumerating the remote. Applies to every thread in the process.
public enum MaterializationGuard {
    /// Call once at process start, before any indexing.
    @discardableResult
    public static func disableDownloads() -> Bool {
        setiopolicy_np(
            IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        ) == 0
    }
}
