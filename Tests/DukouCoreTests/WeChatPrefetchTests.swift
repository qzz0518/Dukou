import XCTest
@testable import DukouCore

final class WeChatPrefetchTests: XCTestCase {
    private func rows(_ texts: [String], from y: Double = 0, height: Double = 100) -> [WeChatViewportRow] {
        texts.enumerated().map { WeChatViewportRow(text: $1, y: y + Double($0) * height, height: height) }
    }

    /// A hundred messages is one native batch and already in the window WeChat
    /// opens with; the pass is for what reaches past it.
    func testOnlySelectionsPastOneBatchAreWorthLoading() {
        XCTAssertEqual(WeChatPrefetch.threshold, 100)
        XCTAssertGreaterThan(WeChatPrefetch.budget(messages: 300), WeChatPrefetch.budget(messages: 200))
        // Never long enough to look like a hang, whatever is asked for.
        XCTAssertLessThanOrEqual(WeChatPrefetch.budget(messages: 100_000), 180)
        XCTAssertGreaterThan(WeChatPrefetch.budget(messages: 101), 40)
    }

    /// The bug this pass shipped with, measured on 4.1.13: a 520-unit gesture
    /// moves the list about 570 points and the list is about 650 tall, so any
    /// burst worth sending clears the screen and the two snapshots share no
    /// rows at all. Reading that as "the burst earned less than a row per
    /// gesture" halved the burst and doubled the gap every time — the pass
    /// throttled itself to a crawl exactly when it was working.
    func testABurstThatClearsTheScreenIsHealthyNotStalled() {
        let before = rows(["a", "b", "c", "d", "e", "f"], height: 108)
        let after = rows(["r", "s", "t", "u", "v", "w"], height: 108)
        let step = WeChatPrefetch.burst(from: before, to: after, gestures: 8, delta: 520,
                                        reach: WeChatPrefetch.reach(delta: 520))
        XCTAssertFalse(step.clamped)
        XCTAssertNil(step.pointsPerGesture, "nothing overlaps, so nothing was measured")
        // Eight gestures of ~572 points over 108-point rows: far more than the
        // screen it left behind, which is all `advance` alone could see.
        XCTAssertEqual(step.rows, 42)
        XCTAssertGreaterThan(step.rows, after.count)
    }

    /// The other half of the same reading: while WeChat fetches history a
    /// gesture nudges the list ~50 points however large it is, so the burst
    /// stays inside the overlap — and that is the one moment its reach can be
    /// measured.
    func testAClampedBurstIsMeasuredAndReportedAsClamped() {
        let before = rows(["a", "b", "c", "d", "e", "f"], height: 100)
        // Two rows arrived; the list moved 200 points across 4 gestures.
        let after = rows(["y", "z", "a", "b", "c", "d"], height: 100)
        let step = WeChatPrefetch.burst(from: before, to: after, gestures: 4, delta: 520, reach: 572)
        XCTAssertEqual(step.rows, 2)
        XCTAssertEqual(step.pointsPerGesture ?? 0, 50, accuracy: 0.001)
        XCTAssertTrue(step.clamped)
    }

    /// A burst that leaves overlap because it travelled nearly a screen is not
    /// clamped — only one that barely moved is.
    func testAlmostAScreenIsNotClamped() {
        let before = rows(["a", "b", "c", "d", "e", "f"], height: 100)
        let after = rows(["v", "w", "x", "y", "z", "a"], height: 100)
        let step = WeChatPrefetch.burst(from: before, to: after, gestures: 1, delta: 520, reach: 572)
        XCTAssertEqual(step.rows, 5)
        XCTAssertEqual(step.pointsPerGesture ?? 0, 500, accuracy: 0.001)
        XCTAssertFalse(step.clamped)
    }

    func testABurstThatKeepsClearingTheScreenGrowsAndTightens() {
        var burst = WeChatPrefetch.firstBurst, pause = WeChatScrollStep.baseGesturePause
        for _ in 0..<40 {
            burst = WeChatPrefetch.nextBurst(burst, clamped: false)
            pause = WeChatPrefetch.nextPause(pause, clamped: false)
        }
        XCTAssertEqual(burst, WeChatPrefetch.maximumBurst)
        XCTAssertEqual(pause, WeChatScrollStep.minimumGesturePause, accuracy: 0.0001)
    }

    func testAStalledBurstIsHalvedAndSpacedOut() {
        var burst = 12, pause = WeChatScrollStep.minimumGesturePause
        burst = WeChatPrefetch.nextBurst(burst, clamped: true)
        pause = WeChatPrefetch.nextPause(pause, clamped: true)
        XCTAssertEqual(burst, 6)
        XCTAssertGreaterThanOrEqual(pause, WeChatScrollStep.baseGesturePause)
        for _ in 0..<10 { burst = WeChatPrefetch.nextBurst(burst, clamped: true) }
        XCTAssertEqual(burst, 1, "a stalled list still gets one gesture per burst to recover on")
        for _ in 0..<10 { pause = WeChatPrefetch.nextPause(pause, clamped: true) }
        XCTAssertLessThanOrEqual(pause, WeChatScrollStep.maximumGesturePause)
    }

    func testTravelIsCountedFromOverlappingContent() {
        let before = rows(["c", "d", "e", "f"])
        // Two older rows arrived on top; c…f moved down by two.
        let after = rows(["a", "b", "c", "d"])
        XCTAssertEqual(WeChatPrefetch.advance(from: before, to: after), 2)
        XCTAssertEqual(WeChatPrefetch.advance(from: before, to: before), 0)
    }

    /// Repeated bodies are everywhere in a group chat: "[图片]", "收到", a
    /// forwarded card. Matching the whole remaining run rather than the first
    /// equal row is what keeps one of them from reading as a step that never
    /// happened — here the top row is "a" both before and after, and the list
    /// still moved two rows.
    func testRepeatedRowsDoNotHideTravel() {
        XCTAssertEqual(WeChatPrefetch.advance(from: rows(["a", "x", "y"]), to: rows(["a", "z", "a"])), 2)
        XCTAssertEqual(WeChatPrefetch.advance(from: rows(["[图片]", "x"]), to: rows(["[图片]", "[图片]", "x"])), 1)
        // Where several readings fit, the shortest one wins: undercounting
        // only makes the pass drag further than asked.
        XCTAssertEqual(WeChatPrefetch.advance(from: rows(["[图片]", "[图片]", "x"]), to: rows(["[图片]", "[图片]", "[图片]"])), 1)
    }

    /// A burst that outran the overlap is credited with the screen it left, so
    /// the pass drags at least as far as asked rather than stopping short.
    func testNoOverlapIsCreditedWithOneScreen() {
        XCTAssertEqual(WeChatPrefetch.advance(from: rows(["a", "b"]), to: rows(["m", "n", "o"])), 3)
        XCTAssertEqual(WeChatPrefetch.advance(from: [], to: rows(["m", "n"])), 2)
    }

    /// Same body, different bubble height: a quoted card and a plain line are
    /// not the same row.
    func testHeightSeparatesRowsThatReadAlike() {
        let before = rows(["同意"], height: 40)
        let after = [WeChatViewportRow(text: "同意", y: 0, height: 180)]
        XCTAssertEqual(WeChatPrefetch.advance(from: before, to: after), 1)
    }
}
