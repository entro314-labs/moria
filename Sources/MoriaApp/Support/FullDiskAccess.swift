import AppKit
import Darwin

/// Full Disk Access status. Without it macOS hides Mail, Messages, Safari data and other app
/// containers, and prompts separately for Desktop, Documents and Downloads.
enum FullDiskAccess {
    /// The system TCC database can only be opened by processes with Full Disk Access.
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
