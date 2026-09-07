import AppKit
import Combine
import DukouCore

@MainActor
final class WeChatQuickForward: ObservableObject {
    @Published var draft: WeChatForwardPreset { didSet { stored.draft = draft; persist() } }
    @Published private(set) var recent: [WeChatForwardPreset]
    @Published private(set) var applications: [RunningApp] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isReadingChat = false
    @Published private(set) var status: String? {
        didSet { if isBusy, let status { hud.update(status: status) } }
    }
    @Published private(set) var error: String?
    @Published private(set) var elapsedSeconds: Double?

    private static let key = "wechatQuickForward.v1"
    private static let worker = DispatchQueue(label: "dev.dukou.wechat.accessibility", qos: .userInitiated)
    private let defaults: UserDefaults
    private var stored: WeChatForwardPreferences
    private let model: AppModel
    private let shelf: ShelfController
    private let runner: ActionRunner
    private let authorization: AccessibilityAuthorization
    private let preferences: Preferences
    private var cancellation: WeChatCancellation?
    private var observers = Set<AnyCancellable>()
    /// Only a full forward raises it. `readCurrentChat` is one AX read with no
    /// synthesized input, so there is nothing to keep the user's hands off.
    private let hud = AutomationHUD()
    /// Set by the app delegate, like `ActionRunner.openEntries`: a failure
    /// capsule over another app needs somewhere to send the user.
    var openSettings: ((SettingsTab) -> Void)?

    init(model: AppModel, shelf: ShelfController, runner: ActionRunner, authorization: AccessibilityAuthorization, preferences: Preferences, defaults: UserDefaults = .standard) {
        self.model = model; self.shelf = shelf; self.runner = runner; self.authorization = authorization; self.preferences = preferences; self.defaults = defaults
        stored = WeChatForwardPreferences.decode(defaults.data(forKey: Self.key))
        draft = stored.draft
        recent = stored.recent
        refreshApplications()
        runner.reservedFrame = { [weak self] in self?.hud.frame }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshApplications() }
                .store(in: &observers)
        }
    }

    var canRun: Bool {
        !isBusy && !isReadingChat && !WeChatForwardPreset.normalizedChat(draft.chat).isEmpty && draft.range.isAvailableForAutomation &&
        applications.contains { $0.id == draft.targetBundleIdentifier }
    }
    func refreshApplications() {
        applications = RunningApp.current(excluding: [Bundle.main.bundleIdentifier ?? "dev.dukou.Dukou", WeChatAccessibility.bundleIdentifier, "com.apple.finder"])
    }
    func chooseTarget(_ id: String) {
        guard let app = applications.first(where: { $0.id == id }) else { return }
        var preset = draft
        preset.targetBundleIdentifier = app.id
        preset.targetName = app.name
        draft = preset
    }
    func use(_ preset: WeChatForwardPreset) { guard !isBusy else { return }; draft = preset; error = nil }
    /// The amount field's text. Held as a count, shown as digits, and filtered
    /// on the way in so the field can never carry something the range cannot be
    /// made of. Empty reads as zero, which the form marks invalid rather than
    /// silently correcting.
    var amountText: String { draft.range.value > 0 ? String(draft.range.value) : "" }
    func setAmount(_ text: String) {
        guard !isBusy else { return }
        draft.range.value = Int(WeChatForwardRange.digits(text)) ?? 0
    }
    func useMessageCount() {
        guard !isBusy else { return }
        draft.range = .init(unit: .messages, value: 100)
        error = nil; status = nil
    }
    func forget(_ preset: WeChatForwardPreset) {
        stored.recent.removeAll { $0.id == preset.id }
        recent = stored.recent
        persist()
    }
    private func persist() { if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) } }

    func readCurrentChat() {
        guard !isBusy, !isReadingChat else { return }
        authorization.refresh()
        guard authorization.isTrusted else { authorization.guideIfNeeded(); return }
        isReadingChat = true; error = nil
        Task {
            defer { isReadingChat = false }
            do {
                let chat: String = try await withCheckedThrowingContinuation { continuation in
                    Self.worker.async { continuation.resume(with: Result { try WeChatAccessibility.currentChat() }) }
                }
                draft.chat = chat
            } catch { self.error = error.localizedDescription }
        }
    }

    func cancel() {
        // The HUD stays clickable for its fade-out, which starts before
        // `isBusy` clears. Without this, a late click on 取消 overwrote the
        // final status with 「正在停止…」 for a run that had already finished.
        guard isBusy, cancellation != nil else { return }
        cancellation?.cancel()
        status = L10n.text("正在停止…")
    }

    func start(_ saved: WeChatForwardPreset? = nil) {
        guard !isBusy, !isReadingChat else { return }
        if let saved { draft = saved }
        guard draft.range.unit == .messages else {
            status = nil
            error = WeChatAutomationError.timeRangeUnavailable.localizedDescription
            return
        }
        refreshApplications()
        guard canRun else {
            error = L10n.text("请填写群名和有效范围，并选择一个正在运行的应用。")
            return
        }
        authorization.refresh()
        guard authorization.isTrusted else { authorization.guideIfNeeded(); return }
        var preset = draft
        preset.chat = WeChatForwardPreset.normalizedChat(preset.chat)
        guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: preset.targetBundleIdentifier).first else { return }
        preset.targetName = target.localizedName ?? preset.targetName
        let token = WeChatCancellation()
        cancellation = token
        isBusy = true; error = nil; elapsedSeconds = nil
        let opening = L10n.text("等待开始微信转发…")
        status = opening
        // The previous run's failure capsule is in the corner this is about to
        // take, and 再次执行 is usually clicked while it is still standing there.
        runner.dismissNotice()
        // Up before the first synthesized event, not when the automation gets
        // around to WeChat: the run may sit in `enqueueExclusive` behind a
        // share, and the seconds where nothing appears to be happening are
        // exactly the ones where the user reaches for the mouse.
        hud.show(status: opening) { [weak self] in self?.cancel() }
        let requestedAt = Date()
        runner.enqueueExclusive { [weak self] in
            guard let self else { return }
            await self.run(preset, targetPID: target.processIdentifier, requestedAt: requestedAt, token: token)
        }
    }

    private func run(_ preset: WeChatForwardPreset, targetPID: pid_t, requestedAt: Date, token: WeChatCancellation) async {
        let started = ProcessInfo.processInfo.systemUptime
        var deferredIntake = false
        defer {
            hud.hide()
            if deferredIntake { model.resumeIntake(); shelf.resumePresentation() }
            elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
            cancellation = nil
            isBusy = false
        }
        do {
            try token.check()
            guard Date().timeIntervalSince(requestedAt) <= BatchIntent.freshnessWindow else { throw WeChatAutomationError.focusChanged }
            guard let inbox = model.inbox else { throw WeChatAutomationError.receiptTimeout }
            guard NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier == preset.targetBundleIdentifier else {
                throw AutoPaste.Failure.didNotBecomeActive(name: preset.targetName)
            }
            let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/DukouShare.appex")
            model.deferIntake()
            shelf.suspendPresentation()
            deferredIntake = true
            let capture: WeChatCapture = try await withCheckedThrowingContinuation { continuation in
                Self.worker.async {
                    continuation.resume(with: Result {
                        let engine = try WeChatAccessibility(chat: preset.chat, cancellation: token) { [weak self] message in
                            DispatchQueue.main.async { self?.status = message }
                        }
                        return try engine.capture(range: preset.range, ready: inbox.ready, shelfExtension: extensionURL)
                    })
                }
            }
            try token.check()
            let reader = InboxReader(inbox: inbox)
            guard capture.messageCount > 0 else {
                status = L10n.text("这个时间范围内没有消息。")
                return
            }
            let batches = capture.directories.reversed().compactMap { reader.batch(at: $0) }
            guard batches.count == capture.directories.count, batches.allSatisfy({ $0.items.count == 1 }) else { throw WeChatAutomationError.invalidArchive }
            let urls = batches.flatMap { $0.items.map(\.url) }
            status = L10n.format("正在粘贴到 %@…", preset.targetName)
            let plan = PastePlan.make(
                urls: urls,
                pathOnly: preset.pastePath,
                prompt: preferences.prompt.attachment(for: .wechat)?.text
            )
            try await AutoPaste.pasteIntoRunning(pid: targetPID, bundleIdentifier: preset.targetBundleIdentifier, displayName: preset.targetName,
                                               plan: plan, checkCancellation: token.check)
            // Initialising only our own receipts above leaves other arrivals
            // untouched. When intake resumes those still receive their actions.
            var savedOutcome = true
            for batch in batches {
                do {
                    try reader.markConsumed(itemIDs: Set(batch.items.map(\.id)), in: batch.id)
                    try reader.recordOutcome(BatchOutcome(kind: .delivered, at: Date()), targetName: preset.targetName, for: batch.id)
                } catch { savedOutcome = false }
            }
            stored.recordSuccess(preset)
            recent = stored.recent
            draft = stored.draft
            persist()
            status = L10n.format("已向 %@ 粘贴 %d 个 ZIP · 约 %d 条消息", preset.targetName, urls.count, capture.messageCount)
            if !savedOutcome { error = L10n.text("粘贴已完成，但部分记录状态未能保存。") }
        } catch is CancellationError {
            status = L10n.text("已取消，已收到的文件保留在暂存架。")
        } catch {
            status = nil
            self.error = error.localizedDescription
            // 设置 is behind WeChat by now and usually closed altogether, so the
            // failure is also said on the capsule the rest of Dukou uses.
            hud.hide()
            runner.notify(
                L10n.format("快捷微信转发失败：%@", error.localizedDescription),
                action: ToastPresenter.Action(title: L10n.text("打开设置")) { [weak self] in
                    self?.openSettings?(.wechat)
                }
            )
        }
    }
}
