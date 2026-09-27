import AppKit
import MoriaCore
import Observation
import ServiceManagement

/// App-wide state: the index, its background controller, settings and status.
@Observable
final class AppModel {
    let database: IndexDatabase
    let controller: IndexController
    let engine: SearchEngine

    private(set) var progress = IndexProgress()
    private(set) var settings: MoriaSettings
    private(set) var stats: IndexDatabase.Stats?
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    private(set) var hotKeyError: String?
    var lastError: String?

    var hotKeyChoice: HotKey.Choice {
        didSet {
            UserDefaults.standard.set(hotKeyChoice.rawValue, forKey: "hotKey")
            registerHotKey()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Could not change the login item: \(error.localizedDescription)"
            }
        }
    }

    /// Saved searches shown in the sidebar, like Finder smart folders.
    private(set) var savedSearches: [SearchModel.SavedSearch] = {
        guard let data = UserDefaults.standard.data(forKey: "savedSearches") else { return [] }
        return (try? JSONDecoder().decode([SearchModel.SavedSearch].self, from: data)) ?? []
    }()

    /// Adds a saved search, or replaces the one with the same id in place.
    func save(_ search: SearchModel.SavedSearch) {
        if let index = savedSearches.firstIndex(where: { $0.id == search.id }) {
            savedSearches[index] = search
        } else {
            savedSearches.append(search)
        }
        persistSavedSearches()
    }

    func renameSavedSearch(_ id: UUID, to name: String) {
        guard let index = savedSearches.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        savedSearches[index].name = name
        persistSavedSearches()
    }

    func duplicateSavedSearch(_ id: UUID) {
        guard let original = savedSearches.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name += " copy"
        savedSearches.insert(copy, at: (savedSearches.firstIndex { $0.id == id } ?? savedSearches.count - 1) + 1)
        persistSavedSearches()
    }

    func moveSavedSearches(from source: IndexSet, to destination: Int) {
        savedSearches.move(fromOffsets: source, toOffset: destination)
        persistSavedSearches()
    }

    func deleteSavedSearch(_ id: UUID) {
        savedSearches.removeAll { $0.id == id }
        persistSavedSearches()
    }

    private func persistSavedSearches() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(savedSearches), forKey: "savedSearches")
        } catch {
            lastError = "Saved searches could not be stored: \(error.localizedDescription)"
        }
    }

    /// Set by the app delegate; toggles the quick search panel.
    var showQuickPanel: () -> Void = {}
    private var hotKey: HotKey?
    private var lastStatsRefresh = Date.distantPast

    init() throws {
        MaterializationGuard.disableDownloads()
        // `-indexPath <file>` opens a different index (development and testing).
        let path = UserDefaults.standard.string(forKey: "indexPath")
        database = try IndexDatabase(url: path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? IndexDatabase.defaultURL)
        controller = try IndexController(database: database)
        engine = SearchEngine(database: database)
        settings = try database.loadSettings()
        hotKeyChoice = UserDefaults.standard.string(forKey: "hotKey").flatMap(HotKey.Choice.init) ?? .controlOptionSpace
    }

    func start() {
        hotKey = HotKey { [weak self] in self?.showQuickPanel() }
        registerHotKey()
        Task {
            var lastUpdate = Date.distantPast
            for await progress in controller.progress {
                // The indexer reports per batch; four UI updates a second are plenty.
                let phaseChanged = progress.phase != self.progress.phase
                guard phaseChanged || Date().timeIntervalSince(lastUpdate) > 0.25 else { continue }
                lastUpdate = Date()
                self.progress = progress
                if let error = progress.lastError { lastError = error }
                if progress.phase == .idle || Date().timeIntervalSince(lastStatsRefresh) > 10 {
                    refreshStats()
                }
            }
        }
        Task {
            do {
                try await controller.start()
            } catch {
                lastError = "Indexing could not start: \(error)"
            }
        }
        if settings.naturalLanguageQueriesEnabled { NaturalLanguageQuery.prewarm() }
        refreshStats()
    }

    /// Re-checks Full Disk Access; when it has just been granted, rescans so folders that were
    /// unreadable during the first crawl (Mail, Messages, …) get indexed.
    func refreshAccess() {
        let granted = FullDiskAccess.isGranted
        if granted, !hasFullDiskAccess { rescan() }
        hasFullDiskAccess = granted
    }

    func refreshStats() {
        lastStatsRefresh = Date()
        let database = database
        Task.detached(priority: .utility) {
            let stats = try? database.stats()
            await MainActor.run { self.stats = stats }
        }
    }

    func update(_ transform: (inout MoriaSettings) -> Void) {
        var new = settings
        transform(&new)
        guard new != settings else { return }
        let enabledNL = new.naturalLanguageQueriesEnabled && !settings.naturalLanguageQueriesEnabled
        settings = new
        if enabledNL { NaturalLanguageQuery.prewarm() }
        Task {
            do {
                try await controller.updateSettings(new)
            } catch {
                lastError = "Settings could not be saved: \(error)"
            }
        }
    }

    func rescan() {
        Task { await controller.requestFullScan() }
    }

    func setPaused(_ paused: Bool) {
        progress.isPaused = paused
        Task { await controller.setPaused(paused) }
    }

    /// Asks before erasing the index; rebuilding reads every file again.
    func confirmRebuild() {
        let alert = NSAlert()
        alert.messageText = "Rebuild the index?"
        alert.informativeText = "Moria will forget everything it has indexed and read all files again. Searching works again as soon as names are scanned; contents take longer. Settings and saved searches are kept."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await controller.rebuild() }
    }

    private func registerHotKey() {
        do {
            try hotKey?.register(hotKeyChoice)
            hotKeyError = nil
        } catch {
            hotKeyError = String(describing: error)
        }
    }

    /// One-line description of what the indexer is doing, for the status bar and menu.
    var statusText: String {
        let count = { (n: Int) in n.formatted(.number) }
        switch progress.phase {
        case .scanning: return "Scanning… \(count(progress.scannedEntries)) items"
        case .updating: return "Applying changes…"
        case .extracting: return "Reading contents… \(count(progress.remainingFiles)) left"
        case .recognizingText: return "Recognizing text in images… \(count(progress.remainingFiles)) left"
        case .embedding: return "Building semantic index… \(count(progress.embeddedFiles)) done"
        case .idle:
            if progress.isPaused { return "Indexing paused" }
            guard let stats else { return "Ready" }
            return "\(count(stats.files + stats.folders)) items indexed"
        }
    }

    var isBusy: Bool { progress.phase != .idle }
}
