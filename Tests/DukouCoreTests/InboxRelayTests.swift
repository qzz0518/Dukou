import DukouCore
import Foundation
import XCTest

/// A generated 「发给 <app>」 entry writes into its own inbox, and the app moves
/// what it finds there into the app group's.
final class InboxRelayTests: XCTestCase {
    private var relay: TemporaryInbox!
    private var main: TemporaryInbox!

    override func setUp() {
        super.setUp()
        relay = TemporaryInbox()
        main = TemporaryInbox()
    }

    override func tearDown() {
        relay.tearDown()
        main.tearDown()
        super.tearDown()
    }

    func testAnExtensionThatNamesAnInboxWritesThere() throws {
        let path = relay.inbox.root.path
        XCTAssertEqual(try Inbox.resolve(info: [DirectShareInfoKey.inboxPath: path]).root.path, path)
    }

    /// The forward travels with the batch: the intent is a file inside it.
    func testABatchArrivesWithItsIntent() throws {
        let target = ForwardTarget(bundleIdentifier: "com.bot.pc.doubao", displayName: "豆包", addedAt: Date())
        let committed = try relay.commitBatch(
            names: ["聊天记录.zip"],
            action: .custom,
            intent: BatchIntent(action: .custom, requestedAt: Date(), target: target)
        )
        let batchID = try XCTUnwrap(UUID(uuidString: committed.lastPathComponent))

        XCTAssertEqual(relay.inbox.drain(into: main.inbox), 1)

        XCTAssertEqual(relay.reader.loadBatches(), [])
        XCTAssertEqual(main.reader.loadBatches().flatMap(\.items).map(\.displayName), ["聊天记录.zip"])
        guard case .ready(let intent) = main.reader.consumeIntent(forBatch: batchID) else {
            return XCTFail("the intent did not come across")
        }
        XCTAssertEqual(intent.target?.bundleIdentifier, "com.bot.pc.doubao")
    }

    /// The extension's only way to report a failure is a file in its inbox.
    func testAFailureReportComesAcross() throws {
        ShareFailure.record(ShareFailure(at: Date(), action: .custom, message: "坏了"), in: relay.inbox)

        relay.inbox.drain(into: main.inbox)

        let moved = try FileManager.default.contentsOfDirectory(atPath: main.inbox.failures.path)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relay.inbox.failures.path), [])
    }

    func testAnEmptyRelayMovesNothing() {
        XCTAssertEqual(relay.inbox.drain(into: main.inbox), 0)
    }
}
