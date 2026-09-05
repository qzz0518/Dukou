import AppKit
import Combine
import DukouCore
import Foundation

/// A batch the app has just noticed, plus what the user asked to happen to it.
///
/// Also raised by the shelf's own context menus and by 记录, which ask for the
/// same destinations for files that are already here — the batch they belong to
/// is resolved from the URLs, so one code path serves both.
struct ArrivedBatch: Sendable {
    let action: ShareAction
    /// Where 「发送到自定义」 was pointed. Nil for every fixed entry, whose
    /// destination the action already names.
    let target: ForwardTarget?
    let urls: [URL]
    /// When the user asked for this — the intent's own timestamp for a share,
    /// and now for a menu inside Dukou. Carried because a forward can wait in
    /// `ActionRunner`'s queue behind another one, and by the time it runs it
    /// may no longer be a gesture anybody is still making.
    let requestedAt: Date

    init(
        action: ShareAction,
        target: ForwardTarget? = nil,
        urls: [URL],
        requestedAt: Date = Date()
    ) {
        self.action = action
        self.target = target
        self.urls = urls
        self.requestedAt = requestedAt
    }

    /// The same window `InboxReader` applies when it reads an intent off disk.
    var isFresh: Bool {
        Date().timeIntervalSince(requestedAt) < BatchIntent.freshnessWindow
    }
}

/// Why an item left the shelf. Only a forward changes what the history says
/// happened to the batch; a drag or a dismissal leaves the record alone, because
/// "已移出" is already visible from the batch having nothing on the shelf.
enum ConsumeReason: Sendable {
    /// Dragged out and accepted by the destination.
    case drag
    /// ✕, "移出暂存架", or the delete key.
    case dismissed
    /// Sent somewhere from the shelf's own menu, and it worked. The name is
    /// carried because 「发送到自定义」 is an entry, not a destination: 记录 has
    /// to be able to say 发给 Cursor once the intent is gone.
    case forwarded(ShareAction, targetName: String? = nil)

    var outcome: BatchOutcome.Kind? {
        switch self {
        case .drag, .dismissed:
            return nil
        case .forwarded(let action, _):
            switch action {
            case .clipboard: return .copied
            case .codex, .claude, .custom: return .delivered
            case .shelf: return .shelved
            }
        }
    }

    var targetName: String? {
        guard case .forwarded(_, let name) = self else { return nil }
        return name
    }
}

/// Everything the shelf, the status menu and the settings window read.
///
/// The model owns no copy of the truth: `reload()` re-reads `Ready` and replaces
/// both lists. That is what makes a lost notification, a crash mid-import or a
/// user deleting a batch in Finder all recover to the same state.
@MainActor
final class AppModel: ObservableObject {
    /// What is on the shelf, newest batch first. A subset of `batches`.
    @Published private(set) var shelfItems: [ReadyItem] = []
    /// Every batch still on disk, newest first — the history.
    @Published private(set) var batches: [ReadyBatch] = []
    /// Selection is a shelf-only idea: the history is a list of records, not of
    /// things to drag.
    @Published var selection: Set<UUID> = []
    /// The row a ⇧-click extends from: the one last clicked without ⇧. Kept
    /// apart from `selection` because a `Set` has no first element to speak
    /// of — extending from whichever member happened to hash first picked a
    /// different range on every click.
    var selectionAnchor: UUID?
    /// Set only for conditions the user can act on — a missing group container
    /// is a build fault, but they still deserve to see it rather than an empty
    /// shelf that never fills.
    @Published private(set) var inboxFailure: String?

    /// Raised once per batch that a rescan finds for the first time, carrying
    /// what the user asked for when they shared it.
    let didArrive = PassthroughSubject<ArrivedBatch, Never>()

    /// Raised when something left the shelf because a drag was accepted. The
    /// shelf's one-time coach mark listens for it: the gesture it describes has
    /// been performed, so it has nothing left to say.
    let didDragOut = PassthroughSubject<Void, Never>()

    /// A share that never became a batch. The extension has no interface to
    /// report one in, so it leaves the message in the app group and this is
    /// where the app picks it up — once, on the scan that follows.
    let didFailToReceive = PassthroughSubject<ShareFailure, Never>()

    private let preferences: Preferences
    private(set) var inbox: Inbox?
    private var reader: InboxReader?
    private var watcher: InboxWatcher?
    private var intakeDeferralCount = 0

    func deferIntake() { intakeDeferralCount += 1 }
    func resumeIntake() {
        intakeDeferralCount = max(0, intakeDeferralCount - 1)
        if intakeDeferralCount == 0 { reload() }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var isShelfEmpty: Bool { shelfItems.isEmpty }

    /// Summed from the batches already in memory rather than from disk: the
    /// settings window reads this while it draws, and a directory walk per frame
    /// is not a thing to do in a view body.
    var historyByteCount: Int64 {
        batches.reduce(0) { $0 + $1.byteCount }
    }

    func start() {
        do {
            let inbox = try Inbox.resolve()
            try inbox.prepareDirectories()
            self.inbox = inbox
            reader = InboxReader(inbox: inbox)
            // Debris from an extension that was killed mid-copy. Safe here
            // because the app runs long after any such copy would have died.
            inbox.pruneStaging()
            let watcher = InboxWatcher(inbox: inbox) { [weak self] in self?.reload() }
            self.watcher = watcher
            watcher.start()
        } catch {
            inboxFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Re-reads `Ready`, announces anything the app has never processed, then
    /// ages out what the retention window says is finished with.
    func reload() {
        guard intakeDeferralCount == 0, let reader else { return }
        publish(reader.loadBatches())

        // `isFirstSeen` comes from `state.json` having had to be written, so it
        // is true exactly once in the app's whole lifetime for a given batch —
        // across relaunches, rescans and second windows. That is what a forward
        // needs: replaying one hours later would paste into someone else's app.
        var recorded = false
        for batch in batches where batch.isFirstSeen {
            recorded = announce(batch, reader: reader) || recorded
        }
        if recorded { publish(reader.loadBatches()) }

        // Read and deleted in one go, so a message is said exactly once however
        // many times the inbox is rescanned.
        for failure in reader.consumeFailures() {
            didFailToReceive.send(failure)
        }

        pruneHistory()
    }

    private func publish(_ loaded: [ReadyBatch]) {
        batches = loaded
        shelfItems = loaded.flatMap(\.shelvedItems)
        selection = selection.intersection(Set(shelfItems.map(\.id)))
        if let anchor = selectionAnchor, !shelfItems.contains(where: { $0.id == anchor }) {
            selectionAnchor = nil
        }
    }

    /// Returns true when it wrote an outcome, so the caller knows the batches it
    /// is holding are stale.
    private func announce(_ batch: ReadyBatch, reader: InboxReader) -> Bool {
        let urls = batch.items.map(\.url)
        switch reader.consumeIntent(forBatch: batch.id) {
        case .ready(let intent):
            didArrive.send(
                ArrivedBatch(
                    action: intent.action,
                    target: intent.target,
                    urls: urls,
                    requestedAt: intent.requestedAt
                )
            )
            return false
        case .expired(let intent):
            // Only a paste can go stale. A copy was finished by the extension
            // itself, however long ago — only an older extension build writes
            // an intent for one — and `BatchState.initial` already said 已复制.
            guard intent.action != .clipboard else { return false }
            // The user did ask for this; it simply cannot be honoured now.
            record(.expired, for: [batch.id])
            return true
        case .none:
            switch batch.action {
            case .shelf:
                // Already shelved by `BatchState.initial`; the announcement is
                // what lets the shelf bump instead of appearing from nowhere.
                didArrive.send(ArrivedBatch(action: .shelf, urls: urls))
                return false
            case .clipboard:
                // Already copied, by the extension, and already recorded as
                // such by `BatchState.initial`. Nothing left to do.
                return false
            case .codex, .claude, .custom:
                // A forward whose one-shot request is already gone: the file was
                // consumed by a run that then died before it could act, or the
                // extension never managed to write it. Either way nothing can be
                // carried out, and the history must not claim otherwise.
                record(.expired, for: [batch.id])
                return true
            }
        }
    }

    // MARK: - Lookup

    func item(id: UUID) -> ReadyItem? {
        shelfItems.first { $0.id == id } ?? batches.flatMap(\.items).first { $0.id == id }
    }

    func batch(id: UUID) -> ReadyBatch? {
        batches.first { $0.id == id }
    }

    /// Batches these files belong to. Matched on path because the URLs come back
    /// from AppKit drags and pasteboards, which do not promise to hand back the
    /// very `URL` value they were given.
    func batchIDs(for urls: [URL]) -> Set<UUID> {
        Set(items(for: urls).map(\.batchID))
    }

    private func items(for urls: [URL]) -> [ReadyItem] {
        let paths = Set(urls.map(\.standardizedFileURL.path))
        return batches.flatMap(\.items).filter { paths.contains($0.url.standardizedFileURL.path) }
    }

    /// A drag carries the whole selection when the dragged row is part of it,
    /// and just that row otherwise — the behaviour Finder has trained everyone
    /// to expect.
    func dragURLs(startingAt id: UUID) -> [URL] {
        if selection.contains(id) {
            return shelfItems.filter { selection.contains($0.id) }.map(\.url)
        }
        return item(id: id).map { [$0.url] } ?? []
    }

    // MARK: - Shelf

    /// Takes items off the shelf. The files stay: the destination of a drag may
    /// read them long after the drop, and the history keeps them until the
    /// retention window or the user says otherwise.
    func consume(ids: Set<UUID>, via reason: ConsumeReason) {
        guard let reader, !ids.isEmpty else { return }
        let affected = Dictionary(
            grouping: batches.flatMap(\.items).filter { ids.contains($0.id) },
            by: \.batchID
        )
        for (batchID, items) in affected {
            do {
                try reader.markConsumed(itemIDs: Set(items.map(\.id)), in: batchID)
            } catch {
                inboxFailure = error.localizedDescription
            }
            // A batch has one outcome, so a partial forward cannot claim it:
            // sending two rows of a five-file batch to Claude from the expanded
            // list would otherwise stamp the whole batch 已送达, for three files
            // that were never sent.
            guard let kind = reason.outcome,
                  items.count == batch(id: batchID)?.items.count
            else { continue }
            try? reader.recordOutcome(
                BatchOutcome(kind: kind, at: Date()),
                targetName: reason.targetName,
                for: batchID
            )
        }
        selection.subtract(ids)
        if case .drag = reason { didDragOut.send() }
        reload()
    }

    func consume(urls: [URL], via reason: ConsumeReason) {
        consume(ids: Set(items(for: urls).map(\.id)), via: reason)
    }

    func consumeAll() {
        consume(ids: Set(shelfItems.map(\.id)), via: .dismissed)
    }

    /// Puts a whole batch back on the shelf. The shelf becomes visible again as
    /// a consequence of having something on it, not as a separate command.
    func restore(batchID: UUID) {
        guard let reader else { return }
        do {
            try reader.restore(batchID: batchID)
        } catch {
            inboxFailure = error.localizedDescription
        }
        reload()
    }

    func restore(urls: [URL]) {
        for batchID in batchIDs(for: urls) { restore(batchID: batchID) }
    }

    // MARK: - History

    /// Records how a forward ended. The files are on the clipboard either way,
    /// which is why a failure is a record rather than an error dialog.
    func recordFailure(_ detail: String, urls: [URL], targetName: String? = nil) {
        record(.failed, detail: detail, targetName: targetName, for: batchIDs(for: urls))
        reload()
    }

    /// A forward that was never carried out because too long passed between the
    /// gesture and its turn — queued behind another forward, or waiting on a
    /// question nobody answered. The same record an intent found hours later
    /// gets: 未执行, nothing pasted, files still on the clipboard.
    func recordExpired(urls: [URL]) {
        record(.expired, for: batchIDs(for: urls))
        reload()
    }

    private func record(
        _ kind: BatchOutcome.Kind,
        detail: String? = nil,
        targetName: String? = nil,
        for batchIDs: Set<UUID>
    ) {
        guard let reader else { return }
        for batchID in batchIDs {
            try? reader.recordOutcome(
                BatchOutcome(kind: kind, detail: detail, at: Date()),
                targetName: targetName,
                for: batchID
            )
        }
    }

    /// Moves individual files to the Trash — the only gesture in Dukou that
    /// actually destroys anything.
    func discard(ids: Set<UUID>) {
        guard let reader else { return }
        for id in ids {
            guard let item = item(id: id) else { continue }
            do {
                try reader.discard(item: item)
            } catch {
                inboxFailure = error.localizedDescription
            }
        }
        selection.subtract(ids)
        reload()
    }

    func discard(batchID: UUID) {
        guard let reader else { return }
        do {
            try reader.discard(batchID: batchID)
        } catch {
            inboxFailure = error.localizedDescription
        }
        reload()
    }

    /// Clears the history without disturbing the shelf: whatever is parked on
    /// screen is the user saying they are not finished with it.
    func discardHistory() {
        guard let reader else { return }
        for batch in batches where batch.shelvedCount == 0 {
            do {
                try reader.discard(batchID: batch.id)
            } catch {
                inboxFailure = error.localizedDescription
            }
        }
        reload()
    }

    var hasDiscardableHistory: Bool {
        batches.contains { $0.shelvedCount == 0 }
    }

    /// Runs at launch and after every reload. Reloading again only when
    /// something was actually removed is what keeps this from recursing.
    func pruneHistory() {
        guard let reader, preferences.historyRetentionDays > 0 else { return }
        let window = TimeInterval(preferences.historyRetentionDays) * 24 * 60 * 60
        if reader.pruneHistory(olderThan: window) > 0 { reload() }
    }

    // MARK: - Finder

    func reveal(id: UUID) {
        guard let item = item(id: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func revealInbox() {
        guard let inbox else { return }
        try? inbox.prepareDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([inbox.ready])
    }

    func open(id: UUID) {
        guard let item = item(id: id) else { return }
        NSWorkspace.shared.open(item.url)
    }
}
