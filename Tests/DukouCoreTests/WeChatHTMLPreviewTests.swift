import Foundation
import XCTest
@testable import DukouCore

final class WeChatHTMLPreviewTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    func testCurrentAccountNicknameUsesAnExactMatchIncludingSpacesAndSpecialCharacters() throws {
        let nickname = "  小林 <&> \"'  "
        let source = try transcript("·另一位\n2026年9月8日 09:00\n第一条\n\n·\(nickname)\n2026年9月8日 09:01\n自己的消息\n")
        let result = try render([
            .init(transcript: source, prefix: "batches/0001", paths: [source.path]),
        ], selfSender: nickname)
        XCTAssertEqual(result.document.defaultSelfSender, nickname)
        XCTAssertEqual(result.document.messages.map(\.sender), ["另一位", nickname])
        XCTAssertFalse(result.json.contains("<&>"))

        let unmatched = try render([
            .init(transcript: source, prefix: "batches/0001", paths: [source.path]),
        ], selfSender: nickname.trimmingCharacters(in: .whitespaces))
        XCTAssertNil(unmatched.document.defaultSelfSender, "Display names must not be normalized into another sender")
    }

    func testUnknownAccountDoesNotInferTheRightSideFromTheChatOrOnlySender() throws {
        let source = try transcript("·Only Sender\n2026年9月8日 09:00\n消息\n")
        for candidate: String? in [nil, "", "different account", "only sender", "Only Sender "] {
            let result = try render([
                .init(transcript: source, prefix: "batches/0001", paths: [source.path]),
            ], chat: "Only Sender", selfSender: candidate)
            XCTAssertNil(result.document.defaultSelfSender)
        }
        let unknown = WeChatNativeArchive.Transcript(path: "聊天记录.txt", body: "Only Sender", records: nil)
        let result = try render([
            .init(transcript: unknown, prefix: "batches/0001", paths: [unknown.path]),
        ], selfSender: "Only Sender")
        XCTAssertNil(result.document.defaultSelfSender)
    }

    func testTimelineSortsAcrossBatchesAndPreservesSameMinuteOrderAndDuplicates() throws {
        let first = try transcript("""
        ·最后
        2026年9月9日 12:20
        晚

        ·甲
        2026年9月8日 09:00
        重复

        ·甲
        2026年9月8日 09:00
        重复

        """)
        let second = try transcript("""
        ·最早
        2026年9月7日 10:00
        最早

        ·乙
        2026年9月8日 09:00
        同一分钟

        ·甲
        2026年9月8日 09:00
        重复

        """)
        let result = try render([
            .init(transcript: first, prefix: "batches/0001", paths: [first.path]),
            .init(transcript: second, prefix: "batches/0002", paths: [second.path]),
        ])
        XCTAssertEqual(result.document.messages.map(\.sender), ["最早", "甲", "甲", "乙", "甲", "最后"])
        XCTAssertEqual(result.document.messages.map { $0.parts.compactMap(\.text).joined(separator: "\n") },
                       ["最早", "重复", "重复", "同一分钟", "重复", "晚"])
        XCTAssertEqual(result.document.messages.map(\.day), ["2026-09-07", "2026-09-08", "2026-09-08", "2026-09-08", "2026-09-08", "2026-09-09"])
        XCTAssertEqual(result.document.messages.map(\.time), ["10:00", "09:00", "09:00", "09:00", "09:00", "12:20"])
        XCTAssertTrue(result.document.supplements.isEmpty)
        XCTAssertEqual(result.document.unparsedBatches, 0)
    }

    func testNativeImageBasenamesResolveWithinTheirBatchAndEncodeEveryPathSegment() throws {
        let name = "图片 空格#?%&.PNG"
        let path = "聊天记录内的图片、视频和文件/" + name
        let first = try transcript("·甲\n2026年9月8日 09:00\n前文\n[图片] \(name)\n后文\n")
        let second = try transcript("·乙\n2026年9月8日 09:01\n[图片]\(name)\n")
        let result = try render([
            .init(transcript: first, prefix: "batches/0001", paths: [first.path, path]),
            .init(transcript: second, prefix: "batches/0002", paths: [second.path, path]),
        ])
        let encodedPath = "%E8%81%8A%E5%A4%A9%E8%AE%B0%E5%BD%95%E5%86%85%E7%9A%84%E5%9B%BE%E7%89%87%E3%80%81%E8%A7%86%E9%A2%91%E5%92%8C%E6%96%87%E4%BB%B6/"
            + "%E5%9B%BE%E7%89%87%20%E7%A9%BA%E6%A0%BC%23%3F%25%26.PNG"
        let files = result.document.messages.flatMap(\.parts).compactMap(\.file)
        XCTAssertEqual(files.map(\.name), [name, name])
        XCTAssertEqual(files.map(\.kind), ["image", "image"])
        XCTAssertEqual(files.map(\.href), ["batches/0001/" + encodedPath, "batches/0002/" + encodedPath])
        XCTAssertEqual(result.document.messages[0].parts.map(\.text), ["前文", nil, "后文"])
        for file in files {
            let url = try XCTUnwrap(URLComponents(string: file.href))
            XCTAssertNil(url.scheme)
            XCTAssertNil(url.host)
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
        }
        XCTAssertTrue(result.document.supplements.isEmpty)
    }

    func testAmbiguousBasenameStaysTextWhileAnExplicitRelativePathCanResolve() throws {
        let source = try transcript("""
        ·甲
        2026年9月8日 09:00
        [图片] photo.png

        ·乙
        2026年9月8日 09:01
        [图片] ./first/photo.png

        """)
        let result = try render([
            .init(transcript: source, prefix: "batches/0001", paths: [source.path, "first/photo.png", "second/photo.png"]),
        ])
        XCTAssertEqual(result.document.messages[0].parts, [Part(text: "[图片] photo.png", file: nil)])
        XCTAssertEqual(result.document.messages[1].parts.compactMap(\.file).map(\.href), ["batches/0001/first/photo.png"])
        XCTAssertEqual(result.document.supplements.flatMap(\.files).map(\.href), ["batches/0001/second/photo.png"])
    }

    func testUnknownTranscriptsAndUnreferencedAttachmentsRemainInSupplements() throws {
        let unknownBody = "新版格式\n[未知卡片]\n原文 <tag> & 内容照常保留"
        let unknown = WeChatNativeArchive.Transcript(path: "聊天记录.txt", body: unknownBody, records: nil)
        let recognized = try transcript("·甲\n2026年9月8日 09:00\n[图片] used.png\n")
        let result = try render([
            .init(transcript: unknown, prefix: "batches/0001", paths: [unknown.path, "contact.vcf"]),
            .init(transcript: recognized, prefix: "batches/0002", paths: [recognized.path, "images/used.png", "readme.md", "clip.MOV", "sound.M4A"]),
            .init(transcript: nil, prefix: "batches/0003", paths: ["mystery.dat"]),
        ])
        XCTAssertEqual(result.document.messages.count, 1)
        XCTAssertEqual(result.document.messages[0].parts.compactMap(\.file).map(\.href), ["batches/0002/images/used.png"])
        XCTAssertEqual(result.document.supplements.count, 3)
        XCTAssertEqual(result.document.unparsedBatches, 2)
        XCTAssertEqual(result.document.supplements[0].text, unknownBody)
        XCTAssertEqual(result.document.supplements[0].files.map(\.href), ["batches/0001/contact.vcf"])
        XCTAssertNil(result.document.supplements[1].text)
        XCTAssertEqual(result.document.supplements[1].files.map(\.name), ["readme.md", "clip.MOV", "sound.M4A"])
        XCTAssertEqual(result.document.supplements[1].files.map(\.kind), ["file", "video", "audio"])
        XCTAssertNil(result.document.supplements[2].text)
        XCTAssertEqual(result.document.supplements[2].files.map(\.href), ["batches/0003/mystery.dat"])
    }

    func testUntrustedChatSenderTextAndFilenameCannotTerminateTheJSONDataBlock() throws {
        let chat = "测试 </script><script>alert(\"chat\")</script><img src=x onerror='boom'> & \" '"
        let sender = "昵称 </ScRiPt><svg/onload='boom'> & \""
        let message = "</script><script>alert('text')</script>\n<img src=\"https://example.invalid/x\" onerror='boom'> & 中\u{2028}间\u{2029}段 \" '"
        let filename = "bad <img onerror=\"x\"> &.png"
        let source = try transcript("·\(sender)\n2026年9月8日 09:00\n\(message)\n[图片] \(filename)\n")
        let result = try render([
            .init(transcript: source, prefix: "batches/0001", paths: [source.path, "media/" + filename]),
        ], chat: chat)
        XCTAssertEqual(result.document.chat, chat)
        XCTAssertEqual(result.document.messages[0].sender, sender)
        XCTAssertEqual(result.document.messages[0].parts.compactMap(\.text), [message])
        XCTAssertEqual(result.document.messages[0].parts.compactMap(\.file).map(\.name), [filename])
        for raw in ["<", ">", "&", "\u{2028}", "\u{2029}"] { XCTAssertFalse(result.json.contains(raw)) }
        XCTAssertTrue(result.html.contains("<title>测试 &lt;/script&gt;&lt;script&gt;alert(&quot;chat&quot;)"))
        XCTAssertFalse(result.html.contains("<img src=x"))
        XCTAssertFalse(result.html.contains("<svg/onload="))
        XCTAssertFalse(result.html.contains("<script>alert("))
        XCTAssertEqual(result.html.components(separatedBy: "</script>").count - 1, 2)
    }

    func testUnsafePathsRemainTextAndNeverBecomeAttachmentLinks() throws {
        let paths = [
            "../escape.png", "nested/../../escape.png", "/absolute.png", "//example.invalid/file.png",
            "https://example.invalid/file.png", "file:///etc/passwd", "javascript:alert(1)",
            "C:\\image.png", "nested\\image.png", "dot/./file.png", "double//file.png", "trailing/",
            "bad\u{0}name.png", "line\nname.png", "tab\tname.png",
        ]
        let text = paths.joined(separator: "\n") + "\n结束"
        let source = try transcript("·甲\n2026年9月8日 09:00\n\(text)\n")
        let result = try render([
            .init(transcript: source, prefix: "batches/0001", paths: [source.path] + paths + ["safe.png"]),
        ])
        XCTAssertEqual(result.document.messages[0].parts, [Part(text: text, file: nil)])
        XCTAssertEqual(result.document.supplements.flatMap(\.files).map(\.href), ["batches/0001/safe.png"])
    }

    func testUnsafeBatchPrefixesCannotCreateLinksEvenWithASafeFilename() throws {
        let source = try transcript("·甲\n2026年9月8日 09:00\n[图片] safe.png\n")
        for prefix in ["..", "/tmp", "batches/../other", "https://example.invalid", "batches\\0001", "batches//0001"] {
            let result = try render([.init(transcript: source, prefix: prefix, paths: [source.path, "safe.png"])])
            XCTAssertEqual(result.document.messages[0].parts, [Part(text: "[图片] safe.png", file: nil)])
            XCTAssertTrue(result.document.supplements.flatMap(\.files).isEmpty)
        }
    }

    func testEmptyMessageIsPreservedAsText() throws {
        let source = try transcript("·甲\n2026年9月8日 09:00\n")
        let result = try render([.init(transcript: source, prefix: "batches/0001", paths: [source.path])])
        XCTAssertEqual(result.document.messages.count, 1)
        XCTAssertEqual(result.document.messages[0].parts, [Part(text: "", file: nil)])
    }

    func testCancellationIsObservedBeforeAndDuringRendering() throws {
        XCTAssertThrowsError(try WeChatHTMLPreview.render(chat: "测试", batches: [], timeZone: timeZone) {
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        let body = (0..<40).map { "·甲\n2026年9月8日 09:00\n第 \($0) 条\n" }.joined(separator: "\n")
        let source = try transcript(body)
        var checks = 0
        XCTAssertThrowsError(try WeChatHTMLPreview.render(chat: "测试", batches: [
            .init(transcript: source, prefix: "batches/0001", paths: [source.path]),
        ], timeZone: timeZone) {
            checks += 1
            if checks == 8 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 8)
    }

    private func transcript(_ body: String) throws -> WeChatNativeArchive.Transcript {
        .init(path: "聊天记录.txt", body: body, records: try WeChatTranscriptRecord.parse(body, timeZone: timeZone))
    }

    private func render(_ batches: [WeChatHTMLPreview.Batch], chat: String = "测试群", selfSender: String? = nil) throws -> (html: String, json: String, document: Document) {
        let html = try WeChatHTMLPreview.render(chat: chat, batches: batches, selfSender: selfSender, timeZone: timeZone)
        let pattern = try NSRegularExpression(pattern: #"<script\b[^>]*\bid=["']chat-data["'][^>]*>([\s\S]*?)</script>"#)
        let match = try XCTUnwrap(pattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
        let json = String(html[range])
        return (html, json, try JSONDecoder().decode(Document.self, from: Data(json.utf8)))
    }

    private struct Document: Decodable {
        let chat: String
        let messages: [Message]
        let supplements: [Supplement]
        let defaultSelfSender: String?
        let unparsedBatches: Int
    }

    private struct Message: Decodable {
        let sender: String
        let day: String
        let time: String
        let parts: [Part]
    }

    private struct Part: Decodable, Equatable {
        let text: String?
        let file: Attachment?
    }

    private struct Attachment: Decodable, Equatable {
        let name: String
        let href: String
        let kind: String
    }

    private struct Supplement: Decodable {
        let text: String?
        let files: [Attachment]
    }
}
