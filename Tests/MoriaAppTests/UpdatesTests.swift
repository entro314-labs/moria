import Testing
@testable import MoriaApp

@MainActor
struct UpdatesTests {
    /// Unbundled builds (and tests) have no feed URL: updates are off instead of failing at
    /// every check, and the menu item is hidden.
    @Test func withoutAFeedUpdatesAreOff() {
        let updates = Updates()
        #expect(!updates.isAvailable)
        #expect(!updates.canCheck)
        updates.checksAutomatically = true  // no updater to change; must not crash
    }
}
