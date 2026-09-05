import DukouCore
import Foundation
import XCTest

final class DisplayNameTests: XCTestCase {
    func testKeepsAnOrdinaryChineseName() {
        XCTAssertEqual(DisplayName.sanitize("聊天记录 2026.zip"), "聊天记录 2026.zip")
    }

    func testTakesOnlyTheLastPathComponent() {
        XCTAssertEqual(DisplayName.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(DisplayName.sanitize("/tmp/聊天.zip"), "聊天.zip")
    }

    func testReplacesColonWhichFinderRendersAsASeparator() {
        XCTAssertEqual(DisplayName.sanitize("2026:09:05.zip"), "2026-09-05.zip")
    }

    func testStripsControlCharacters() {
        XCTAssertEqual(DisplayName.sanitize("chat\nlog.zip"), "chat log.zip")
    }

    func testFallsBackForNamesThatAreNotUsableFilenames() {
        for raw in ["", " ", ".", "..", nil] {
            let sanitized = DisplayName.sanitize(raw)
            XCTAssertTrue(sanitized.hasPrefix(DisplayName.fallbackBaseName), "unexpected: \(sanitized)")
        }
    }

    func testDoesNotProduceAHiddenFile() {
        XCTAssertFalse(DisplayName.sanitize(".zshrc").hasPrefix("."))
    }

    func testAddsTheFallbackExtensionOnlyWhenThereIsNone() {
        XCTAssertEqual(DisplayName.sanitize("聊天记录", fallbackExtension: "zip"), "聊天记录.zip")
        XCTAssertEqual(DisplayName.sanitize("聊天记录.txt", fallbackExtension: "zip"), "聊天记录.txt")
    }

    func testTruncationKeepsTheExtension() {
        let long = String(repeating: "记", count: 300) + ".zip"
        let sanitized = DisplayName.sanitize(long)
        XCTAssertTrue(sanitized.hasSuffix(".zip"))
        XCTAssertLessThanOrEqual(sanitized.utf8.count, 200)
        // A filename must survive as a filename: APFS rejects anything over 255
        // bytes, and the extension is what makes the file openable at all.
        XCTAssertTrue(sanitized.hasPrefix("记"))
    }
}
