import XCTest
@testable import DukouCore

final class ChatMemoryTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0)!
    private func date(_ minutes: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + minutes * 60) }

    func testAChatsOwnPromptWinsOverTheSelectionUntilItIsDeleted() {
        let summary = AttachedPrompt(text: "总结"), translate = AttachedPrompt(text: "翻译")
        var settings = PromptSettings(prompts: [summary, translate], selectedID: summary.id, attachToForwards: true)
        var memories = ChatMemories()
        memories.setPrompt(translate.id, for: "产品群 (128)")

        XCTAssertEqual(memories.promptID(for: "产品群"), translate.id, "The member count is not part of the name")
        XCTAssertEqual(settings.attachment(for: .forward, preferring: memories.promptID(for: "产品群"))?.id, translate.id)
        XCTAssertEqual(settings.attachment(for: .forward, preferring: memories.promptID(for: "别的群"))?.id, summary.id)
        XCTAssertNil(settings.attachment(for: .wechat, preferring: translate.id), "A chat's prompt does not turn a surface on")

        settings.remove(id: translate.id)
        memories.forget(prompt: translate.id)
        XCTAssertNil(memories.promptID(for: "产品群"))
        XCTAssertEqual(settings.attachment(for: .forward, preferring: translate.id)?.id, summary.id)
    }

    func testCursorIsPerPromptAndOnlyMovesForward() {
        let summary = UUID(), translate = UUID()
        var memories = ChatMemories()
        memories.advance("产品群", prompt: summary, to: date(30))
        memories.advance("产品群", prompt: summary, to: date(10))
        XCTAssertEqual(memories.cursor(for: "产品群", prompt: summary), date(30))
        XCTAssertNil(memories.cursor(for: "产品群", prompt: translate))
        XCTAssertNil(memories.cursor(for: "别的群", prompt: summary))
    }

    func testResumeNoteOnlyWhenTheExportStraddlesTheCursor() {
        XCTAssertNotNil(ResumeNote.text(cursor: date(30), start: date(0), end: date(60), timeZone: timeZone))
        XCTAssertNotNil(ResumeNote.text(cursor: date(30), start: date(30), end: date(31), timeZone: timeZone))
        XCTAssertNil(ResumeNote.text(cursor: date(30), start: date(31), end: date(60), timeZone: timeZone), "Nothing is repeated")
        XCTAssertNil(ResumeNote.text(cursor: date(30), start: date(0), end: date(30), timeZone: timeZone), "Sent again on purpose")
        XCTAssertTrue(try XCTUnwrap(ResumeNote.text(cursor: Date(timeIntervalSince1970: 1_789_000_200), start: .distantPast, end: .distantFuture,
                                                    timeZone: timeZone)).contains("2026-09-"))
    }

    func testOldestChatsAreForgottenPastTheLimitAndTheBlobRoundTrips() throws {
        var memories = ChatMemories()
        let prompt = UUID()
        for index in 0...ChatMemories.limit {
            memories.advance("群\(index)", prompt: prompt, to: date(1), at: date(Double(index)))
        }
        XCTAssertEqual(memories.chats.count, ChatMemories.limit)
        XCTAssertNil(memories.cursor(for: "群0", prompt: prompt))
        XCTAssertNotNil(memories.cursor(for: "群\(ChatMemories.limit)", prompt: prompt))
        let decoded = try JSONDecoder().decode(ChatMemories.self, from: JSONEncoder().encode(memories))
        XCTAssertEqual(decoded, memories)
    }

    func testPromptSettingsWrittenBeforeResumeExistedDefaultToOn() throws {
        let legacy = Data(#"{"prompts":[],"attachToForwards":true}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(PromptSettings.self, from: legacy).resumesChats)
    }
}
