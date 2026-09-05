import DukouCore
import Foundation
import XCTest

/// The app-owned half of a batch: which items are on the shelf, and what became
/// of the share. All of it is on disk, because the answer has to survive a
/// relaunch — a forward that replays hours later is the failure this state file
/// exists to prevent.
final class BatchStateTests: XCTestCase {
    private var temporary: TemporaryInbox!

    override func setUp() {
        super.setUp()
        temporary = TemporaryInbox()
    }

    override func tearDown() {
        temporary.tearDown()
        super.tearDown()
    }

    // MARK: - Manifest

    func testAManifestWithoutAnActionFieldReadsAsShelf() throws {
        let directory = try temporary.commitBatch(names: ["旧的.zip"], action: .claude)
        let url = directory.appendingPathComponent("manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        // Exactly what a manifest written by the shipped build looks like.
        json.removeValue(forKey: "action")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(batch.action, .shelf)
        XCTAssertEqual(batch.items.map(\.action), [.shelf])
    }

    func testAnActionSurvivesTheManifestRoundTrip() throws {
        let manifest = BatchManifest(
            batchID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_772_000_000),
            items: [],
            action: .codex
        )
        let data = try BatchManifest.encoder().encode(manifest)
        XCTAssertEqual(try BatchManifest.decoder().decode(BatchManifest.self, from: data), manifest)
    }

    // MARK: - Initialisation

    func testAShelfBatchStartsWithEveryItemOnTheShelf() throws {
        let directory = try temporary.commitBatch(names: ["a.zip", "b.zip"], action: .shelf)

        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(batch.shelvedCount, 2)
        XCTAssertEqual(batch.outcome?.kind, .shelved)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(BatchState.fileName).path
            ),
            "the state must be on disk, not only in the returned value"
        )
    }

    func testAForwardBatchStartsWithNothingOnTheShelf() throws {
        try temporary.commitBatch(names: ["a.zip"], action: .claude)

        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(batch.shelvedCount, 0)
        XCTAssertFalse(batch.items[0].isShelved)
        // Nothing has happened to it yet; the app records that once it has run.
        XCTAssertNil(batch.outcome)
    }

    func testABatchIsOnlyEverFirstSeenOnce() throws {
        try temporary.commitBatch(names: ["a.zip"])

        XCTAssertEqual(temporary.reader.loadBatches().map(\.isFirstSeen), [true])
        // A second reader is a second launch: the batch is new to the process
        // and not new to the app, which is what stops a forward replaying.
        XCTAssertEqual(temporary.reader.loadBatches().map(\.isFirstSeen), [false])
    }

    func testTheShelvedOutcomeIsStampedWithTheShareTimeNotTheReadTime() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try temporary.commitBatch(names: ["a.zip"], createdAt: created)

        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(batch.outcome?.at, created)
    }

    // MARK: - Consume and restore

    func testConsumingTakesItemsOffTheShelfAndLeavesTheFiles() throws {
        try temporary.commitBatch(names: ["a.zip", "b.zip"])
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        let first = batch.items[0]

        try temporary.reader.markConsumed(itemIDs: [first.id], in: batch.id)

        let reloaded = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(reloaded.shelvedItems.map(\.displayName), ["b.zip"])
        XCTAssertEqual(reloaded.items.count, 2, "the batch keeps both files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
    }

    func testRestorePutsTheWholeBatchBackOnTheShelf() throws {
        try temporary.commitBatch(names: ["a.zip", "b.zip"])
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        try temporary.reader.markConsumed(itemIDs: Set(batch.items.map(\.id)), in: batch.id)
        XCTAssertEqual(temporary.reader.loadBatches().first?.shelvedCount, 0)

        try temporary.reader.restore(batchID: batch.id)

        XCTAssertEqual(temporary.reader.loadBatches().first?.shelvedCount, 2)
    }

    func testRestoreLeavesTheRecordedOutcomeAlone() throws {
        try temporary.commitBatch(names: ["a.zip"], action: .claude)
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        try temporary.reader.recordOutcome(
            BatchOutcome(kind: .failed, detail: "Claude 没有切到前台", at: Date()),
            for: batch.id
        )

        try temporary.reader.restore(batchID: batch.id)

        let reloaded = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(reloaded.shelvedCount, 1)
        // Why it is on the shelf is still worth saying: it is here because a
        // forward failed, not because the user asked for the shelf.
        XCTAssertEqual(reloaded.outcome?.kind, .failed)
        XCTAssertEqual(reloaded.outcome?.detail, "Claude 没有切到前台")
    }

    func testTrashingOneItemAlsoTakesItOffTheShelf() throws {
        try temporary.commitBatch(names: ["a.zip", "b.zip"])
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)

        try temporary.reader.discard(item: batch.items[0])

        let reloaded = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(reloaded.shelvedItems.map(\.displayName), ["b.zip"])
    }

    // MARK: - Outcome

    func testAnOutcomeSurvivesAReload() throws {
        try temporary.commitBatch(names: ["a.zip"], action: .clipboard)
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        let at = Date(timeIntervalSince1970: 1_772_000_000)

        try temporary.reader.recordOutcome(BatchOutcome(kind: .copied, at: at), for: batch.id)

        let reloaded = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(reloaded.outcome?.kind, .copied)
        XCTAssertEqual(reloaded.outcome?.at, at)
        XCTAssertNil(reloaded.outcome?.detail)
    }

    /// 「复制到剪贴板」 is finished by the extension before it exits, and the app
    /// is not launched for it. The batch therefore has to arrive already
    /// recorded: a launch days later must read 已复制, not 未执行.
    func testAClipboardBatchArrivesAlreadyCopied() throws {
        let createdAt = Date(timeIntervalSince1970: 1_772_000_000)
        try temporary.commitBatch(names: ["a.zip"], createdAt: createdAt, action: .clipboard)

        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(batch.outcome?.kind, .copied)
        XCTAssertEqual(batch.outcome?.at, createdAt)
        XCTAssertEqual(batch.shelvedCount, 0)
        XCTAssertTrue(batch.isFirstSeen)
    }

    func testRecordingAnOutcomeDoesNotDisturbTheShelf() throws {
        try temporary.commitBatch(names: ["a.zip", "b.zip"])
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)

        try temporary.reader.recordOutcome(BatchOutcome(kind: .delivered, at: Date()), for: batch.id)

        XCTAssertEqual(temporary.reader.loadBatches().first?.shelvedCount, 2)
    }

    // MARK: - Pruning

    func testPruningRemovesOnlyBatchesPastTheWindow() throws {
        let now = Date()
        let week: TimeInterval = 7 * 24 * 60 * 60
        try temporary.commitBatch(
            names: ["old.zip"],
            createdAt: now.addingTimeInterval(-week - 60),
            action: .claude
        )
        try temporary.commitBatch(
            names: ["fresh.zip"],
            createdAt: now.addingTimeInterval(-60),
            action: .claude
        )

        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: week, now: now), 1)
        XCTAssertEqual(
            temporary.reader.loadBatches().flatMap(\.items).map(\.displayName),
            ["fresh.zip"]
        )
    }

    func testABatchExactlyAtTheWindowIsKept() throws {
        // A whole second, because `createdAt` round-trips through ISO-8601 and
        // comes back without its fraction: a boundary written as `Date()` minus
        // a day reads back a few hundred milliseconds *older* than the window.
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let day: TimeInterval = 24 * 60 * 60
        try temporary.commitBatch(names: ["edge.zip"], createdAt: now.addingTimeInterval(-day), action: .codex)

        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: day, now: now), 0)
        XCTAssertEqual(temporary.reader.loadBatches().count, 1)
    }

    func testPruningNeverTouchesABatchWithAnythingOnTheShelf() throws {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        // A shelf batch from a month ago: still parked in the corner of the
        // screen, so still the user's business and not the cleaner's.
        try temporary.commitBatch(names: ["parked.zip"], createdAt: now.addingTimeInterval(-30 * day))

        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: day, now: now), 0)
        XCTAssertEqual(temporary.reader.loadBatches().count, 1)
    }

    func testAConsumedBatchIsPrunedOnceItAges() throws {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        try temporary.commitBatch(names: ["dragged.zip"], createdAt: now.addingTimeInterval(-3 * day))
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        try temporary.reader.markConsumed(
            itemIDs: Set(batch.items.map(\.id)),
            in: batch.id,
            now: now.addingTimeInterval(-2 * day)
        )

        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: day, now: now), 1)
        XCTAssertEqual(temporary.reader.loadBatches(), [])
    }

    /// The retention clock starts when the shelf lets go. Dragging out a batch
    /// that has been parked longer than the whole window used to trash it in
    /// the same instant — before the destination app had read a single byte.
    func testAJustConsumedBatchSurvivesEvenWhenItsShareIsAncient() throws {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        try temporary.commitBatch(names: ["parked-for-a-fortnight.zip"], createdAt: now.addingTimeInterval(-14 * day))
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        try temporary.reader.markConsumed(itemIDs: Set(batch.items.map(\.id)), in: batch.id, now: now)

        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: 7 * day, now: now), 0)
        XCTAssertEqual(temporary.reader.loadBatches().count, 1)
    }

    /// Putting a batch back on the shelf has to stop the clock too, or the
    /// sweep would take it away while it is visibly parked on screen.
    func testRestoringClearsTheRetentionClock() throws {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        try temporary.commitBatch(names: ["restored.zip"], createdAt: now.addingTimeInterval(-30 * day))
        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        try temporary.reader.markConsumed(
            itemIDs: Set(batch.items.map(\.id)),
            in: batch.id,
            now: now.addingTimeInterval(-20 * day)
        )
        try temporary.reader.restore(batchID: batch.id)

        XCTAssertNil(temporary.reader.state(forBatch: batch.id)?.clearedAt)
        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: day, now: now), 0)
    }

    func testAZeroWindowMeansKeepForever() throws {
        try temporary.commitBatch(
            names: ["ancient.zip"],
            createdAt: Date(timeIntervalSince1970: 0),
            action: .clipboard
        )

        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: 0), 0)
        XCTAssertEqual(temporary.reader.loadBatches().count, 1)
    }

    // MARK: - Legacy manifests

    /// The upgrade case. Every batch written by the previously installed
    /// extension has no `action` field, so it decodes as `.shelf`; without
    /// reading the request that is still sitting beside it, the first launch
    /// after an update would park every old forward on the shelf and then
    /// forward it as well.
    func testALegacyManifestWithALiveIntentIsNotShelved() throws {
        let directory = try temporary.commitBatch(
            names: ["转发过的.zip"],
            action: .claude,
            intent: BatchIntent(action: .claude, requestedAt: Date())
        )
        try stripActionFromManifest(at: directory)

        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        XCTAssertEqual(batch.shelvedCount, 0)
        XCTAssertEqual(batch.action, .claude)
    }

    /// And it has to keep saying so: `intent.json` is consumed the moment the
    /// forward runs, so the resolved action is written into `state.json` or the
    /// history would call a delivered batch 「暂存到渡口」 from then on.
    func testTheResolvedActionOutlivesTheConsumedIntent() throws {
        let directory = try temporary.commitBatch(
            names: ["转发过的.zip"],
            action: .codex,
            intent: BatchIntent(action: .codex, requestedAt: Date())
        )
        try stripActionFromManifest(at: directory)

        let batch = try XCTUnwrap(temporary.reader.loadBatches().first)
        _ = temporary.reader.consumeIntent(forBatch: batch.id)

        XCTAssertEqual(temporary.reader.loadBatches().first?.action, .codex)
    }

    // MARK: - Debris

    /// A manifest truncated by a crash mid-write makes a batch that can never
    /// be listed, counted or cleared by hand. Left out of the sweep it would
    /// occupy the group container for good.
    func testAnUnreadableBatchIsSweptOnceItAges() throws {
        let directory = try temporary.commitBatch(names: ["坏掉的.zip"])
        try Data("{".utf8).write(to: directory.appendingPathComponent("manifest.json"))

        // The manifest's own `createdAt` is exactly what has been destroyed, so
        // the age has to come from the directory — hence a future `now` rather
        // than a backdated fixture.
        let later = Date().addingTimeInterval(3600)
        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: 60, now: later), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// But a manifest this build simply does not understand yet belongs to a
    /// future one, and trashing it would destroy a share nobody has read.
    func testABatchFromANewerSchemaIsNeverSwept() throws {
        let directory = try temporary.commitBatch(
            names: ["未来的.zip"],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let url = directory.appendingPathComponent("manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["schemaVersion"] = BatchManifest.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: 60, now: Date().addingTimeInterval(3600)), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Counting bytes and sweeping history must never be what first "sees" a
    /// batch: `isFirstSeen` is spent once, and spending it here would drop the
    /// forward the next reload was supposed to run.
    func testCountingBytesDoesNotSpendTheFirstSeenSignal() throws {
        try temporary.commitBatch(names: ["未读的.zip"], action: .clipboard)

        XCTAssertEqual(temporary.reader.totalByteCount(), 16)
        XCTAssertEqual(temporary.reader.pruneHistory(olderThan: 24 * 60 * 60), 0)
        XCTAssertEqual(temporary.reader.loadBatches().first?.isFirstSeen, true)
    }

    private func stripActionFromManifest(at directory: URL) throws {
        let url = directory.appendingPathComponent("manifest.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json.removeValue(forKey: "action")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    // MARK: - Size

    func testTotalByteCountAddsUpEveryBatch() throws {
        try temporary.commitBatch(names: ["a.zip", "b.zip"])
        try temporary.commitBatch(names: ["c.zip"], action: .codex)

        // 16 bytes per fixture file, counted whether or not it is on the shelf.
        XCTAssertEqual(temporary.reader.totalByteCount(), 48)
    }

    func testTotalByteCountIsZeroOnAnEmptyInbox() {
        XCTAssertEqual(temporary.reader.totalByteCount(), 0)
    }
}
