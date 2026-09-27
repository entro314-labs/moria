import SwiftUI

/// The Help window: how searching works, the query syntax, and keyboard shortcuts.
struct HelpView: View {
    private enum Topic: String, CaseIterable, Identifiable {
        case searching = "Searching"
        case syntax = "Query Syntax"
        case keyboard = "Keyboard Shortcuts"
        case index = "What Gets Indexed"
        case intelligence = "Ask & Meaning"
        case integration = "Finder, Services & Automation"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .searching: "magnifyingglass"
            case .syntax: "curlybraces"
            case .keyboard: "keyboard"
            case .index: "externaldrive"
            case .intelligence: "sparkles"
            case .integration: "puzzlepiece.extension"
            }
        }
    }

    @State private var topic: Topic = .searching

    var body: some View {
        NavigationSplitView {
            List(Topic.allCases, selection: $topic) { topic in
                Label(topic.rawValue, systemImage: topic.symbol).tag(topic)
            }
            .navigationSplitViewColumnWidth(220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(topic.rawValue).font(.largeTitle.weight(.semibold))
                    content
                }
                .padding(28)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 900, height: 620)
    }

    @ViewBuilder
    private var content: some View {
        switch topic {
        case .searching:
            paragraph("Type in the search field at the top right. Results appear as you type and match file names and the text inside files. Each result says why it matched: **Name**, **Contents** (with the number of matching lines), **Text in image**, or **Meaning**.")
            paragraph("Use the scope bar under the toolbar to search **Everything**, only **Names**, only **Contents**, or with a **Regex**. The sidebar narrows by kind, date, size and location. Every active filter appears as a chip under the toolbar; click × to remove it. When results mix kinds, the chips on the right narrow to one kind in one click, or leave it out with Option-click.")
            paragraph("Select a result to preview it on the right, with every matching line listed below the preview. Press Space for Quick Look, Return to open, ⌘R to show it in Finder, and ⌘K for more actions. Save a search with ⌘S to keep it in the sidebar.")
        case .syntax:
            SyntaxTable()
        case .keyboard:
            shortcuts([
                ("⌃⌥Space", "Quick search from anywhere (change in Settings)"),
                ("⌥⌘F  or  ⌘L", "Go to the search field"),
                ("Return (in the field)", "Move to the results"),
                ("↑ ↓", "Move through results"),
                ("Return  or  ⌘↓", "Open"),
                ("⌘R", "Show in Finder"),
                ("Space  or  ⌘Y", "Quick Look"),
                ("⌘K", "Actions for the selection"),
                ("⌘C / ⌥⌘C", "Copy files / copy paths"),
                ("⌘⌫", "Move to Trash"),
                ("⌘1 … ⌘4", "Everything, Names, Contents, Regex"),
                ("⇧⌘M / ⇧⌘A", "Search by meaning / Ask (when turned on)"),
                ("⌘S", "Save search"),
                ("⇧⌘F", "Criteria builder"),
                ("⌥⌘R", "Regex builder"),
                ("⇧⌘E", "Export results"),
                ("⌥⌘I", "Show or hide the preview"),
                ("⌘N", "New search window"),
            ])
        case .index:
            paragraph("Moria keeps its own index, so it finds files Spotlight skips. Every file and folder under your locations is indexed by name, including hidden files and app data. Changes are picked up as they happen, including those made while Moria wasn't running.")
            paragraph("Text is read from documents, PDFs (scanned pages are recognized), Office and OpenDocument files, e-books, web pages, email files, code and plain text, and images of text. To keep the index small, files in your Library, in hidden folders and in dependency or build folders are indexed by name only; you can change this in Settings › Contents. Regex search still reads code and text files everywhere.")
            paragraph("Files in iCloud Drive, Dropbox, OneDrive and Google Drive that aren't downloaded are indexed by name only. Moria never downloads files to read them.")
            paragraph("For Moria to see Mail, Messages and other protected data, allow **Full Disk Access** in System Settings › Privacy & Security. Everything stays on this Mac.")
        case .intelligence:
            paragraph("Turn these on in Settings › Intelligence. Both use Apple's on-device models; nothing is sent anywhere.")
            paragraph("**Ask** turns a request such as “invoices about rent from last spring over 1 MB” into filters. The filters appear as chips so you can check them, remove one, or choose **Edit as Query** to fine-tune the text.")
            paragraph("**Meaning** also finds documents related to your words even when the exact words don't appear, and shows the closest passage. It covers documents, PDFs, notes and recognized text in Latin-script languages.")
        case .integration:
            paragraph("**Services:** select text in any app, or a folder in Finder, and choose Services › Search with Moria (or Search in Folder with Moria).")
            paragraph("**Links:** `moria://search?q=invoice%20ext:pdf&scope=contents` opens a search. Scopes: everything, names, contents, regex.")
            paragraph("**Command line:** the `moria` tool in Moria.app/Contents/Resources shares the app's index: `moria search \"lease\" --json`, `moria search --regex 'INV-\\d+'`, `moria stats`. Add `--show` to open the results in the app.")
        }
    }

    private func paragraph(_ text: LocalizedStringKey) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
    }

    private func shortcuts(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            ForEach(rows, id: \.0) { key, action in
                GridRow {
                    Text(key).font(.system(.body, design: .rounded).weight(.medium))
                    Text(action).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Query syntax reference, shared by the Help window and the toolbar popover.
struct SyntaxTable: View {
    var onSelect: ((String) -> Void)?

    static let rows: [(String, String)] = [
        ("tax return", "all words, in the name or the contents"),
        ("\"exact phrase\"", "words in this order"),
        ("-draft", "leave out files containing a word"),
        ("name:report  content:lease", "match only names or only contents"),
        ("name:IMG*  name:*.draft  name:=README", "name begins with, ends with, is exactly"),
        ("name:/^IMG_\\d{4}$/", "name matches a regular expression"),
        ("ext:pdf,docx  -ext:tmp", "file extensions (or leave some out)"),
        ("path:invoices", "text anywhere in the full path"),
        ("kind:image  -kind:folder", "document, pdf, image, audio, video, archive, text, code, folder, app"),
        ("size:>10mb  size:1mb..5mb", "size limits (kb, mb, gb)"),
        ("modified:<7d  modified:today", "relative dates (h, d, w, m, y)"),
        ("modified:2026-03..2026-05", "calendar ranges (year, month or day)"),
        ("created:2025", "creation date"),
        ("in:~/Documents  -in:~/Library", "inside or outside a folder"),
        ("hidden:no  cloud:no", "skip hidden files or cloud-only files"),
    ]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            ForEach(Self.rows, id: \.0) { example, meaning in
                GridRow {
                    if let onSelect {
                        Button(example) { onSelect(example) }
                            .buttonStyle(.link)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text(example).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                    Text(meaning).foregroundStyle(.secondary)
                }
            }
        }
    }
}
