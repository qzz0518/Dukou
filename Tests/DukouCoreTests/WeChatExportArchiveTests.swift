import Foundation
import XCTest
import zlib
@testable import DukouCore

final class WeChatExportArchiveTests: XCTestCase {
    private var temporary: TemporaryInbox!
    override func setUp() { temporary = TemporaryInbox() }
    override func tearDown() { temporary.tearDown() }

    func testMergedZIPContainsChronologicalTextAndBothSameNamedAttachments() throws {
        let firstText = "·甲\n2026年9月8日 09:10\n重复\n\n·甲\n2026年9月8日 09:11\nimages/photo.png\n"
        let secondText = "·乙\n2026年9月8日 10:20\n重复\n\n·乙\n2026年9月8日 10:21\nimages/photo.png\n"
        let first = try batch([("聊天记录.txt", Data(firstText.utf8)), ("images/photo.png", Data([1, 2, 3]))])
        let second = try batch([("聊天记录.txt", Data(secondText.utf8)), ("images/photo.png", Data([4, 5, 6]))])
        let originalBytes = try [first, second].map { try Data(contentsOf: $0.items[0].url) }
        let ready = try WeChatExportArchive.merge([first, second], chat: "测试群", fallbackCounts: [99, 99], in: temporary.inbox)
        let merged = try XCTUnwrap(InboxReader(inbox: temporary.inbox).batch(at: ready))
        XCTAssertEqual(merged.items.count, 1)
        let file = merged.items[0]
        XCTAssertTrue(file.displayName.contains("测试群"))
        XCTAssertTrue(file.displayName.contains("20260908"))
        XCTAssertTrue(file.displayName.contains("4条"))
        let extracted = try unzip(file.url)
        let text = try String(contentsOf: extracted.appendingPathComponent("聊天记录.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains(firstText)); XCTAssertTrue(text.contains(secondText))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: firstText)?.lowerBound), try XCTUnwrap(text.range(of: secondText)?.lowerBound))
        XCTAssertEqual(text.components(separatedBy: "重复").count - 1, 2, "Do not deduplicate repeated messages")
        for (index, value) in [Data([1, 2, 3]), Data([4, 5, 6])].enumerated() {
            let path = "batches/000\(index + 1)/images/photo.png"
            XCTAssertTrue(text.contains(path))
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(path)), value)
        }
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("batches/0001/聊天记录.txt"), encoding: .utf8), firstText)
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0.items[0].url) }, originalBytes)
        XCTAssertFalse(text.contains(temporary.root.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.inbox.staging.path), [])
    }

    func testRenamingUsesActualCountAndDatesWithoutChangingZIPBytes() throws {
        let text = "·甲\n2026年9月8日 11:25\n正文\n"
        let original = try batch([("聊天记录.txt", Data(text.utf8))])
        let data = try Data(contentsOf: original.items[0].url)
        try WeChatExportArchive.rename(original, chat: "客户/测试群", fallbackCount: 100)
        let renamed = try XCTUnwrap(InboxReader(inbox: temporary.inbox).batch(at: original.directory))
        XCTAssertTrue(renamed.items[0].displayName.contains("1条"))
        XCTAssertTrue(renamed.items[0].displayName.contains("20260908"))
        XCTAssertFalse(renamed.items[0].displayName.contains("导出"))
        XCTAssertEqual(renamed.items[0].id, original.items[0].id)
        XCTAssertEqual(try Data(contentsOf: renamed.items[0].url), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.items[0].url.path))
    }

    func testUnknownTextAndAttachmentOnlyFormatsStillMergeWithoutBeingDiscarded() throws {
        let future = Data("新版格式\n[未知卡片]\n内容照常保留".utf8)
        let first = try batch([("聊天记录.txt", future), ("contact.vcf", Data("future card".utf8))])
        let second = try batch([("audio.dat", Data([7, 8]))])
        let ready = try WeChatExportArchive.merge([first, second], chat: "测试", fallbackCounts: [4, 2], in: temporary.inbox)
        let item = try XCTUnwrap(InboxReader(inbox: temporary.inbox).batch(at: ready)?.items.first)
        XCTAssertTrue(item.displayName.contains("导出")); XCTAssertTrue(item.displayName.contains("6条"))
        let extracted = try unzip(item.url)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("batches/0001/聊天记录.txt")), future)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("batches/0002/audio.dat")), Data([7, 8]))
        try WeChatExportArchive.rename(first, chat: "测试", fallbackCount: 4)
        let renamed = try XCTUnwrap(InboxReader(inbox: temporary.inbox).batch(at: first.directory)?.items.first)
        XCTAssertTrue(renamed.displayName.contains("导出")); XCTAssertTrue(renamed.displayName.contains("4条"))
    }

    func testUnmergedBatchesWithIdenticalTimesAndCountsKeepDistinctNames() throws {
        let text = Data("·甲\n2026年9月8日 11:25\n正文\n".utf8)
        let first = try batch([("聊天记录.txt", text)])
        let second = try batch([("聊天记录.txt", text)])
        let longChat = String(repeating: "很长的群名", count: 40)
        try WeChatExportArchive.rename(first, chat: longChat, fallbackCount: 1, part: 1)
        try WeChatExportArchive.rename(second, chat: longChat, fallbackCount: 1, part: 2)
        let reader = InboxReader(inbox: temporary.inbox)
        let names = try [first, second].map { try XCTUnwrap(reader.batch(at: $0.directory)?.items.first?.displayName) }
        XCTAssertNotEqual(names[0], names[1])
        XCTAssertTrue(names[0].hasSuffix("_1条_第1批.zip"))
        XCTAssertTrue(names[1].hasSuffix("_1条_第2批.zip"))
        XCTAssertTrue(names.allSatisfy { $0.utf8.count <= 200 })
    }

    func testMergeRejectsTraversalLinksAliasesAndCorruptionWithoutPublishingOrChangingSources() throws {
        let unsafe: [Data] = [
            zip([("../escape.txt", Data([1]), 0o100600)]),
            zip([("/absolute.txt", Data([1]), 0o100600)]),
            zip([("link", Data("../target".utf8), 0o120777)]),
            zip([("Images/a", Data([1]), 0o100600), ("images/b", Data([2]), 0o100600)]),
        ]
        var corrupted = zip([("file.bin", Data([1, 2, 3]), 0o100600)])
        corrupted[38] ^= 0xff
        for data in unsafe + [corrupted] {
            let source = try batch(data: data)
            let countBefore = try FileManager.default.contentsOfDirectory(atPath: temporary.inbox.ready.path).count
            XCTAssertThrowsError(try WeChatExportArchive.merge([source], chat: "测试", fallbackCounts: [1], in: temporary.inbox))
            XCTAssertEqual(try Data(contentsOf: source.items[0].url), data)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.inbox.ready.path).count, countBefore)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.inbox.staging.path), [])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.root.appendingPathComponent("escape.txt").path))
    }

    func testCancellationDuringExtractionLeavesNativeSourcesAndNoPartialOutput() throws {
        let source = try batch([("large.bin", Data(repeating: 0x35, count: 2_000_000))])
        var checks = 0
        XCTAssertThrowsError(try WeChatExportArchive.merge([source], chat: "测试", fallbackCounts: [1], in: temporary.inbox) {
            checks += 1
            if checks == 15 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.inbox.ready.path), [source.id.uuidString])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.inbox.staging.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.items[0].url.path))
    }

    private func batch(_ files: [(String, Data)]) throws -> ReadyBatch {
        try batch(data: zip(files.map { ($0.0, $0.1, 0o100600) }))
    }
    private func batch(data: Data) throws -> ReadyBatch {
        let stage = try BatchStaging.create(in: temporary.inbox)
        let id = UUID(), name = "聊天记录.zip"
        try data.write(to: stage.destination(for: id, displayName: name))
        let item = ManifestItem(id: id, displayName: name, relativePath: stage.relativePath(for: id, displayName: name),
                                contentType: "public.zip-archive", byteCount: Int64(data.count), itemIndex: 0, attachmentIndex: 0, loadStrategy: .fileURL)
        let ready = try stage.commit(manifest: BatchManifest(batchID: stage.batchID, createdAt: Date(), items: [item]), diagnostics: nil, intent: nil, in: temporary.inbox)
        return try XCTUnwrap(InboxReader(inbox: temporary.inbox).batch(at: ready))
    }
    private func unzip(_ file: URL) throws -> URL {
        let destination = temporary.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", file.path, "-C", destination.path]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return destination
    }
    /// Minimal stored ZIP fixtures, built independently of the production tar
    /// writer; the modes exercise the extraction boundary as well as CRC data.
    private func zip(_ entries: [(String, Data, UInt32)]) -> Data {
        var data = Data(), central = Data()
        func put(_ value: UInt32, _ bytes: Int, into output: inout Data) {
            for index in 0..<bytes { output.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        for (name, content, mode) in entries {
            let path = Data(name.utf8), offset = data.count
            let crc = content.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            put(0x04034b50, 4, into: &data)
            for value: UInt32 in [20, 0x800, 0, 0, 0] { put(value, 2, into: &data) }
            for value in [crc, UInt32(content.count), UInt32(content.count)] { put(value, 4, into: &data) }
            put(UInt32(path.count), 2, into: &data); put(0, 2, into: &data)
            data.append(path); data.append(content)
            put(0x02014b50, 4, into: &central)
            for value: UInt32 in [0x0314, 20, 0x800, 0, 0, 0] { put(value, 2, into: &central) }
            for value in [crc, UInt32(content.count), UInt32(content.count)] { put(value, 4, into: &central) }
            for value in [UInt32(path.count), 0, 0, 0, 0] { put(value, 2, into: &central) }
            put(mode << 16, 4, into: &central); put(UInt32(offset), 4, into: &central); central.append(path)
        }
        let start = data.count
        data.append(central)
        put(0x06054b50, 4, into: &data)
        for value in [UInt32(0), 0, UInt32(entries.count), UInt32(entries.count)] { put(value, 2, into: &data) }
        put(UInt32(central.count), 4, into: &data); put(UInt32(start), 4, into: &data); put(0, 2, into: &data)
        return data
    }
}
