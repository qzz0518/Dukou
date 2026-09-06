import XCTest
@testable import DukouCore

final class WeChatScrollStepTests: XCTestCase {
    private let listHeight: CGFloat = 651

    func testUnmeasuredStepKeepsTheCarefulReach() {
        let reach = WeChatScrollStep.reach(listHeight: listHeight, tallestRow: 98, gainMeasured: false, reachFactor: 1)
        XCTAssertEqual(reach, listHeight / 2.5, accuracy: 0.001)
    }

    /// The whole point: on a text conversation a measured step travels about
    /// twice as far, and still leaves the tallest row's worth of overlap.
    func testMeasuredStepLeavesOneRowOfOverlap() {
        let tallest: CGFloat = 98
        let reach = WeChatScrollStep.reach(listHeight: listHeight, tallestRow: tallest, gainMeasured: true, reachFactor: 1)
        XCTAssertEqual(reach, listHeight - tallest - 24, accuracy: 0.001)
        XCTAssertGreaterThan(reach, WeChatScrollStep.careful(listHeight: listHeight) * 1.9)
        XCTAssertLessThanOrEqual(reach + tallest, listHeight)
    }

    /// A conversation of tall images must not push the step to nothing, and
    /// must never reach further than a screen.
    func testTallRowsFallBackToAThirdOfAScreenAtMost() {
        let reach = WeChatScrollStep.reach(listHeight: listHeight, tallestRow: 900, gainMeasured: true, reachFactor: 1)
        XCTAssertEqual(reach, listHeight / 3, accuracy: 0.001)
        XCTAssertLessThan(reach, listHeight)
    }

    func testReachFactorBacksTheStepOff() {
        let full = WeChatScrollStep.reach(listHeight: listHeight, tallestRow: 98, gainMeasured: true, reachFactor: 1)
        let halved = WeChatScrollStep.reach(listHeight: listHeight, tallestRow: 98, gainMeasured: true, reachFactor: 0.5)
        XCTAssertEqual(halved, full / 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(WeChatScrollStep.reach(listHeight: listHeight, tallestRow: 98, gainMeasured: true, reachFactor: 4), full)
    }

    func testClampedOrMidGlideGainsAreRejected() {
        XCTAssertTrue(WeChatScrollStep.isPlausible(gain: 1.1))
        XCTAssertTrue(WeChatScrollStep.isPlausible(gain: 0.4))
        // The 0.08 a clamped 600-unit gesture reported on 2026-09-06.
        XCTAssertFalse(WeChatScrollStep.isPlausible(gain: 0.08))
        XCTAssertFalse(WeChatScrollStep.isPlausible(gain: 12))
    }

    func testTheGestureGapIsFeltOutAndSnapsBackWhenTheListStalls() {
        var pause = WeChatScrollStep.baseGesturePause
        // Four steps that moved as asked buy 20 ms.
        for step in 1...4 { pause = WeChatScrollStep.shortened(pause, healthySteps: step) }
        XCTAssertEqual(pause, WeChatScrollStep.baseGesturePause - 0.02, accuracy: 0.0001)
        for step in 1...40 { pause = WeChatScrollStep.shortened(pause, healthySteps: step) }
        XCTAssertGreaterThanOrEqual(pause, WeChatScrollStep.minimumGesturePause)
        // One clamped step gives all of it back, and then some.
        XCTAssertGreaterThanOrEqual(WeChatScrollStep.lengthened(pause), WeChatScrollStep.baseGesturePause)
        XCTAssertLessThanOrEqual(WeChatScrollStep.lengthened(0.8), WeChatScrollStep.maximumGesturePause)
    }

    func testDeltaConvertsReachThroughTheMeasuredGainAndStaysBounded() {
        XCTAssertEqual(WeChatScrollStep.delta(reach: 400, gain: 1), 400)
        // Content that moves twice as far per unit needs half the units.
        XCTAssertEqual(WeChatScrollStep.delta(reach: 400, gain: 2), 200)
        // A gain reported as ~0 must not turn one step into a gesture WeChat
        // clamps to a crawl.
        XCTAssertEqual(WeChatScrollStep.delta(reach: 400, gain: 0.0001), WeChatScrollStep.maximumDelta)
        XCTAssertLessThanOrEqual(WeChatScrollStep.delta(reach: 5000, gain: 1), WeChatScrollStep.maximumDelta)
        XCTAssertEqual(WeChatScrollStep.delta(reach: 1, gain: 1), 10)
        XCTAssertEqual(WeChatScrollStep.delta(reach: .nan, gain: 1), 10)
    }
}
