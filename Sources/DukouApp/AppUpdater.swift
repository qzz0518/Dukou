import Combine
import Foundation
import Sparkle

/// Owns Sparkle for the status menu and the 关于 pane.
///
/// `swift run Dukou` has no assembled Info.plist and therefore no `SUFeedURL`,
/// so starting Sparkle there would only produce an updater error during
/// development. The release bundle carries the feed and starts normally.
///
/// Automatic checks are switched on in Info.plist rather than asked for: the
/// share extension starts this app in the background over WeChat, and
/// Sparkle's permission prompt would otherwise be the first window a new user
/// ever saw from Dukou.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    private let isConfigured: Bool
    private var canCheckObserver: AnyCancellable?

    init(bundle: Bundle = .main) {
        isConfigured = bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        guard isConfigured else { return }
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObserver = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    /// The daily check, as the 通用 pane's switch. Reads false and ignores
    /// writes in an unconfigured build, which is the honest state of a
    /// `swift run` binary with no feed to check.
    var automaticallyChecksForUpdates: Bool {
        get {
            guard isConfigured else { return false }
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            guard isConfigured else { return }
            // Sparkle owns the value; the view only needs to know it moved.
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }
}
