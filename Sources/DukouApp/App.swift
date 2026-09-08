import AppKit
import Combine
import DukouCore
import SwiftUI

/// A menu bar app with one on-demand window.
///
/// `LSUIElement` keeps Dukou out of the Dock: it is a resident receiver, and the
/// share extension launches it in the background where a bouncing Dock icon
/// would be noise. The one window it does have is real, user-visible
/// functionality of its own, and AppKit — not SwiftUI — decides when it appears.
@main
struct DukouMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// An empty placeholder: `App` requires a scene, and Dukou's one window is
    /// opened by `SettingsWindowController` instead. An accessory app never owns
    /// a menu bar, so this scene is unreachable and draws nothing.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences: Preferences
    let model: AppModel
    let loginItem = LoginItem()
    let authorization = AccessibilityAuthorization()
    let settingsRouter = SettingsRouter()
    let forwardTargets = ForwardTargets()
    /// Started only in a real bundle — see `AppUpdater`.
    let updater = AppUpdater()
    private(set) var shelfController: ShelfController?
    private var actionRunner: ActionRunner?
    private var wechat: WeChatQuickForward?
    private var moments: MomentsQuickForward?
    private var statusItem: StatusItemController?
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: SettingsWindowController?
    private var pendingSettingsTab: SettingsTab?
    private var onboardingWindow: OnboardingWindowController?

    /// The model reads the retention window straight off the preferences, so the
    /// two are built together rather than wired up later — a prune that ran
    /// before the preference arrived would use the wrong window exactly once,
    /// on the launch where it does the most damage.
    override init() {
        let preferences = Preferences()
        self.preferences = preferences
        model = AppModel(preferences: preferences)
        super.init()
    }

    /// Handed to the settings window so a pane can reach the shelf and the
    /// action runner without holding either of them.
    var settingsActions: SettingsActions {
        SettingsActions(
            perform: { [weak self] action, target, urls in
                self?.forward(ArrivedBatch(action: action, target: target, urls: urls))
            },
            showShelf: { [weak self] in self?.shelfController?.show() },
            showEntries: { [weak self] in self?.openMainWindow(.entries) },
            // Forgetting the dragged position is the whole gesture; docking back
            // to the chosen corner is a consequence of it.
            forgetShelfAnchor: { [weak self] in self?.shelfController?.forgetDraggedPosition() },
            // The counter is reset here, not only on 完成: a guide that was
            // re-run and then closed at 权限 leaves it at 2, and the next
            // 重新运行 would resume rather than run.
            restartOnboarding: { [weak self] in
                self?.preferences.onboardingStep = 0
                self?.onboardingWindow?.show()
            }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would race for the same inbox and stack two shelves on
        // screen. The one already running wins.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0 != .current }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        // Redundant when LSUIElement is set, and necessary for `swift run`,
        // which has no Info.plist at all.
        NSApp.setActivationPolicy(.accessory)

        let shelf = ShelfController(model: model, preferences: preferences, targets: forwardTargets)
        let runner = ActionRunner(
            model: model,
            shelf: shelf,
            authorization: authorization,
            targets: forwardTargets,
            preferences: preferences
        )
        shelf.perform = { [weak self] in self?.forward($0) }
        shelf.openEntries = { [weak self] in self?.openMainWindow(.entries) }
        runner.openEntries = { [weak self] in self?.openMainWindow(.entries) }
        shelfController = shelf
        actionRunner = runner
        let wechat = WeChatQuickForward(
            model: model, shelf: shelf, runner: runner, authorization: authorization, preferences: preferences
        )
        wechat.openSettings = { [weak self] tab in self?.openMainWindow(tab) }
        self.wechat = wechat
        let moments = MomentsQuickForward(
            model: model, shelf: shelf, runner: runner, authorization: authorization, preferences: preferences
        )
        moments.openSettings = { [weak self] tab in self?.openMainWindow(tab) }
        self.moments = moments
        wechat.otherAutomationIsBusy = { [weak moments] in moments?.isBusy ?? false }
        moments.otherAutomationIsBusy = { [weak wechat] in (wechat?.isBusy ?? false) || (wechat?.isReadingChat ?? false) }
        runner.reservedFrame = { [weak wechat, weak moments] in moments?.hudFrame ?? wechat?.hudFrame }

        // One place decides what an arriving batch means; the shelf and the
        // forwards are both just outcomes of it.
        model.didArrive
            .receive(on: RunLoop.main)
            .sink { [weak self] arrival in self?.forward(arrival) }
            .store(in: &cancellables)

        // The share extension has no screen of its own (ADR-0005). What it
        // could not do is said here, in the app, on the same capsule every
        // other failure uses.
        model.didFailToReceive
            .receive(on: RunLoop.main)
            .sink { [weak runner] failure in runner?.report(failure) }
            .store(in: &cancellables)

        settingsWindow = SettingsWindowController(router: settingsRouter) { [unowned self] in
            SettingsView(
                model: model,
                preferences: preferences,
                loginItem: loginItem,
                authorization: authorization,
                router: settingsRouter,
                forwardTargets: forwardTargets,
                wechat: wechat,
                moments: moments,
                updater: updater,
                actions: settingsActions
            )
        }

        onboardingWindow = OnboardingWindowController { [unowned self] in
            OnboardingFlow(
                preferences: preferences,
                authorization: authorization,
                finish: { [weak self] in self?.finishOnboarding() }
            )
        }

        statusItem = StatusItemController(
            model: model, shelf: shelf, wechat: wechat, updater: updater,
            openSettings: { [weak self] tab in self?.openMainWindow(tab) }
        )
        model.start()
        model.reload()
        if let tab = pendingSettingsTab {
            pendingSettingsTab = nil
            openMainWindow(tab)
        } else if !preferences.onboardingCompleted, !Self.launchedInBackground {
            // A person's first launch — Finder, Launchpad, Spotlight — gets the
            // guide at once. Nothing else would happen: an accessory app is not
            // activated by the system, so without this a fresh install put a
            // menu bar icon on screen and nothing that said what to do with it.
            onboardingWindow?.show()
        }
    }

    /// The share extension says so when it is the one starting the app
    /// (`LaunchArgument.background`): the user is in WeChat at that moment, and
    /// a window over it would undo the point of an extension with no screen.
    private static let launchedInBackground = CommandLine.arguments.contains(LaunchArgument.background)

    /// First-run guidance waits for the user to actually bring Dukou forward.
    /// The share extension launches this app in the background on purpose, and
    /// throwing a window over WeChat at that moment would undo the point of it.
    ///
    /// Measured: this does not fire on launch. macOS never activates an
    /// `LSUIElement` app by itself, so `open Dukou.app` and a double click in
    /// Finder both leave it inactive — which is why `openMainWindow` carries the
    /// same first-run rule for the path a menu bar app actually has.
    func applicationDidBecomeActive(_ notification: Notification) {
        loginItem.refresh()
        guard !preferences.onboardingCompleted else { return }
        onboardingWindow?.show()
    }

    /// Only finishing the guide counts as having done it. Closing its window at
    /// step 3 is not an answer, so it comes back on the next activation — and
    /// the step counter goes back to the start, because 重新运行设置向导 means
    /// run it, not resume it.
    ///
    /// 设置 opens as the guide closes. The guide only switched on entries and
    /// asked for one permission; a new user's next questions — 停靠位置, 附加
    /// Prompt, 微信转发 — all live there, and a window that simply vanished
    /// left them with a menu bar icon they had not yet learned to look for.
    private func finishOnboarding() {
        preferences.onboardingCompleted = true
        preferences.onboardingStep = 0
        onboardingWindow?.close()
        openMainWindow(.general)
    }

    /// One door for every forward, wherever it was asked for: an arriving batch,
    /// the shelf's 发给 ▸ menu, 记录's. Remembering the target here rather than
    /// in `ActionRunner` keeps the runner ignorant of the user's list — it only
    /// ever needs the one app it is about to activate.
    private func forward(_ arrival: ArrivedBatch) {
        if let target = arrival.target { forwardTargets.recordUse(target) }
        actionRunner?.handle(arrival)
    }

    /// A `dukou://` URL. Nothing in this tree sends one any more — the share
    /// panel that did is gone — but the scheme stays registered and routed as
    /// the app's front door onto a settings pane. `AppLink` explains why.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == AppLink.scheme {
            // An unknown path still opens the window: the user asked for Dukou,
            // and silence would look like the button did nothing.
            openMainWindow(AppLink.settingsPath(of: url).flatMap(SettingsTab.init(rawValue:)))
        }
    }

    /// Closing the window must not quit a menu bar app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A reopen only counts when a person performed it.
    ///
    /// Measured 2026-09-05 on the signed build: the share extension starts the
    /// app with `NSWorkspace.openApplication(activates: false)`, and AppKit
    /// delivers that to an *already running* app as a reopen — so every share
    /// into a running Dukou put the 780 × 560 settings window on screen over
    /// WeChat. Window count went 1 → 2 on a bare `open -g`. The extension's
    /// reopen leaves the app inactive; a double click in Finder or a click on
    /// the Dock icon activates it first, which is the difference this reads.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if sender.isActive, !hasVisibleWindows { openMainWindow() }
        return true
    }

    /// Until the guide has been finished it is the app's front door, whatever
    /// pane was asked for.
    ///
    /// Not a preference for the guide over the settings window so much as a
    /// refusal to show both: measured, `SettingsWindowController.show` has to
    /// call `NSApp.activate` — an accessory app is never activated by the
    /// system — which fires `applicationDidBecomeActive`, which on a first run
    /// opens the guide. Letting a named pane through would therefore have put
    /// two windows on screen for one click, not one.
    ///
    /// This is also where a real first run lands: macOS never activates an
    /// `LSUIElement` app by itself, so 设置… in the status menu, and not the
    /// activation notification, is what a new user actually reaches Dukou with.
    func openMainWindow(_ tab: SettingsTab? = nil) {
        guard settingsWindow != nil else {
            pendingSettingsTab = tab ?? .general
            return
        }
        guard preferences.onboardingCompleted else {
            onboardingWindow?.show()
            return
        }
        settingsWindow?.show(tab)
    }
}
