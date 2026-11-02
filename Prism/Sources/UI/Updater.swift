import Sparkle
import SwiftUI

/// Sparkle: checks https://prism.mattfalconer.com/appcast.xml once a day and from Check for Updates…,
/// and installs updates signed with the key whose public half is `SUPublicEDKey` in Info.plist.
@Observable
final class Updater {
    static let shared = Updater()

    private(set) var canCheck = false
    @ObservationIgnored private let feed = FeedOverride()
    @ObservationIgnored private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: feed, userDriverDelegate: nil)
    @ObservationIgnored private var observation: NSKeyValueObservation?

    func start() {
        controller.startUpdater()
        // Sparkle changes this on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    func check() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

/// `PRISM_FEED_URL` points a build at a test appcast; normal launches use Info.plist's `SUFeedURL`.
private final class FeedOverride: NSObject, SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["PRISM_FEED_URL"]
    }
}

struct CheckForUpdatesButton: View {
    var body: some View {
        Button("Check for Updates…") { Updater.shared.check() }
            .disabled(!Updater.shared.canCheck)
    }
}
