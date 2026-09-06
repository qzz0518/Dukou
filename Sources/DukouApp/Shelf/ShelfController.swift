import AppKit
import Combine
import DukouCore
import SwiftUI

/// What the shelf's own animations run on.
///
/// A window cannot scale itself: `alphaValue` is AppKit's to animate, but the
/// 0.96 → 1 settle and the bump have to happen inside the SwiftUI content, so
/// the controller drives them through published values the view reads.
@MainActor
final class ShelfPresentation: ObservableObject {
    @Published var scale: CGFloat = 1
    /// Collapsed square or open list. Published rather than handed to a rebuilt
    /// `ShelfView`: a fresh `rootView` replaces one state with the other between
    /// two frames, and a cross-fade needs the same view changing its mind.
    @Published var isExpanded = false
}

/// Owns the shelf panel's lifetime, size and position.
///
/// The panel exists exactly while something is on the shelf, and there is no
/// toggle: an empty floating window over someone else's work is clutter, and a
/// shelf that can be hidden while still holding files is a place to lose them.
/// Visibility follows the model, so "放回暂存架" from the history and a fresh
/// share both bring it back through the same path.
///
/// It docks to the corner the user picked in 设置 → 通用 → 暂存架 and stays
/// there. The previous build put it under the pointer, which meant the shelf was
/// in a different place after every share and the user had to find it again
/// before they could drag from it.
@MainActor
final class ShelfController: NSObject, NSWindowDelegate {
    /// Set by the app delegate once the action runner exists, so the shelf's
    /// context menus can forward without the two owning each other.
    var perform: ((ArrivedBatch) -> Void)?
    /// Opens 设置 → 入口. Offered by the 发给 ▸ submenu when the user has not
    /// added an app of their own yet.
    var openEntries: (() -> Void)?
    private let model: AppModel
    private let preferences: Preferences
    /// Read by the shelf's 发给 ▸ submenu, which lists the same destinations as
    /// everywhere else in the app.
    private let targets: ForwardTargets
    private let presentation = ShelfPresentation()
    private let coachMark: ShelfCoachMark
    private var panel: ShelfPanel?
    private var cancellables = Set<AnyCancellable>()
    private var isExpanded: Bool { presentation.isExpanded }
    /// Only a shelf that *grew* bumps. Every other reason the model republishes
    /// — a consume, a prune, a rename — must leave the window alone.
    private var shelvedCount = 0
    /// `windowDidMove` cannot tell the user's drag from the controller's own
    /// `setFrame`, and remembering the latter would slowly overwrite the anchor
    /// with wherever the shelf last happened to be clamped to.
    ///
    /// Counted rather than flagged: an animated move holds it for its whole
    /// 180 ms, and a second move starting inside the first would otherwise have
    /// its predecessor's completion declare the window still while it is very
    /// much still travelling.
    private var positioning = 0
    private var isPositioning: Bool { positioning > 0 }
    private var bumpBack: Task<Void, Never>?
    private var anchorWrite: Task<Void, Never>?
    private var presentationSuspended = false

    func suspendPresentation() { presentationSuspended = true; hide() }
    func resumePresentation() {
        presentationSuspended = false
        if !model.isShelfEmpty { show() }
    }

    init(model: AppModel, preferences: Preferences, targets: ForwardTargets) {
        self.model = model
        self.preferences = preferences
        self.targets = targets
        coachMark = ShelfCoachMark(preferences: preferences)
        super.init()

        model.$shelfItems
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                let grew = items.count > self.shelvedCount
                let wasUp = self.panel?.isVisible == true
                self.shelvedCount = items.count
                guard !items.isEmpty else {
                    // Not animated: the window is going away in the same pass,
                    // and cross-fading a card back to its square while it fades
                    // out is two exits arguing over one shelf.
                    self.presentation.isExpanded = false
                    self.hide()
                    return
                }
                // `show()` is idempotent: it only places the window when the
                // window is not already on screen. Calling it unconditionally is
                // what repairs a panel caught mid-fade-out by a share that
                // landed 100 ms too late.
                self.show()
                self.resize()
                if grew, wasUp { self.bump() }
            }
            .store(in: &cancellables)

        // The drag the coach mark describes is the moment it has served its
        // purpose; leaving it up afterwards would be the app explaining what the
        // user just did.
        model.didDragOut
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.coachMark.acknowledge() }
            .store(in: &cancellables)

        // Picking a corner is the user overruling wherever they last dragged the
        // shelf, so the remembered position goes with it. `dropFirst` because
        // `@Published` replays its current value on subscribe, and honouring
        // that would wipe the anchor on every launch.
        preferences.$shelfCorner
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] corner in self?.dock(to: corner) }
            .store(in: &cancellables)

        // A display unplugged, a resolution change, the Dock changing edge: the
        // remembered corner may no longer be a place on this Mac, and AppKit's
        // own rescue drops floating windows wherever it likes. This is §6.1's
        // third — and only other — licence to reposition.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                guard !self.isOnScreen(panel) else { return }
                self.setFrame(panel, self.frame(for: self.cardSize()))
            }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Fully inside some screen's usable area. The transparent bump ring is not
    /// part of what has to fit, or a shelf docked hard against the edge would
    /// report itself as stranded.
    private func isOnScreen(_ panel: ShelfPanel) -> Bool {
        let card = panel.frame.insetBy(dx: Metrics.shelfBumpInset, dy: Metrics.shelfBumpInset)
        return NSScreen.screens.contains { $0.visibleFrame.contains(card) }
    }

    /// Everything the shelf occupies on screen: the card, plus the coach mark
    /// standing beside it. The toast asks for this so it can step aside rather
    /// than land on top of either.
    var visibleFrame: NSRect? {
        guard let card = cardFrame else { return nil }
        guard let mark = coachMark.frame else { return card }
        return card.union(mark)
    }

    /// The card's frame on screen, without the transparent ring the bump needs.
    private var cardFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame.insetBy(dx: Metrics.shelfBumpInset, dy: Metrics.shelfBumpInset)
    }

    func show() {
        guard !presentationSuspended else { return }
        guard !model.isShelfEmpty else { return }
        let panel = panel ?? makePanel()
        (panel.contentView as? FirstMouseHostingView<ShelfView>)?.rootView = shelfView

        let entering = !panel.isVisible
        if entering {
            // Position first, animate second. The shelf appears where it lives;
            // it never travels there.
            setFrame(panel, frame(for: cardSize()))
            presentation.scale = Motion.systemReducesMotion ? 1 : 0.96
            panel.alphaValue = Motion.systemReducesMotion ? 1 : 0
        }
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the shelf
        // appears while the user is still in WeChat, and taking key status here
        // would swallow their next keystroke.
        panel.orderFrontRegardless()

        // Only ever once, and only with something actually on the shelf — which
        // is what the guard at the top of this method already established.
        if let cardFrame { coachMark.show(beside: cardFrame) }

        guard entering else {
            // Already up, so nothing about its position is allowed to change —
            // §6.1 forbids repositioning on reload, on a new batch and on a
            // repeat `show()`. The one exception is a shelf that is no longer
            // anywhere: a display unplugged or reconfigured under it leaves the
            // panel somewhere unreachable, and 显示暂存架 is the only way back.
            if !isOnScreen(panel) { setFrame(panel, frame(for: cardSize())) }
            // The only other thing left to do is cancel a dismissal that was
            // still fading it out.
            if panel.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    panel.animator().alphaValue = 1
                }
            }
            return
        }
        guard !Motion.systemReducesMotion else { return }

        // One turn of the run loop before the animation: SwiftUI coalesces a
        // value set and animated away in the same pass, and the 0.96 would
        // never be drawn — measured as a plain fade with no settle at all.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.panelIn
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            withAnimation(.easeOut(duration: Motion.panelIn)) { self.presentation.scale = 1 }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        bumpBack?.cancel()
        coachMark.dismiss()
        guard !Motion.systemReducesMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.panelOut
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            // A share that landed during the fade has already turned the alpha
            // back up; ordering out here would hide a shelf that has something
            // on it again.
            guard let panel, panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
        }
    }

    /// Forgets where the user dragged the shelf and docks it back to the corner
    /// they picked. The move is instantaneous on purpose — this is the one
    /// command in Dukou whose whole content is "it is over there now".
    ///
    /// A shelf with nothing on it stays off screen: the previous version called
    /// `show()` here, which returned immediately on an empty shelf and made the
    /// button look broken.
    func forgetDraggedPosition() {
        // A drag still settling would otherwise write its corner back in a
        // fifth of a second and undo this.
        anchorWrite?.cancel()
        preferences.shelfAnchor = nil
        guard let panel, panel.isVisible else { return }
        setFrame(panel, frame(for: cardSize()))
    }

    /// A new corner takes effect where the user can see it happen, which is why
    /// this repositions a visible shelf immediately rather than waiting for the
    /// next share. The dragged position goes with it — choosing a corner is the
    /// user saying "not there, here".
    private func dock(to corner: ShelfCorner) {
        anchorWrite?.cancel()
        preferences.shelfAnchor = nil
        guard let panel, panel.isVisible else { return }
        setFrame(panel, clamped(home(corner, size: panel.frame.size)))
    }

    /// One nudge, in place, when something joins a shelf that is already up.
    /// Moving the window instead would pull it out from under a pointer that is
    /// already reaching for it.
    private func bump() {
        guard !Motion.systemReducesMotion else { return }
        bumpBack?.cancel()
        let half = Motion.bump / 2
        withAnimation(.easeOut(duration: half)) { presentation.scale = 1.05 }
        bumpBack = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(half * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeIn(duration: half)) { self.presentation.scale = 1 }
        }
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel(contentRect: frame(for: cardSize()))
        let hosting = FirstMouseHostingView(rootView: shelfView)
        // The controller owns the panel's size. Left to its defaults the hosting
        // view installs intrinsic-size constraints on the window and wins the
        // argument, producing a frame that matches neither state — measured as a
        // 300×180 window that was collapsed in height and expanded in width.
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.delegate = self
        // Esc used to hide the shelf, which contradicts a window whose presence
        // *is* "there is still something here". It now only drops the selection,
        // the way Esc does in a list.
        panel.onCancel = { [weak self] in self?.model.selection = [] }
        // Delete takes things off the shelf; it does not delete files. ⌘⌫ is the
        // Trash, the same split Finder uses. With nothing selected both act on
        // the whole shelf, because the collapsed blob has no selection to make
        // and ✕ already means "all of it".
        panel.onDeleteSelection = { [weak self] in
            guard let self else { return }
            self.model.consume(ids: self.targetedIDs, via: .dismissed)
        }
        // ⌫ acts on the whole shelf when nothing is selected — it only takes
        // things off, the files stay. ⌘⌫ does not: a stray keystroke on a panel
        // that has just taken key status must not trash a share with nothing to
        // undo it, so the Trash needs something explicitly selected.
        panel.onTrashSelection = { [weak self] in
            guard let self, !self.model.selection.isEmpty else { return }
            self.model.discard(ids: self.model.selection)
        }
        panel.onSelectAll = { [weak self] in
            guard let self else { return }
            self.model.selection = Set(self.model.shelfItems.map(\.id))
        }
        self.panel = panel
        return panel
    }

    private var targetedIDs: Set<UUID> {
        model.selection.isEmpty ? Set(model.shelfItems.map(\.id)) : model.selection
    }

    private var shelfView: ShelfView {
        ShelfView(
            model: model,
            presentation: presentation,
            targets: targets,
            onClose: { [weak self] in self?.model.consumeAll() },
            onToggleExpanded: { [weak self] in self?.setExpanded(!(self?.isExpanded ?? false)) },
            onAction: { [weak self] action, target, urls in
                self?.perform?(ArrivedBatch(action: action, target: target, urls: urls))
            },
            onAddTarget: { [weak self] in self?.openEntries?() }
        )
    }

    /// Two halves of one 180 ms, started in the same turn and given the same
    /// curve: AppKit grows the window, SwiftUI fades one state into the other
    /// inside it. Neither can do the other's job — a window cannot cross-fade
    /// its content, and the content cannot move the window it is drawn in — so
    /// the only thing that makes them read as one movement is starting together.
    ///
    /// The `rootView` is deliberately not replaced any more: swapping it is what
    /// used to make the two states two different views, with no transition left
    /// for SwiftUI to run between them.
    private func setExpanded(_ expanded: Bool) {
        guard expanded != presentation.isExpanded else { return }
        if Motion.systemReducesMotion {
            presentation.isExpanded = expanded
        } else {
            withAnimation(.easeOut(duration: Motion.panelIn)) { presentation.isExpanded = expanded }
        }
        resize()
    }

    // MARK: - Geometry

    /// The visible card. The panel is this plus a transparent ring on every
    /// side, which is what the bump grows into.
    private func cardSize() -> NSSize {
        guard isExpanded else {
            return NSSize(width: Metrics.shelfBlobSide, height: Metrics.shelfBlobSide)
        }
        let rows = min(max(model.shelfItems.count, 1), Metrics.shelfVisibleRows)
        let listHeight = CGFloat(rows) * (Metrics.shelfRowHeight + Space.xxs) + (Space.xs + 2) * 2
        return NSSize(
            width: Metrics.shelfListWidth,
            height: Metrics.shelfHeaderHeight + Stroke.hairline + listHeight
        )
    }

    private func panelSize(for card: NSSize) -> NSSize {
        NSSize(
            width: card.width + Metrics.shelfBumpInset * 2,
            height: card.height + Metrics.shelfBumpInset * 2
        )
    }

    /// Grows from the corner it is docked by: a left corner keeps its left edge,
    /// a bottom corner keeps its bottom edge. Anchoring everything at the
    /// top-left pushed a top-right shelf's expanded list straight off the screen;
    /// anchoring everything at the top-right now does the same to the two bottom
    /// corners and to a shelf dragged against the left edge.
    ///
    /// Animated, unlike every other move in here: this is the one that changes
    /// the shelf's shape rather than its whereabouts, and a card that snaps
    /// between a square and a list gives the user nothing to follow. The corner
    /// it is anchored by stays fixed for the whole animation, so it still grows
    /// out of where it sits rather than travelling.
    private func resize() {
        guard let panel else { return }
        let size = panelSize(for: cardSize())
        guard size != panel.frame.size else { return }
        let corner = dockedCorner(of: panel.frame)
        var frame = NSRect(origin: panel.frame.origin, size: size)
        if corner.isRight { frame.origin.x = panel.frame.maxX - size.width }
        if corner.isTop { frame.origin.y = panel.frame.maxY - size.height }
        setFrame(panel, clamped(frame), animated: true)
    }

    /// Where the panel goes: the dragged position when it is still usable, the
    /// chosen corner of the current screen otherwise.
    private func frame(for card: NSSize) -> NSRect {
        let size = panelSize(for: card)
        guard let dragged = anchoredCorner() else {
            return clamped(home(preferences.shelfCorner, size: size))
        }
        return clamped(NSRect(
            x: dragged.x + Metrics.shelfBumpInset - size.width,
            y: dragged.y + Metrics.shelfBumpInset - size.height,
            width: size.width,
            height: size.height
        ))
    }

    /// The panel's frame for one of the four docking corners, 12 pt in from the
    /// screen's usable area — which already excludes the menu bar and the Dock.
    /// The margin applies to the card, not to the panel: the transparent bump
    /// ring would otherwise show as a corner the shelf never quite reaches.
    private func home(_ corner: ShelfCorner, size: NSSize) -> NSRect {
        // The screen the shelf is already on, not whichever one holds the
        // keyboard: 停靠位置 changes which corner it docks to, and carrying it to
        // another display at the same time is a second move nobody asked for.
        // Off screen it has no screen of its own, and `NSScreen.main` is then the
        // best guess at where the user is looking.
        let visible = FloatingCapsule.visibleFrame(
            holding: panel?.isVisible == true ? panel?.frame : nil
        )
        let card = NSSize(
            width: size.width - Metrics.shelfBumpInset * 2,
            height: size.height - Metrics.shelfBumpInset * 2
        )
        return FloatingCapsule
            .corner(corner, size: card, in: visible)
            .insetBy(dx: -Metrics.shelfBumpInset, dy: -Metrics.shelfBumpInset)
    }

    /// Which corner a frame is anchored by while it grows.
    ///
    /// A shelf the user has dragged has no chosen corner, so it takes the corner
    /// of the screen it is nearest — which is what keeps an expanding list
    /// growing away from the edge it was parked against rather than through it.
    private func dockedCorner(of frame: NSRect) -> ShelfCorner {
        guard preferences.shelfAnchor != nil else { return preferences.shelfCorner }
        let visible = FloatingCapsule.visibleFrame(holding: frame)
        switch (frame.midX >= visible.midX, frame.midY >= visible.midY) {
        case (true, true): return .topRight
        case (true, false): return .bottomRight
        case (false, true): return .topLeft
        case (false, false): return .bottomLeft
        }
    }

    /// The remembered corner, but only while it is still a place on this Mac.
    /// A point saved on a monitor that has since been unplugged, or on a screen
    /// that has changed resolution, has to be recognised as unusable — clamping
    /// it would drop the shelf somewhere the user never put it.
    private func anchoredCorner() -> NSPoint? {
        guard let anchor = preferences.shelfAnchor else { return nil }
        let screen = NSScreen.screens.first {
            $0.frame == anchor.screenFrame && $0.visibleFrame.contains(anchor.topRight)
        }
        return screen == nil ? nil : anchor.topRight
    }

    private func clamped(_ frame: NSRect) -> NSRect {
        let anchor = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return frame }

        // The transparent ring is not part of what has to stay on screen.
        let margin = Metrics.screenMargin - Metrics.shelfBumpInset
        var clamped = frame
        clamped.origin.x = min(
            max(frame.minX, visible.minX + margin),
            visible.maxX - frame.width - margin
        )
        clamped.origin.y = min(
            max(frame.minY, visible.minY + margin),
            visible.maxY - frame.height - margin
        )
        return clamped
    }

    private func setFrame(_ panel: ShelfPanel, _ frame: NSRect, animated: Bool = false) {
        let card = frame.insetBy(dx: Metrics.shelfBumpInset, dy: Metrics.shelfBumpInset)
        // Told where the shelf is going rather than where it is: the hint has no
        // journey of its own to make, and a shelf growing towards a capsule that
        // has not stepped aside yet would sit on it for the whole animation.
        coachMark.follow(card)

        guard animated, !Motion.systemReducesMotion else {
            positioning += 1
            panel.setFrame(frame, display: true)
            // A transparent window's shadow is derived from what it drew, so it
            // has to be recomputed whenever the card changes size.
            panel.invalidateShadow()
            positioning -= 1
            return
        }

        positioning += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.panelIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self, weak panel] in
            // AppKit runs this on the main thread; the compiler cannot see that
            // through a `Sendable` completion handler, which is all
            // `assumeIsolated` is asserting.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.positioning -= 1
                panel?.invalidateShadow()
            }
        }
    }

    /// Wherever the user parks it is where it belongs from now on. The top-right
    /// corner is what is remembered, not the origin: the shelf grows downwards
    /// and leftwards, so an origin would move the window every time the list
    /// opened.
    ///
    /// Only a drag counts, and a drag always has a mouse button held down. macOS
    /// moves floating windows on its own too — a display reconfiguration, the
    /// Dock changing edge, Stage Manager — and one such move was measured to
    /// arrive with a frame six points left of the one that had just been set,
    /// which is how the shelf taught itself a corner nobody had chosen.
    func windowDidMove(_ notification: Notification) {
        guard !isPositioning, NSEvent.pressedMouseButtons != 0 else { return }
        if let cardFrame { coachMark.follow(cardFrame) }
        // A drag delivers one of these per frame, and AppKit adds a few points
        // of settle after the button comes up. Reading the frame when the moves
        // have stopped — rather than remembering the one that arrived last —
        // is what makes the shelf come back exactly where it was dropped.
        anchorWrite?.cancel()
        anchorWrite = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.rememberPosition()
        }
    }

    private func rememberPosition() {
        guard let panel, panel.isVisible, let screen = panel.screen ?? NSScreen.main else { return }
        preferences.shelfAnchor = ShelfAnchor(
            topRight: NSPoint(
                x: panel.frame.maxX - Metrics.shelfBumpInset,
                y: panel.frame.maxY - Metrics.shelfBumpInset
            ),
            screenFrame: screen.frame
        )
    }
}

/// A non-activating panel's first click must reach the control under it.
///
/// Without this the first click on the shelf only raises the window, which for a
/// panel whose entire purpose is "close me" or "grab me" means every interaction
/// costs two clicks.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
