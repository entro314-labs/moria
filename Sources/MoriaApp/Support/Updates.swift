import Combine
import Foundation
import Observation
import Sparkle
import SwiftUI

/// Software updates through Sparkle, from the feed in `SUFeedURL` (the latest GitHub release's
/// `appcast.xml`). Updates are signed with the key whose public half is `SUPublicEDKey`.
///
/// Builds without a feed URL (unbundled development runs) have updates turned off rather than
/// failing: Sparkle would report a missing feed at every check.
@Observable
final class Updates {
    private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: Set<AnyCancellable> = []

    /// A check can start now (not while one is already running).
    private(set) var canCheck = false

    var isAvailable: Bool { controller != nil }

    /// Checks in the background on Sparkle's schedule (daily). Sparkle asks at the second
    /// launch and sets this itself; the toggle in Settings follows it.
    var checksAutomatically = false {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in if self?.checksAutomatically != $0 { self?.checksAutomatically = $0 } }
            .store(in: &observations)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Moria › Check for Updates…, after About.
struct UpdateCommands: View {
    let updates: Updates

    var body: some View {
        if updates.isAvailable {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
        }
    }
}
