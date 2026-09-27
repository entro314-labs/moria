import AppKit
import MoriaCore
import SwiftUI

/// Filter sidebar. Filters combine with the query; a filter typed in the query wins.
struct SidebarView: View {
    @Bindable var model: SearchModel
    @State private var customFolders: [String] = []

    private static let kinds: [(FileKind, String)] = [
        (.document, "doc.richtext"), (.pdf, "doc.text"), (.image, "photo"), (.text, "text.alignleft"),
        (.code, "chevron.left.forwardslash.chevron.right"), (.folder, "folder"), (.application, "app"),
        (.audio, "waveform"), (.video, "film"), (.archive, "archivebox"),
    ]

    var body: some View {
        List {
            Section("Kind") {
                ForEach(Self.kinds, id: \.0) { kind, symbol in
                    CheckRow(title: kind.displayName, symbol: symbol, checked: model.filters.kinds.contains(kind)) {
                        if model.filters.kinds.contains(kind) { model.filters.kinds.remove(kind) } else { model.filters.kinds.insert(kind) }
                    }
                }
            }
            Section("Date") {
                Picker("Date", selection: $model.filters.date) {
                    ForEach(FilterState.DatePreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                Picker("Date Field", selection: $model.filters.dateUsesCreation) {
                    Text("Modified").tag(false)
                    Text("Created").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.filters.date == .any)
            }
            Section("Size") {
                Picker("Size", selection: $model.filters.size) {
                    ForEach(FilterState.SizePreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            Section("Location") {
                locationRow(nil, title: "Everywhere", symbol: "globe")
                ForEach(locations, id: \.self) { path in
                    locationRow(path, title: path == NSHomeDirectory() ? "Home" : (path as NSString).lastPathComponent,
                                symbol: symbol(for: path))
                }
                Button("Choose Folder…", systemImage: "plus") { chooseFolder() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Section("Options") {
                Toggle("Hide Library & hidden files", isOn: $model.filters.hideSystemFiles)
                    .toggleStyle(.checkbox)
                Toggle("Hide cloud-only files", isOn: $model.filters.hideCloudOnly)
                    .toggleStyle(.checkbox)
            }
            if model.filters.isActive {
                Button("Reset Filters", systemImage: "arrow.counterclockwise") { model.filters = FilterState() }
                    .buttonStyle(.borderless)
            }
        }
        .listStyle(.sidebar)
    }

    private var locations: [String] {
        let home = NSHomeDirectory()
        var paths = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
        paths += model.app.settings.roots.filter { !paths.contains($0) }
        paths += customFolders.filter { !paths.contains($0) }
        return paths
    }

    private func symbol(for path: String) -> String {
        switch (path as NSString).lastPathComponent {
        case "Desktop": "menubar.dock.rectangle"
        case "Documents": "doc"
        case "Downloads": "arrow.down.circle"
        default: path == NSHomeDirectory() ? "house" : "folder"
        }
    }

    private func locationRow(_ path: String?, title: String, symbol: String) -> some View {
        CheckRow(title: title, symbol: symbol, checked: model.filters.folder == path) {
            model.filters.folder = path
        }
        .help(path.map(Display.abbreviate) ?? "All indexed locations")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Search Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customFolders.append(url.path)
        model.filters.folder = url.path
    }
}

/// A sidebar row that toggles a filter: accent-colored symbol, title, trailing checkmark.
private struct CheckRow: View {
    let title: String
    let symbol: String
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if checked {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}
