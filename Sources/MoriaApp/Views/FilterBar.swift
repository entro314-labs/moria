import MoriaCore
import SwiftUI

/// The row under the scope bar, shown only when it has something to say: the regex builder in
/// Regex mode, what Ask understood, Clear for the filters (which are tokens in the field),
/// and kind facets with counts to narrow the results in one click.
struct FilterBar: View {
    @Bindable var model: SearchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Chips grow in and shrink out; with Reduce Motion they fade.
    private var animation: Animation? { reduceMotion ? nil : .snappy(duration: 0.2) }

    private var hasFilters: Bool { model.filters.isActive || !model.typedChips.isEmpty }

    var body: some View {
        if model.mode == .regex || model.interpretation != nil || hasFilters || !model.facets.isEmpty {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if model.mode == .regex {
                            Button("Regex Builder", systemImage: "asterisk") { model.showRegexBuilder = true }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .font(.caption.weight(.medium))
                                .help("Build and test a pattern (⌥⌘R)")
                        }
                        if model.interpretation != nil {
                            Label("Understood as", systemImage: "sparkles")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.purple)
                            ForEach(model.typedChips) { chip in
                                ActiveChip(chip: chip) { model.remove(chip) }
                                    .transition(.chip(reduceMotion))
                            }
                            Button("Edit as Query") { model.editInterpretation() }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                        if hasFilters {
                            Button("Clear Filters") {
                                model.filters = FilterState()
                                // Keeps the search words and phrases; every filter goes.
                                let query = QueryParser().parse(model.text)
                                model.text = (query.terms + query.phrases.map { "\"\($0)\"" }).joined(separator: " ")
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Remove every filter, typed or chosen")
                        }
                    }
                    .padding(.vertical, 1)
                    .animation(animation, value: model.activeChips.map(\.id))
                }
                .scrollIndicators(.never)
                if !model.facets.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(model.facets) { facet in
                            FacetChip(facet: facet) { exclude in model.applyFacet(facet, exclude: exclude) }
                                .transition(.chip(reduceMotion))
                        }
                    }
                    .fixedSize()
                    .animation(animation, value: model.facets.map(\.id))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

extension AnyTransition {
    /// A chip grows in and shrinks out; with Reduce Motion it fades.
    static func chip(_ reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity)
    }
}

/// The menu contents shared by "+ Filter" and each chip.
struct FilterOptions: View {
    @Binding var filters: FilterState
    let roots: [String]
    var only: Category?

    enum Category { case kind, date, size, location, options }

    private static let kinds: [(FileKind, String)] = [
        (.document, "doc.richtext"), (.pdf, "doc.text"), (.image, "photo"), (.text, "text.alignleft"),
        (.code, "chevron.left.forwardslash.chevron.right"), (.folder, "folder"), (.application, "app"),
        (.audio, "waveform"), (.video, "film"), (.archive, "archivebox"),
    ]

    var body: some View {
        if only == nil || only == .kind { kindMenu }
        if only == nil || only == .date { dateMenu }
        if only == nil || only == .size { sizeMenu }
        if only == nil || only == .location { locationMenu }
        if only == nil || only == .options {
            Divider()
            Toggle("Hide Library & Hidden Files", isOn: $filters.hideSystemFiles)
            Toggle("Hide Cloud-Only Files", isOn: $filters.hideCloudOnly)
        }
    }

    @ViewBuilder private var kindMenu: some View {
        let items = ForEach(Self.kinds, id: \.0) { kind, symbol in
            Toggle(isOn: Binding(get: { filters.kinds.contains(kind) },
                                 set: { if $0 { filters.kinds.insert(kind) } else { filters.kinds.remove(kind) } })) {
                Label(kind.displayName, systemImage: symbol)
            }
        }
        if only == .kind { items } else { Menu("Kind") { items } }
    }

    @ViewBuilder private var dateMenu: some View {
        let items = Group {
            Picker("Date", selection: $filters.date) {
                ForEach(FilterState.DatePreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Picker("Use", selection: $filters.dateUsesCreation) {
                Text("Date Modified").tag(false)
                Text("Date Created").tag(true)
            }
            .pickerStyle(.inline)
        }
        if only == .date { items } else { Menu("Date") { items } }
    }

    @ViewBuilder private var sizeMenu: some View {
        let items = Picker("Size", selection: $filters.size) {
            ForEach(FilterState.SizePreset.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.inline)
        if only == .size { items } else { Menu("Size") { items } }
    }

    @ViewBuilder private var locationMenu: some View {
        let home = NSHomeDirectory()
        let paths = Array(Set(roots + ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 })).sorted()
        let items = Group {
            Picker("Location", selection: $filters.folder) {
                Text("Everywhere").tag(String?.none)
                ForEach(paths, id: \.self) { Text(Display.abbreviate($0)).tag(String?.some($0)) }
                if let folder = filters.folder, !paths.contains(folder) {
                    Text(Display.abbreviate(folder)).tag(String?.some(folder))
                }
            }
            .pickerStyle(.inline)
            Button("Choose Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Search Here"
                if panel.runModal() == .OK, let url = panel.url { filters.folder = Volumes.canonicalPath(url.path) ?? url.path }
            }
        }
        if only == .location { items } else { Menu("Location") { items } }
    }
}

private struct ActiveChip: View {
    let chip: SearchModel.FilterChip
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: chip.symbol).imageScale(.small)
            Text(chip.label).lineLimit(1)
            Button("Remove", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .imageScale(.small)
                .fontWeight(.bold)
                .opacity(hovering ? 1 : 0.6)
                .help("Remove this filter from the query")
        }
        .font(.caption)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .foregroundStyle(chip.isExclusion ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
        .chipBackground(chip.isExclusion ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint), dashed: true)
        .onHover { hovering = $0 }
        .help("Typed in the query")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Filter: \(chip.label)")
        .accessibilityAction(named: "Remove", remove)
    }
}

/// The tinted capsule behind chips and match labels. With Increase Contrast on, the fill is
/// stronger and the outline solid.
struct ChipBackground<Style: ShapeStyle>: ViewModifier {
    let style: Style
    /// Dashed outline: a filter typed in the query rather than chosen in the bar.
    var dashed = false
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        content
            .background(style.opacity(increased ? 0.24 : 0.14), in: Capsule())
            .overlay {
                if increased || dashed {
                    Capsule().strokeBorder(style.opacity(increased ? 1 : 0.25),
                                           style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
                }
            }
    }
}

extension View {
    func chipBackground(_ style: some ShapeStyle, dashed: Bool = false) -> some View {
        modifier(ChipBackground(style: style, dashed: dashed))
    }
}

private struct FacetChip: View {
    let facet: SearchModel.Facet
    let apply: (_ exclude: Bool) -> Void

    var body: some View {
        Button {
            apply(NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: 4) {
                Text(facet.kind.displayName)
                Text(facet.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Show only \(facet.kind.displayName.lowercased()) results. Option-click to leave them out.")
    }
}

/// ⌘K: a filterable list of actions on the selection, each with its shortcut (Raycast-style).
struct ActionPalette: View {
    let model: SearchModel
    let close: () -> Void
    @State private var filter = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Action: Identifiable {
        var title: String
        var symbol: String
        var shortcut: String
        var run: () -> Void
        var id: String { title }
    }

    private var actions: [Action] {
        let urls = model.selectedURLs
        guard let first = urls.first else { return [] }
        var list = [
            Action(title: "Open", symbol: "arrow.up.forward.app", shortcut: "↩") { FileActions.open(urls) },
            Action(title: "Show in Finder", symbol: "folder", shortcut: "⌘R") { FileActions.reveal(urls) },
            Action(title: "Quick Look", symbol: "eye", shortcut: "Space") { model.toggleQuickLook() },
            Action(title: "Copy File", symbol: "doc.on.doc", shortcut: "⌘C") { FileActions.copyFiles(urls) },
            Action(title: "Copy Path", symbol: "doc.on.clipboard", shortcut: "⌥⌘C") { FileActions.copyPaths(urls) },
            Action(title: "Copy Name", symbol: "textformat", shortcut: "") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.lastPathComponent).joined(separator: "\n"), forType: .string)
            },
        ]
        let folder = first.deletingLastPathComponent().path
        list.append(Action(title: "Search in “\(first.deletingLastPathComponent().lastPathComponent)”", symbol: "folder.badge.gearshape", shortcut: "") {
            model.filters.folder = folder
        })
        list.append(Action(title: "Open in Terminal", symbol: "terminal", shortcut: "") { FileActions.openTerminal(at: first) })
        if model.canUseMeaning, urls.count == 1 {
            list.append(Action(title: "Find Similar", symbol: "sparkles", shortcut: "") { model.findSimilar(to: first.path) })
        }
        return list
    }

    private var filtered: [Action] {
        filter.isEmpty ? actions : actions.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Actions for \(model.selectedItems.first?.result.name ?? "selection")…", text: $filter)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit(runHighlighted)
                .onChange(of: filter) { highlighted = 0 }
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, action in
                        HStack {
                            Label(action.title, systemImage: action.symbol)
                            Spacer()
                            Text(action.shortcut).foregroundStyle(.secondary).font(.caption)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(index == highlighted ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = index; runHighlighted() }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(index == highlighted ? .isSelected : [])
                        .accessibilityAction { highlighted = index; runHighlighted() }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .onKeyPress(.downArrow) { highlight(highlighted + 1); return .handled }
        .onKeyPress(.upArrow) { highlight(highlighted - 1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onAppear { focused = true }
    }

    /// Moves the highlight; announced because focus stays in the filter field.
    private func highlight(_ index: Int) {
        guard !filtered.isEmpty else { return }
        highlighted = max(0, min(index, filtered.count - 1))
        AccessibilityNotification.Announcement(filtered[highlighted].title).post()
    }

    private func runHighlighted() {
        guard filtered.indices.contains(highlighted) else { return }
        close()
        filtered[highlighted].run()
    }
}

/// What's indexed and what isn't, with reasons: opened from the status bar.
struct CoverageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Index Coverage").font(.headline)
            if let stats = app.stats {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("magnifyingglass", "Names", (stats.files + stats.folders).formatted(), "every file and folder in your locations")
                    row("doc.text", "Contents", stats.contentIndexed.formatted(), "files whose text is searchable")
                    if stats.contentPending > 0 {
                        row("hourglass", "Still reading", stats.contentPending.formatted(), "text is being extracted")
                    }
                    row("line.3.horizontal.decrease", "Names only", stats.namesOnly.formatted(), "Library, hidden and build folders (Settings › Contents)")
                    row("icloud", "Cloud-only", stats.cloudOnly.formatted(), "not downloaded, so never opened")
                    if stats.failed > 0 {
                        row("exclamationmark.triangle", "Unreadable", stats.failed.formatted(), "damaged or protected files")
                    }
                    if app.progress.unreadableDirectories > 0 {
                        row("lock", "Locked folders", app.progress.unreadableDirectories.formatted(),
                            app.hasFullDiskAccess ? "no permission" : "need Full Disk Access")
                    }
                    if app.settings.semanticSearchEnabled {
                        row("sparkles", "Meaning", stats.embeddedChunks.formatted(), "passages in the semantic index")
                    }
                }
                .font(.callout)
                Text("Index size \(ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text("Searching: " + app.settings.roots.map(Display.abbreviate).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Rescan Now") { app.rescan() }
                Button("Settings…") { openSettings() }
                if !app.hasFullDiskAccess {
                    Button("Allow Full Disk Access…") { FullDiskAccess.openSystemSettings() }
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 420)
        .onAppear { app.refreshStats() }
    }

    private func row(_ symbol: String, _ title: String, _ value: String, _ note: String) -> some View {
        GridRow {
            Label(title, systemImage: symbol)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing)
            Text(note).foregroundStyle(.secondary).font(.caption)
        }
    }
}
