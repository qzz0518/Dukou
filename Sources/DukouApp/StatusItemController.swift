import AppKit
import Combine
import DukouCore

/// The menu bar item: the only part of Dukou that is always on screen when the
/// shelf is empty.
///
/// The menu is handed to `NSStatusItem`, which is what makes left click, right
/// click and ⌃click all open it. Doing something else on left click meant the
/// one gesture everybody tries first led nowhere near the settings or the
/// history — and worse, toggling the shelf from here contradicted a shelf whose
/// visibility is supposed to mean "there is still something on it".
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Ten batches is about a screen of menu. Beyond that the submenu stops
    /// being a shortcut and 全部记录… is the better answer.
    private static let recentLimit = 10

    private let statusItem: NSStatusItem
    private let model: AppModel
    private let shelf: ShelfController
    private let wechat: WeChatQuickForward
    private let updater: AppUpdater
    private let openSettings: (SettingsTab) -> Void
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var lastLoaded: Bool?

    init(
        model: AppModel,
        shelf: ShelfController,
        wechat: WeChatQuickForward,
        updater: AppUpdater,
        openSettings: @escaping (SettingsTab) -> Void
    ) {
        self.model = model
        self.shelf = shelf
        self.wechat = wechat
        self.updater = updater
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // Without this AppKit re-enables every item through the responder chain,
        // and 清空暂存架 would stay clickable on an empty shelf.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        statusItem.button?.toolTip = "Dukou"

        // Counted, not just emptiness: a second share landing on a shelf that
        // already held one leaves `isEmpty` unchanged, and VoiceOver went on
        // reading the old number. `refresh()` rebuilds the glyph only when the
        // one bit it carries actually flips.
        model.$shelfItems
            .map(\.count)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    /// The glyph carries one bit — is anything on the shelf — and no count. The
    /// shelf is a visible window when it is not empty, so a number in the menu
    /// bar would be a second indicator for the same fact.
    private func refresh() {
        guard let button = statusItem.button else { return }
        let count = model.shelfItems.count
        let loaded = count > 0
        if loaded != lastLoaded {
            lastLoaded = loaded
            let image = StatusGlyph.image(loaded: loaded)
            image.accessibilityDescription = "Dukou"
            button.image = image
        }
        button.setAccessibilityLabel(
            count > 0 ? L10n.format("Dukou，暂存 %d 个文件", count) : L10n.text("Dukou，暂存架是空的")
        )
    }

    // MARK: - Menu

    /// Rebuilt on every open rather than kept in sync: the shelf, the history
    /// and the retention sweep all change underneath it, and a menu that is only
    /// ever seen for a second is the cheapest thing in the app to rebuild.
    func menuNeedsUpdate(_ menu: NSMenu) {
        actionTargets.removeAll()
        menu.removeAllItems()

        menu.addItem(item(L10n.text("显示暂存架"), enabled: !model.isShelfEmpty) { [weak self] in
            self?.shelf.show()
        })
        menu.addItem(item(L10n.text("清空暂存架"), enabled: !model.isShelfEmpty) { [weak self] in
            self?.model.consumeAll()
        })
        menu.addItem(.separator())

        let quick = NSMenuItem(title: L10n.text("快捷微信转发"), action: nil, keyEquivalent: "")
        let quickMenu = NSMenu()
        quickMenu.autoenablesItems = false
        quickMenu.addItem(item(L10n.text("配置微信转发…")) { [weak self] in self?.openSettings(.wechat) })
        if wechat.isBusy {
            quickMenu.addItem(item(L10n.text("取消本次转发")) { [weak self] in self?.wechat.cancel() })
        }
        if !wechat.recent.isEmpty {
            quickMenu.addItem(.separator())
            for preset in wechat.recent {
                quickMenu.addItem(item(preset.chat + " · " + preset.range.title, enabled: !wechat.isBusy) { [weak self] in
                    self?.openSettings(.wechat)
                    self?.wechat.start(preset)
                })
            }
        }
        quick.submenu = quickMenu
        menu.addItem(quick)

        let recent = NSMenuItem(title: L10n.text("最近记录"), action: nil, keyEquivalent: "")
        recent.submenu = recentMenu()
        menu.addItem(recent)
        menu.addItem(.separator())

        menu.addItem(item(L10n.text("设置…"), key: ",") { [weak self] in self?.openSettings(.general) })
        menu.addItem(item(L10n.text("关于 Dukou…")) { [weak self] in self?.openSettings(.about) })
        // Where a regular app keeps it: under the About item. A menu bar app
        // has no application menu, so the status menu is the only one it has.
        menu.addItem(item(L10n.text("检查更新…"), enabled: updater.canCheckForUpdates) { [weak self] in
            self?.updater.checkForUpdates()
        })
        menu.addItem(.separator())
        menu.addItem(item(L10n.text("退出 Dukou"), key: "q") { NSApp.terminate(nil) })
    }

    private func recentMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        guard !model.batches.isEmpty else {
            submenu.addItem(item(L10n.text("暂无记录"), enabled: false) {})
            return submenu
        }

        let now = Date()
        for batch in model.batches.prefix(Self.recentLimit) {
            let isShelved = batch.shelvedCount > 0
            let entry = item(
                HistoryLabel.menuTitle(for: batch, now: now),
                // A tick, not a disabled row: what is already on the shelf is
                // still worth clicking, it just brings the shelf forward
                // instead of putting the files back on it.
                state: isShelved ? .on : .off
            ) { [weak self] in
                guard let self else { return }
                if isShelved {
                    shelf.show()
                } else {
                    model.restore(batchID: batch.id)
                }
            }
            submenu.addItem(entry)
        }

        submenu.addItem(.separator())
        submenu.addItem(item(L10n.text("全部记录…")) { [weak self] in self?.openSettings(.history) })
        submenu.addItem(item(L10n.text("清空记录"), enabled: model.hasDiscardableHistory) { [weak self] in
            self?.model.discardHistory()
        })
        return submenu
    }

    private func item(
        _ title: String,
        key: String = "",
        enabled: Bool = true,
        state: NSControl.StateValue = .off,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let target = ActionTarget(action)
        actionTargets.append(target)
        let menuItem = NSMenuItem(title: title, action: #selector(ActionTarget.invoke), keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        menuItem.target = target
        menuItem.isEnabled = enabled
        menuItem.state = state
        return menuItem
    }

    /// `NSMenuItem` does not retain its target, and the menu outlives the call
    /// that built it.
    private var actionTargets: [ActionTarget] = []

    private final class ActionTarget: NSObject {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}
