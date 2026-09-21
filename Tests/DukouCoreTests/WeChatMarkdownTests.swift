import XCTest
@testable import DukouCore

final class WeChatMarkdownTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    func testNoteHasFrontMatterDaysAndAttachmentsWhereTheirMessagesNameThem() throws {
        let first = try transcript("·甲\n2026年9月8日 09:00\n早\n[图片] photo 1.png\n\n·乙\n2026年9月9日 10:30\n[文件] 报告.pdf\n")
        let second = try transcript("·丙\n2026年9月7日 08:00\n最早\n")
        let note = try WeChatMarkdown.render(chat: "产品\"群\"", batches: [
            .init(transcript: first, prefix: "batches/0001", paths: [first.path, "files/photo 1.png", "files/报告.pdf", "files/没人提到.mp4"]),
            .init(transcript: second, prefix: "batches/0002", paths: [second.path]),
        ], exportedAt: Date(timeIntervalSince1970: 1_789_000_000), timeZone: timeZone)

        XCTAssertTrue(note.hasPrefix("---\ntitle: \"产品\\\"群\\\"\"\nsource: WeChat\n"))
        XCTAssertTrue(note.contains("start: 2026-09-07 08:00\nend: 2026-09-09 10:30\nmessages: 3\n"))
        let days = ["## 2026-09-07", "## 2026-09-08", "## 2026-09-09"].map { note.range(of: $0)?.lowerBound }
        XCTAssertEqual(days.compactMap { $0 }.count, 3)
        XCTAssertTrue(zip(days, days.dropFirst()).allSatisfy { $0! < $1! }, "Batches are interleaved by time, not by order of arrival")
        XCTAssertTrue(note.contains("**甲** 09:00\n\n早  \n![photo 1.png](batches/0001/files/photo%201.png)"))
        XCTAssertTrue(note.contains("\n[报告.pdf](batches/0001/files/%E6%8A%A5%E5%91%8A.pdf)"), "A file is linked, not embedded")
        XCTAssertTrue(note.contains("其他附件\n\n- [没人提到.mp4]("))
    }

    func testChatTextCannotRestructureTheNote() {
        XCTAssertEqual(WeChatMarkdown.escape("# 标题"), "\\# 标题")
        XCTAssertEqual(WeChatMarkdown.escape("> 引用"), "\\> 引用")
        XCTAssertEqual(WeChatMarkdown.escape("- 列表"), "\\- 列表")
        XCTAssertEqual(WeChatMarkdown.escape("1. 第一"), "1\\. 第一")
        XCTAssertEqual(WeChatMarkdown.escape("---"), "\\---")
        XCTAssertEqual(WeChatMarkdown.escape("<script>[x](y)`"), "\\<script>\\[x](y)\\`")
        XCTAssertEqual(WeChatMarkdown.escape("        缩进八格"), "缩进八格")
        XCTAssertEqual(WeChatMarkdown.escape("https://a.com/x_y-z*1"), "https://a.com/x_y-z*1", "Ordinary text stays readable")
        XCTAssertEqual(WeChatMarkdown.escape("-5 度"), "-5 度")
    }

    func testATranscriptWithoutDatesIsKeptWordForWord() throws {
        let unknown = WeChatNativeArchive.Transcript(path: "聊天记录.txt", body: "# 新格式\n内容", records: nil)
        let note = try WeChatMarkdown.render(chat: "群", batches: [.init(transcript: unknown, prefix: "batches/0001", paths: [unknown.path, "a.png"])],
                                             timeZone: timeZone)
        XCTAssertTrue(note.contains("messages: 0\n"))
        XCTAssertFalse(note.contains("start:"))
        XCTAssertTrue(note.contains("\n    # 新格式\n    内容\n"))
        XCTAssertTrue(note.contains("- [a.png](batches/0001/a.png)"))
    }

    private func transcript(_ body: String) throws -> WeChatNativeArchive.Transcript {
        .init(path: "聊天记录.txt", body: body, records: try WeChatTranscriptRecord.parse(body, timeZone: timeZone))
    }
}
