import AppKit
import MoriaCore
import SwiftUI

struct SettingsView: View {
    /// HIG: Settings reopens on the last pane viewed.
    @AppStorage("settingsPane") private var pane = "general"

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Locations", systemImage: "folder", value: "locations") { LocationSettings() }
            Tab("Contents", systemImage: "doc.text", value: "contents") { ContentSettings() }
            Tab("Intelligence", systemImage: "sparkles", value: "intelligence") { IntelligenceSettings() }
            Tab("Index", systemImage: "externaldrive", value: "index") { IndexSettings() }
        }
        .frame(width: 620, height: 500)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(Updates.self) private var updates
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("defaultScope") private var defaultScope = SearchScope.everything.rawValue

    var body: some View {
        @Bindable var app = app
        @Bindable var updates = updates
        Form {
            Section {
                Picker("Quick search shortcut", selection: $app.hotKeyChoice) {
                    ForEach(HotKey.Choice.allCases) { Text($0.label).tag($0) }
                }
                if let error = app.hotKeyError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Toggle("Open at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.launchAtLogin = $0 }))
                if updates.isAvailable {
                    Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                }
                Toggle("Show in menu bar", isOn: $showMenuBarExtra)
                Toggle("Show in Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) {
                        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
                        if !showDockIcon { showMenuBarExtra = true }  // keep a way back to the app
                    }
                    .disabled(!showMenuBarExtra && showDockIcon)
                Picker("New searches look in", selection: $defaultScope) {
                    ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            } footer: {
                Text("Moria keeps its index current in the background while it's running.")
            }
            Section("Privacy") {
                LabeledContent("Full Disk Access") {
                    if app.hasFullDiskAccess {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Privacy Settings…") { FullDiskAccess.openSystemSettings() }
                    }
                }
                Text("Without Full Disk Access, Mail, Messages, Safari and other protected app data can't be searched, and macOS asks separately for Desktop, Documents and Downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Locations

private struct LocationSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                PathList(paths: app.settings.roots, addTitle: "Add Folder…") { roots in app.update { $0.roots = roots } }
            } header: {
                Text("Search in")
            } footer: {
                Text("Every file and folder under these locations is indexed by name, including hidden ones.")
            }
            Section {
                PathList(paths: app.settings.excludedPaths, addTitle: "Exclude Folder…") { paths in app.update { $0.excludedPaths = paths } }
                NameList(names: app.settings.excludedNames) { names in app.update { $0.excludedNames = names } }
            } header: {
                Text("Skip entirely")
            } footer: {
                Text("Skipped folders are not indexed at all. Names match anywhere, e.g. node_modules.")
            }
            Section {
                Toggle("Include hidden files", isOn: binding(\.includeHidden))
                Toggle("Look inside packages (apps, photo libraries)", isOn: binding(\.descendIntoPackages))
            }
            Section {
                Button("Restore Default Locations") {
                    let defaults = MoriaSettings.defaults()
                    app.update {
                        $0.roots = defaults.roots
                        $0.excludedPaths = defaults.excludedPaths
                        $0.excludedNames = defaults.excludedNames
                        $0.includeHidden = defaults.includeHidden
                        $0.descendIntoPackages = defaults.descendIntoPackages
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ keyPath: WritableKeyPath<MoriaSettings, Bool>) -> Binding<Bool> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { value in app.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Contents

private struct ContentSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                Toggle("Recognize text in images", isOn: binding(\.ocrImages))
                Toggle("Recognize text in scanned PDFs", isOn: binding(\.ocrScannedPDFs))
                Toggle("Recognize what photos show", isOn: binding(\.imageLabels))
                    .help("Words like “beach”, “receipt” or “dog” find the photos that show them.")
                Toggle("Read files inside hidden folders", isOn: binding(\.extractHiddenContent))
                Stepper("Text kept per file: \(app.settings.maxContentKilobytes) KB",
                        value: intBinding(\.maxContentKilobytes), in: 32...4096, step: 32)
                Stepper("Skip files larger than \(app.settings.maxFileMegabytes) MB",
                        value: intBinding(\.maxFileMegabytes), in: 10...2000, step: 10)
            } footer: {
                Text("Text recognition runs after all other files are read, a few images per second.")
            }
            Section {
                PathList(paths: app.settings.contentExcludedPaths, addTitle: "Add Folder…") { paths in
                    app.update { $0.contentExcludedPaths = paths }
                }
                NameList(names: app.settings.contentExcludedNames) { names in app.update { $0.contentExcludedNames = names } }
                Button("Restore Defaults") {
                    let defaults = MoriaSettings.defaults()
                    app.update {
                        $0.contentExcludedPaths = defaults.contentExcludedPaths
                        $0.contentExcludedNames = defaults.contentExcludedNames
                        $0.extractHiddenContent = defaults.extractHiddenContent
                        $0.maxContentKilobytes = defaults.maxContentKilobytes
                        $0.maxFileMegabytes = defaults.maxFileMegabytes
                        $0.ocrImages = defaults.ocrImages
                        $0.ocrScannedPDFs = defaults.ocrScannedPDFs
                        $0.imageLabels = defaults.imageLabels
                    }
                }
                .controlSize(.small)
            } header: {
                Text("Names only (don't read contents)")
            } footer: {
                Text("Dependencies and build output are found by name; Regex search still reads their text and code.")
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ keyPath: WritableKeyPath<MoriaSettings, Bool>) -> Binding<Bool> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { value in app.update { $0[keyPath: keyPath] = value } })
    }

    private func intBinding(_ keyPath: WritableKeyPath<MoriaSettings, Int>) -> Binding<Int> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { value in app.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Intelligence

private struct IntelligenceSettings: View {
    @Environment(AppModel.self) private var app
    @State private var embeddable: Int?

    var body: some View {
        Form {
            Section {
                Toggle("Ask in plain language", isOn: binding(\.naturalLanguageQueriesEnabled))
                    .disabled(!NaturalLanguageQuery.isAvailable)
                if !NaturalLanguageQuery.isAvailable {
                    Label("Apple Intelligence isn't available on this Mac.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Adds an Ask button. The on-device model turns a request like “invoices from last spring over 1 MB” into filters you can review and edit. Nothing leaves your Mac.")
            }
            Section {
                Toggle("Search by meaning", isOn: binding(\.semanticSearchEnabled))
                if let embeddable, !app.settings.semanticSearchEnabled {
                    // Each document takes ~10 ms to embed and up to 4 KB of index and memory.
                    let minutes = max(1, embeddable / 100 / 60)
                    Label("Covers \(embeddable.formatted()) documents: about \(minutes.formatted()) min of background work and \(ByteCountFormatter.string(fromByteCount: Int64(embeddable) * 4096, countStyle: .memory)) of index kept in memory while searching.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if app.settings.semanticSearchEnabled, let stats = app.stats {
                    LabeledContent("Indexed passages", value: stats.embeddedChunks.formatted())
                }
            } footer: {
                Text("Adds a Meaning toggle that also finds documents related to your words, using Apple's on-device language model. Covers documents, PDFs, notes and recognized text in Latin-script languages (English, French, German, …). Greek and other scripts are still found by words. Turning it off deletes the semantic index.")
            }
        }
        .formStyle(.grouped)
        .task {
            let database = app.database
            embeddable = await Task.detached(priority: .utility) { try? database.embeddableCount() }.value
        }
    }

    private func binding(_ keyPath: WritableKeyPath<MoriaSettings, Bool>) -> Binding<Bool> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { value in app.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Index

private struct IndexSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Activity") {
                    HStack {
                        if app.isBusy { ProgressView().controlSize(.small) }
                        Text(app.statusText)
                    }
                }
                if let stats = app.stats {
                    LabeledContent("Files", value: stats.files.formatted())
                    LabeledContent("Folders", value: stats.folders.formatted())
                    LabeledContent("Contents indexed", value: stats.contentIndexed.formatted())
                    LabeledContent("Waiting to be read", value: stats.contentPending.formatted())
                    LabeledContent("Names only (Contents settings)", value: stats.namesOnly.formatted())
                    LabeledContent("Cloud-only (names only)", value: stats.cloudOnly.formatted())
                    LabeledContent("Couldn't be read", value: stats.failed.formatted())
                    LabeledContent("Index size", value: ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file))
                }
                if let date = app.progress.lastScanDate {
                    LabeledContent("Last full scan", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if app.progress.unreadableDirectories > 0 {
                    LabeledContent("Unreadable folders", value: app.progress.unreadableDirectories.formatted())
                }
            }
            Section {
                HStack {
                    Button(app.progress.isPaused ? "Resume Indexing" : "Pause Indexing") { app.setPaused(!app.progress.isPaused) }
                    Button("Rescan Now") { app.rescan() }
                    Button("Rebuild Index…") { app.confirmRebuild() }
                    Spacer()
                    Button("Show in Finder") { FileActions.reveal([app.database.url]) }
                }
            } footer: {
                Text("Moria follows file changes as they happen; a rescan is only needed if something looks out of date. Rebuilding erases the index and reads everything again.")
            }
        }
        .formStyle(.grouped)
        .onAppear { app.refreshStats() }
    }
}

// MARK: - Editable lists

private struct PathList: View {
    let paths: [String]
    let addTitle: String
    let onChange: ([String]) -> Void
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(paths, id: \.self, selection: $selection) { path in
                Label(Display.abbreviate(path), systemImage: "folder")
            }
            .frame(minHeight: 70, maxHeight: 120)
            HStack {
                Button(addTitle) { add() }
                Button("Remove") {
                    if let selection { onChange(paths.filter { $0 != selection }) }
                    selection = nil
                }
                .disabled(selection == nil)
            }
            .controlSize(.small)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        onChange(paths + panel.urls.map(\.path).filter { !paths.contains($0) })
    }
}

private struct NameList: View {
    let names: [String]
    let onChange: ([String]) -> Void
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        TextField("Folder names (comma-separated)", text: $text)
            .focused($editing)
            .onAppear { text = names.joined(separator: ", ") }
            // Restore Defaults (or `moria config`) changes the names while the field shows the
            // old ones; follow them, unless an edit is under way.
            .onChange(of: names) { if !editing { text = names.joined(separator: ", ") } }
            .onSubmit(commit)
            // Leaving the field keeps the edit too, as the other controls in the pane do.
            .onChange(of: editing) { if !editing { commit() } }
    }

    private func commit() {
        let edited = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if edited != names { onChange(edited) }
    }
}
