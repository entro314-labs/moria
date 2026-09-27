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

    /// Set by the app delegate; toggles the quick search panel.
    var showQuickPanel: () -> Void = {}
    private var hotKey: HotKey?
    private var lastStatsRefresh = Date.distantPast

    init() throws {
        MaterializationGuard.disableDownloads()
        database = try IndexDatabase()
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

    func refreshAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted
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
            guard let stats else { return "Ready" }
            return "\(count(stats.files + stats.folders)) items indexed"
        }
    }

    var isBusy: Bool { progress.phase != .idle }
}
