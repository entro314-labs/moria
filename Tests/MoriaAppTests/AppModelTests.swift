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
