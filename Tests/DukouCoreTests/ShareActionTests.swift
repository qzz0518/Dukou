import DukouCore
import Foundation
import XCTest

final class ShareActionTests: XCTestCase {
    private var temporary: TemporaryInbox!

    override func setUp() {
        super.setUp()
        temporary = TemporaryInbox()
    }

    override func tearDown() {
        temporary.tearDown()
        super.tearDown()
    }

    func testOnlyForwardingActionsNameATargetApp() {
        XCTAssertEqual(ShareAction.codex.targetBundleIdentifier, "com.openai.codex")
        XCTAssertEqual(ShareAction.claude.targetBundleIdentifier, "com.anthropic.claudefordesktop")
        XCTAssertNil(ShareAction.shelf.targetBundleIdentifier)
        XCTAssertNil(ShareAction.clipboard.targetBundleIdentifier)
        // 「发送到自定义」 names no app of its own: the one it goes to is chosen
        // in the share panel and travels in the intent.
        XCTAssertNil(ShareAction.custom.targetBundleIdentifier)
    }

    func testAnIntentIsReadableExactlyOnce() throws {
        let batchID = try commitBatch(intent: BatchIntent(action: .codex, requestedAt: Date()))

        guard case .ready(let intent) = temporary.reader.consumeIntent(forBatch: batchID) else {
            return XCTFail("expected a fresh intent")
        }
        XCTAssertEqual(intent.action, .codex)
        // The second read is the one that matters: without consumption a rescan,
        // a relaunch or a second window would replay the forward.
        XCTAssertEqual(temporary.reader.consumeIntent(forBatch: batchID), .none)
    }

    func testAStaleIntentIsReportedAsExpiredRatherThanCarriedOut() throws {
        let old = Date(timeIntervalSinceNow: -BatchIntent.freshnessWindow - 60)
        let batchID = try commitBatch(intent: BatchIntent(action: .claude, requestedAt: old))

        // Reported as its own case — pasting into whatever is frontmost hours
        // later is worse than doing nothing, but the history still has to be
        // able to say the forward never happened — and still removed from disk.
        let result = temporary.reader.consumeIntent(forBatch: batchID)
        guard case .expired(let intent) = result else {
            return XCTFail("expected an expired intent, got \(result)")
        }
        XCTAssertEqual(intent.action, .claude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intentURL(batchID).path))
    }

    /// The two entries the extension finishes by itself write no request; an
    /// intent for either could only ever be found late and read as a forward
    /// that never ran.
    func testOnlyForwardsWriteAnIntent() {
        XCTAssertFalse(ShareAction.shelf.needsIntent)
        XCTAssertFalse(ShareAction.clipboard.needsIntent)
        for action in [ShareAction.codex, .claude, .custom] {
            XCTAssertTrue(action.needsIntent, "\(action)")
        }
    }

    func testABatchWithoutAnIntentReadsAsNoRequest() throws {
        let batchID = try commitBatch(intent: nil)
        XCTAssertEqual(temporary.reader.consumeIntent(forBatch: batchID), .none)
    }

    func testAnIntentFromANewerSchemaIsNotGuessedAt() throws {
        let batchID = try commitBatch(intent: BatchIntent(action: .codex, requestedAt: Date()))
        let url = intentURL(batchID)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["schemaVersion"] = BatchIntent.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        XCTAssertEqual(temporary.reader.consumeIntent(forBatch: batchID), .none)
    }

    func testTheBatchItselfSurvivesItsIntentBeingConsumed() throws {
        let batchID = try commitBatch(intent: BatchIntent(action: .clipboard, requestedAt: Date()))
        _ = temporary.reader.consumeIntent(forBatch: batchID)

        // A forward that already happened must not take the files with it: the
        // same archive is still in the history to send again.
        XCTAssertEqual(temporary.reader.loadBatches().flatMap(\.items).count, 1)
    }

    // MARK: - Helpers

    private func intentURL(_ batchID: UUID) -> URL {
        temporary.inbox.ready
            .appendingPathComponent(batchID.uuidString, isDirectory: true)
            .appendingPathComponent(BatchIntent.fileName)
    }

    private func commitBatch(intent: BatchIntent?) throws -> UUID {
        let directory = try temporary.commitBatch(
            names: ["聊天记录.zip"],
            action: intent?.action ?? .shelf,
            intent: intent
        )
        return temporary.batchID(of: directory)
    }
}
