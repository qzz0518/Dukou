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

    // Independently generated with Python's zipfile: two repeated multiline
    // messages, a media reference, UTF-8 filenames, and an attachment CRC.
    private let storedZIP = "UEsDBBQAAAgAAMBAJV0fGRySiQAAAIkAAAAQAAAA6IGK5aSp6K6w5b2VLnR4dMK355SyCjIwMjblubQ55pyINeaXpSAwODowNQrkvaDlpb0K56ys5LqM6KGMCgrCt+S5mQoyMDI25bm0OeaciDXml6UgMDg6MDUK5L2g5aW9CuesrOS6jOihjAoKwrfnlLIKMjAyNuW5tDnmnIg15pelIDA4OjA2CmltYWdlcy9waG90by5wbmcKUEsDBBQAAAAAAMBAJV2KfiaRIAAAACAAAAAQAAAAaW1hZ2VzL3Bob3RvLnBuZwABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fUEsBAhQDFAAACAAAwEAlXR8ZHJKJAAAAiQAAABAAAAAAAAAAAAAAAIABAAAAAOiBiuWkqeiusOW9lS50eHRQSwECFAMUAAAAAADAQCVdin4mkSAAAAAgAAAAEAAAAAAAAAAAAAAAgAG3AAAAaW1hZ2VzL3Bob3RvLnBuZ1BLBQYAAAAAAgACAHwAAAAFAQAAAAA="
    private let deflatedZIP = "UEsDBBQAAAgIAMBAJV0fGRySUAAAAIkAAAAQAAAA6IGK5aSp6K6w5b2VLnR4dDu0/fmUTVxGBkZmT3dusXw2p8P02fSlCgYWVgamXE/2Lni6dC/X8zVrnuzqebGwh4vr0PYnO2eSoBqX2WZcmbmJ6anF+gUZ+SX5egV56VwAUEsDBBQAAAAIAMBAJV2KfiaRIgAAACAAAAAQAAAAaW1hZ2VzL3Bob3RvLnBuZ2NgZGJmYWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTBwBQSwECFAMUAAAICADAQCVdHxkcklAAAACJAAAAEAAAAAAAAAAAAAAAgAEAAAAA6IGK5aSp6K6w5b2VLnR4dFBLAQIUAxQAAAAIAMBAJV2KfiaRIgAAACAAAAAQAAAAAAAAAAAAAACAAX4AAABpbWFnZXMvcGhvdG8ucG5nUEsFBgAAAAACAAIAfAAAAM4AAAAAAA=="

    func testNativeArchiveStoredAndDeflatedWithMedia() throws {
        for encoded in [storedZIP, deflatedZIP] {
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertEqual(try WeChatNativeArchive.messageCount(data), 3)
        }
    }

    // Fictional fixtures generated independently with Python zipfile. The
    // archive reader accepts the native output without observing AX bodies.
    func testNativeArchiveEstimatesCountsAroundTheHundredMessageBatch() throws {
        let fixtures: [(Int, String)] = [
            (99, "UEsDBBQAAAAIAAAAJ10RN2wSUAEAABAnAAAOAAAAdHJhbnNjcmlwdC50eHTt0V9LwlAYBvD7fYqxiy6d7aJIkD5I7GK0kaJNcbOCCJRmamIrIkWxf+ToDxReiFZTL/ZZds7ZvkWTirrU++dcPnDeh/f9eeOg06U3FrEvwlI5KFU4KS6tkY/hBu3V1mnb4VelRDzObdHeC712SPOe1asyT1sDVq8x1/LdEX8oZNK6KiSEop7Rc/u6cMRx3qJzw8sZPXNknvU//VmDT5lm3kiIonag7OazWiyt7ynZtCrmFTO1+TM/GUVFbSVXULVCcjul6DuaunhjtIj/3gimU9a1ws58AdF3XWrZ5LzJHgcxxTA0c4kFgvIp6T8HbwMyvZI5PnremJxUwuOnv6/zNOpltw5tj8L2kN5NyMT+F3/flb4+0FZ1iW6gAAUoQAEKUIACFKAABShAAQpQgAIUoAAFKEABClCAAhSgAAUoQAEKUIACFKAABShAAcovyhdQSwECFAMUAAAACAAAACddETdsElABAAAQJwAADgAAAAAAAAAAAAAAgAEAAAAAdHJhbnNjcmlwdC50eHRQSwUGAAAAAAEAAQA8AAAAfAEAAAAA"),
            (100, "UEsDBBQAAAAIAAAAJ11udzJtUgEAAIwnAAAOAAAAdHJhbnNjcmlwdC50eHTt0V9LwlAYBvD7fYqxiy6d7aJIkD5I7GK0kUOb4mYFESjN1MQsIkWxf+ToDxReiFZTL/ZZds7ZvkWTgrrUuy6ec/nAeR/e9+eNg06X3tikeREWS0GxzElxaY18DDdor7pO2w6/KiXicW6L9l7otUMa96xWkXnaGrBalbm27474QyGtG6qQEApG2sjuG8IRx3mLzg0vZ/TMkXnW//RndT5lWTkzIYragbKby2gx3dhTMroq5hQrtfkzPxlFBW0lm1e1fHI7pRg7mrp4Y7SI/14PplPWtcPOfAHRd11qN8l5gz0OYoppatYSCwSlU9J/Dt4GZHolc3z0vDE5KYfHT79f52nUy24d2h6F7SG9m5BJ80/8fVf6+kBblSW6gQIUoAAFKEABClCAAhSgAAUoQAEKUIACFKAABShAAQpQgAIUoAAFKEABClCAAhSgAAUo/wHlC1BLAQIUAxQAAAAIAAAAJ11udzJtUgEAAIwnAAAOAAAAAAAAAAAAAACAAQAAAAB0cmFuc2NyaXB0LnR4dFBLBQYAAAAAAQABADwAAAB+AQAAAAA="),
            (101, "UEsDBBQAAAAIAAAAJ100fEIVUQEAAOQnAAAOAAAAdHJhbnNjcmlwdC50eHTt0V9LwlAYBvD7fYqxiy6d7aJIkD5I7GK0kUOb4mYFESjN1MQsIkWxf+ToDxReiFZTL/ZZds7ZvkWTgrrU23jO5QPnfXjfnzcOOl16Y5PmRVgsBcUyJ8WlNfIx3KC96jptO/yqlIjHuS3ae6HXDmncs1pF5mlrwGpV5tq+O+IPhbRuqEJCKBhpI7tvCEcc5y06N7yc0TNH5ln/05/V+ZRl5cyEKGoHym4uo8V0Y0/J6KqYU6zU5s/8ZBQVtJVsXtXyye2UYuxo6uKN0SL+ez2YTlnXDjvzBUTfdandJOcN9jiIKaapWUssEJROSf85eBuQ6ZXM8dHzxuSkHB4//X6dp1Evu3VoexS2h/RuQibNP/H3XenrA21VlugGClCAAhSgAAUoQAEKUIACFKAABShAAQpQgAIUoAAFKEABClCAAhSgAAUoQAEKUIACFKD8Z5QvUEsBAhQDFAAAAAgAAAAnXTR8QhVRAQAA5CcAAA4AAAAAAAAAAAAAAIABAAAAAHRyYW5zY3JpcHQudHh0UEsFBgAAAAABAAEAPAAAAH0BAAAAAA=="),
        ]
        for (expected, encoded) in fixtures {
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertEqual(try WeChatNativeArchive.messageCount(data), expected)
        }
    }

    func testNativeArchiveAcceptsUnknownCardsMissingReferencesAndUnorderedDates() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIAAAAJ10x879qEQEAAJQBAAAOAAAAdHJhbnNjcmlwdC50eHQ7tP3FzFnP5rU87Z/4sqHxRUMrl5GBkdnTnVssn83pMH82famCoZGVgTFX9LM5q57NXfq0d+HzzvZYhWfTNjzv7Hi+u+XJ7m0K1UrZmXkpSlZKpXnZefnleUq1XFyHiDLXkCv65eR9z/qWxio8X7Lryb5uhYySkoJiK3391IrE3IKcVL3MvLLEnMwU/YLEkgx7qPm2QKHSVLX8opTUItvkjMS89NQU4m0EeuTJju4Xe/c+n9XycibIA/pPdu9+1tL/dELv8+Ub9BKLi1NLiDXOgCv6RWPX0yUrX6zb8HTv1FguBSA4tP1pW+vL5hUIrSBRoL3P5y99Nn3by+lbni3Y83RPP5IwJFyfrV38bFo7FwBQSwECFAMUAAAACAAAACddMfO/ahEBAACUAQAADgAAAAAAAAAAAAAAgAEAAAAAdHJhbnNjcmlwdC50eHRQSwUGAAAAAAEAAQA8AAAAPQEAAAAA"))
        XCTAssertEqual(try WeChatNativeArchive.messageCount(data), 4)
    }

    func testNativeArchiveUsesLargestRecognizableTranscriptCount() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIAAAAJ1206EYGOQAAAFkAAAAOAAAAdHJhbnNjcmlwdC50eHQ7tP3FzFnP5rU87Z/4sqHxRUMrl5GBkdnTnVssn83pMH82famCoZGVgQHX8ymbuLgOEan4yc6ZXABQSwMEFAAAAAgAAAAnXazxhbVAAAAAswAAABIAAABhdHRhY2hlZC9vdGhlci5UWFQ7tP3FzFnP5rU87Z/4sqHxRUMrl5GBkdnTnVssn83pMH82famCoZGVgQHX8ymbuLgOEan4yc6ZJCjeQZLiRi4AUEsDBBQAAAAIAAAAJ12Q6/sAGAAAABYAAAAKAAAAcmVhZG1lLnR4dHNUSCstKS1KVUitKMgvKlFIyy/KTSwBAFBLAQIUAxQAAAAIAAAAJ1206EYGOQAAAFkAAAAOAAAAAAAAAAAAAACAAQAAAAB0cmFuc2NyaXB0LnR4dFBLAQIUAxQAAAAIAAAAJ12s8YW1QAAAALMAAAASAAAAAAAAAAAAAACAAWUAAABhdHRhY2hlZC9vdGhlci5UWFRQSwECFAMUAAAACAAAACddkOv7ABgAAAAWAAAACgAAAAAAAAAAAAAAgAHVAAAAcmVhZG1lLnR4dFBLBQYAAAAAAwADALQAAAAVAQAAAAA="))
        XCTAssertEqual(try WeChatNativeArchive.messageCount(data), 4)
    }

    func testNativeArchiveKeepsUnknownTextAndAttachmentOnlyArchivesWithoutACount() throws {
        let fixtures = [
            "UEsDBBQAAAAIAAAAJ10muxkFOQAAADsAAAAOAAAAdHJhbnNjcmlwdC50eHR7NmfV8/lLn89qeTZtw7MFe57u6efKTS0uTkxPtVJIrUjMLchJ5cooKSkottLXh/L1MvPKEnMyUwBQSwMEFAAAAAgAAAAnXYp+JpEiAAAAIAAAAA4AAABhdHRhY2htZW50LmJpbmNgZGJmYWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTBwBQSwECFAMUAAAACAAAACddJrsZBTkAAAA7AAAADgAAAAAAAAAAAAAAgAEAAAAAdHJhbnNjcmlwdC50eHRQSwECFAMUAAAACAAAACddin4mkSIAAAAgAAAADgAAAAAAAAAAAAAAgAFlAAAAYXR0YWNobWVudC5iaW5QSwUGAAAAAAIAAgB4AAAAswAAAAAA",
            "UEsDBBQAAAAIAAAAJ10AjkiuBgAAAAQAAAAOAAAAdHJhbnNjcmlwdC50eHT7/+8XAwBQSwMEFAAAAAgAAAAnXYp+JpEiAAAAIAAAAA4AAABhdHRhY2htZW50LmJpbmNgZGJmYWVj5+Dk4ubh5eMXEBQSFhEVE5eQlJKWkZWTBwBQSwECFAMUAAAACAAAACddAI5IrgYAAAAEAAAADgAAAAAAAAAAAAAAgAEAAAAAdHJhbnNjcmlwdC50eHRQSwECFAMUAAAACAAAACddin4mkSIAAAAgAAAADgAAAAAAAAAAAAAAgAEyAAAAYXR0YWNobWVudC5iaW5QSwUGAAAAAAIAAgB4AAAAgAAAAAAA",
            "UEsDBBQAAAAIAAAAJ12KfiaRIgAAACAAAAAOAAAAYXR0YWNobWVudC5iaW5jYGRiZmFlY+fg5OLm4eXjFxAUEhYRFROXkJSSlpGVkwcAUEsBAhQDFAAAAAgAAAAnXYp+JpEiAAAAIAAAAA4AAAAAAAAAAAAAAIABAAAAAGF0dGFjaG1lbnQuYmluUEsFBgAAAAABAAEAPAAAAE4AAAAAAA==",
        ]
        for encoded in fixtures {
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            XCTAssertNil(try WeChatNativeArchive.messageCount(data))
        }
    }

    func testNativeArchiveRejectsEmptyFilesAndArchives() throws {
        let fixtures = [
            Data(),
            try XCTUnwrap(Data(base64Encoded: "UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA==")),
            try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIAAAAJ10AAAAAAgAAAAAAAAAOAAAAdHJhbnNjcmlwdC50eHQDAFBLAQIUAxQAAAAIAAAAJ10AAAAAAgAAAAAAAAAOAAAAAAAAAAAAAACAAQAAAAB0cmFuc2NyaXB0LnR4dFBLBQYAAAAAAQABADwAAAAuAAAAAAA=")),
        ]
        for data in fixtures {
            XCTAssertThrowsError(try WeChatNativeArchive.messageCount(data)) { error in
                XCTAssertEqual(error as? WeChatReadError, .invalidTranscript)
            }
        }
    }

    func testTranscriptParserKeepsMultilineBodiesAndRejectsUnrecognizedHeaders() throws {
        let rows = try records([("2026年9月5日 08:05", "第一行\n第二行"), ("2026年9月5日 08:06", "再见")])
        XCTAssertEqual(rows.map(\.text), ["第一行\n第二行", "再见"])
        XCTAssertThrowsError(try WeChatTranscriptRecord.parse("unrecognized text"))
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
        XCTAssertThrowsError(try WeChatNativeArchive.messageCount(data))
        XCTAssertThrowsError(try WeChatNativeArchive.messageCount(Data(data.dropLast(8))))
        XCTAssertThrowsError(try WeChatNativeArchive.messageCount(Data(base64Encoded: deflatedZIP)!, checkCancellation: { throw CancellationError() })) { error in
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
