import DukouCore
import Foundation
import XCTest

final class ForwardArchiveNameTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private var exportedAt: Date { date("2026-09-08T22:00:00Z") }

    func testNamesKnownRangeAndCountInChronologicalOrder() {
        let first = date("2026-09-08T09:10:00Z")
        let last = date("2026-09-08T21:30:00Z")
        let expected = "研发群_20260908-0910至20260908-2130_300条.zip"
        for (start, end) in [(first, last), (last, first)] {
            XCTAssertEqual(make("研发群", count: 300, start: start, end: end), expected)
        }
    }

    func testSingleInstantAndSameMinuteDoNotRepeatTheStamp() {
        let first = date("2026-09-08T09:10:00Z")
        for end in [first, first.addingTimeInterval(30)] {
            XCTAssertEqual(make("好友", count: 1, start: first, end: end), "好友_20260908-0910_1条.zip")
        }
    }

    func testIncompleteRangesExplicitlyUseExportTime() {
        let known = date("2026-01-01T09:10:00Z")
        let endpoints: [(Date?, Date?)] = [(nil, nil), (known, nil), (nil, known)]
        for (start, end) in endpoints {
            XCTAssertEqual(
                make("群名", count: 2000, start: start, end: end),
                "群名_导出20260908-220000_2000条.zip"
            )
        }
    }

    func testUnknownAndInvalidCountsAreExplicitRatherThanGuessed() {
        for count in [nil, -1, Int.min] as [Int?] {
            XCTAssertEqual(make("群名", count: count), "群名_导出20260908-220000_条数未知.zip")
        }
        XCTAssertEqual(make("群名", count: 0), "群名_导出20260908-220000_0条.zip")
    }

    func testSuppliedTimeZoneAppliesToContentAndExportDates() {
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        XCTAssertEqual(
            ForwardArchiveName.make(source: "群名", count: 1, start: nil, end: nil, exportedAt: exportedAt, timeZone: zone),
            "群名_导出20260909-060000_1条.zip"
        )
        XCTAssertEqual(
            ForwardArchiveName.make(source: "群名", count: 1, start: exportedAt, end: exportedAt, timeZone: zone),
            "群名_20260909-0600_1条.zip"
        )
    }

    func testHostileSourcesRemainOneVisiblePortableFileComponent() {
        let sources = [
            "../../private/group", "C:\\users\\group", "file:///tmp/group", "%2e%2e%2fgroup",
            "群名:<>\"'`|?*", "群\0名\n\r\t", "群\u{202E}gpj\u{202C}",
            "群\u{2066}名\u{2069}\u{200E}\u{200F}\u{2028}\u{2029}",
            " .hidden. ", "..", "", "   ", String(repeating: "/\\:", count: 100),
        ]
        let forbidden = CharacterSet(charactersIn: "/\\:<>\"'`|?*%")
        let directory = URL(fileURLWithPath: "/tmp/export", isDirectory: true)
        for source in sources {
            let name = make(source, count: 20)
            XCTAssertTrue(name.hasSuffix("_导出20260908-220000_20条.zip"), source.debugDescription)
            XCTAssertFalse(name.hasPrefix("."), source.debugDescription)
            XCTAssertFalse(name.unicodeScalars.contains {
                forbidden.contains($0)
                    || [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            }, source.debugDescription)
            let file = directory.appendingPathComponent(name)
            XCTAssertEqual(file.lastPathComponent, name)
            XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        }
        XCTAssertEqual(make("..", count: 1), "记录_导出20260908-220000_1条.zip")
    }

    func testWindowsDeviceStemsWithExtensionsAreEscaped() {
        for source in ["CON", "con.txt", "NUL.anything", "AUX.log", "COM1.txt", "LPT9.log", "COM¹.txt", "CONOUT$.txt"] {
            XCTAssertTrue(make(source, count: 1).hasPrefix("_" + source + "_"), source)
        }
        XCTAssertEqual(make("CONversations", count: 1), "CONversations_导出20260908-220000_1条.zip")
    }

    func testLongMultibyteSourcesShortenWithoutTruncatingDatesCountOrExtension() {
        let first = date("2026-09-08T09:10:00Z")
        let last = date("2026-09-08T21:30:00Z")
        let suffix = "_20260908-0910至20260908-2130_\(Int.max)条.zip"
        let source = String(repeating: "研究群🌅", count: 200)
        let name = make(source, count: Int.max, start: first, end: last)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertGreaterThan(name.utf8.count, 190)
        XCTAssertTrue(name.hasSuffix("…" + suffix))
        let shortenedSource = String(name.dropLast(suffix.count + 1))
        XCTAssertTrue(source.hasPrefix(shortenedSource))
        XCTAssertFalse(shortenedSource.isEmpty)
    }

    func testLongSourceStillPreservesUnknownCountAndExplicitExportTime() {
        let name = make(String(repeating: "𠮷", count: 200), count: nil)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertTrue(name.hasSuffix("…_导出20260908-220000_条数未知.zip"))
    }

    func testCanonicalEquivalentSourcesProduceTheSameName() {
        XCTAssertEqual(make("Café 🐈", count: 1), make("Cafe\u{301} 🐈", count: 1))
        XCTAssertTrue(make("Café 🐈", count: 1).hasPrefix("Café_🐈_"))
    }

    func testOversizedSingleCharacterCannotOverflowTheFilenameBudget() {
        let source = "a" + String(repeating: "\u{301}", count: 500)
        let name = make(source, count: 1)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertEqual(name, "记录_导出20260908-220000_1条.zip")
    }

    private func make(_ source: String, count: Int?, start: Date? = nil, end: Date? = nil) -> String {
        ForwardArchiveName.make(source: source, count: count, start: start, end: end, exportedAt: exportedAt, timeZone: utc)
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
