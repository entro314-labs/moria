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
            paragraph("Type in the search field at the top. Results appear as you type and match file names and the text inside files. Each result says why it matched: **Name**, **Contents** (with the number of matching lines), **Text in image**, **In picture** (what a photo shows, such as “beach” or “receipt”), or **Meaning**.")
            paragraph("The scope bar under the search field chooses what the text means: **Everything**, only **Names**, only **Contents**, a **Regex**, a request to **Ask** in plain language, or a question to **Answer** from your files (the last two when turned on). Filters are tokens in the field: type one (`ext:pdf`, `modified:<7d`) and it becomes a token when you press Space, or add one from the **Filter** menu in the toolbar; Delete removes the last token. When results mix kinds, the chips on the right narrow to one kind in one click, or leave it out with Option-click.")
            paragraph("Results are ranked by how well the words match names and contents. A search that names an app (“saf”, “final cut”) lists the app first, so quick search launches it with Return. What you open for a search comes first the next time you type it, and fades over the following weeks.")
            paragraph("Select a result to preview it on the right, with every matching line listed below the preview. Press Space for Quick Look, Return to open, ⌘R to show it in Finder, and ⌘K for more actions. Save a search with ⌘S to keep it in the sidebar.")
        case .syntax:
            SyntaxTable()
        case .keyboard:
            shortcuts([
                ("⌃⌥Space", "Quick search from anywhere (change in Settings)"),
                ("⌥⌘F", "Go to the search field"),
                ("⌘.", "Stop the search"),
                ("Return (in the field)", "Move to the results"),
                ("↑ ↓", "Move through results"),
                ("Return  or  ⌘↓", "Open"),
                ("⌘R", "Show in Finder"),
                ("Space  or  ⌘Y", "Quick Look"),
                ("⌘K", "Actions for the selection"),
                ("⌘C / ⌥⌘C", "Copy files / copy paths"),
                ("⌘⌫", "Move to Trash"),
                ("⌘Z", "Undo Move to Trash, or deleting a saved search"),
                ("⌘G / ⇧⌘G", "Next / previous matching line in the preview"),
                ("⌘1 … ⌘6", "Everything, Names, Contents, Regex, Ask, Answer (the last two when turned on)"),
                ("⇧⌘M", "Search by meaning (when turned on)"),
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
            paragraph("With **Transcribe speech in audio and video** on (Settings › Contents), voice memos, meetings and videos are searchable by what is said. Transcripts are made on this Mac in the system language, one recording at a time after everything else is read. Each matching line shows the time it was said at; select the recording and click a line to play from there.")
            paragraph("Searches ignore case and accents in every script. A word also finds its other forms in English, Greek and Russian: “αποδείξεις” finds “απόδειξη”, “invoices” finds “invoice”.")
            paragraph("Files in iCloud Drive, Dropbox, OneDrive and Google Drive that aren't downloaded are indexed by name only. Moria never downloads files to read them.")
            paragraph("Locations on external drives and network volumes stay in the index when the drive is ejected: their results are marked **Offline**, and their stored text is still searchable. When the drive is connected again, Moria reads the location again, catching changes made on another Mac.")
            paragraph("Finder tags are indexed where contents are read, and follow changes as you tag files. Search them with `tag:`, and show them in the Tags column (right-click the column headers).")
            paragraph("For Moria to see Mail, Messages and other protected data, allow **Full Disk Access** in System Settings › Privacy & Security. Everything stays on this Mac.")
        case .intelligence:
            paragraph("Turn these on in Settings › Intelligence. Both use Apple's on-device models; nothing is sent anywhere.")
            paragraph("**Ask** turns a request such as “invoices about rent from last spring over 1 MB” into filters. The filters appear as chips so you can check them, remove one, or choose **Edit as Query** to fine-tune the text.")
            paragraph("**Answer** replies to a question such as “what does the lease say about pets?” from the text of your files. Moria finds the files that bear on the question, hands the model a passage from each, and shows the answer with its sources numbered; click a number or a source to preview the file. The answer only draws on those passages, so it says when they don't settle the question. Turn on Meaning to find sources by sense as well as by words.")
            paragraph("**Meaning** also finds documents related to your words even when the exact words don't appear, and shows the closest passage. It covers documents, PDFs, notes and recognized text in Latin-script languages.")
            paragraph("**Find Similar** (File menu, ⌘K or a result's context menu) lists the documents closest in meaning to the selected one. It's the query `similar:` followed by the file's path, so filters and words narrow it and it can be saved.")
        case .integration:
            paragraph("**Services:** select text in any app, or a folder in Finder, and choose Services › Search with Moria (or Search in Folder with Moria).")
            paragraph("**Drag and drop:** drop a folder from Finder on a Moria window to search inside it. Drag results out to Finder or any app.")
            paragraph("**Shortcuts:** **Search in Moria** opens a search, and **Find Files with Moria** finds files and passes them to the next action (to move, attach or open them) without showing Moria. Both take the same query syntax as the search field.")
            paragraph("**Links:** `moria://search?q=invoice%20ext:pdf&scope=contents` opens a search. Scopes: everything, names, contents, regex. Add `&mode=ask` or `&mode=answer` to run the text as a request or a question.")
            paragraph("**Command line:** the `moria` tool in Moria.app/Contents/Resources shares the app's index: `moria search \"lease\" --json`, `moria search --regex 'INV-\\d+'`, `moria stats`. Add `--show` to open the results in the app.")
            paragraph("**AI agents:** `moria mcp` is a Model Context Protocol server. Add it to an agent (Claude, Cursor, …) as a stdio server with the command `/Applications/Moria.app/Contents/Resources/moria` and the argument `mcp`; the agent can then search names, contents and regular expressions. It can't change files.")
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
        ("taken:2024-07", "when a photo was taken"),
        ("duration:>10m  duration:1m..5m", "length of audio and video (s, m, h)"),
        ("author:smith", "author of a PDF or Office document"),
        ("in:~/Documents  -in:~/Library", "inside or outside a folder"),
        ("tag:red,\"Needs Review\"  -tag:done", "Finder tags (any of them), or leave some out"),
        ("hidden:no  cloud:no", "skip hidden files or cloud-only files"),
        ("duplicates:yes  size:>1mb", "identical files, in groups (most space wasted first)"),
        ("similar:~/Documents/lease.pdf", "documents close in meaning to a file (Meaning on)"),
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
