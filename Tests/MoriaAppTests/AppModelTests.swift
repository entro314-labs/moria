import Foundation
import Testing
@testable import MoriaApp

/// An app model on a scratch index and its own defaults, so tests never touch the real ones.
@MainActor
func makeAppModel() throws -> (AppModel, UserDefaults) {
    let suite = "moria-app-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(FileManager.default.temporaryDirectory.appending(path: suite + ".sqlite").path, forKey: "indexPath")
    return (try AppModel(defaults: defaults), defaults)
}

@MainActor
struct AppModelTests {
    @Test func chosenSidebarFoldersPersistAndCanBeRemoved() throws {
        let (app, defaults) = try makeAppModel()
        app.addCustomLocation("/Volumes/Archive")
        app.addCustomLocation("/Volumes/Archive")
        app.addCustomLocation("/tmp/Projects")
        #expect(app.customLocations == ["/Volumes/Archive", "/tmp/Projects"])

        // A new model (a relaunch) sees the same folders.
        let reopened = try AppModel(defaults: defaults)
        #expect(reopened.customLocations == ["/Volumes/Archive", "/tmp/Projects"])

        reopened.removeCustomLocation("/Volumes/Archive")
        #expect(try AppModel(defaults: defaults).customLocations == ["/tmp/Projects"])
    }
}

@MainActor
struct SavedSearchTests {
    @Test func deletingASavedSearchCanBeUndoneAndRedone() throws {
        let (app, defaults) = try makeAppModel()
        let names = ["Invoices", "Taxes", "Photos"]
        for name in names {
            app.save(SearchModel.SavedSearch(name: name, text: name.lowercased(), scope: .everything, filters: FilterState()))
        }
        let undo = UndoManager()
        undo.groupsByEvent = false

        undo.beginUndoGrouping()
        app.deleteSavedSearch(app.savedSearches[1].id, undoManager: undo)
        undo.endUndoGrouping()
        #expect(app.savedSearches.map(\.name) == ["Invoices", "Photos"])
        #expect(undo.undoActionName == "Delete Saved Search")

        undo.undo()
        #expect(app.savedSearches.map(\.name) == names)
        // Restored in storage too, not just in memory.
        #expect(try AppModel(defaults: defaults).savedSearches.map(\.name) == names)

        undo.redo()
        #expect(app.savedSearches.map(\.name) == ["Invoices", "Photos"])
    }
}
