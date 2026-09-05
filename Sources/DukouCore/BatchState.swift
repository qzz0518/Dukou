import Foundation

/// What became of a batch, as far as the user is concerned.
///
/// One record per batch, overwritten as the batch's story moves on: a forward
/// that failed and was then put on the shelf ends up `shelved`, because that is
/// where the files actually are. `detail` carries the failure text so the
/// history can say *why* something did not arrive, which is the only part of a
/// failure the user can act on.
public struct BatchOutcome: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Parked on the shelf. Still the outcome after the user drags the files
        /// out — `shelvedCount` is what says whether they are still there.
        case shelved
        /// Activated the target app and pressed ⌘V for the user.
        case delivered
        /// Written to the clipboard and nothing else.
        case copied
        /// A forward that did not happen. The files are on the clipboard.
        case failed
        /// The request was found too late to carry out — the Mac was asleep or
        /// Dukou never started — so nothing was done with it at all.
        case expired
    }

    public let kind: Kind
    public let detail: String?
    public let at: Date

    public init(kind: Kind, detail: String? = nil, at: Date) {
        self.kind = kind
        self.detail = detail
        self.at = at
    }
}

/// The app's own notes about a batch: `Ready/<batch-id>/state.json`.
///
/// Kept beside the manifest instead of inside it because the two have different
/// writers. The extension owns the manifest and never reads this file; the app
/// owns this file and never rewrites the manifest except to drop an item. That
/// split is what lets the app record a shelf change without racing an extension
/// that may be committing another batch at the same moment.
public struct BatchState: Codable, Sendable, Hashable {
    public static let fileName = "state.json"
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// Item IDs currently on the shelf. Items are consumed, not deleted, so this
    /// shrinks to nothing while the files and the history entry stay.
    public let shelved: [UUID]
    /// Nil only while a forward has been noticed but not yet carried out.
    public let outcome: BatchOutcome?
    /// Which Share-menu entry actually produced this batch.
    ///
    /// Recorded here as well as in the manifest because a manifest written
    /// before the `action` field existed decodes as `.shelf`, and the only
    /// other record of the request — `intent.json` — is consumed the instant
    /// the batch is first processed. Without this, every forward made by an
    /// older build would read 「暂存到渡口」 in the history forever.
    public let action: ShareAction?
    /// When the last item left the shelf, if it ever did.
    ///
    /// The retention clock runs from here rather than from `createdAt`: a file
    /// parked on the shelf for a fortnight and then dragged out has to stay in
    /// 记录 afterwards, and the destination of that drag may not read the bytes
    /// until seconds after the drop.
    public let clearedAt: Date?
    /// Which app a 「发送到自定义」 batch was pointed at, as it was named on
    /// screen at the time.
    ///
    /// Kept here because `intent.json` is consumed the instant the batch is
    /// first processed, and 记录 still has to read 「发给 Cursor」 a week later —
    /// 「发送到自定义」 on its own would say nothing about where the files went.
    /// Nil for every other entry, and nil in every state file written before
    /// this field existed.
    public let targetName: String?

    public init(
        shelved: [UUID],
        outcome: BatchOutcome?,
        action: ShareAction? = nil,
        clearedAt: Date? = nil,
        targetName: String? = nil,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.shelved = shelved
        self.outcome = outcome
        self.action = action
        self.clearedAt = clearedAt
        self.targetName = targetName
    }

    /// The state a batch gets the first time the app ever sees it.
    ///
    /// Only "暂存到渡口" puts anything on the shelf: a forward is meant to end
    /// up in another app, and a shelf that fills with every share the user ever
    /// forwarded would be the clutter the shelf exists to avoid. The outcome is
    /// stamped with the batch's own creation time rather than now, so a batch
    /// found after a week away is not backdated to this launch.
    ///
    /// `requestedAction` is what `intent.json` asked for, and it wins over the
    /// manifest: a batch written before the manifest carried `action` decodes
    /// as `.shelf`, and shelving a forward would pop the shelf open for a share
    /// meant for another app — the one thing §2 says must never happen.
    public static func initial(
        for manifest: BatchManifest,
        requestedAction: ShareAction? = nil,
        targetName: String? = nil
    ) -> BatchState {
        let action = requestedAction ?? manifest.action
        switch action {
        case .shelf:
            return BatchState(
                shelved: manifest.items.map(\.id),
                outcome: BatchOutcome(kind: .shelved, at: manifest.createdAt),
                action: action,
                targetName: targetName
            )
        case .clipboard:
            // Already done: the extension wrote the pasteboard before it exited,
            // and the app is not even launched for it. Left nil, the first
            // launch after a copy found "a request that never ran" and wrote
            // 未执行 over a copy that had worked.
            return BatchState(
                shelved: [],
                outcome: BatchOutcome(kind: .copied, at: manifest.createdAt),
                action: action,
                targetName: targetName
            )
        case .codex, .claude, .custom:
            return BatchState(shelved: [], outcome: nil, action: action, targetName: targetName)
        }
    }

    /// `clearedAt` defaults to nil because the common caller is "putting things
    /// back": a batch that is on the shelf again has no retention clock running.
    public func withShelved(_ shelved: [UUID], clearedAt: Date? = nil) -> BatchState {
        BatchState(
            shelved: shelved,
            outcome: outcome,
            action: action,
            clearedAt: clearedAt,
            targetName: targetName,
            schemaVersion: schemaVersion
        )
    }

    /// `targetName` defaults to "leave it alone": most outcomes are recorded by
    /// code that has no opinion about the destination, and passing nil there
    /// must not erase the name a custom forward already wrote.
    public func withOutcome(_ outcome: BatchOutcome?, targetName: String? = nil) -> BatchState {
        BatchState(
            shelved: shelved,
            outcome: outcome,
            action: action,
            clearedAt: clearedAt,
            targetName: targetName ?? self.targetName,
            schemaVersion: schemaVersion
        )
    }
}
