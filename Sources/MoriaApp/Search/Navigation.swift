import Foundation
import MoriaCore

/// How the search text is used: the scopes plus Ask, as one menu (⌘1–⌘5).
enum SearchMode: String, CaseIterable, Identifiable {
    case everything, names, contents, regex, ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: "Everything"
        case .names: "Names"
        case .contents: "Contents"
        case .regex: "Regex"
        case .ask: "Ask"
        }
    }

    var symbol: String {
        switch self {
        case .everything: "magnifyingglass"
        case .names: "textformat"
        case .contents: "doc.text.magnifyingglass"
        case .regex: "asterisk"
        case .ask: "text.bubble"
        }
    }

    var help: String {
        switch self {
        case .everything: "File names and the text inside files"
        case .names: "File and folder names only"
        case .contents: "Text inside files only"
        case .regex: "Regular expression over names and contents"
        case .ask: "Describe what you're looking for; press Return"
        }
    }

    var scope: SearchScope? {
        switch self {
        case .everything: .everything
        case .names: .names
        case .contents: .contents
        case .regex: .regex
        case .ask: nil
        }
    }
}

/// Built-in one-click searches shown in the sidebar and on the home screen. Each is plain
/// query syntax, so selecting one shows exactly what it does and can be edited.
struct Collection: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var symbol: String
    var query: String
    /// Counted for the sidebar and home screen. Duplicates aren't: counting them reads files.
    var isCounted = true

    static let all: [Collection] = [
        Collection(name: "Recent Documents", symbol: "clock",
                   query: "kind:document,pdf,text modified:<7d -in:~/Library hidden:no"),
        Collection(name: "Downloads", symbol: "arrow.down.circle", query: "in:~/Downloads"),
        Collection(name: "Screenshots", symbol: "camera.viewfinder", query: "name:screenshot kind:image"),
        Collection(name: "PDFs", symbol: "doc.richtext", query: "ext:pdf -in:~/Library hidden:no"),
        Collection(name: "Images", symbol: "photo", query: "kind:image -in:~/Library hidden:no"),
        Collection(name: "Recent Code", symbol: "chevron.left.forwardslash.chevron.right",
                   query: "kind:code modified:<14d -in:~/Library hidden:no"),
        Collection(name: "Large Files", symbol: "externaldrive", query: "size:>500mb -in:~/Library"),
        Collection(name: "Duplicates", symbol: "square.on.square", query: "duplicates:yes size:>1mb -in:~/Library hidden:no",
                   isCounted: false),
    ]
}

/// What's selected in the sidebar.
enum SidebarItem: Hashable {
    case home
    case collection(String)
    case saved(UUID)
    case location(String)
}
