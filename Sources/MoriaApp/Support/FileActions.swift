import AppKit
import MoriaCore
import UniformTypeIdentifiers

/// Finder-style actions on search results.
enum FileActions {
    static func open(_ urls: [URL]) {
        for url in urls { NSWorkspace.shared.open(url) }
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyPaths(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    static func copyFiles(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    static func openTerminal(at url: URL) {
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// File icons by type, without touching the file (which could download a cloud placeholder).
@MainActor
enum IconCache {
    private static var byType: [String: NSImage] = [:]
    private static var byApp: [String: NSImage] = [:]

    static func icon(for result: SearchResult) -> NSImage {
        if result.kind == .application, result.isDirectory, !result.isCloudOnly {
            if let cached = byApp[result.path] { return cached }
            let icon = NSWorkspace.shared.icon(forFile: result.path)
            byApp[result.path] = icon
            return icon
        }
        let key = result.isDirectory ? "/" + result.ext : result.ext
        if let cached = byType[key] { return cached }
        let type: UTType = if result.isDirectory {
            result.ext.isEmpty ? .folder : UTType(filenameExtension: result.ext, conformingTo: .directory) ?? .folder
        } else {
            UTType(filenameExtension: result.ext) ?? .data
        }
        let icon = NSWorkspace.shared.icon(for: type)
        byType[key] = icon
        return icon
    }
}

/// Display formatting shared by the table, inspector and quick panel.
enum Display {
    static let home = NSHomeDirectory()

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func parent(of path: String) -> String {
        abbreviate((path as NSString).deletingLastPathComponent)
    }

    static func size(_ result: SearchResult) -> String {
        result.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)).capitalizedFirst
    }

    static let absoluteDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Renders a snippet with `SearchResult.highlightStart/End` markers as highlighted text.
    static func highlighted(_ snippet: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.35),
        ]
        var highlighted = false
        var buffer = ""
        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(NSAttributedString(string: buffer, attributes: highlighted ? bold : normal))
            buffer = ""
        }
        for character in snippet {
            if character == SearchResult.highlightStart {
                flush()
                highlighted = true
            } else if character == SearchResult.highlightEnd {
                flush()
                highlighted = false
            } else {
                buffer.append(character)
            }
        }
        flush()
        return result
    }
}

extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
