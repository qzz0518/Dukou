import XCTest
@testable import DukouCore

final class WeChatInterfaceVisibilityTests: XCTestCase {
    private typealias Child = WeChatInterfaceVisibility.Child

    func testTheCollapsedTreeIssue3ReportedIsHidden() {
        // Window → three title-bar buttons, one with a child of its own, and
        // one group with nothing in it.
        let shell = [Child(role: "AXGroup", childCount: 0), Child(role: "AXButton", childCount: 0),
                     Child(role: "AXButton", childCount: 1), Child(role: "AXButton", childCount: 0)]
        XCTAssertEqual(WeChatInterfaceVisibility.evaluate([shell]), .hidden)
        XCTAssertEqual(WeChatInterfaceVisibility.evaluate([shell, shell]), .hidden)
    }

    func testOneWindowWithContentIsEnough() {
        let shell = [Child(role: "AXGroup", childCount: 0), Child(role: "AXButton", childCount: 1)]
        let main = [Child(role: "AXGroup", childCount: 7), Child(role: "AXButton", childCount: 0)]
        XCTAssertEqual(WeChatInterfaceVisibility.evaluate([main]), .visible)
        XCTAssertEqual(WeChatInterfaceVisibility.evaluate([shell, main]), .visible)
    }

    func testNoWindowIsNotEvidence() {
        XCTAssertEqual(WeChatInterfaceVisibility.evaluate([]), .unknown)
    }
}
