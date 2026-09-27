import MoriaCore
import SwiftUI

/// The main window: filter sidebar, results, and a preview inspector, with the search field
/// and scopes in the toolbar (macOS HIG: search at the trailing edge of the toolbar).
struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SearchModel
    @SceneStorage("showInspector") private var showInspector = true
    @State private var exporting = false
    @State private var window: NSWindow?
    @Environment(\.openWindow) private var openWindow
    @State private var showSyntax = false
    @State private var saveName = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("onboarded") private var onboarded = false

    init(app: AppModel) {
        _model = State(initialValue: SearchModel(app: app))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            ResultsArea(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top) { FilterBar(model: model) }
                .overlay(alignment: .top) {
                    if model.showActions, !model.selection.isEmpty {
                        ActionPalette(model: model) { model.showActions = false }
                            .padding(.top, 60)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.18), value: model.showActions)
                .safeAreaBar(edge: .bottom) { StatusBar(model: model) }
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        .searchable(text: $model.text, placement: .toolbarPrincipal, prompt: Text(model.prompt))
        .searchSuggestions {
            ForEach(model.suggestions) { suggestion in
                Label(suggestion.title, systemImage: suggestion.symbol)
                    .searchCompletion(suggestion.completion)
            }
        }
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            model.submit()
            if !model.askMode { model.focusResults() }
        }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .navigationTitle("Moria")
        .focusedSceneValue(\.searchModel, model)
        .focusedSceneValue(\.inspectorVisible, $showInspector)
        .focusedSceneValue(\.exportResults, $exporting)
        .fileExporter(isPresented: $exporting, document: CSVDocument(text: model.exportCSV()),
                      contentType: .commaSeparatedText, defaultFilename: "Moria Results") { result in
            if case let .failure(error) = result { app.lastError = "Export failed: \(error.localizedDescription)" }
        }
        .onAppear {
            searchFocused = true
            AppDelegate.openMainWindow = { openWindow(id: "main") }
            if let request = AppDelegate.pendingRequest {
                AppDelegate.pendingRequest = nil
                model.show(request)
            } else if let query = UserDefaults.standard.string(forKey: "initialQuery") {
                // `open -a Moria --args -initialQuery "…"` starts on a query.
                model.text = query
            }
        }
        .onChange(of: model.focusSearchRequest) { searchFocused = true }
        .alert("Save Search", isPresented: $model.showSavePrompt) {
            TextField("Name", text: $saveName)
            Button("Save") { app.save(model.currentAsSaved(named: saveName.isEmpty ? model.text : saveName)) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved searches appear in the sidebar and always show current results.")
        }
        .onChange(of: model.showSavePrompt) { if model.showSavePrompt { saveName = model.text } }
        .sheet(isPresented: $model.showCriteria, onDismiss: { model.editingSaved = nil }) {
            CriteriaBuilderView(model: model, editing: model.editingSaved).environment(app)
        }
        .sheet(isPresented: $model.showRegexBuilder) {
            RegexBuilderView(model: model).environment(app)
        }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingView { onboarded = true }
        }
        .background(WindowReader(window: $window))
        .onReceive(NotificationCenter.default.publisher(for: .moriaSearch)) { note in
            // Requests are addressed to one window.
            guard let request = note.userInfo?["request"] as? SearchRequest,
                  let target = note.object as? NSWindow, target === window else { return }
            model.show(request)
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshAccess()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.canUseMeaning {
                Toggle(isOn: $model.useMeaning) {
                    Label("Search by Meaning", systemImage: "sparkles")
                }
                .help("Also find documents related in meaning, not only by their words (⇧⌘M)")
                .disabled(model.mode == .regex)
            }
        }
        ToolbarSpacer(.fixed)
        ToolbarItem(placement: .primaryAction) {
            Button("Query Syntax", systemImage: "questionmark.circle") { showSyntax.toggle() }
                .help("Filters you can type in the search field")
                .popover(isPresented: $showSyntax, arrowEdge: .bottom) { SyntaxHelp(model: model).padding() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Preview", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .help("Show or hide the preview (⌥⌘I)")
        }
    }
}

extension Notification.Name {
    /// Posted with a query string to show it in the main window.
    static let moriaSearch = Notification.Name("MoriaSearch")
}

// MARK: - Mode menu

/// Search mode as a compact menu at the start of the filter bar (⌘1–⌘5), replacing scope tabs.
struct ModeMenu: View {
    @Bindable var model: SearchModel

    var body: some View {
        Menu {
            Picker("Mode", selection: $model.mode) {
                ForEach(SearchMode.allCases.filter { $0 != .ask || model.canAsk }) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            if !model.canAsk {
                Divider()
                SettingsLink { Text("Turn On Ask…") }
            }
        } label: {
            // A single Text: menu buttons reduce a Label to its icon.
            Text("\(Image(systemName: model.mode.symbol))  \(model.mode.title)")
        }
        .font(.caption.weight(.medium))
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("\(model.mode.help) (⌘1–⌘5)")
    }
}

// MARK: - Results area

private struct ResultsArea: View {
    let model: SearchModel

    var body: some View {
        if !model.items.isEmpty {
            ResultsTable(model: model)
        } else if model.text.isEmpty, !model.filters.isActive {
            HomeView(model: model)
        } else if model.isSearching {
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = model.message, message != "No matches" {
            ContentUnavailableView("Search Problem", systemImage: "exclamationmark.magnifyingglass", description: Text(message))
        } else {
            ContentUnavailableView.search(text: model.text)
        }
    }
}

// MARK: - Status bar

/// Finder-style footer: result count on the left, indexing status on the right.
private struct StatusBar: View {
    @Environment(AppModel.self) private var app
    let model: SearchModel
    @State private var showCoverage = false

    var body: some View {
        HStack(spacing: 10) {
            Text(model.summary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if !app.hasFullDiskAccess {
                Button("Limited Access", systemImage: "exclamationmark.lock") { FullDiskAccess.openSystemSettings() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help("Moria can't see Mail, Messages and other protected folders. Click to allow Full Disk Access.")
            }
            if let error = app.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }
            Button {
                showCoverage.toggle()
            } label: {
                HStack(spacing: 6) {
                    if app.isBusy { ProgressView().controlSize(.mini) }
                    Text(app.statusText).monospacedDigit().lineLimit(1)
                    Image(systemName: "info.circle").imageScale(.small)
                }
            }
            .buttonStyle(.plain)
            .help("What's indexed")
            .popover(isPresented: $showCoverage, arrowEdge: .top) { CoverageView() }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // Fixed height: the status text changes several times a second while indexing.
        .frame(height: 24)
        .padding(.horizontal, 14)
    }
}

// MARK: - Syntax help

struct SyntaxHelp: View {
    let model: SearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Query Syntax").font(.headline)
            SyntaxTable { example in model.append(example) }
            Text("Click an example to add it. Filters combine with the sidebar; a filter you type wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 600)
    }
}

import UniformTypeIdentifiers

/// Exported results for `fileExporter`.
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Reports the window hosting a view.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window { DispatchQueue.main.async { window = view.window } }
    }
}
