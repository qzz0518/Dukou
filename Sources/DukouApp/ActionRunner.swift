import AppKit
import DukouCore
import Foundation

/// Carries out what the user picked in the Share menu.
///
/// The extension never does this itself: pasting into another app needs the
/// Accessibility permission, which an app extension can never hold, and the
/// extension is killed seconds after it finishes. So the extension commits the
/// files and records the request; this runs it, in the app, where a failure has
/// somewhere to be reported.
///
/// Only "暂存到渡口" is allowed to put the shelf on screen. A forward that
/// fails leaves the files on the clipboard and offers the shelf as a button —
/// throwing a floating window over the app the user was about to paste into is
/// how the previous build turned one failure into two interruptions.
///
/// Success is silent. Every destination ends with the result in front of the
/// user — the shelf appearing, the share sheet's own 「已复制」, the pasted
/// files in the target app — so the only thing left to report is a failure.
@MainActor
final class ActionRunner {
    /// Opens 设置 → 入口, which is the only place the 「发送到自定义」 list can be
    /// filled in. Offered as the one action on the toast a share raises when
    /// that list is empty.
    var openEntries: (() -> Void)?

    /// Something other than the shelf that owns the top-right corner while it is
    /// up — today the quick forward's HUD. The shelf is suspended for the length
    /// of a forward, so without this the toast reads that corner as free and
    /// lands on the HUD's 取消 button for as long as 8 s.
    var reservedFrame: () -> NSRect? = { nil }

    private let model: AppModel
    private let shelf: ShelfController
    private let authorization: AccessibilityAuthorization
    /// The user's own destinations, read when 「发送到自定义」 arrives without one
    /// — which is every share, now that the extension no longer asks.
    private let targets: ForwardTargets
    /// For the 附加 Prompt settings: which prompt, and whether forwards attach
    /// one at all.
    private let preferences: Preferences
    private let toast = ToastPresenter()
    private let picker = TargetPickerPanel()
    /// The forward currently in flight, so the next one waits for it.
    ///
    /// `forward` writes the clipboard and then suspends for seconds — launching
    /// the target, waiting up to 4 s for it to come frontmost, settling before
    /// ⌘V — and every one of those awaits hands the MainActor back. Two
    /// arrivals in one `reload()` is the ordinary case whenever the app was not
    /// running when the shares were made, so two unserialised forwards
    /// interleave: the second one's `FilePasteboard.write` lands while the
    /// first is still waiting to paste, and the first then pastes the second's
    /// files while both batches record 已送达. Chaining means the pasteboard is
    /// only ever written for the forward that is about to press ⌘V.
    private var pending: Task<Void, Never>?

    init(
        model: AppModel,
        shelf: ShelfController,
        authorization: AccessibilityAuthorization,
        targets: ForwardTargets,
        preferences: Preferences
    ) {
        self.model = model
        self.shelf = shelf
        self.authorization = authorization
        self.targets = targets
        self.preferences = preferences
        // The two floating windows share one corner, so the toast has to know
        // where the shelf is before it can decide not to sit on it.
        toast.shelfFrame = { [weak shelf, weak self] in shelf?.visibleFrame ?? self?.reservedFrame() }
        // The open question is anchored to the click that raised it, not to the
        // shelf, so moving the shelf no longer moves it. Dismissing it instead is
        // not an option either: a question that disappeared because the user
        // tidied their shelf would cancel a forward they never cancelled.
    }

    func enqueueExclusive(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pending
        pending = Task { await previous?.value; await operation() }
    }

    func handle(_ arrival: ArrivedBatch) {
        switch arrival.action {
        case .shelf:
            // The batch is already on the shelf — `BatchState.initial` put it
            // there, and the panel followed the model on its own. This only
            // raises it above whatever has been opened since. No toast: the
            // window appearing *is* the confirmation.
            shelf.show()
        case .clipboard:
            // Reached from the shelf's and 记录's own 复制到剪贴板, and from an
            // intent an older extension build wrote. A share made with this
            // build never gets here: the extension copies it itself and the
            // batch arrives already recorded as 已复制.
            enqueueExclusive { [weak self] in
                FilePasteboard.write(arrival.urls)
                self?.model.consume(urls: arrival.urls, via: .forwarded(.clipboard))
            }
            // Nothing is shown: the share sheet said 「已复制到剪贴板」 a moment
            // ago and is still on screen. A second capsule saying it again is
            // Dukou talking over the system.
        case .codex, .claude, .custom:
            // Shares and WeChat captures share the same clipboard queue.
            //
            // Read here rather than where the panel opens. This forward may wait
            // in the queue behind a 快捷微信转发, and that run drives WeChat with
            // synthetic clicks that move the real cursor — so by the time the
            // panel is placed the pointer is parked on whatever WeChat control
            // the automation pressed last, on WeChat's display. Now is the
            // moment the user's own gesture is still the last thing that moved
            // it. `.custom` is the only action that asks anything; the others
            // carry the value harmlessly.
            let pointer = NSEvent.mouseLocation
            let previous = pending
            pending = Task { [weak self] in
                await previous?.value
                guard let self else { return }
                // Checked again here, not only when the intent came off disk.
                // A forward can wait in this queue for as long as the one in
                // front of it takes — an unanswered picker, a target app that
                // never comes frontmost — and `BatchIntent.freshnessWindow`
                // exists precisely so that a request the user has stopped
                // thinking about does not suddenly paste into whatever they
                // have open now. The files are on the clipboard either way.
                guard arrival.isFresh else {
                    self.model.recordExpired(urls: arrival.urls)
                    return
                }
                await self.deliver(arrival, askingNear: pointer)
            }
        }
    }

    /// One step before `forward`: 「发送到自定义」 arrives without a destination
    /// and has to be given one.
    ///
    /// Every other entry — and every 发给 ▸ menu inside Dukou, which names the
    /// app in the row the user clicked — arrives knowing where it is going and
    /// goes straight through.
    /// `askingNear` is where the pointer was when the share arrived — see
    /// `handle`, which reads it before this forward can be delayed by another.
    private func deliver(_ arrival: ArrivedBatch, askingNear pointer: NSPoint) async {
        guard arrival.action == .custom, arrival.target == nil else {
            await forward(arrival)
            return
        }

        switch CustomForwardDecision.decide(targets: targets.orderedTargets) {
        case .none:
            // Nothing to send to and nothing to ask. The share is not lost —
            // the files are on the clipboard — so this is a message with a way
            // out of it, not an error.
            fallBack(
                arrival,
                message: L10n.text("还没有添加自定义应用。"),
                action: ToastPresenter.Action(title: L10n.text("添加应用")) { [weak self] in
                    self?.openEntries?()
                }
            )
        case .single(let target):
            // One app is not a choice. The user's requirement, and the reason
            // no panel appears here.
            await forward(arrival, to: target)
        case .choose(let list):
            // Written before the panel opens rather than after a pick, so that
            // cancelling still leaves the user one ⌘V from their files.
            FilePasteboard.write(arrival.urls)
            // Where the user was pointing when this arrived. The panel answers
            // that gesture and stays put afterwards, so the pointer is read once,
            // in `handle`, and never again while the panel is open. Parking it in
            // the shelf's corner instead put it on the menu-bar screen — the wrong
            // display for anyone whose WeChat is on the other one (2026-09-07).
            let answer = await picker.choose(from: list) { size in
                FloatingCapsule.near(pointer, size: size)
            }
            switch answer {
            case .picked(let target):
                await forward(arrival, to: target)
            case .cancelled:
                // Cancelling is an answer, not a fault: no toast — the user
                // just dismissed a panel and knows they did — but the history
                // has to say why nothing was delivered.
                model.recordFailure(L10n.text("已取消"), urls: arrival.urls)
            case .expired:
                // Nobody answered for a minute and a half. Same record as an
                // intent that outlived its window, because that is what it is:
                // 未执行, files on the clipboard, nothing pasted anywhere.
                model.recordExpired(urls: arrival.urls)
            }
        }
    }

    /// Remembers the pick, then forwards. The next 「发送到自定义」 share opens
    /// the panel on this app, and Return takes it.
    private func forward(_ arrival: ArrivedBatch, to target: ForwardTarget) async {
        targets.recordUse(target)
        await forward(
            ArrivedBatch(
                action: arrival.action,
                target: target,
                urls: arrival.urls,
                requestedAt: arrival.requestedAt
            )
        )
    }

    /// A share the extension could not complete. It has no interface of its own
    /// any more, so the message travels through the app group and is said here —
    /// with no action, because there is nothing on disk left to act on.
    func report(_ failure: ShareFailure) {
        toast.show(
            L10n.format("没能接住这次转发：%@", failure.message),
            symbol: "exclamationmark.triangle.fill",
            tone: .warning
        )
    }

    /// A failure from something Dukou is doing that has no window of its own to
    /// report into.
    ///
    /// The quick WeChat forward is the case: it runs with WeChat in front and
    /// 设置 behind it or closed, so `WeChatQuickForward.error` alone is a
    /// message written on a page nobody is looking at. The capsule is the only
    /// surface that reaches the user where the automation left them, and the
    /// toast presenter is already the one thing that owns that corner.
    func notify(_ message: String, action: ToastPresenter.Action? = nil) {
        toast.show(message, symbol: "exclamationmark.triangle.fill", tone: .warning, action: action)
    }

    /// Takes down whatever is in the corner before something else claims it.
    ///
    /// The retry flow is the reason: a failure capsule stands for 8 s with 打开设置
    /// on it, and 再次执行 clicked while it is up puts the HUD in the same corner,
    /// over that button, while the capsule keeps counting down underneath.
    func dismissNotice() { toast.dismiss() }

    /// One path for every destination.
    ///
    /// The two built-in entries name their app in `ShareAction`; 「发送到自定义」
    /// arrives here with the app `deliver` resolved, or the one a 发给 ▸ menu
    /// named. Beyond resolving which of the two it is, nothing here knows the
    /// difference — a forward is a bundle identifier, a display name and a ⌘V.
    private func forward(_ arrival: ArrivedBatch) async {
        let action = arrival.action
        let target = arrival.target
        let name = target?.displayName ?? action.targetDisplayName

        // A custom forward with no target should be impossible — `deliver`
        // resolves one or stops — so reaching here means a build mismatch about
        // the intent schema. The files are still on the clipboard, and saying so
        // beats pretending an app is missing.
        guard let bundleIdentifier = target?.bundleIdentifier ?? action.targetBundleIdentifier else {
            fallBack(arrival, message: L10n.text("这条转发没有指定目标 App。"))
            return
        }
        guard let applicationURL = AutoPaste.applicationURL(forBundleIdentifier: bundleIdentifier) else {
            fallBack(arrival, message: AutoPaste.Failure.notInstalled(name: name).localizedDescription)
            return
        }

        // The files, or their paths as text for an app — a terminal — that
        // cannot take a pasted file. The list is asked, not the arrival: the
        // checkbox in 设置 owns this, and an intent stamped by an older
        // extension names the app without it.
        let pathOnly = targets.pastesPathOnly(for: bundleIdentifier) ?? target?.pastesPathOnly ?? false
        // The prompt, if 入口 attaches one: a first ⌘V before the files, or
        // folded into the one line a terminal gets. See `PastePlan`.
        let plan = PastePlan.make(
            urls: arrival.urls,
            pathOnly: pathOnly,
            prompt: preferences.prompt.attachment(for: .forward)?.text
        )

        // Written again here, not just in the extension: this is the process
        // that is about to press ⌘V, so it owns what ⌘V will produce.
        writePasteboard(plan)

        authorization.refresh()
        guard authorization.isTrusted else {
            // Nothing was lost: the files are on the clipboard, so the user is
            // one ⌘V away while they decide about the permission.
            fallBack(
                arrival,
                message: pathOnly
                    ? L10n.format("路径已在剪贴板，去 %@ 按 ⌘V 就行。", name)
                    : L10n.format("文件已在剪贴板，去 %@ 按 ⌘V 就行。", name),
                action: ToastPresenter.Action(title: L10n.text("开启自动粘贴")) { [weak authorization] in
                    authorization?.guideIfNeeded()
                },
                plan: plan
            )
            return
        }

        do {
            try await AutoPaste.activateAndPaste(
                applicationAt: applicationURL,
                bundleIdentifier: bundleIdentifier,
                displayName: name,
                plan: plan
            )
            model.consume(urls: arrival.urls, via: .forwarded(action, targetName: target?.displayName))
            // No confirmation: the user is looking at the target app with their
            // files already pasted into it. Telling them it worked is a capsule
            // over the evidence — removed at the user's request, 2026-09-05.
        } catch {
            fallBack(
                arrival,
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                plan: plan
            )
        }
    }

    /// What a manual ⌘V should produce: the files, or the one line a
    /// terminal would have received — never the bare prompt.
    private func writePasteboard(_ plan: [PastePayload]) {
        if let payload = PastePlan.manualPayload(plan) {
            FilePasteboard.write(payload)
        }
    }

    /// Every failure lands here, and every failure ends the same way: the files
    /// are on the clipboard, the history says what went wrong, and the shelf is
    /// one click away for the user who would rather drag them.
    private func fallBack(
        _ arrival: ArrivedBatch,
        message: String,
        action: ToastPresenter.Action? = nil,
        plan: [PastePayload]? = nil
    ) {
        // Whatever the forward was about to paste stays pasteable: a terminal
        // that was going to get a path still gets a path from a manual ⌘V.
        writePasteboard(plan ?? [.files(arrival.urls)])
        // The chosen app is named even when the forward failed. A batch that
        // arrived through 「发送到自定义」 carries it in its intent already, but
        // one sent from 记录's 发给 ▸ has nothing else that remembers who it was
        // aimed at, and 「未送达」 with no destination is half a record.
        model.recordFailure(message, urls: arrival.urls, targetName: arrival.target?.displayName)
        let fallbackAction = action ?? ToastPresenter.Action(title: L10n.text("放到暂存架")) { [weak model] in
            model?.restore(urls: arrival.urls)
        }
        toast.show(message, symbol: "exclamationmark.triangle.fill", tone: .warning, action: fallbackAction)
    }
}
