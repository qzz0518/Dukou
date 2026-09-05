import AppKit
import DukouCore
import SwiftUI

/// The one-time capsule beside the shelf that says what the shelf is for.
///
/// The shelf teaches nothing by appearing: a square of file icons over another
/// app looks like something to close, not something to drag out of. So the very
/// first time anything lands on it, one sentence appears next to it — and only
/// that first time, because the second showing would be explaining a gesture the
/// user has already made.
///
/// It does not time out. A capsule that has a button has to outlive a glance,
/// and this one is dismissed by the button or by the drag it is describing —
/// whichever the user does first.
@MainActor
final class ShelfCoachMark {
    private let preferences: Preferences
    private var panel: NSPanel?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// Where it sits, so the failure toast can treat it as part of the shelf
    /// rather than landing on top of it.
    var frame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    /// Shows it beside the shelf, at most once in the app's lifetime.
    ///
    /// Nothing is recorded here. §11.3 records it 「点击或首次成功拖出后」 —
    /// on acknowledgement — and that is not a technicality: the shelf can be
    /// emptied two seconds after it appears, while the user is still in WeChat,
    /// and writing the flag on presentation would spend the one explanation of
    /// what the square is for on a capsule nobody read.
    func show(beside shelf: NSRect) {
        guard !preferences.hasShownShelfCoachMark, panel == nil else { return }

        let panel = FloatingCapsule.panel()
        self.panel = panel
        let hosting = FirstMouseHostingView(rootView: view)
        panel.contentView = hosting
        panel.setFrame(placement(hosting: hosting, beside: shelf), display: true)
        panel.alphaValue = Motion.systemReducesMotion ? 1 : 0
        // Beside a shelf that is itself fading in, so it appears in place rather
        // than dropping the toast's 6 pt: two capsules arriving from different
        // directions at the same moment read as a glitch.
        panel.orderFrontRegardless()
        guard !Motion.systemReducesMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.panelIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Stays glued to the shelf while the shelf changes corner or opens its
    /// list. Instant, because it is the shelf that moved and the capsule is not
    /// making a journey of its own.
    func follow(_ shelf: NSRect) {
        guard let panel, panel.isVisible, let hosting = panel.contentView else { return }
        panel.setFrame(placement(hosting: hosting, beside: shelf), display: true)
    }

    /// The user answered it — the button, or the drag it was describing. This is
    /// the only path that spends the one-time flag.
    func acknowledge() {
        guard panel != nil else { return }
        preferences.hasShownShelfCoachMark = true
        dismiss()
    }

    /// Takes it off screen without spending the flag: the shelf emptied under
    /// it, so the hint has nowhere to point and has still not been read.
    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        guard !Motion.systemReducesMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.toastOut
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private var view: ToastView {
        ToastView(
            message: L10n.text("拖出去就送达；连续暂存会叠在一起。"),
            symbol: "hand.draw",
            tone: .neutral,
            actionTitle: L10n.text("知道了")
        ) { [weak self] in
            self?.acknowledge()
        }
    }

    private func placement(hosting: NSView, beside shelf: NSRect) -> NSRect {
        let size = FloatingCapsule.measure(hosting)
        let visible = FloatingCapsule.visibleFrame(holding: shelf)
        return FloatingCapsule.fitted(
            FloatingCapsule.clamped(
                FloatingCapsule.beside(shelf, size: size, in: visible),
                in: visible
            ),
            to: hosting
        )
    }
}
