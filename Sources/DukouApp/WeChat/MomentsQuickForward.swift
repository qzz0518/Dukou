import AppKit
import Combine
import DukouCore

@MainActor
final class MomentsQuickForward: ObservableObject {
    @Published var draft: MomentsForwardPreset { didSet { persist() } }
    @Published private(set) var applications: [RunningApp] = []
    @Published private(set) var isBusy = false
    @Published private(set) var status: String? { didSet { if isBusy, let status { hud.update(status: status) } } }
    @Published private(set) var error: String?
    @Published private(set) var elapsedSeconds: Double?
    var otherAutomationIsBusy: () -> Bool = { false }
    var openSettings: ((SettingsTab) -> Void)?
    var hudFrame: NSRect? { hud.frame }

    private let model: AppModel
    private let shelf: ShelfController
    private let runner: ActionRunner
    private let authorization: AccessibilityAuthorization
    private let preferences: Preferences
    private let defaults: UserDefaults
    private let hud = AutomationHUD()
    private var token: WeChatCancellation?
    private var observers = Set<AnyCancellable>()
    private static let key = "momentsQuickForward.v1"
    private static let worker = DispatchQueue(label: "dev.dukou.moments.accessibility", qos: .userInitiated)

    init(model: AppModel, shelf: ShelfController, runner: ActionRunner, authorization: AccessibilityAuthorization,
         preferences: Preferences, defaults: UserDefaults = .standard) {
        self.model = model; self.shelf = shelf; self.runner = runner
        self.authorization = authorization; self.preferences = preferences; self.defaults = defaults
        draft = MomentsForwardPreset.decode(defaults.data(forKey: Self.key))
        refreshApplications()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshApplications() }.store(in: &observers)
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: Self.key) }
    }
    var canRun: Bool {
        !isBusy && !otherAutomationIsBusy() && draft.isValid &&
        (draft.destinationFolder != nil || applications.contains { $0.id == draft.targetBundleIdentifier })
    }
    func refreshApplications() {
        applications = RunningApp.current(excluding: [Bundle.main.bundleIdentifier ?? "dev.dukou.Dukou", WeChatAccessibility.bundleIdentifier, "com.apple.finder"])
    }
    func chooseTarget(_ id: String) {
        guard !isBusy, let app = applications.first(where: { $0.id == id }) else { return }
        draft.targetBundleIdentifier = app.id; draft.targetName = app.name; draft.destinationFolder = nil
    }
    func chooseFolder() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = L10n.text("选择文件夹")
        panel.directoryURL = draft.destinationFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        draft.destinationFolder = folder; draft.pastePath = false
    }
    func cancel() {
        guard isBusy, token != nil else { return }
        token?.cancel(); status = L10n.text("正在停止…")
    }
    func start() {
        guard !isBusy, !otherAutomationIsBusy() else { return }
        refreshApplications()
        guard canRun else {
            error = L10n.text("请输入有效的朋友圈条数，并选择应用或文件夹。")
            return
        }
        authorization.refresh()
        guard authorization.isTrusted else { authorization.guideIfNeeded(); return }
        let preset = draft
        let target = preset.destinationFolder == nil
            ? NSRunningApplication.runningApplications(withBundleIdentifier: preset.targetBundleIdentifier).first : nil
        guard preset.destinationFolder != nil || target != nil else { return }
        let token = WeChatCancellation()
        self.token = token; isBusy = true; error = nil; elapsedSeconds = nil
        let opening = L10n.text("等待开始朋友圈转发…")
        status = opening
        runner.dismissNotice()
        hud.show(status: opening) { [weak self] in self?.cancel() }
        let requestedAt = Date()
        runner.enqueueExclusive { [weak self] in
            await self?.run(preset, targetPID: target?.processIdentifier, requestedAt: requestedAt, token: token)
        }
    }
    private func run(_ preset: MomentsForwardPreset, targetPID: pid_t?, requestedAt: Date, token: WeChatCancellation) async {
        let started = ProcessInfo.processInfo.systemUptime
        var intakeDeferred = false
        defer {
            hud.hide()
            if intakeDeferred { model.resumeIntake(); shelf.resumePresentation() }
            elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
            self.token = nil; isBusy = false
        }
        do {
            try token.check()
            guard Date().timeIntervalSince(requestedAt) <= BatchIntent.freshnessWindow else { throw WeChatAutomationError.focusChanged }
            guard let inbox = model.inbox else { throw WeChatAutomationError.receiptTimeout }
            if let targetPID {
                guard NSRunningApplication(processIdentifier: targetPID)?.bundleIdentifier == preset.targetBundleIdentifier else {
                    throw AutoPaste.Failure.didNotBecomeActive(name: preset.targetName)
                }
            }
            if let folder = preset.destinationFolder {
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true, FileManager.default.isWritableFile(atPath: folder.path) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
            model.deferIntake(); shelf.suspendPresentation(); intakeDeferred = true
            let capture: MomentsCapture = try await withCheckedThrowingContinuation { continuation in
                Self.worker.async {
                    continuation.resume(with: Result {
                        let engine = try MomentsAccessibility(cancellation: token) { [weak self] message in
                            DispatchQueue.main.async { self?.status = message }
                        }
                        return try engine.capture(preset, inbox: inbox)
                    })
                }
            }
            try token.check()
            let reader = InboxReader(inbox: inbox)
            guard let batch = reader.batch(at: capture.directory), batch.items.count == 1 else { throw WeChatAutomationError.invalidArchive }
            let urls = batch.items.map(\.url)
            let destinationName: String
            if let folder = preset.destinationFolder {
                status = L10n.text("正在保存到文件夹…")
                _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[URL], Error>) in
                    Self.worker.async { continuation.resume(with: Result { try QuickForwardFolderDelivery.save(urls, to: folder, checkCancellation: token.check) }) }
                }
                destinationName = folder.lastPathComponent
                status = L10n.format("已保存 %d 条朋友圈 · %d 个媒体文件", capture.count, capture.mediaCount)
            } else if let targetPID {
                status = L10n.format("正在粘贴到 %@…", preset.targetName)
                let plan = PastePlan.make(urls: urls, pathOnly: preset.pastePath, prompt: preferences.prompt.attachment(for: .moments)?.text)
                try await AutoPaste.pasteIntoRunning(pid: targetPID, bundleIdentifier: preset.targetBundleIdentifier,
                                                    displayName: preset.targetName, plan: plan, checkCancellation: token.check)
                destinationName = preset.targetName
                status = L10n.format("已向 %@ 粘贴 %d 条朋友圈 · %d 个媒体文件", preset.targetName, capture.count, capture.mediaCount)
            } else { throw WeChatAutomationError.focusChanged }
            do {
                try reader.markConsumed(itemIDs: Set(batch.items.map(\.id)), in: batch.id)
                try reader.recordOutcome(BatchOutcome(kind: .delivered, at: Date()), targetName: destinationName, for: batch.id)
            } catch { self.error = L10n.text("文件已交付，但记录状态未能保存。") }
            if capture.incomplete || capture.missingMedia > 0 {
                let partialWarning = capture.incomplete
                    ? L10n.text("未取得全部请求内容；已保存的 ZIP 内有缺失说明。")
                    : L10n.format("有 %d 个媒体文件未能保存，TXT 中已注明。", capture.missingMedia)
                error = [error, partialWarning].compactMap { $0 }.joined(separator: "\n")
            }
            if let folder = preset.destinationFolder { NSWorkspace.shared.open(folder) }
        } catch is CancellationError {
            status = L10n.text("已取消，尚未完成的朋友圈采集已停止；已打包的文件保留在暂存架。")
        } catch {
            status = nil; self.error = error.localizedDescription
            hud.hide()
            runner.notify(L10n.format("快捷朋友圈转发失败：%@", error.localizedDescription),
                          action: ToastPresenter.Action(title: L10n.text("打开设置")) { [weak self] in self?.openSettings?(.moments) })
        }
    }
}
