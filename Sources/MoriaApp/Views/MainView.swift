import MoriaCore
import SwiftUI

/// The main window: filter sidebar, results, and a preview inspector, with the search field
/// and scopes in the toolbar (macOS HIG: search at the trailing edge of the toolbar).
struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SearchModel
    @State private var showInspector = true
    @State private var showSyntax = false
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
                .safeAreaBar(edge: .top) {
                    if let interpretation = model.interpretation {
                        InterpretationBar(summary: interpretation.summary) { model.editInterpretation() }
                    }
                }
                .safeAreaBar(edge: .bottom) { StatusBar(model: model) }
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                }
        }
        .searchable(text: $model.text, placement: .toolbar, prompt: Text(model.prompt))
        .searchScopes($model.scope) {
            ForEach(SearchScope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
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
            if !model.askMode { model.focusResults() }
        }
        .toolbar { toolbar }
        .navigationTitle("Moria")
        .navigationSubtitle(model.scope == .everything ? "" : model.scope.rawValue)
        .focusedSceneValue(\.searchModel, model)
        .focusedSceneValue(\.inspectorVisible, $showInspector)
        .onAppear {
            searchFocused = true
            // `open -a Moria --args -initialQuery "…"` starts on a query.
            if let query = UserDefaults.standard.string(forKey: "initialQuery") { model.text = query }
        }
        .onChange(of: model.focusSearchRequest) { searchFocused = true }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingView { onboarded = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .moriaSearch)) { note in
            if let text = note.object as? String { model.text = text }
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
                .help("Also find documents related in meaning, not only by their words")
                .disabled(model.scope == .regex)
            }
            if model.canAsk {
                Toggle(isOn: $model.askMode) {
                    Label("Ask", systemImage: "text.bubble")
                }
                .help("Describe what you're looking for in plain language, then press Return")
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

// MARK: - Results area

private struct ResultsArea: View {
    let model: SearchModel

    var body: some View {
        if !model.items.isEmpty {
            ResultsTable(model: model)
        } else if model.text.isEmpty, !model.filters.isActive {
            WelcomeView(model: model)
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

/// First screen: what can be searched, with example queries that run on click.
private struct WelcomeView: View {
    let model: SearchModel

    private let examples: [(String, String)] = [
        ("invoice ext:pdf", "PDFs mentioning invoices"),
        ("kind:image modified:<7d", "Images from the past week"),
        ("\"lease agreement\" in:~/Documents", "An exact phrase in Documents"),
        ("size:>1gb", "Files over 1 GB"),
        ("name:readme -in:~/Library", "READMEs outside Library"),
    ]

    var body: some View {
        ContentUnavailableView {
            Label("Search Everything", systemImage: "magnifyingglass")
        } description: {
            Text("Names, the text inside documents and code, and text in scans and screenshots.")
        } actions: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(examples, id: \.0) { query, meaning in
                    Button {
                        model.text = query
                    } label: {
                        HStack {
                            Text(query).font(.system(.body, design: .monospaced))
                            Spacer(minLength: 16)
                            Text(meaning).foregroundStyle(.secondary)
                        }
                        .frame(width: 440)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

/// Shows how an Ask request was understood, with a way to edit it as a normal query.
private struct InterpretationBar: View {
    let summary: String
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text("Searching for \(Text(summary).fontWeight(.medium))")
            Spacer()
            Button("Edit as Query", action: edit)
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Status bar

/// Finder-style footer: result count on the left, indexing status on the right.
private struct StatusBar: View {
    @Environment(AppModel.self) private var app
    let model: SearchModel

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
            if app.isBusy { ProgressView().controlSize(.mini) }
            Text(app.statusText)
                .monospacedDigit()
                .lineLimit(1)
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

    private let rows: [(String, String)] = [
        ("tax return", "all words, in the name or the contents"),
        ("\"exact phrase\"", "words in this order"),
        ("-draft", "leave out files containing a word"),
        ("name:report  content:lease", "match only names or only contents"),
        ("ext:pdf,docx", "file extensions"),
        ("kind:image", "folder, document, pdf, image, audio, video, archive, text, code, app"),
        ("size:>10mb  size:1mb..5mb", "size limits (kb, mb, gb)"),
        ("modified:<7d  modified:today", "relative dates (h, d, w, m, y)"),
        ("modified:2026-03..2026-05", "calendar ranges (year, month or day)"),
        ("created:2025", "creation date"),
        ("in:~/Documents  -in:~/Library", "inside or outside a folder"),
        ("hidden:no  cloud:no", "skip hidden files or cloud-only files"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Query Syntax").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { example, meaning in
                    GridRow {
                        Button(example) { model.append(example) }
                            .buttonStyle(.link)
                            .font(.system(.body, design: .monospaced))
                        Text(meaning).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Click an example to add it. Filters combine with the sidebar; a filter you type wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 580)
    }
}
