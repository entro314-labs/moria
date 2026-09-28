import MoriaCore
import SwiftUI

/// Criteria builder (⇧⌘F): rows of attribute / operator / value. It edits the same query text
/// as the search field, so anything built here can be typed, saved or tweaked by hand.
struct CriteriaBuilderView: View {
    let model: SearchModel
    /// When editing a saved search, saving updates it instead of creating a new one.
    var editing: SearchModel.SavedSearch?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var rows: [Criterion] = []
    @State private var count: Int?
    @State private var countFailed = false
    @State private var name = ""
    @State private var askingName = false

    private var query: String { Criterion.query(from: rows) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(editing.map { "Edit “\($0.name)”" } ?? "Find items where all of these match")
                    .font(.headline)
                Spacer()
                Text(countText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rows) { $row in
                        CriterionRow(criterion: $row, roots: app.settings.roots, canRemove: rows.count > 1) {
                            rows.removeAll { $0.id == row.id }
                        } add: {
                            let index = rows.firstIndex { $0.id == row.id }.map { $0 + 1 } ?? rows.count
                            rows.insert(Criterion(attribute: .name), at: index)
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(minHeight: 160, maxHeight: 420)

            VStack(alignment: .leading, spacing: 6) {
                Text("Query").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(query.isEmpty ? "—" : query)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(18)

            Divider()
            HStack {
                Button("Add Criterion", systemImage: "plus") { rows.append(Criterion(attribute: .name)) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Save…" : "Save Changes") {
                    if let editing {
                        // The builder edits the text; the saved search's filters and mode stay.
                        app.save(SearchModel.SavedSearch(id: editing.id, name: editing.name, text: query,
                                                         scope: editing.scope, filters: editing.filters))
                        dismiss()
                    } else {
                        name = ""
                        askingName = true
                    }
                }
                .disabled(query.isEmpty)
                Button("Search") {
                    if let editing {
                        // The edited search as it would be saved: its own mode and filters.
                        model.apply(SearchModel.SavedSearch(id: editing.id, name: editing.name, text: query,
                                                            scope: editing.scope, filters: editing.filters))
                    } else {
                        // Criteria are query text, not a pattern or a request; other modes and
                        // the chosen filters stay.
                        if model.mode == .regex || model.mode == .ask { model.mode = .everything }
                        model.text = query
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 760)
        .onAppear {
            let source = editing?.text ?? model.text
            rows = Criterion.criteria(from: source)
            if rows.isEmpty { rows = [Criterion(attribute: .words)] }
        }
        .task(id: query) { await updateCount() }
        .alert("Save Search", isPresented: $askingName) {
            TextField("Name", text: $name)
            Button("Save") {
                let scope = model.scope == .regex ? .everything : model.scope
                app.save(SearchModel.SavedSearch(name: name.isEmpty ? query : name, text: query, scope: scope, filters: model.filters))
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var countText: String {
        if countFailed { return "Couldn't count matches" }
        guard let count else { return query.isEmpty ? "" : "Counting…" }
        return count >= 1000 ? "1,000+ matches" : "\(count.formatted()) match\(count == 1 ? "" : "es")"
    }

    private func updateCount() async {
        countFailed = false
        guard !query.isEmpty else { count = nil; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        // Counted as Search would run it: in the saved search's mode and filters when editing,
        // else in the window's.
        let scope = editing?.scope ?? model.scope
        let filters = editing?.filters ?? model.filters
        do {
            let result = try await app.engine.search(model.query(for: query, scope: scope, filters: filters), limit: 1000).count
            guard !Task.isCancelled else { return }
            withAnimation { count = result }
        } catch {
            guard !Task.isCancelled else { return }
            count = nil
            countFailed = true
        }
    }
}

/// One criterion: attribute and operator menus, then the value control that fits them.
private struct CriterionRow: View {
    @Binding var criterion: Criterion
    let roots: [String]
    let canRemove: Bool
    let remove: () -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Attribute", selection: attribute) {
                ForEach(Criterion.Attribute.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170, alignment: .leading)
            Picker("Operator", selection: $criterion.op) {
                ForEach(criterion.attribute.operators, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .frame(width: 160, alignment: .leading)
            valueControl
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove", systemImage: "minus.circle.fill", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!canRemove)
            Button("Add", systemImage: "plus.circle.fill", action: add)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    /// Changing the attribute resets the operator and value to ones that fit.
    private var attribute: Binding<Criterion.Attribute> {
        Binding {
            criterion.attribute
        } set: { newValue in
            guard newValue != criterion.attribute else { return }
            criterion = Criterion(attribute: newValue, value: newValue == .kind ? FileKind.document.rawValue : "")
        }
    }

    @ViewBuilder
    private var valueControl: some View {
        switch criterion.attribute {
        case .hidden, .cloud:
            EmptyView()
        case .kind:
            Picker("Kind", selection: $criterion.value) {
                ForEach(FileKind.allCases.filter { $0 != .other }, id: \.self) { Text($0.displayName).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
        case .folder:
            HStack {
                TextField("Folder", text: $criterion.value)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { criterion.value = Volumes.canonicalPath(url.path) ?? url.path }
                }
            }
        case .similar:
            HStack {
                TextField("File", text: $criterion.value)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url { criterion.value = Volumes.canonicalPath(url.path) ?? url.path }
                }
            }
        case .size:
            HStack {
                TextField("Size", text: $criterion.value).frame(width: 70)
                if criterion.op == .between {
                    Text("and")
                    TextField("Size", text: $criterion.value2).frame(width: 70)
                }
                Picker("Unit", selection: $criterion.unit) {
                    Text("KB").tag("kb")
                    Text("MB").tag("mb")
                    Text("GB").tag("gb")
                }
                .labelsHidden()
                .fixedSize()
            }
        case .duration:
            HStack {
                TextField("Length", text: $criterion.value).frame(width: 70)
                if criterion.op == .between {
                    Text("and")
                    TextField("Length", text: $criterion.value2).frame(width: 70)
                }
                Picker("Unit", selection: $criterion.unit) {
                    Text("seconds").tag("s")
                    Text("minutes").tag("m")
                    Text("hours").tag("h")
                }
                .labelsHidden()
                .fixedSize()
            }
        case .modified, .created, .taken:
            switch criterion.op {
            case .withinLast:
                HStack {
                    TextField("Amount", text: $criterion.value).frame(width: 60)
                    Picker("Unit", selection: $criterion.unit) {
                        Text("days").tag("d")
                        Text("weeks").tag("w")
                        Text("months").tag("m")
                        Text("years").tag("y")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            case .between:
                HStack {
                    DateField(text: $criterion.value)
                    Text("and")
                    DateField(text: $criterion.value2)
                }
            default:
                DateField(text: $criterion.value)
            }
        case .ext:
            TextField("pdf, docx", text: $criterion.value)
        case .name where criterion.op == .matchesRegex:
            TextField("Regular expression", text: $criterion.value)
                .font(.system(.body, design: .monospaced))
        default:
            TextField("Text", text: $criterion.value)
        }
    }
}

/// A date picker bound to a `yyyy-MM-dd` string. A whole month or year (`2026-03`, `2025`,
/// from typed queries) stays a text field, since a date picker can only show one day.
private struct DateField: View {
    @Binding var text: String

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        if text.range(of: #"^\d{4}(-\d{2})?$"#, options: .regularExpression) != nil {
            TextField("yyyy-MM", text: $text)
                .frame(width: 90)
        } else {
            DatePicker("Date", selection: Binding(
                get: { Self.formatter.date(from: text) ?? Date() },
                set: { text = Self.formatter.string(from: $0) }
            ), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.field)
            .onAppear { if text.isEmpty { text = Self.formatter.string(from: Date()) } }
        }
    }
}
