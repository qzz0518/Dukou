import Foundation

public struct ReadyItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let batchID: UUID
    public let displayName: String
    public let url: URL
    public let byteCount: Int64
    public let contentType: String?
    public let createdAt: Date
    /// Where the batch this item belongs to came from. Carried on the item so a
    /// shelf row can say "发给 Claude 失败的那一批" without a second lookup.
    public let action: ShareAction
    /// On the shelf right now. False once the user has dragged it out, forwarded
    /// it, or dismissed it — the file itself is untouched either way.
    public let isShelved: Bool

    public init(
        id: UUID,
        batchID: UUID,
        displayName: String,
        url: URL,
        byteCount: Int64,
        contentType: String?,
        createdAt: Date,
        action: ShareAction,
        isShelved: Bool
    ) {
        self.id = id
        self.batchID = batchID
        self.displayName = displayName
        self.url = url
        self.byteCount = byteCount
        self.contentType = contentType
        self.createdAt = createdAt
        self.action = action
        self.isShelved = isShelved
    }
}

public struct ReadyBatch: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let directory: URL
    public let createdAt: Date
    public let action: ShareAction
    public let items: [ReadyItem]
    public let outcome: BatchOutcome?
    /// The app a 「发送到自定义」 batch was pointed at, as it was named on screen
    /// when the user picked it. Nil for every other entry.
    public let targetName: String?
    /// When the last item left the shelf, if it ever did. The retention sweep
    /// ages a batch from here rather than from `createdAt`, so a file parked on
    /// the shelf past the window is not trashed the instant it is dragged out.
    public let clearedAt: Date?
    /// True when this very load had to write `state.json`, which is the one
    /// durable signal that no run of the app has ever processed this batch.
    /// A batch that is merely new to *this process* — every batch, after a
    /// relaunch — is not an arrival and must not replay a forward.
    public let isFirstSeen: Bool

    public init(
        id: UUID,
        directory: URL,
        createdAt: Date,
        action: ShareAction,
        items: [ReadyItem],
        outcome: BatchOutcome?,
        targetName: String? = nil,
        clearedAt: Date? = nil,
        isFirstSeen: Bool
    ) {
        self.id = id
        self.directory = directory
        self.createdAt = createdAt
        self.action = action
        self.items = items
        self.outcome = outcome
        self.targetName = targetName
        self.clearedAt = clearedAt
        self.isFirstSeen = isFirstSeen
    }

    public var shelvedItems: [ReadyItem] { items.filter(\.isShelved) }
    public var shelvedCount: Int { items.lazy.filter(\.isShelved).count }
    public var byteCount: Int64 { items.reduce(0) { $0 + $1.byteCount } }
}

/// The app's half of the inbox protocol: read `Ready`, never touch `Staging`.
///
/// The app is the only process that writes into `Ready` after the extension's
/// commit rename, so rewriting a manifest to drop one item, or writing
/// `state.json`, needs no cross-process coordination — the extension only ever
/// creates new batches under new UUIDs.
public struct InboxReader {
    /// How a removed batch leaves the container.
    public enum Removal: Sendable {
        /// The product behaviour: recoverable from Finder.
        case trash
        /// Used by tests, which must not deposit fixtures in the user's Trash.
        case delete
    }

    public let inbox: Inbox
    private let fileManager: FileManager
    private let removal: Removal

    public init(inbox: Inbox, fileManager: FileManager = .default, removal: Removal = .trash) {
        self.inbox = inbox
        self.fileManager = fileManager
        self.removal = removal
    }

    /// Newest batch first. A batch whose manifest is missing, unreadable or
    /// written by a newer schema is skipped rather than partially shown: a
    /// half-listed share is worse than a share the user can still find on disk.
    ///
    /// Reading is also what initialises a batch: a batch without `state.json`
    /// has never been processed, so one is written here from the manifest's
    /// action. Doing it during the read keeps "the app has seen this" and "the
    /// app knows about this" from ever disagreeing after a crash.
    public func loadBatches() -> [ReadyBatch] {
        batches(initializing: true)
    }

    /// `isFirstSeen` is spent the moment `state.json` lands on disk, and it is
    /// the only durable signal that a forward has never been carried out. So
    /// anything that merely counts or sweeps batches reads with
    /// `initializing: false`: were it to initialise, the `reload()` that
    /// follows would find nothing to announce and the user's forward would be
    /// silently dropped.
    private func batches(initializing: Bool) -> [ReadyBatch] {
        let directories = (try? fileManager.contentsOfDirectory(
            at: inbox.ready,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories
            .compactMap { batch(at: $0, initializing: initializing) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func batch(at directory: URL) -> ReadyBatch? {
        batch(at: directory, initializing: true)
    }

    private func batch(at directory: URL, initializing: Bool) -> ReadyBatch? {
        guard let manifest = manifest(at: directory) else { return nil }

        let stored = state(at: directory)
        // A batch written before the manifest carried `action` decodes as
        // `.shelf`, and shelving a forward is wrong twice over: the shelf pops
        // open for a share meant for another app, and the history labels it
        // 「暂存到渡口」. The request is still on disk at this point — reading
        // it without consuming it is the only thing that can tell them apart.
        let requested = stored == nil ? peekIntent(at: directory) : nil
        let state = stored ?? BatchState.initial(
            for: manifest,
            requestedAction: requested?.action,
            targetName: requested?.targetDisplayName
        )
        // Best effort: a container that refuses the write still shows the user
        // their files, it just re-derives the same state on the next read.
        if stored == nil, initializing { try? write(state, at: directory) }

        // The state's own copy outlives `intent.json`, so the history keeps
        // saying where a legacy batch came from long after the request is gone.
        let action = state.action ?? manifest.action
        let shelved = Set(state.shelved)
        let items = manifest.items.compactMap { item -> ReadyItem? in
            let url = directory.appendingPathComponent(item.relativePath)
            // A manifest entry without its file is debris from a manual delete
            // in Finder, not a batch to advertise.
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return ReadyItem(
                id: item.id,
                batchID: manifest.batchID,
                displayName: item.displayName,
                url: url,
                byteCount: item.byteCount,
                contentType: item.contentType,
                createdAt: manifest.createdAt,
                action: action,
                isShelved: shelved.contains(item.id)
            )
        }
        guard !items.isEmpty else { return nil }
        return ReadyBatch(
            id: manifest.batchID,
            directory: directory,
            createdAt: manifest.createdAt,
            action: action,
            items: items,
            outcome: state.outcome,
            targetName: state.targetName,
            clearedAt: state.clearedAt,
            isFirstSeen: stored == nil && initializing
        )
    }

    /// Every batch still on disk, in bytes. What the settings window reports as
    /// "占用", so it counts the payload the user could get back by clearing the
    /// history — not the manifests and state files around it.
    public func totalByteCount() -> Int64 {
        batches(initializing: false).reduce(0) { $0 + $1.byteCount }
    }

    // MARK: - Shelf state

    /// Takes items off the shelf without touching their files.
    ///
    /// The file stays because the destination of a drag may read it long after
    /// the drop — and because "移出暂存架" is not "删除". The history keeps the
    /// batch until it is trashed by hand or aged out.
    public func markConsumed(itemIDs: Set<UUID>, in batchID: UUID, now: Date = Date()) throws {
        try mutateState(batchID: batchID) { state in
            let remaining = state.shelved.filter { !itemIDs.contains($0) }
            // The retention clock starts when the shelf lets go, not when the
            // share arrived — otherwise dragging out a batch that has been
            // parked longer than the window trashes it in the same instant,
            // before the destination has read a single byte. Stamped once and
            // kept, so a second consume cannot keep pushing the expiry out.
            let cleared = remaining.isEmpty ? (state.clearedAt ?? now) : nil
            return state.withShelved(remaining, clearedAt: cleared)
        }
    }

    /// Puts every item of a batch back on the shelf.
    ///
    /// The outcome is deliberately left alone: how the batch was *asked* to be
    /// handled is history, and a restored batch already reads as "在暂存架上"
    /// through `shelvedCount`.
    public func restore(batchID: UUID) throws {
        let directory = directory(for: batchID)
        guard let manifest = manifest(at: directory) else {
            throw InboxError.manifestUnreadable(reason: BatchStaging.manifestFileName)
        }
        let current = state(at: directory) ?? BatchState.initial(for: manifest)
        try write(current.withShelved(manifest.items.map(\.id)), at: directory)
    }

    /// `targetName` is only ever written, never cleared: a forward from the
    /// shelf's own 发给 ▸ menu names the app it went to, and every other caller
    /// leaves whatever the batch already said alone.
    public func recordOutcome(
        _ outcome: BatchOutcome,
        targetName: String? = nil,
        for batchID: UUID
    ) throws {
        try mutateState(batchID: batchID) { $0.withOutcome(outcome, targetName: targetName) }
    }

    public func state(forBatch batchID: UUID) -> BatchState? {
        state(at: directory(for: batchID))
    }

    // MARK: - Removal

    /// Moves a whole batch to the user's Trash.
    ///
    /// Trash rather than `removeItem` on purpose: "移到废纸篓" is a routine
    /// gesture, and the archive may be the only copy of a chat export the user
    /// has. Finder's own restore is a better undo than anything Dukou would
    /// build, and it costs no extra lifecycle in the group container.
    public func discard(batchID: UUID) throws {
        try trashOrRemove(directory(for: batchID))
    }

    /// Removes one item and rewrites the batch manifest; the batch itself goes
    /// away once its last item does.
    public func discard(item: ReadyItem) throws {
        let directory = directory(for: item.batchID)
        guard let manifest = manifest(at: directory) else {
            throw InboxError.manifestUnreadable(reason: BatchStaging.manifestFileName)
        }

        let remaining = manifest.items.filter { $0.id != item.id }
        guard !remaining.isEmpty else {
            try trashOrRemove(directory)
            return
        }

        try trashOrRemove(item.url.deletingLastPathComponent())
        let updated = BatchManifest(
            batchID: manifest.batchID,
            createdAt: manifest.createdAt,
            items: remaining,
            action: manifest.action,
            schemaVersion: manifest.schemaVersion
        )
        try BatchManifest.encoder().encode(updated).write(
            to: directory.appendingPathComponent(BatchStaging.manifestFileName),
            options: .atomic
        )
        // A shelf entry for a file that no longer exists would keep the shelf
        // open with nothing in it.
        try? markConsumed(itemIDs: [item.id], in: item.batchID)
    }

    public func discardAll() throws {
        for batch in batches(initializing: false) {
            try discard(batchID: batch.id)
        }
    }

    /// Ages out history the user has finished with.
    ///
    /// A batch with anything still on the shelf is never touched, however old it
    /// is: the shelf is the user saying "I am not done with this", and silently
    /// trashing what is visibly parked in the corner of their screen is the one
    /// unforgivable failure for a tool that holds files. Returns how many
    /// batches were removed.
    @discardableResult
    public func pruneHistory(olderThan interval: TimeInterval, now: Date = Date()) -> Int {
        // A non-positive window means "keep forever", not "delete everything":
        // the preference's 0 is the "从不" option.
        guard interval > 0 else { return 0 }
        var removed = 0
        for batch in batches(initializing: false) {
            guard batch.shelvedCount == 0 else { continue }
            let since = max(batch.createdAt, batch.clearedAt ?? .distantPast)
            guard now.timeIntervalSince(since) > interval else { continue }
            if (try? discard(batchID: batch.id)) != nil { removed += 1 }
        }
        return removed + pruneUnreadable(olderThan: interval, now: now)
    }

    /// Debris no `ReadyBatch` can be built from: a manifest truncated by a
    /// crash mid-write, or a batch whose files were deleted by hand in Finder.
    /// It is invisible in 记录 and counts for nothing in 占用, so without this
    /// it would sit in the group container forever.
    ///
    /// A manifest written by a *newer* schema is the one thing left alone: a
    /// future build understands it, and this one has no business trashing what
    /// it merely cannot read yet.
    private func pruneUnreadable(olderThan interval: TimeInterval, now: Date) -> Int {
        let directories = (try? fileManager.contentsOfDirectory(
            at: inbox.ready,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var removed = 0
        for directory in directories {
            guard batch(at: directory, initializing: false) == nil else { continue }
            let data = try? Data(contentsOf: directory.appendingPathComponent(BatchStaging.manifestFileName))
            let decoded = data.flatMap { try? BatchManifest.decoder().decode(BatchManifest.self, from: $0) }
            if let decoded, decoded.schemaVersion > BatchManifest.currentSchemaVersion { continue }
            let values = try? directory.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            guard values?.isDirectory != false else { continue }
            // An unparseable manifest still leaves the directory's own creation
            // date. Unknown age counts as "just arrived", because trashing on a
            // guess is the one mistake with no way back.
            let created = decoded?.createdAt ?? values?.creationDate ?? now
            guard now.timeIntervalSince(created) > interval else { continue }
            if (try? trashOrRemove(directory)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Failures

    /// Every message the extension left behind, oldest first, read and deleted
    /// in one gesture.
    ///
    /// Deleting as it reads is the whole protocol: there is no state to say a
    /// failure has been shown, so the file's existence *is* that state. A
    /// report the app cannot decode is deleted too — a stale byte sequence
    /// nothing will ever be able to read would otherwise be re-examined on
    /// every scan for the life of the container.
    public func consumeFailures() -> [ShareFailure] {
        let files = (try? fileManager.contentsOfDirectory(
            at: inbox.failures,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        var failures: [ShareFailure] = []
        for file in files where file.pathExtension == "json" {
            let data = try? Data(contentsOf: file)
            try? fileManager.removeItem(at: file)
            guard let data,
                  let failure = try? BatchManifest.decoder().decode(ShareFailure.self, from: data)
            else { continue }
            failures.append(failure)
        }
        // Oldest first, so a burst of them ends with the most recent message on
        // screen: the toast replaces its own content rather than queueing.
        return failures.sorted { $0.at < $1.at }
    }

    // MARK: - Files

    private func directory(for batchID: UUID) -> URL {
        inbox.ready.appendingPathComponent(batchID.uuidString, isDirectory: true)
    }

    private func manifest(at directory: URL) -> BatchManifest? {
        let url = directory.appendingPathComponent(BatchStaging.manifestFileName)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? BatchManifest.decoder().decode(BatchManifest.self, from: data),
              manifest.schemaVersion <= BatchManifest.currentSchemaVersion
        else { return nil }
        return manifest
    }

    private func state(at directory: URL) -> BatchState? {
        let url = directory.appendingPathComponent(BatchState.fileName)
        guard let data = try? Data(contentsOf: url),
              let state = try? BatchManifest.decoder().decode(BatchState.self, from: data),
              state.schemaVersion <= BatchState.currentSchemaVersion
        else { return nil }
        return state
    }

    private func write(_ state: BatchState, at directory: URL) throws {
        try BatchManifest.encoder().encode(state).write(
            to: directory.appendingPathComponent(BatchState.fileName),
            options: .atomic
        )
    }

    /// Read-modify-write against the file rather than against a `ReadyBatch` the
    /// caller is holding: two shelf gestures in the same run loop turn would
    /// otherwise each write the state they were built from and lose one another.
    private func mutateState(batchID: UUID, _ transform: (BatchState) -> BatchState) throws {
        let directory = directory(for: batchID)
        guard let manifest = manifest(at: directory) else {
            throw InboxError.manifestUnreadable(reason: BatchStaging.manifestFileName)
        }
        let current = state(at: directory) ?? BatchState.initial(for: manifest)
        try write(transform(current), at: directory)
    }

    /// A volume without a trash (or a sandbox refusal) must not leave the user
    /// unable to clear the shelf.
    private func trashOrRemove(_ url: URL) throws {
        guard removal == .trash else {
            try fileManager.removeItem(at: url)
            return
        }
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try fileManager.removeItem(at: url)
        }
    }
}

/// What `consumeIntent` found. A stale request is reported as its own case
/// rather than as "nothing": the user did ask for a forward, it did not happen,
/// and the history has to be able to say so.
public enum ConsumedIntent: Sendable, Hashable {
    /// No request attached — a shelf batch — or one that was already consumed,
    /// or one written by a schema this build cannot read.
    case none
    /// Requested moments ago: carry it out.
    case ready(BatchIntent)
    /// Requested too long ago to act on. Record it, do not run it.
    case expired(BatchIntent)

    public var action: ShareAction? {
        switch self {
        case .none: return nil
        case .ready(let intent), .expired(let intent): return intent.action
        }
    }
}

extension InboxReader {
    /// Reads and immediately consumes the batch's one-shot request.
    ///
    /// Consumption is the deletion: an intent that has been read is gone from
    /// disk, so a rescan, a relaunch or a second window can never replay a
    /// forward the user asked for once. A stale request is consumed too — and
    /// reported as `.expired`, because pasting into whatever app happens to be
    /// frontmost hours later is worse than doing nothing.
    public func consumeIntent(forBatch batchID: UUID, now: Date = Date()) -> ConsumedIntent {
        let url = directory(for: batchID).appendingPathComponent(BatchIntent.fileName)
        guard let data = try? Data(contentsOf: url) else { return .none }
        try? fileManager.removeItem(at: url)

        guard let intent = try? BatchManifest.decoder().decode(BatchIntent.self, from: data),
              intent.schemaVersion <= BatchIntent.currentSchemaVersion
        else { return .none }
        return intent.isFresh(now: now) ? .ready(intent) : .expired(intent)
    }

    /// The batch's request, read and left exactly where it is.
    ///
    /// `consumeIntent` deletes as it reads, on purpose — a forward must never
    /// replay. But the shelving decision has to be made *before* that, while
    /// the app is only asking what the user wanted, so this is the one read
    /// that leaves the file alone. Freshness is irrelevant here: a stale
    /// forward is still a forward, and still must not land on the shelf. The
    /// chosen app comes back with it, because 记录 has to keep saying 「发给
    /// Cursor」 long after `intent.json` is gone.
    private func peekIntent(at directory: URL) -> BatchIntent? {
        let url = directory.appendingPathComponent(BatchIntent.fileName)
        guard let data = try? Data(contentsOf: url),
              let intent = try? BatchManifest.decoder().decode(BatchIntent.self, from: data),
              intent.schemaVersion <= BatchIntent.currentSchemaVersion
        else { return nil }
        return intent
    }
}
