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

        let moved = relay.inbox.drain(into: main.inbox, accepting: { $0.targetBundleIdentifier == "com.bot.pc.doubao" }, acceptsReports: true)
        XCTAssertEqual(moved.values.map(\.lastPathComponent), [committed.lastPathComponent])

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

        relay.inbox.drain(into: main.inbox, accepting: { _ in true }, acceptsReports: true)

        let moved = try FileManager.default.contentsOfDirectory(atPath: main.inbox.failures.path)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relay.inbox.failures.path), [])
    }

    func testAnEmptyRelayMovesNothing() {
        XCTAssertEqual(relay.inbox.drain(into: main.inbox, accepting: { _ in true }, acceptsReports: true), [:])
    }

    /// The relay is open to any process the user runs. A batch whose intent the
    /// app does not vouch for — no intent, or a forward to an app without its
    /// own entry — is deleted, not delivered.
    func testABatchTheAppDoesNotVouchForIsDropped() throws {
        try relay.commitBatch(names: ["no-intent.zip"])
        try relay.commitBatch(
            names: ["elsewhere.zip"],
            action: .custom,
            intent: BatchIntent(
                action: .custom,
                requestedAt: Date(),
                target: ForwardTarget(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal", addedAt: Date())
            )
        )

        let moved = relay.inbox.drain(into: main.inbox, accepting: { $0.targetBundleIdentifier == "com.bot.pc.doubao" }, acceptsReports: true)

        XCTAssertEqual(moved, [:])
        XCTAssertEqual(main.reader.loadBatches(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relay.inbox.ready.path), [])
    }

    /// A manifest that points outside its batch would make 记录 and the shelf
    /// act on someone else's files.
    func testABatchThatPointsOutsideItselfIsDropped() throws {
        let committed = try relay.commitBatch(
            names: ["x.zip"],
            action: .custom,
            intent: BatchIntent(action: .custom, requestedAt: Date(), target: nil)
        )
        let manifestURL = committed.appendingPathComponent(BatchStaging.manifestFileName)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        var items = json["items"] as! [[String: Any]]
        items[0]["relativePath"] = "../../Documents/x.zip"
        json["items"] = items
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)

        XCTAssertEqual(relay.inbox.drain(into: main.inbox, accepting: { _ in true }, acceptsReports: true), [:])
    }

    /// With no entry that could have written them, reports are not shown.
    func testReportsAreDroppedWhenNoEntryExists() throws {
        ShareFailure.record(ShareFailure(at: Date(), action: .custom, message: "点这里"), in: relay.inbox)

        relay.inbox.drain(into: main.inbox, accepting: { _ in true }, acceptsReports: false)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: main.inbox.failures.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relay.inbox.failures.path), [])
    }
}
