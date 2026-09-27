import AppKit
import MoriaCore
import SwiftUI

@main
struct MoriaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        WindowGroup("Moria", id: "main") {
            if let app = delegate.app {
                MainView(app: app)
                    .environment(app)
                    .frame(minWidth: 900, minHeight: 520)
            } else {
                StartupFailure(message: delegate.startupError ?? "Unknown error")
            }
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Moria") { AboutPanel.show() }
            }
            CommandGroup(after: .appSettings) {
                if let app = delegate.app {
                    IndexingCommands(app: app)
                }
            }
            MoriaCommands { delegate.quickPanel?.toggle() }
            CommandGroup(replacing: .help) {
                HelpCommands()
            }
        }

        Window("Moria Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            if let app = delegate.app {
                SettingsView()
                    .environment(app)
                    .windowResizeAnchor(.top)
            }
        }

        // HIG: people decide whether a menu bar extra is shown (Settings > General).
        MenuBarExtra(isInserted: $showMenuBarExtra) {
            if let app = delegate.app {
                MenuBarContent(app: app, showQuickPanel: { delegate.quickPanel?.show() })
            }
        } label: {
            Label("Moria", systemImage: delegate.app?.isBusy == true ? "doc.text.magnifyingglass" : "magnifyingglass")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var app: AppModel?
    private(set) var startupError: String?
    private(set) var quickPanel: QuickPanelController?

    override init() {
        super.init()
        do {
            app = try AppModel()
        } catch {
            startupError = "The index could not be opened: \(error)"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let app else { return }
        quickPanel = QuickPanelController(app: app) { text in
            Self.showSearch(text)
        }
        app.showQuickPanel = { [weak self] in self?.quickPanel?.toggle() }
        NSApp.servicesProvider = self
        if !UserDefaults.standard.bool(forKey: "showDockIcon", default: true) {
            NSApp.setActivationPolicy(.accessory)
        }
        app.start()
    }

    /// Keep indexing in the menu bar after the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open shows one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.showSearch(nil) }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let quick = NSMenuItem(title: "Quick Search", action: #selector(dockQuickSearch), keyEquivalent: "")
        quick.target = self
        menu.addItem(quick)
        return menu
    }

    @objc private func dockQuickSearch() {
        quickPanel?.show()
    }

    // MARK: URL scheme

    /// `moria://search?q=invoice%20ext:pdf&scope=contents`
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "moria" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = items.first { $0.name == "q" }?.value ?? ""
            let scope = items.first { $0.name == "scope" }?.value.flatMap { SearchScope(rawValue: $0.capitalized) }
            Self.showSearch(query, scope: scope)
        }
    }

    // MARK: Services

    /// Services menu: "Search with Moria" on selected text.
    @objc func searchText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        Self.showSearch(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Services menu on folders in Finder: "Search in Folder with Moria".
    @objc func searchFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard let folder = urls.first(where: \.hasDirectoryPath) ?? urls.first else { return }
        var query = SearchQuery()
        query.folders = [folder.path]
        Self.showSearch(QueryFormatter().string(from: query) + " ")
    }

    /// Brings a main window forward (opening one if needed) and shows `text` in it.
    static func showSearch(_ text: String?, scope: SearchScope? = nil) {
        NSApp.activate()
        let request = SearchRequest(text: text, scope: scope)
        let mainWindows = NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
        if let window = mainWindows.first(where: \.isKeyWindow) ?? mainWindows.first {
            window.makeKeyAndOrderFront(nil)
            // Addressed to one window explicitly: "is active" updates too late to decide.
            NotificationCenter.default.post(name: .moriaSearch, object: window, userInfo: ["request": request])
        } else {
            pendingRequest = request
            openMainWindow?()
        }
    }

    /// SwiftUI's `openWindow(id: "main")`, registered by the first window that appears
    /// (AppKit code has no other way to open a SwiftUI scene).
    static var openMainWindow: (() -> Void)?

    /// A request waiting for a newly opened window to pick it up.
    static var pendingRequest: SearchRequest?
}

/// Text (and optionally a scope) to show in a main window.
struct SearchRequest {
    var text: String?
    var scope: SearchScope?
}

extension UserDefaults {
    func bool(forKey key: String, default value: Bool) -> Bool {
        object(forKey: key) == nil ? value : bool(forKey: key)
    }
}

// MARK: - About

enum AboutPanel {
    static func show() {
        let credits = NSMutableAttributedString(
            string: "Deep search for everything on your Mac: names, contents and meaning.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(
            string: "Includes ripgrep by Andrew Gallant (MIT / Unlicense) and GRDB.swift by Gwendal Roué (MIT). Built on SQLite FTS5, PDFKit, Vision, Natural Language and Foundation Models. Everything is indexed on this Mac and never leaves it.",
            attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

// MARK: - Menu bar extra

private struct MenuBarContent: View {
    let app: AppModel
    let showQuickPanel: () -> Void

    var body: some View {
        Text(app.statusText)
        Divider()
        Button("Quick Search") { showQuickPanel() }
        Button("Open Moria") { AppDelegate.showSearch(nil) }
        Divider()
        Button(app.progress.isPaused ? "Resume Indexing" : "Pause Indexing") { app.setPaused(!app.progress.isPaused) }
        Button("Rescan Now") { app.rescan() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Moria") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct StartupFailure: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Moria Couldn't Start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        }
        .frame(width: 480, height: 300)
    }
}
