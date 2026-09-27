import AppKit
import SwiftUI

extension FocusedValues {
    /// The search model of the focused main window.
    @Entry var searchModel: SearchModel?
    @Entry var inspectorVisible: Binding<Bool>?
    /// Set to true to show the export panel of the focused window.
    @Entry var exportResults: Binding<Bool>?
}

/// Menu commands for everything reachable from the toolbar and results (HIG: every toolbar
/// action is also a menu command). Shortcuts follow Spotlight and Finder.
struct MoriaCommands: Commands {
    @FocusedValue(\.searchModel) private var model
    @FocusedValue(\.inspectorVisible) private var inspectorVisible
    @FocusedValue(\.exportResults) private var exportResults
    let toggleQuickPanel: () -> Void

    private var noSelection: Bool { model?.selection.isEmpty ?? true }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Quick Search") { toggleQuickPanel() }
            Divider()
            Button("Open") { model?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(noSelection)
            OpenWithMenu(urls: model?.selectedURLs ?? [])
            Button("Show in Finder") { model?.revealSelection() }
                .keyboardShortcut("r")
                .disabled(noSelection)
            Button("Quick Look") { model?.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(noSelection)
            Button("Actions…") { model?.showActions.toggle() }
                .keyboardShortcut("k")
                .disabled(noSelection)
            Divider()
            Button("Move to Trash") { model?.moveSelectionToTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(noSelection)
            Divider()
            Button("Save Search…") { model?.showSavePrompt = true }
                .keyboardShortcut("s")
                .disabled(!(model?.canSave ?? false))
            Button("Export Results…") { exportResults?.wrappedValue = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.items.isEmpty ?? true)
        }
        CommandGroup(after: .pasteboard) {
            Button("Copy Path") { if let urls = model?.selectedURLs { FileActions.copyPaths(urls) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(noSelection)
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { model?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Go to Search Field") { model?.focusSearch() }
                .keyboardShortcut("l")
                .disabled(model == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(SearchMode.allCases.enumerated()), id: \.element) { index, mode in
                if mode != .ask || model?.canAsk == true {
                    Toggle(isOn: Binding(get: { model?.mode == mode }, set: { if $0 { model?.mode = mode } })) {
                        Label(mode.title, systemImage: mode.symbol)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(model == nil)
                }
            }
            Divider()
            if let model, model.canUseMeaning {
                Toggle("Search by Meaning", isOn: Binding(get: { model.useMeaning }, set: { model.useMeaning = $0 }))
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            Picker("Sort By", selection: Binding(get: { model?.sort ?? .relevance }, set: { model?.sort = $0 })) {
                ForEach(ResultSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(model == nil)
            Divider()
        }
        CommandGroup(after: .sidebar) {
            Button(inspectorVisible?.wrappedValue == true ? "Hide Preview" : "Show Preview") {
                inspectorVisible?.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(inspectorVisible == nil)
        }
    }
}

/// File > Open With: the apps that can open the selection, default first.
private struct OpenWithMenu: View {
    let urls: [URL]

    var body: some View {
        Menu("Open With") {
            if let first = urls.first {
                let apps = NSWorkspace.shared.urlsForApplications(toOpen: first)
                let preferred = NSWorkspace.shared.urlForApplication(toOpen: first)
                ForEach(apps.prefix(15), id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path) + (app == preferred ? " (default)" : "")) {
                        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            }
        }
        .disabled(urls.isEmpty)
    }
}

/// Moria menu: indexing controls, after Settings.
struct IndexingCommands: View {
    let app: AppModel

    var body: some View {
        Button(app.progress.isPaused ? "Resume Indexing" : "Pause Indexing") { app.setPaused(!app.progress.isPaused) }
        Button("Rescan Now") { app.rescan() }
        Button("Rebuild Index…") { app.confirmRebuild() }
    }
}

/// Help menu: the in-app guide and the query syntax.
struct HelpCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Moria Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
    }
}
