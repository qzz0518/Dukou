import XCTest
@testable import DukouCore

final class WeChatResumeTests: XCTestCase {
    private func mark(_ hash: String, _ height: Double = 98) -> WeChatMessageMark { .init(hash: hash, height: height) }

    private func search(_ window: [WeChatMessageMark], walking rows: [WeChatMessageMark]) throws -> Int? {
        var search = WeChatResumeSearch(window: window)
        for row in rows { search.add(row) }
        return try search.arrivals()
    }

    func testNothingArrivedFindsTheOldNewestFirst() throws {
        let window = [mark("a"), mark("b"), mark("c")]
        XCTAssertNil(try search(window, walking: [mark("a"), mark("b")]), "Still looking until the whole window has been read")
        XCTAssertEqual(try search(window, walking: window + [mark("d")]), 0)
    }

    func testArrivalsAreCountedBelowTheOldNewest() throws {
        let window = [mark("a"), mark("b"), mark("c")]
        XCTAssertEqual(try search(window, walking: [mark("x"), mark("y")] + window + [mark("d")]), 2)
    }

    func testHeightsSettleARunOfIdenticalLabels() throws {
        // Every photo reads 图片. Two photos arrived, and the newest messages
        // the earlier run saw were photos too.
        let window = [mark("photo", 120), mark("photo", 300), mark("photo", 80)]
        let rows = [mark("photo", 200), mark("photo", 120), mark("photo", 120), mark("photo", 300), mark("photo", 80)]
        XCTAssertEqual(try search(window, walking: rows), 2)
    }

    func testLabelsAloneAreTakenWhenTheyAreUnique() throws {
        // The window was resized in between: every height differs, the labels do not.
        let window = [mark("a", 98), mark("b", 98)]
        XCTAssertEqual(try search(window, walking: [mark("x", 60), mark("a", 60), mark("b", 60)]), 1)
    }

    func testATieNothingSettlesIsRefused() {
        let window = [mark("photo"), mark("photo")]
        XCTAssertThrowsError(try search(window, walking: Array(repeating: mark("photo"), count: 4))) {
            XCTAssertEqual($0 as? WeChatResumeSearch.Failure, .ambiguous)
        }
    }

    func testGivesUpPastTheArrivalsItAllows() {
        let window = [mark("a"), mark("b")]
        let rows = Array(repeating: mark("x"), count: WeChatResumeSearch.maximumArrivals + 1)
        XCTAssertNil(try search(window, walking: rows))
        XCTAssertThrowsError(try search(window, walking: rows + [mark("x")])) {
            XCTAssertEqual($0 as? WeChatResumeSearch.Failure, .notFound)
        }
        XCTAssertThrowsError(try search([], walking: [mark("a")])) {
            XCTAssertEqual($0 as? WeChatResumeSearch.Failure, .notFound)
        }
    }

    func testPreferencesWithoutAnInterruptionStillDecode() throws {
        var preferences = WeChatForwardPreferences()
        preferences.draft = WeChatForwardPreset(chat: "产品群", range: .init(unit: .messages, value: 300))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as? [String: Any])
        json["interrupted"] = nil
        let legacy = WeChatForwardPreferences.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.draft.chat, "产品群")
        XCTAssertNil(legacy.interrupted)

        preferences.interrupted = WeChatForwardInterruption(chat: "产品群", exported: 200, newest: [mark("a")],
                                                            batches: ["B", "A"], counts: [100, 99])
        XCTAssertEqual(WeChatForwardPreferences.decode(try JSONEncoder().encode(preferences)).interrupted, preferences.interrupted)
    }
}
