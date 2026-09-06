import DukouCore
import Foundation
import XCTest

final class WeChatForwardTests: XCTestCase {
    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)!
    }
    private func records(_ rows: [(String, String)]) throws -> [WeChatTranscriptRecord] {
        try WeChatTranscriptRecord.parse(rows.map { "·甲\n\($0.0)\n\($0.1)\n" }.joined(separator: "\n"))
    }

    func testNativeTimeBoundaryPreservesDuplicatesAndRollingDays() throws {
        let end = date("2026-09-05 08:05:48")
        let hours = WeChatForwardRange(unit: .hours, value: 1)
        XCTAssertEqual(hours.start(at: end), date("2026-09-05 07:05:00"))
        XCTAssertEqual(WeChatForwardRange(unit: .days, value: 1).start(at: end), date("2026-09-04 08:05:00"))
        let rows = try records([("2026年9月5日 07:04", "older"), ("2026年9月5日 07:05", "same"), ("2026年9月5日 07:05", "same"), ("2026年9月5日 08:05", "last")])
        XCTAssertEqual(try hours.excludedPrefix(in: rows, at: end), 1)
        XCTAssertEqual(Array(rows.dropFirst()).filter { $0.text == "same" }.count, 2)
        XCTAssertEqual(try WeChatForwardRange(unit: .days, value: 1).excludedPrefix(in: rows, at: end), 0)
        XCTAssertThrowsError(try hours.excludedPrefix(in: rows.reversed(), at: end))
        XCTAssertThrowsError(try hours.excludedPrefix(in: records([("2026年9月5日 08:06", "future")]), at: end))
        XCTAssertEqual(try hours.excludedPrefix(in: records([("2026年9月5日 07:04", "all older")]), at: end), 1)
    }

    func testCountRangeValidation() {
        XCTAssertTrue(WeChatForwardRange(unit: .messages, value: 2000).isValid)
        XCTAssertFalse(WeChatForwardRange(unit: .messages, value: 0).isValid)
        XCTAssertFalse(WeChatForwardRange(unit: .messages, value: 2001).isValid)
        XCTAssertNil(WeChatForwardRange(unit: .messages, value: 10).start(at: Date()))
    }

    func testOnlyCountRangesCanStartAutomationWhileOldTimePresetsArePreserved() throws {
        XCTAssertEqual(WeChatForwardRange(), WeChatForwardRange(unit: .messages, value: 100))
        XCTAssertTrue(WeChatForwardRange(unit: .messages, value: 105).isAvailableForAutomation)
        XCTAssertFalse(WeChatForwardRange(unit: .messages, value: 0).isAvailableForAutomation)
        for unit in [WeChatRangeUnit.hours, .days] {
            let preset = WeChatForwardPreset(chat: "Saved group", range: .init(unit: unit, value: 3))
            var preferences = WeChatForwardPreferences()
            preferences.recordSuccess(preset)
            let loaded = WeChatForwardPreferences.decode(try JSONEncoder().encode(preferences))
            XCTAssertEqual(loaded.draft.range, preset.range)
            XCTAssertEqual(loaded.recent.first?.range, preset.range)
            XCTAssertFalse(loaded.draft.range.isAvailableForAutomation)
        }
    }

    func testPresetRemembersOnlyRecordedSuccessAndReplacesTheSameGroup() throws {
        var preferences = WeChatForwardPreferences()
        preferences.draft.chat = "not yet successful"
        XCTAssertTrue(preferences.recent.isEmpty)
        let old = WeChatForwardPreset(chat: "Example (500)", range: .init(unit: .hours, value: 5), targetBundleIdentifier: "app.one", targetName: "One")
        preferences.recordSuccess(old, at: date("2026-09-05 08:00:00"))
        var new = old
        new.chat = "Example（499）"
        new.pastePath = true
        new.range = .init(unit: .messages, value: 40)
        preferences.recordSuccess(new)
        XCTAssertEqual(preferences.recent.count, 1)
        XCTAssertEqual(preferences.recent[0].chat, "Example")
        XCTAssertTrue(preferences.recent[0].pastePath)
        let loaded = WeChatForwardPreferences.decode(try JSONEncoder().encode(preferences))
        XCTAssertEqual(loaded.recent, preferences.recent)
        XCTAssertEqual(loaded.draft, preferences.draft)
        XCTAssertTrue(WeChatForwardPreferences.decode(Data("bad".utf8)).recent.isEmpty)
    }

    func testSelectionMatchesExactBodyDespiteGroupAliasAndQuotedPreview() throws {
        let rows = try records([("2026年9月5日 08:05", "第一行\n第二行"), ("2026年9月5日 08:06", "再见")])
        XCTAssertTrue(WeChatSelectedMessage(description: "不同的群昵称 第一行\n第二行").matches(rows[0], attachmentNames: []))
        XCTAssertTrue(WeChatSelectedMessage(description: "群昵称 再见\n引用 某人的消息 : 图片").matches(rows[1], attachmentNames: []))
        XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 第一行").matches(rows[0], attachmentNames: []))
        XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 不再见").matches(rows[1], attachmentNames: []))
        let emoji = try records([("2026年9月5日 08:06", "[动画表情]")])[0]
        XCTAssertTrue(WeChatSelectedMessage(description: "群昵称 动画表情").matches(emoji, attachmentNames: []))
        let image = try records([("2026年9月5日 08:06", "[图片]")])[0]
        XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 图片").matches(image, attachmentNames: []))
        XCTAssertThrowsError(try WeChatTranscriptRecord.parse("unrecognized text"))
    }

    func testChannelsCardMatchesCompleteAuthorAndNativeURLFormat() throws {
        for author in ["星河实验室", "星河实验室 Studio"] {
            let card = try records([("2026年9月5日 08:06", "[视频号] \(author) https://weixin.qq.com/sph/Example_90-z")])[0]
            XCTAssertTrue(WeChatSelectedMessage(description: "群昵称 视频号\(author)").matches(card, attachmentNames: []))
            XCTAssertTrue(WeChatSelectedMessage(description: "群昵称 视频号\(author)\n引用 虚构引用内容").matches(card, attachmentNames: []))
            XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 视频号\(author)分号").matches(card, attachmentNames: []))
            XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 视频号别的\(author)").matches(card, attachmentNames: []))
            XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 视频号\(author) 额外文本").matches(card, attachmentNames: []))
        }
    }

    func testQuotedMediaKeepsTypeAndAttachmentVerification() throws {
        let native = try records([
            ("2026年9月5日 08:06", "[动画表情]"),
            ("2026年9月5日 08:07", "images/example.png"),
            ("2026年9月5日 08:08", "[语音]"),
        ])
        let emoji = WeChatSelectedMessage(description: "群昵称 动画表情\n引用 虚构引用内容")
        XCTAssertTrue(emoji.matches(native[0], attachmentNames: []))
        XCTAssertFalse(emoji.matches(native[2], attachmentNames: []))

        let image = WeChatSelectedMessage(description: "群昵称 图片\n引用 虚构引用内容")
        XCTAssertTrue(image.matches(native[1], attachmentNames: ["example.png"]))
        XCTAssertFalse(image.matches(native[1], attachmentNames: []))
        XCTAssertFalse(image.matches(native[1], attachmentNames: ["different.png"]))
        XCTAssertFalse(image.matches(native[0], attachmentNames: []))
        XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 普通文字\n引用 图片").matches(native[1], attachmentNames: ["example.png"]))
    }

    func testQuoteHandlingPreservesExactTextAndRequiresExplicitSuffix() throws {
        let literal = try records([("2026年9月5日 08:06", "正文\n引用 也是正文的一部分")])[0]
        XCTAssertTrue(WeChatSelectedMessage(description: "群昵称 正文\n引用 也是正文的一部分").matches(literal, attachmentNames: []))

        let emoji = try records([("2026年9月5日 08:06", "[动画表情]")])[0]
        XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 动画表情\n引用没有分隔空格").matches(emoji, attachmentNames: []))
        XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 动画表情\n其他尾文").matches(emoji, attachmentNames: []))
        XCTAssertFalse(WeChatSelectedMessage(description: "群昵称 动画表情额外文字\n引用 虚构引用内容").matches(emoji, attachmentNames: []))
    }

    func testChannelsCardRejectsWrongAuthorsMalformedURLsAndExtraText() throws {
        let selected = WeChatSelectedMessage(description: "群昵称 视频号星河实验室")
        let invalid = [
            "[视频号] 星河 https://weixin.qq.com/sph/Example",
            "[视频号] 星河实验室分号 https://weixin.qq.com/sph/Example",
            "[视频号] 星河实验室",
            "[视频号] 星河实验室 http://weixin.qq.com/sph/Example",
            "[视频号] 星河实验室 https://weixin.qq.com.evil.example/sph/Example",
            "[视频号] 星河实验室 https://fake.weixin.qq.com/sph/Example",
            "[视频号] 星河实验室 https://weixin.qq.com@evil.example/sph/Example",
            "[视频号] 星河实验室 https://weixin.qq.com:443/sph/Example",
            "[视频号] 星河实验室 https://weixin.qq.com/sph/",
            "[视频号] 星河实验室 https://weixin.qq.com/sph/Example/extra",
            "[视频号] 星河实验室 https://weixin.qq.com/sph/Example?extra=1",
            "[视频号] 星河实验室 https://weixin.qq.com/sph/Example#extra",
            "[视频号] 星河实验室 https://weixin.qq.com/sph/Example%20id",
            "[视频号] 星河实验室 https://weixin.qq.com/sph/Example+id",
            "[视频号] 星河实验室 https://weixin.qq.com/sph/Example 额外文本",
            "[视频号] 星河实验室 https://weixin.qq.com/sph/Example\n额外文本",
            "额外文本 [视频号] 星河实验室 https://weixin.qq.com/sph/Example",
            "[视频号]  星河实验室 https://weixin.qq.com/sph/Example",
            "[视频号] 星河实验室  https://weixin.qq.com/sph/Example",
        ]
        for text in invalid {
            let card = try records([("2026年9月5日 08:06", text)])[0]
            XCTAssertFalse(selected.matches(card, attachmentNames: []), text)
        }
    }

    // Independently generated with Python's zipfile: two repeated multiline
    // messages, a media reference, UTF-8 filenames, and an attachment CRC.
    private let storedZIP = "UEsDBBQAAAgAAMBAJV0fGRySiQAAAIkAAAAQAAAA6IGK5aSp6K6w5b2VLnR4dMK355SyCjIwMjblubQ55pyINeaXpSAwODowNQrkvaDlpb0K56ys5LqM6KGMCgrCt+S5mQoyMDI25bm0OeaciDXml6UgMDg6MDUK5L2g5aW9CuesrOS6jOihjAoKwrfnlLIKMjAyNuW5tDnmnIg15pelIDA4OjA2CmltYWdlcy9waG90by5wbmcKUEsDBBQAAAAAAMBAJV2KfiaRIAAAACAAAAAQAAAAaW1hZ2VzL3Bob3RvLnBuZwABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fUEsBAhQDFAAACAAAwEAlXR8ZHJKJAAAAiQAAABAAAAAAAAAAAAAAAIABAAAAAOiBiuWkqeiusOW9lS50eHRQSwECFAMUAAAAAADAQCVdin4mkSAAAAAgAAAAEAAAAAAAAAAAAAAAgAG3AAAAaW1hZ2VzL3Bob3RvLnBuZ1BLBQYAAAAAAgACAHwAAAAFAQAAAAA="
    private let deflatedZIP = "UEsDBBQAAAgIAMBAJV0fGRySUAAAAIkAAAAQAAAA6IGK5aSp6K6w5b2VLnR4dDu0/fmUTVxGBkZmT3dusXw2p8P02fSlCgYWVgamXE/2Lni6dC/X8zVrnuzqebGwh4vr0PYnO2eSoBqX2WZcmbmJ6anF+gUZ+SX5egV56VwAUEsDBBQAAAAIAMBAJV2KfiaRIgAAACAAAAAQAAAAaW1hZ2VzL3Bob3RvLnBuZ2NgZGJmYWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTBwBQSwECFAMUAAAICADAQCVdHxkcklAAAACJAAAAEAAAAAAAAAAAAAAAgAEAAAAA6IGK5aSp6K6w5b2VLnR4dFBLAQIUAxQAAAAIAMBAJV2KfiaRIgAAACAAAAAQAAAAAAAAAAAAAACAAX4AAABpbWFnZXMvcGhvdG8ucG5nUEsFBgAAAAACAAIAfAAAAM4AAAAAAA=="

    private var archiveExpected: [WeChatSelectedMessage] {
        [WeChatSelectedMessage(description: "群昵称甲 你好\n第二行"), WeChatSelectedMessage(description: "群昵称乙 你好\n第二行"), WeChatSelectedMessage(description: "群昵称甲 图片")]
    }
    func testNativeArchiveStoredAndDeflatedWithMedia() throws {
        for encoded in [storedZIP, deflatedZIP] {
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            let actual = try WeChatNativeArchive.records(data, selected: archiveExpected)
            XCTAssertEqual(actual.count, 3)
            XCTAssertEqual(actual[0].text, actual[1].text)
            XCTAssertEqual(actual[0].date, date("2026-09-05 08:05:00"))
            XCTAssertThrowsError(try WeChatNativeArchive.records(data, selected: archiveExpected.reversed()))
            XCTAssertThrowsError(try WeChatNativeArchive.records(data, selected: Array(archiveExpected.dropFirst())))
            XCTAssertEqual(try WeChatNativeArchive.records(data, count: 3, newest: archiveExpected[2], oldest: archiveExpected[0]), actual)
            XCTAssertThrowsError(try WeChatNativeArchive.records(data, count: 100, newest: archiveExpected[2], oldest: nil))
            XCTAssertThrowsError(try WeChatNativeArchive.records(data, count: 3, newest: archiveExpected[0], oldest: nil))
        }
    }

    func testViewportNavigationUsesContentAndTranslationInsteadOfCellIndices() throws {
        func row(_ text: String, _ y: Double, _ h: Double = 100) -> WeChatViewportRow { .init(text: text, y: y, height: h) }
        var viewport = WeChatViewport(rows: [row("A", -20), row("B", 80), row("C", 180)], anchorIndex: 2)
        // The cells were recycled and older content appeared above the overlap.
        try viewport.advance([row("older", -30, 160), row("A", 130), row("B", 230)], older: true)
        XCTAssertEqual(viewport.firstOrdinal, 3)
        XCTAssertEqual(viewport.index(of: 2), 1)
        XCTAssertEqual(viewport.lastDisplacement, 150)
        try viewport.advance([row("A", 30), row("B", 130), row("C", 230)], older: false)
        XCTAssertEqual(viewport.firstOrdinal, 2)
        XCTAssertThrowsError(try viewport.advance([row("unrelated", 10)], older: true))
    }

    func testViewportReconstructsIndicesAroundAKnownOrdinal() {
        let rows = ["older", "anchor", "newer"].enumerated().map {
            WeChatViewportRow(text: $1, y: Double($0) * 100, height: 100)
        }
        let viewport = WeChatViewport(rows: rows, anchorIndex: 1, anchorOrdinal: 100)
        XCTAssertEqual(viewport.firstOrdinal, 101)
        XCTAssertEqual(viewport.index(of: 100), 1)
        XCTAssertEqual(viewport.index(of: 101), 0)
        XCTAssertEqual(viewport.index(of: 99), 2)
        XCTAssertNil(viewport.index(of: 102))
        XCTAssertNil(viewport.index(of: 98))
        XCTAssertEqual(WeChatViewport(rows: rows, anchorIndex: 1).index(of: 0), 1)
    }

    func testViewportKeepsKnownOrdinalThroughResumeAndRepeatedOverlap() throws {
        func row(_ text: String, _ y: Double) -> WeChatViewportRow { .init(text: text, y: y, height: 100) }
        // Keyboard navigation found ordinal 99 at the second repeated row.
        var viewport = WeChatViewport(
            rows: [row("boundary", -20), row("repeated", 80), row("repeated", 180), row("newer", 280)],
            anchorIndex: 2, anchorOrdinal: 99
        )
        try viewport.resume([row("boundary", 0), row("repeated", 100), row("repeated", 200), row("newer", 300)])
        XCTAssertEqual(viewport.firstOrdinal, 101)
        XCTAssertEqual(viewport.index(of: 99), 2)
        XCTAssertEqual(viewport.lastDisplacement, 20)

        try viewport.advance([row("older", 0), row("boundary", 100), row("repeated", 200), row("repeated", 300)], older: true)
        XCTAssertEqual(viewport.firstOrdinal, 102)
        XCTAssertEqual(viewport.index(of: 100), 2)
        XCTAssertEqual(viewport.index(of: 99), 3)
        XCTAssertNil(viewport.index(of: 98))
        XCTAssertEqual(viewport.lastDisplacement, 100)

        // Both repeated occurrences participate in the overlap on the way back.
        try viewport.advance([row("repeated", 0), row("repeated", 100), row("newer", 200), row("latest", 300)], older: false)
        XCTAssertEqual(viewport.firstOrdinal, 100)
        XCTAssertEqual(viewport.index(of: 100), 0)
        XCTAssertEqual(viewport.index(of: 99), 1)
        XCTAssertEqual(viewport.index(of: 98), 2)
        XCTAssertEqual(viewport.lastDisplacement, -200)
    }

    func testRangeSelectionOfOversizedEndpointRequiresInsetAndKeyboardProof() {
        func viewport(_ y: Double) -> WeChatViewport {
            .init(rows: [.init(text: "oversized", y: y, height: 1370)], anchorIndex: 0, anchorOrdinal: 99)
        }
        for keyboardVerified in [false, true] {
            XCTAssertFalse(viewport(139).canSelectRange(endingAt: 99, listTop: 139, listHeight: 629, keyboardVerified: keyboardVerified))
        }
        XCTAssertTrue(viewport(147).canSelectRange(endingAt: 99, listTop: 139, listHeight: 629, keyboardVerified: true))
        XCTAssertFalse(viewport(147).canSelectRange(endingAt: 99, listTop: 139, listHeight: 629, keyboardVerified: false))
        XCTAssertFalse(viewport(147).canSelectRange(endingAt: 100, listTop: 139, listHeight: 629, keyboardVerified: true))
    }

    func testRangeSelectionIgnoresPartialOlderRowButRejectsAnotherStartingInside() {
        func viewport(olderY: Double, olderHeight: Double) -> WeChatViewport {
            .init(rows: [
                .init(text: "older", y: olderY, height: olderHeight),
                .init(text: "oversized", y: 147, height: 1370),
            ], anchorIndex: 1, anchorOrdinal: 199)
        }
        XCTAssertTrue(viewport(olderY: 39, olderHeight: 108).canSelectRange(endingAt: 199, listTop: 139, listHeight: 629, keyboardVerified: true))
        XCTAssertFalse(viewport(olderY: 39, olderHeight: 108).canSelectRange(endingAt: 199, listTop: 139, listHeight: 629, keyboardVerified: false))
        XCTAssertFalse(viewport(olderY: 143, olderHeight: 4).canSelectRange(endingAt: 199, listTop: 139, listHeight: 629, keyboardVerified: true))
    }

    func testRangeSelectionRetainsFirstFullyVisibleEndpointBehavior() {
        let viewport = WeChatViewport(rows: [
            .init(text: "partial older", y: 39, height: 108),
            .init(text: "endpoint", y: 147, height: 100),
            .init(text: "newer", y: 247, height: 100),
        ], anchorIndex: 1, anchorOrdinal: 99)
        for keyboardVerified in [false, true] {
            XCTAssertTrue(viewport.canSelectRange(endingAt: 99, listTop: 139, listHeight: 629, keyboardVerified: keyboardVerified))
            XCTAssertFalse(viewport.canSelectRange(endingAt: 98, listTop: 139, listHeight: 629, keyboardVerified: keyboardVerified))
        }
        let flush = WeChatViewport(rows: [.init(text: "endpoint", y: 139, height: 100)], anchorIndex: 0)
        XCTAssertFalse(flush.canSelectRange(endingAt: 0, listTop: 139, listHeight: 629, keyboardVerified: false))
    }

    func testSecondBatchResumesAtExactlyOneMessageOlderThanFirstHundred() throws {
        func row(_ text: String, _ y: Double) -> WeChatViewportRow { .init(text: text, y: y, height: 100) }
        var viewport = WeChatViewport(rows: [row("m100", -90), row("m99", 10), row("m98", 110)], anchorIndex: 100)
        // A recipient sheet was closed. Its old AX handles are not reused.
        try viewport.resume([row("m100", -90), row("m99", 10), row("m98", 110)])
        try viewport.advance([row("m100", 0), row("m99", 100), row("m98", 200)], older: true)
        XCTAssertEqual(viewport.index(of: 100), 0)
        XCTAssertEqual(viewport.index(of: 99), 1)
        // Jumping to a different message after closing the sheet must fail
        // before posting any recovery scroll, even if the row count matches.
        XCTAssertThrowsError(try viewport.resume([row("older", 0), row("m100", 100), row("m99", 200)]))
    }

    func testExternalSharingExitsMultiSelectWithoutLosingTheNextBatchPosition() throws {
        func row(_ text: String, _ y: Double) -> WeChatViewportRow { .init(text: text, y: y, height: 100) }
        var viewport = WeChatViewport(rows: [row("甲 第101条", -90), row("乙 第100条", 10), row("甲 第99条", 110)], anchorIndex: 100)
        let normal = [row("第101条", -90), row("第100条", 10), row("第99条", 110)]
        XCTAssertThrowsError(try viewport.resume(normal))
        try viewport.resume(normal, afterLeavingSelection: true)
        try viewport.advance([row("第101条", 0), row("第100条", 100), row("第99条", 200)], older: true)
        XCTAssertEqual(viewport.index(of: 100), 0)
        XCTAssertEqual(viewport.index(of: 99), 1)
        XCTAssertThrowsError(try viewport.resume([row("第102条", 0), row("第101条", 100), row("第100条", 200)], afterLeavingSelection: true))
    }

    func testSelectionModeChangeUsesOrderedContextAndRetainsDuplicateOccurrences() throws {
        let selected = ["甲 开始", "乙 重复", "乙 重复", "甲 结束"]
        XCTAssertEqual(try WeChatMessageContext.resolve(selected: selected, target: 2, normal: ["开始", "重复", "重复", "结束"]), 2)
        XCTAssertEqual(try WeChatMessageContext.resolve(selected: selected, target: 2, normal: ["更早", "开始", "重复", "重复", "结束"]), 3)
        XCTAssertThrowsError(try WeChatMessageContext.resolve(selected: selected, target: 2, normal: ["无关", "重复", "结束"]))
        XCTAssertThrowsError(try WeChatMessageContext.resolve(selected: ["甲 图片", "甲 图片", "甲 图片"], target: 1, normal: ["图片", "图片", "图片", "图片"]))
    }
    func testNativeArchiveRejectsCorruptionTruncationAndCancellation() throws {
        var data = try XCTUnwrap(Data(base64Encoded: storedZIP))
        data[245] ^= 0xff // attachment payload, outside the transcript
        XCTAssertThrowsError(try WeChatNativeArchive.records(data, selected: archiveExpected))
        XCTAssertThrowsError(try WeChatNativeArchive.records(Data(data.dropLast(8)), selected: archiveExpected))
        XCTAssertThrowsError(try WeChatNativeArchive.records(Data(base64Encoded: deflatedZIP)!, selected: archiveExpected, checkCancellation: { throw CancellationError() })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}

extension WeChatForwardTests {
    /// The field showed "②00" — a Chinese IME offered a circled numeral and the
    /// free-text field took it, because `TextField(value:format:)` only parses
    /// when it loses focus.
    func testCircledAndFullWidthNumeralsFoldToDigits() {
        XCTAssertEqual(WeChatForwardRange.digits("②00"), "200")
        XCTAssertEqual(WeChatForwardRange.digits("２００"), "200")
        XCTAssertEqual(WeChatForwardRange.digits("三00"), "300")
        XCTAssertEqual(WeChatForwardRange.digits("٣٠٠"), "300")
    }

    func testAnythingThatIsNotADigitIsRefused() {
        XCTAssertEqual(WeChatForwardRange.digits("1a2 3-"), "123")
        XCTAssertEqual(WeChatForwardRange.digits("1.5"), "15")
        XCTAssertEqual(WeChatForwardRange.digits("abc"), "")
        XCTAssertEqual(WeChatForwardRange.digits(""), "")
        // 十 and 百 carry numeric values of their own; neither is a digit.
        XCTAssertEqual(WeChatForwardRange.digits("十"), "")
        XCTAssertEqual(WeChatForwardRange.digits("½"), "")
    }

    func testLeadingZerosCollapseButASingleZeroSurvives() {
        XCTAssertEqual(WeChatForwardRange.digits("007"), "7")
        XCTAssertEqual(WeChatForwardRange.digits("0"), "0")
        XCTAssertEqual(WeChatForwardRange.digits("000"), "0")
    }

    /// Out of range is still typeable — the form says why, rather than the
    /// field silently correcting what was typed.
    func testAnOutOfRangeNumberIsKeptSoTheFormCanExplainIt() {
        XCTAssertEqual(WeChatForwardRange.digits("5000"), "5000")
        XCTAssertFalse(WeChatForwardRange(unit: .messages, value: 5000).isValid)
        // Bounded so a held key cannot overflow the count it becomes.
        XCTAssertEqual(WeChatForwardRange.digits(String(repeating: "9", count: 40)).count, 6)
    }
}
