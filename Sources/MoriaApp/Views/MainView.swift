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
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .animation(.snappy(duration: 0.18), value: model.showActions)
                .safeAreaBar(edge: .bottom) { StatusBar(model: model) }
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        // A folder dragged from Finder onto the window is searched inside.
        .dropDestination(for: URL.self) { urls, _ in _ = model.searchInside(urls) }
        // Filters are tokens in the field, as in Finder and Mail; the mode is the scope bar.
        .searchable(text: $model.fieldWords, tokens: $model.fieldTokens, placement: .toolbarPrincipal, prompt: Text(model.prompt)) { token in
            Label(token.label, systemImage: token.symbol)
        }
        .searchScopes($model.mode, activation: .onSearchPresentation) {
            ForEach(SearchMode.allCases.filter { !$0.needsModel || model.canAsk }) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .searchSuggestions {
            ForEach(model.suggestions) { suggestion in
                Label(suggestion.title, systemImage: suggestion.symbol)
                    .searchCompletion(suggestion.completion)
            }
        }
        .searchFocused($searchFocused)
        .onSubmit(of: .search) {
            model.submit()
            if !model.askMode, !model.answerMode { model.focusResults() }
        }
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .navigationTitle("Moria")
        .focusedSceneValue(\.searchModel, model)
        .focusedSceneValue(\.inspectorVisible, $showInspector)
        .focusedSceneValue(\.exportResults, $exporting)
        .focusedSceneValue(\.searchFieldFocused, searchFocused)
        // Built only while exporting: this runs on every redraw, and the CSV covers every result.
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.exportCSV()) : nil,
                      contentType: .commaSeparatedText, defaultFilename: "Moria Results") { result in
            if case let .failure(error) = result { app.lastError = "Export failed: \(error.localizedDescription)" }
        }
        .onAppear {
            searchFocused = true
            model.undoManager = undoManager
            // From the window, not the sidebar: a collapsed sidebar never appears, and the
            // home screen needs the recent files and counts too.
            model.loadHome()
            AppDelegate.openMainWindow = { openWindow(id: "main") }
            if let request = AppDelegate.pendingRequest {
                AppDelegate.pendingRequest = nil
                model.show(request)
            } else if let query = UserDefaults.standard.string(forKey: "initialQuery") {
                // `open -a Moria --args -initialQuery "…" -initialMode answer` starts on a query.
                let mode = UserDefaults.standard.string(forKey: "initialMode").flatMap(SearchMode.init)
                model.show(SearchRequest(text: query, scope: nil, mode: mode))
            }
        }
        .onChange(of: model.focusSearchRequest) { searchFocused = true }
        .onChange(of: app.savedSearches) { model.loadHome() }
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
        .sheet(isPresented: $model.showRegexBuilder, onDismiss: { model.editingSaved = nil }) {
            RegexBuilderView(model: model, editing: model.editingSaved).environment(app)
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
            app.reloadSettings()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // In a narrow window the filters stay and the help goes to the overflow menu first.
        if #available(macOS 26.1, *) {
            filterItems.visibilityPriority(.high)
        } else {
            filterItems
        }
        ToolbarSpacer(.fixed)
        ToolbarItemGroup(placement: .primaryAction) {
            if model.canUseMeaning {
                Toggle(isOn: $model.useMeaning) {
                    Label("Search by Meaning", systemImage: "sparkles")
                        .symbolEffect(.bounce, value: reduceMotion ? false : model.useMeaning)
                }
                .help("Also find documents related in meaning, not only by their words (⇧⌘M)")
                .disabled(model.mode == .regex)
            }
        }
        ToolbarSpacer(.fixed)
        if #available(macOS 26.1, *) {
            syntaxItem.visibilityPriority(.low)
        } else {
            syntaxItem
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Preview", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .help("Show or hide the preview (⌥⌘I)")
        }
    }

    private var filterItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                FilterOptions(filters: $model.filters, roots: app.settings.roots)
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease")
            }
            .help("Add a filter: kind, date, size, location")
            Button("Criteria", systemImage: "slider.horizontal.3") { model.showCriteria = true }
                .help("Build a detailed search from criteria (⇧⌘F)")
        }
    }

    private var syntaxItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Query Syntax", systemImage: "questionmark.circle") { showSyntax.toggle() }
                .help("Filters you can type in the search field")
                .popover(isPresented: $showSyntax, arrowEdge: .bottom) { SyntaxHelp(model: model).padding() }
        }
    }
}

extension Notification.Name {
    /// Posted with a query string to show it in the main window.
    static let moriaSearch = Notification.Name("MoriaSearch")
}

// MARK: - Results area

private struct ResultsArea: View {
    let model: SearchModel
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The search has run long enough to show progress: every keystroke starts a search, and
    /// a spinner for each would flash between the old rows and the new.
    @State private var slow = false

    private enum Content: Equatable {
        case answer, results, home, searching, stopped, problem(String), empty
    }

    private var content: Content {
        if model.answerMode, model.answer != nil { return .answer }
        if !model.items.isEmpty { return .results }
        if model.text.isEmpty, !model.filters.isActive { return .home }
        if model.isSearching { return .searching }
        if model.isStopped { return .stopped }
        if let message = model.message, message != "No matches" { return .problem(message) }
        return .empty
    }

    var body: some View {
        ZStack {
            switch content {
            case .answer:
                ResultsTable(model: model)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            AnswerView(model: model)
                            Divider()
                        }
                    }
            case .results:
                ResultsTable(model: model)
            case .home:
                HomeView(model: model)
            case .searching:
                if slow {
                    VStack(spacing: 12) {
                        ProgressView("Searching…")
                        Button("Stop", action: model.stop)
                            .help("Stop this search (⌘.)")
                    }
                }
            case .stopped:
                ContentUnavailableView {
                    Label("Search Stopped", systemImage: "stop.circle")
                } description: {
                    Text("Change the search, or search again.")
                } actions: {
                    Button("Search Again") { model.search(debounce: false) }
                }
            case let .problem(message):
                ContentUnavailableView("Search Problem", systemImage: "exclamationmark.magnifyingglass", description: Text(message))
            case .empty:
                ContentUnavailableView {
                    Label(model.text.isEmpty ? "No Results" : "No Results for “\(model.text)”", systemImage: "magnifyingglass")
                } description: {
                    Text(emptyHint)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The states cross-fade instead of swapping.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: content)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: slow)
        .task(id: model.isSearching) {
            slow = false
            guard model.isSearching else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { slow = true }
        }
    }

    /// While the index is being built, nothing found may mean not read yet.
    private var emptyHint: String {
        switch app.progress.phase {
        case .scanning: "Moria is still scanning your files; more may turn up as the scan continues."
        case .extracting, .recognizingText, .transcribing: "Moria is still reading file contents; more may turn up as indexing continues."
        case .updating, .readingDetails, .embedding, .idle: "Check the spelling or try a new search."
        }
    }
}

// MARK: - Status bar

/// Finder-style footer: result count on the left, indexing status on the right.
private struct StatusBar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: SearchModel
    @State private var showCoverage = false

    var body: some View {
        HStack(spacing: 10) {
            Text(model.summary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .default, value: model.items.count)
            if model.isSearching {
                ProgressView().controlSize(.mini)
                Button("Stop", action: model.stop)
                    .buttonStyle(.borderless)
                    .help("Stop this search (⌘.)")
            }
            Spacer(minLength: 8)
            if !app.hasFullDiskAccess {
                Button("Limited Access", systemImage: "exclamationmark.lock") { FullDiskAccess.openSystemSettings() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                    .help("Moria can't see Mail, Messages and other protected folders. Click to allow Full Disk Access.")
            }
            if let error = app.lastError {
                // App errors stay until dismissed; indexing errors clear when indexing succeeds.
                Button { app.lastError = nil } label: {
                    Label(error, systemImage: "exclamationmark.triangle").lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help(error + "\nClick to dismiss.")
            } else if let error = app.progress.lastError {
                Label("Indexing problem: " + error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            } else if let problem = app.progress.transcriptionProblem {
                Label("Recordings aren't being transcribed: " + problem, systemImage: "waveform.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(problem + "\nRecordings wait until the speech model is available.")
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
