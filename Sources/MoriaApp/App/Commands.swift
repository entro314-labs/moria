import SwiftUI

extension FocusedValues {
    /// The search model of the focused main window.
    @Entry var searchModel: SearchModel?
    @Entry var inspectorVisible: Binding<Bool>?
}

/// Menu commands for everything reachable from the toolbar and results (HIG: every toolbar
/// action is also a menu command). Shortcuts follow Spotlight and Finder.
struct MoriaCommands: Commands {
    @FocusedValue(\.searchModel) private var model
    @FocusedValue(\.inspectorVisible) private var inspectorVisible
    let toggleQuickPanel: () -> Void

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Quick Search") { toggleQuickPanel() }
            Divider()
            Button("Open") { model?.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model?.selection.isEmpty ?? true)
            Button("Show in Finder") { model?.revealSelection() }
                .keyboardShortcut("r")
                .disabled(model?.selection.isEmpty ?? true)
            Button("Quick Look") { model?.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(model?.selection.isEmpty ?? true)
            Button("Copy Path") { if let urls = model?.selectedURLs { FileActions.copyPaths(urls) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model?.selection.isEmpty ?? true)
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { model?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(model == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(SearchScope.allCases.enumerated()), id: \.element) { index, scope in
                Toggle(scope.rawValue, isOn: Binding(get: { model?.scope == scope }, set: { if $0 { model?.scope = scope } }))
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(model == nil)
            }
            Divider()
            if let model, model.canUseMeaning {
                Toggle("Search by Meaning", isOn: Binding(get: { model.useMeaning }, set: { model.useMeaning = $0 }))
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            if let model, model.canAsk {
                Toggle("Ask in Plain Language", isOn: Binding(get: { model.askMode }, set: { model.askMode = $0 }))
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
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
