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
