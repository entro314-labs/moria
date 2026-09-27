import AppKit
import MoriaCore
import SwiftUI

/// Source-list sidebar: where to look, not a form. Home, one-click collections, saved
/// searches and locations, each with a live count.
struct SidebarView: View {
    @Bindable var model: SearchModel
    @State private var customFolders: [String] = []
    @State private var renaming: SearchModel.SavedSearch?
    @State private var newName = ""

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Label("Home", systemImage: "house")
                .tag(SidebarItem.home)

            Section("Collections") {
                ForEach(Collection.all) { collection in
                    row(collection.name, collection.symbol, count: model.counts[.collection(collection.name)])
                        .tag(SidebarItem.collection(collection.name))
                        .help(collection.query)
                }
            }

            if !model.app.savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(model.app.savedSearches) { saved in
                        row(saved.name, saved.scope == .regex ? "asterisk.circle" : "magnifyingglass.circle",
                            count: model.counts[.saved(saved.id)])
                            .tag(SidebarItem.saved(saved.id))
                            .help(saved.text.isEmpty ? saved.scope.rawValue : saved.text)
                            .contextMenu {
                                Button("Edit…") {
                                    if saved.scope == .regex {
                                        model.apply(saved)
                                        model.showRegexBuilder = true
                                    } else {
                                        model.editingSaved = saved
                                        model.showCriteria = true
                                    }
                                }
                                Button("Rename…") { renaming = saved; newName = saved.name }
                                Button("Duplicate") { model.app.duplicateSavedSearch(saved.id) }
                                Divider()
                                Button("Delete", role: .destructive) { model.app.deleteSavedSearch(saved.id) }
                            }
                    }
                    .onMove { model.app.moveSavedSearches(from: $0, to: $1) }
                }
            }

            Section("Locations") {
                ForEach(locations, id: \.self) { path in
                    Label(title(for: path), systemImage: symbol(for: path))
                        .tag(SidebarItem.location(path))
                        .help(Display.abbreviate(path))
                }
                Button("Choose Folder…", systemImage: "plus") { chooseFolder() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .onAppear { model.loadHome() }
        .onChange(of: model.app.savedSearches) { model.loadHome() }
        .alert("Rename Saved Search", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.app.renameSavedSearch(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ symbol: String, count: Int?) -> some View {
        Label(title, systemImage: symbol)
            .badge(count.map { $0 >= 1000 ? Text("999+") : Text($0.formatted()) })
    }

    private var locations: [String] {
        let home = NSHomeDirectory()
        var paths = model.app.settings.roots
        for name in ["Desktop", "Documents", "Downloads"] where !paths.contains(home + "/" + name) {
            paths.append(home + "/" + name)
        }
        return paths + customFolders.filter { !paths.contains($0) }
    }

    private func title(for path: String) -> String {
        path == NSHomeDirectory() ? "Home Folder" : FileManager.default.displayName(atPath: path)
    }

    private func symbol(for path: String) -> String {
        switch (path as NSString).lastPathComponent {
        case "Desktop": "menubar.dock.rectangle"
        case "Documents": "doc"
        case "Downloads": "arrow.down.circle"
        default: path == NSHomeDirectory() ? "person.crop.square" : "folder"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Search Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customFolders.append(url.path)
        model.sidebarSelection = .location(url.path)
    }
}
