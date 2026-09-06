import AppKit
import DukouCore
import SwiftUI

/// Progress and cancellation for a quick WeChat forward.
///
/// The run drives WeChat with synthetic clicks, so the pointer stops being the
/// user's for its duration — the panel says so, names the step it is on, and
/// keeps 取消 one click away. Non-activating on purpose: raising it must not
/// take the front away from the app the automation is about to paste into.
@MainActor
final class AutomationHUD {
    private var panel: NSPanel?
    private var onCancel: () -> Void = {}
    /// Set for the length of the fade-out. A capsule on its way out has already
    /// given the corner back, and nothing should stand aside for it.
    private var isLeaving = false

    /// Where it sits, so the failure toast can step aside instead of landing on
    /// the 取消 button. Same contract as `ShelfCoachMark.frame`.
    var frame: NSRect? {
        guard let panel, panel.isVisible, !isLeaving else { return nil }
        return panel.frame
    }

    /// Raises it, or replaces the text of one that is already up: `start` is
    /// reachable again from 记住的群聊 the moment the previous run ended.
    func show(status: String, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        let panel = self.panel ?? FloatingCapsule.panel()
        self.panel = panel
        let showing = panel.isVisible
        isLeaving = false
        let frame = place(status, in: panel)
        guard !showing else {
            // `hide` may still be fading it out — 再次执行 clicked the moment the
            // previous run ended is exactly that. Turning the alpha back up is
            // what makes the `alphaValue == 0` guard below fail; without it the
            // fade finishes, the panel is ordered out, and the new run spends
            // its whole length with no HUD and no 取消 (and every `update` is
            // skipped, because the panel is no longer visible).
            if panel.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    panel.animator().alphaValue = 1
                }
            }
            return
        }
        enter(panel, frame: frame)
    }

    /// Every step of the forward writes one line here. The capsule is measured
    /// again — 「正在选择并导出消息 · 已完成 300 条」 is wider than 「正在打开微信群聊…」
    /// — and stays anchored in its corner rather than replaying the entrance,
    /// which for a status that changes every second would be a flicker.
    func update(status: String) {
        guard let panel, panel.isVisible else { return }
        _ = place(status, in: panel)
    }

    /// Idempotent: a second call while the fade is running would only hang
    /// another identical animation group off a panel that is already leaving.
    func hide() {
        guard let panel, panel.isVisible, !isLeaving else { return }
        isLeaving = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.toastOut
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            // A second run raised it again during the fade; ordering out here
            // would take down a HUD that belongs to the run in progress.
            guard let panel, panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
        }
    }

    /// Writes the content and the frame, and answers with the frame — the top
    /// right corner of the screen, which is where the toast lives too. Nothing
    /// steps aside for the shelf: the shelf is suspended for the length of a
    /// forward (`ShelfController.suspendPresentation`), so there is nothing in
    /// that corner to avoid.
    @discardableResult
    private func place(_ status: String, in panel: NSPanel) -> NSRect {
        let view = AutomationHUDView(
            status: status,
            instruction: L10n.text("完成前请不要动鼠标和键盘")
        ) { [weak self] in self?.onCancel() }
        // `ToastHostingView`, not a plain one: Dukou is never the active app
        // while this is up, so 取消 has to take the first click rather than
        // spend it on raising the window.
        let hosting = (panel.contentView as? ToastHostingView<AutomationHUDView>) ?? {
            let created = ToastHostingView(rootView: view)
            panel.contentView = created
            return created
        }()
        hosting.rootView = view
        let size = FloatingCapsule.measure(hosting)
        let visible = FloatingCapsule.visibleFrame(holding: nil)
        let frame = FloatingCapsule.fitted(
            FloatingCapsule.clamped(FloatingCapsule.corner(.topRight, size: size, in: visible), in: visible),
            to: hosting
        )
        panel.setFrame(frame, display: true)
        return frame
    }

    /// The toast's entrance, for the same reason: a capsule that appears over
    /// another app's window is easier to notice arriving than sitting there.
    private func enter(_ panel: NSPanel, frame: NSRect) {
        let drops = !Motion.systemReducesMotion
        panel.setFrame(drops ? frame.offsetBy(dx: 0, dy: Metrics.toastDrop) : frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.toastIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if drops { panel.animator().setFrame(frame, display: true) }
        }
    }
}

/// Deliberately built out of `ToastView`'s material, radius, hairline and
/// padding: this is the same kind of object in the same corner, and a second
/// capsule with a shape of its own would read as a different app talking.
struct AutomationHUDView: View {
    let status: String
    let instruction: String
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                // The line that is the point of the whole panel. It never
                // changes while the status above it does, so the user reads it
                // once and it stays put.
                Text(instruction)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The same allowance `ToastView` gives a message with a button:
            // spinner, gap and 取消 take the rest of the 360 pt.
            .frame(maxWidth: Metrics.toastMaxWidth - 140, alignment: .leading)
            Button(L10n.text("取消"), action: onCancel)
                .controlSize(.small)
                .buttonStyle(.borderless)
                // Not `Color.accentColor`, which is whatever the user picked in
                // System Settings; and not the warning colour — nothing has
                // gone wrong here.
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 11)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .fixedSize()
    }
}
