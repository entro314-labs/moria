import AppKit
import MoriaCore
import SwiftUI

@main
struct MoriaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        Window("Moria", id: "main") {
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
            MoriaCommands { delegate.quickPanel?.toggle() }
            CommandGroup(after: .appSettings) {
                Button("Rescan Now") { delegate.app?.rescan() }
            }
        }

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
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .moriaSearch, object: text)
        }
        app.showQuickPanel = { [weak self] in self?.quickPanel?.toggle() }
        app.start()
    }

    /// Keep indexing in the menu bar after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuBarContent: View {
    let app: AppModel
    let showQuickPanel: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(app.statusText)
        Divider()
        Button("Quick Search") { showQuickPanel() }
        Button("Open Moria") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Divider()
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
