import AppKit
import Darwin
import DukouCore
import Foundation
import XCTest

final class MomentsArchiveTests: XCTestCase {
    private var temporary: TemporaryInbox!
    private let manager = FileManager.default
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+y5p8AAAAASUVORK5CYII=")!
    private let utc = TimeZone(secondsFromGMT: 0)!
    private var namingDate: Date { ISO8601DateFormatter().date(from: "2026-09-08T22:00:00Z")! }
    private enum Stop: Error { case cancelled }

    override func setUp() {
        super.setUp()
        temporary = TemporaryInbox()
    }

    override func tearDown() {
        temporary.tearDown()
        super.tearDown()
    }

    private var media: URL { temporary.root.appendingPathComponent("moments-media", isDirectory: true) }

    func testUnzippedArchiveContainsChronologicalTextAndExactlyTheReferencedMedia() throws {
        let photo = "照片 [1] 🐈.png"
        let video = "-视频 $(echo test).mov"
        let videoBytes = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0, 0, 0xff])
        try makeMedia(photo, data: png)
        try makeMedia(video, data: videoBytes)
        try makeMedia("未选择.png", data: png)
        try makeMedia(".DS_Store", data: Data("private metadata".utf8))
        try manager.createSymbolicLink(at: media.appendingPathComponent("未引用链接"), withDestinationURL: temporary.root)
        let records = [
            MomentsRecord(author: "最新作者", timestamp: "5 分钟前", text: "最新正文\n第二行 🌅", attachments: [video], notes: ["链接卡片无法保存", "另有 2 张图片未选择"]),
            MomentsRecord(author: "中间作者", timestamp: "昨天", text: "", notes: ["视频无法保存"]),
            MomentsRecord(author: "../../姓名/绝不能成为路径", timestamp: "9月1日", text: "最早正文", attachments: [photo, photo, video]),
        ]

        let ready = try create(records)
        let archive = try archiveURL(in: ready)
        let (extracted, entries) = try extract(archive)
        let expectedFiles: Set<String> = ["朋友圈.txt", "media/\(photo)", "media/\(video)"]
        XCTAssertEqual(Set(entries.filter { !$0.hasSuffix("/") }), expectedFiles)
        XCTAssertEqual(entries.count, Set(entries).count, "ZIP entries must not be duplicated")
        XCTAssertTrue(entries.filter { $0.hasSuffix("/") }.allSatisfy { $0 == "media/" })
        XCTAssertTrue(entries.allSatisfy { !$0.hasPrefix("/") && !$0.contains("../") && !$0.contains("__MACOSX") })
        let text = try String(contentsOf: extracted.appendingPathComponent("朋友圈.txt"), encoding: .utf8)
        let expected = """
        [1]
        作者：../../姓名/绝不能成为路径
        原始时间：9月1日
        正文：
        最早正文
        媒体：
        media/\(photo)
        media/\(photo)
        media/\(video)
        说明：
        无

        [2]
        作者：中间作者
        原始时间：昨天
        正文：

        媒体：
        无
        说明：
        视频无法保存

        [3]
        作者：最新作者
        原始时间：5 分钟前
        正文：
        最新正文
        第二行 🌅
        媒体：
        media/\(video)
        说明：
        链接卡片无法保存
        另有 2 张图片未选择
        """ + "\n\n"
        let bodyStart = try XCTUnwrap(text.range(of: "\n\n")).upperBound
        XCTAssertEqual(String(text[bodyStart...]), expected)
        let references = Set(text.components(separatedBy: "\n").filter { $0.hasPrefix("media/") })
        XCTAssertEqual(references, expectedFiles.subtracting(["朋友圈.txt"]))
        XCTAssertFalse(text.contains(temporary.root.path))
        XCTAssertFalse(text.contains("file://"))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("media/\(photo)")), png)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("media/\(video)")), videoBytes)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: ready.path).sorted(), ["items", "manifest.json"])
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: temporary.inbox.staging.path), [])
        XCTAssertTrue(manager.fileExists(atPath: media.appendingPathComponent("未选择.png").path))
    }

    func testTranscriptStartsWithZonedGenerationTimeAndPreservesWeChatTimeLabels() throws {
        let records = ["3小时前", "昨天", "9月1日"].map {
            MomentsRecord(author: "作者", timestamp: $0, text: "正文")
        }
        let startedAt = Date()
        let ready = try create(records)
        let finishedAt = Date()
        let manifest = try readManifest(in: ready)
        let (extracted, _) = try extract(archiveURL(in: ready))
        let text = try String(contentsOf: extracted.appendingPathComponent("朋友圈.txt"), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let firstLine = try XCTUnwrap(lines.first)
        XCTAssertTrue(firstLine.hasPrefix("生成时间："))
        let timestamp = String(firstLine.dropFirst("生成时间：".count))
        XCTAssertNotNil(timestamp.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression
        ), "the first line must include an absolute date and explicit time zone")
        let generatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
        // The exported timestamp has second precision; both representations
        // must identify the same generation instant, before media compression.
        XCTAssertGreaterThanOrEqual(generatedAt.timeIntervalSince1970, floor(startedAt.timeIntervalSince1970))
        XCTAssertLessThanOrEqual(generatedAt, finishedAt)
        XCTAssertEqual(generatedAt, manifest.createdAt)
        XCTAssertEqual(Array(lines.dropFirst().prefix(3)), [
            "时间说明：记录的原始时间按微信显示保留，未推算为绝对时间。", "", "[1]",
        ])
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("原始时间：") },
            records.reversed().map { "原始时间：\($0.timestamp)" }
        )
    }

    func testSingleTextOnlyRecordAndExistingShelfHistoryAndPastePipeline() throws {
        var record = MomentsRecord(author: "作者", timestamp: "刚刚", text: "只有文字")
        XCTAssertEqual(record.attachments, [])
        XCTAssertEqual(record.notes, [])
        record.attachments = []
        record.notes.append("图片未选择")
        // No media references means no need to open even a missing directory.
        let ready = try create([record])
        let manifest = try readManifest(in: ready)
        XCTAssertEqual(manifest.action, .shelf)
        XCTAssertEqual(manifest.schemaVersion, BatchManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.items.count, 1)
        let item = try XCTUnwrap(manifest.items.first)
        let expectedName = MomentsArchive.displayName(for: [record], exportedAt: manifest.createdAt)
        XCTAssertEqual(item.displayName, expectedName)
        XCTAssertTrue(item.displayName.hasPrefix("作者的朋友圈_导出"))
        XCTAssertTrue(item.displayName.hasSuffix("_1条.zip"))
        XCTAssertEqual(item.contentType, "public.zip-archive")
        XCTAssertEqual(item.itemIndex, 0)
        XCTAssertEqual(item.attachmentIndex, 0)
        XCTAssertEqual(item.loadStrategy, .fileURL)
        XCTAssertEqual(item.relativePath, "items/\(item.id.uuidString)/\(expectedName)")
        XCTAssertEqual(manifest.batchID.uuidString, ready.lastPathComponent)
        let archive = ready.appendingPathComponent(item.relativePath)
        XCTAssertEqual(item.byteCount, Int64(try Data(contentsOf: archive).count))
        let (extracted, entries) = try extract(archive)
        XCTAssertEqual(entries, ["朋友圈.txt"])
        XCTAssertTrue(try String(contentsOf: extracted.appendingPathComponent("朋友圈.txt"), encoding: .utf8).contains("图片未选择"))

        let reader = temporary.reader
        let batch = try XCTUnwrap(reader.loadBatches().first)
        XCTAssertEqual(batch.shelvedCount, 1)
        XCTAssertEqual(batch.action, .shelf)
        XCTAssertEqual(batch.outcome?.kind, .shelved)
        let loadedArchive = try XCTUnwrap(batch.items.first?.url)
        XCTAssertEqual(loadedArchive.resolvingSymlinksInPath(), archive.resolvingSymlinksInPath())
        let plan = PastePlan.make(urls: batch.items.map(\.url), pathOnly: false, prompt: nil)
        XCTAssertEqual(plan, [.files([loadedArchive])])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(FilePasteboard.write(try XCTUnwrap(plan.first), to: pasteboard))
        let pasted = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        XCTAssertEqual(pasted, [loadedArchive])
        try reader.markConsumed(itemIDs: [item.id], in: batch.id)
        XCTAssertEqual(reader.loadBatches().first?.shelvedCount, 0)
        XCTAssertEqual(reader.loadBatches().first?.items.first?.url, loadedArchive, "history retains the ZIP")
        XCTAssertTrue(manager.fileExists(atPath: archive.path))
        try reader.restore(batchID: batch.id)
        XCTAssertEqual(reader.loadBatches().first?.shelvedCount, 1)
    }

    func testSingleAuthorNameUsesCompleteAbsoluteRangeWithoutSortingTheTranscript() throws {
        let records = [
            MomentsRecord(author: "小明", timestamp: "2026年9月8日 21:30", text: "第一条"),
            MomentsRecord(author: "小明", timestamp: "2026年9月8日 09:10", text: "第二条"),
            MomentsRecord(author: "小明", timestamp: "2026-09-08 15:20:30", text: "第三条"),
        ]
        let ready = try MomentsArchive.create(
            records: records, mediaDirectory: media, in: temporary.inbox,
            exportedAt: namingDate, timeZone: utc
        )
        let item = try XCTUnwrap(readManifest(in: ready).items.first)
        let name = "小明的朋友圈_20260908-0910至20260908-2130_3条.zip"
        XCTAssertEqual(item.displayName, name)
        XCTAssertEqual(item.relativePath, "items/\(item.id.uuidString)/\(name)")
        let archive = ready.appendingPathComponent(item.relativePath)
        XCTAssertEqual(archive.lastPathComponent, item.displayName)
        let (extracted, entries) = try extract(archive)
        XCTAssertEqual(entries, ["朋友圈.txt"])
        let text = try String(contentsOf: extracted.appendingPathComponent("朋友圈.txt"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("生成时间：2026-09-08T22:00:00Z\n"))
        XCTAssertEqual(
            text.components(separatedBy: "\n").filter { $0.hasPrefix("原始时间：") },
            records.reversed().map { "原始时间：\($0.timestamp)" },
            "naming must not reorder records or rewrite their labels"
        )
    }

    func testMultipleAuthorsUseGenericFeedNameAndChronologicalDateEndpoints() {
        let records = [
            MomentsRecord(author: "乙", timestamp: "2026年9月8日 21:30", text: "正文"),
            MomentsRecord(author: "甲", timestamp: "2026年9月7日 09:10", text: "正文"),
        ]
        let name = "朋友圈_20260907-0910至20260908-2130_2条.zip"
        XCTAssertEqual(displayName(records), name)
        XCTAssertEqual(displayName(Array(records.reversed())), name)
    }

    func testRelativeIncompleteOrInvalidLabelsMakeTheWholeRangeUseExportTime() {
        let uncertain = [
            "刚刚", "5 分钟前", "昨天 12:30", "Yesterday 12:30", "9月8日 12:30",
            "2026年9月8日", "2026-09-08", "2026年9月8日 9", "2026年9月8日 9:1",
            "2026年2月30日 12:30", "2025年2月29日 12:30", "2026年13月8日 12:30",
            "2026年9月8日 24:00", "2026年9月8日 12:60", "2026年9月8日 12:30:60",
            "0000年9月8日 12:30", "2026年9月8日 12:30 来自手机", "", "09/08/2026 12:30",
        ]
        for label in uncertain {
            let records = [
                MomentsRecord(author: "作者", timestamp: "2026年9月8日 21:30", text: "完整日期"),
                MomentsRecord(author: "作者", timestamp: label, text: "不确定日期"),
            ]
            XCTAssertEqual(displayName(records), "作者的朋友圈_导出20260908-220000_2条.zip", label)
        }
    }

    func testAbsoluteLabelsUseSuppliedTimeZoneAndAcceptRealLeapDays() {
        let record = MomentsRecord(author: "作者", timestamp: "2024年2月29日 9:10:30", text: "正文")
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        XCTAssertEqual(
            MomentsArchive.displayName(for: [record], exportedAt: namingDate, timeZone: zone),
            "作者的朋友圈_20240229-0910_1条.zip"
        )
        XCTAssertEqual(
            MomentsArchive.displayName(for: [self.record()], exportedAt: namingDate, timeZone: zone),
            "作者的朋友圈_导出20260909-060000_1条.zip"
        )
    }

    func testNonexistentLocalTimeFallsBackInsteadOfMovingTheClockForward() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let record = MomentsRecord(author: "作者", timestamp: "2026年3月8日 02:30", text: "正文")
        XCTAssertEqual(
            MomentsArchive.displayName(for: [record], exportedAt: namingDate, timeZone: zone),
            "作者的朋友圈_导出20260908-150000_1条.zip"
        )
    }

    func testEmptyAuthorUsesGenericFeedName() {
        let records = [MomentsRecord(author: " \n", timestamp: "昨天", text: "正文")]
        XCTAssertEqual(displayName(records), "朋友圈_导出20260908-220000_1条.zip")
    }

    func testRepeatedLocalTimeFallsBackInsteadOfChoosingAnOffset() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let record = MomentsRecord(author: "作者", timestamp: "2026年11月1日 01:30", text: "正文")
        XCTAssertEqual(
            MomentsArchive.displayName(for: [record], exportedAt: namingDate, timeZone: zone),
            "作者的朋友圈_导出20260908-150000_1条.zip"
        )
    }

    func testMaliciousLongAuthorIsSanitizedOnlyInZIPNameAndMatchesManifest() throws {
        let author = "../../" + String(repeating: "作者🌅", count: 100) + "\u{202E}\"."
        let records = [MomentsRecord(author: author, timestamp: "昨天 12:30", text: "正文", attachments: ["photo.png"])]
        try makeMedia("photo.png", data: png)
        let expectedName = displayName(records)
        let ready = try MomentsArchive.create(
            records: records, mediaDirectory: media, in: temporary.inbox,
            exportedAt: namingDate, timeZone: utc
        )
        let manifest = try readManifest(in: ready)
        let item = try XCTUnwrap(manifest.items.first)
        XCTAssertEqual(item.displayName, expectedName)
        XCTAssertLessThanOrEqual(item.displayName.utf8.count, 200)
        XCTAssertTrue(item.displayName.hasSuffix("_导出20260908-220000_1条.zip"))
        let archive = ready.appendingPathComponent(item.relativePath)
        XCTAssertEqual(archive.lastPathComponent, item.displayName)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path), [expectedName])
        XCTAssertEqual(item.byteCount, Int64(try Data(contentsOf: archive).count))
        let (extracted, entries) = try extract(archive)
        XCTAssertEqual(Set(entries.filter { !$0.hasSuffix("/") }), ["朋友圈.txt", "media/photo.png"])
        let text = try String(contentsOf: extracted.appendingPathComponent("朋友圈.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("作者：\(author)\n原始时间：昨天 12:30\n"))
        XCTAssertTrue(text.contains("media/photo.png\n"))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("media/photo.png")), png)
    }

    func testAcceptsMoreThan100RecordsWithoutParsingTheirTimeLabels() throws {
        let records = (0..<1_000).map { MomentsRecord(author: "作者\($0)", timestamp: "今天", text: "正文\($0)") }
        let ready = try create(records)
        let (extracted, _) = try extract(archiveURL(in: ready))
        let text = try String(contentsOf: extracted.appendingPathComponent("朋友圈.txt"), encoding: .utf8)
        let authors = text.components(separatedBy: "\n").filter { $0.hasPrefix("作者：") }
        XCTAssertEqual(authors, records.reversed().map { "作者：\($0.author)" })
        XCTAssertTrue(text.contains("[1000]\n作者：作者0\n"))
    }

    func testRejectsEmptyInputWithoutPublishing() throws {
        XCTAssertThrowsError(try create([])) {
            XCTAssertEqual($0 as? MomentsArchive.Failure, .invalidRecordCount)
        }
        try assertClean()
    }

    func testRejectsDangerousFileNamesInsteadOfSanitizingOrResolvingThem() throws {
        let dangerous = [
            "", ".", "..", "../outside.png", "a/../../outside.png", "/tmp/outside.png",
            "nested/photo.png", "..\\outside.png", "C:\\photo.png", "file:///tmp/photo.png",
            "photo:stream", "photo\0.png", "photo\n.png", "photo\r.png", "photo\t.png",
            "photo\u{2028}.png", "photo\u{202E}.png", "%2e%2e%2fphoto.png", ".hidden.png",
            " photo.png", "photo.png ", "photo.png.", "*.png", "?.png", "NUL.png", "COM1.png",
            String(repeating: "图", count: 100) + ".png",
        ]
        for name in dangerous {
            XCTAssertThrowsError(try create([record(attachments: [name])]), "unexpectedly accepted \(name.debugDescription)") {
                XCTAssertEqual($0 as? MomentsArchive.Failure, .unsafeMedia)
            }
            try assertClean()
        }
    }

    func testRejectsCaseAndUnicodeAliasesThatCouldBreakReferences() throws {
        for names in [["Photo.png", "photo.png"], ["é.png", "e\u{301}.png"]] {
            XCTAssertThrowsError(try create([record(attachments: names)])) {
                XCTAssertEqual($0 as? MomentsArchive.Failure, .unsafeMedia)
            }
            try assertClean()
        }
    }

    func testMissingReferencedMediaCleansAlreadyCopiedFiles() throws {
        try makeMedia("exists.png", data: png)
        XCTAssertThrowsError(try create([record(attachments: ["exists.png", "missing.png"])])) {
            XCTAssertEqual($0 as? MomentsArchive.Failure, .mediaUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: media.appendingPathComponent("exists.png")), png)
        try assertClean()
    }

    func testRejectsSymlinksHardLinksDirectoriesAndFIFOs() throws {
        let outside = temporary.root.appendingPathComponent("private.png")
        try png.write(to: outside)
        try manager.createDirectory(at: media, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: media.appendingPathComponent("symlink.png"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: media.appendingPathComponent("dangling.png"), withDestinationURL: temporary.root.appendingPathComponent("absent"))
        try manager.linkItem(at: outside, to: media.appendingPathComponent("hardlink.png"))
        try manager.createDirectory(at: media.appendingPathComponent("directory.png"), withIntermediateDirectories: false)
        XCTAssertEqual(Darwin.mkfifo(media.appendingPathComponent("fifo.png").path, 0o600), 0)
        for name in ["symlink.png", "dangling.png", "hardlink.png", "directory.png", "fifo.png"] {
            XCTAssertThrowsError(try create([record(attachments: [name])])) {
                XCTAssertEqual($0 as? MomentsArchive.Failure, .unsafeMedia)
            }
            try assertClean()
        }
        XCTAssertEqual(try Data(contentsOf: outside), png)
    }

    func testRejectsSymlinkMediaDirectoryAndNonFileURL() throws {
        try makeMedia("photo.png", data: png)
        let link = temporary.root.appendingPathComponent("directory-link", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: media)
        for directory in [link, URL(string: "https://example.invalid/media")!] {
            XCTAssertThrowsError(try MomentsArchive.create(records: [record(attachments: ["photo.png"])], mediaDirectory: directory, in: temporary.inbox)) {
                XCTAssertEqual($0 as? MomentsArchive.Failure, .unsafeMedia)
            }
            try assertClean()
        }
    }

    func testRejectsSymlinkInMediaDirectoryAncestry() throws {
        try makeMedia("photo.png", data: png)
        let link = temporary.root.appendingPathComponent("ancestor-link", isDirectory: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: temporary.root)
        let directory = link.appendingPathComponent("moments-media", isDirectory: true)
        XCTAssertThrowsError(try MomentsArchive.create(records: [record(attachments: ["photo.png"])], mediaDirectory: directory, in: temporary.inbox)) {
            XCTAssertEqual($0 as? MomentsArchive.Failure, .unsafeMedia)
        }
        try assertClean()
    }

    func testSourcePermissionsContentsAndModificationTimeRemainUnchanged() throws {
        let source = try makeMedia("photo.png", data: png)
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: media.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: media.path) }
        let before = try manager.attributesOfItem(atPath: source.path)
        let ready = try create([record(attachments: ["photo.png"])])
        let (extracted, _) = try extract(archiveURL(in: ready))
        let after = try manager.attributesOfItem(atPath: source.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.posixPermissions] as? NSNumber, after[.posixPermissions] as? NSNumber)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: media.path), ["photo.png"])
        XCTAssertEqual(try Data(contentsOf: source), png)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("media/photo.png")), png)
    }

    func testSymlinkSwapBeforeOpeningMediaIsRejected() throws {
        let source = try makeMedia("photo.png", data: png)
        let outside = temporary.root.appendingPathComponent("private.png")
        try Data("private".utf8).write(to: outside)
        var swapped = false
        XCTAssertThrowsError(try create([record(attachments: ["photo.png"])]) {
            if !swapped, try self.stagedPaths().contains(where: { $0.lastPathComponent == "media" }) {
                swapped = true
                try self.manager.removeItem(at: source)
                try self.manager.createSymbolicLink(at: source, withDestinationURL: outside)
            }
        }) { XCTAssertEqual($0 as? MomentsArchive.Failure, .unsafeMedia) }
        XCTAssertTrue(swapped)
        try assertClean()
    }

    func testTruncatedSourceFailsWithoutPublishing() throws {
        let source = try makeMedia("large.png", data: Data(repeating: 0x41, count: 1_048_576))
        var truncated = false
        XCTAssertThrowsError(try create([record(attachments: ["large.png"])]) {
            if !truncated, try self.hasStagedFile(extension: "png", minimumBytes: 1) {
                truncated = true
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 1)
            }
        }) { XCTAssertEqual($0 as? MomentsArchive.Failure, .mediaUnavailable) }
        XCTAssertTrue(truncated)
        try assertClean()
    }

    func testCancellationBeforeWorkDoesNotCreateAnything() throws {
        XCTAssertThrowsError(try create([record()]) { throw Stop.cancelled }) {
            XCTAssertTrue($0 is Stop)
        }
        try assertClean()
    }

    func testCancellationDuringTextWritingCleansPartialTranscript() throws {
        var interrupted = false
        let largeText = String(repeating: "中文 🌅\n", count: 40_000)
        XCTAssertThrowsError(try create([MomentsRecord(author: "作者", timestamp: "今天", text: largeText)]) {
            if try self.hasStagedFile(extension: "txt", minimumBytes: 65_536) {
                interrupted = true
                throw Stop.cancelled
            }
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertTrue(interrupted)
        try assertClean()
    }

    func testCancellationDuringMediaCopyPreservesSourceAndOtherBatches() throws {
        let bytes = Data(repeating: 0x41, count: 1_048_576)
        let source = try makeMedia("large.png", data: bytes)
        let otherStaging = try BatchStaging.create(in: temporary.inbox)
        let marker = otherStaging.directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let otherReady = try temporary.commitBatch(names: ["keep.zip"])
        var interrupted = false
        XCTAssertThrowsError(try create([record(attachments: ["large.png"])]) {
            if try self.hasStagedFile(extension: "png", minimumBytes: 1) {
                interrupted = true
                throw Stop.cancelled
            }
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertTrue(interrupted)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        try assertClean(staging: [otherStaging.directory.lastPathComponent], ready: [otherReady.lastPathComponent])
    }

    func testCancellationWhileCompressorRunsReapsHelperAndCleansItsZIP() throws {
        try makeLargeMedia()
        var child: Int32?
        var cancelledAt: TimeInterval?
        XCTAssertThrowsError(try create([record(attachments: ["large.mov"])]) {
            if try self.hasStagedFile(extension: "zip", minimumBytes: 1) {
                child = Int32(try self.runTool("/usr/bin/pgrep", ["-P", String(getpid()), "-x", "tar"]).trimmingCharacters(in: .whitespacesAndNewlines))
                cancelledAt = ProcessInfo.processInfo.systemUptime
                throw Stop.cancelled
            }
        }) { XCTAssertTrue($0 is Stop) }
        let pid = try XCTUnwrap(child, "cancellation must exercise a live compressor")
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - (try XCTUnwrap(cancelledAt)), 2)
        try assertClean()
    }

    func testCompressorFailureCleansStagingWithoutPublishing() throws {
        try makeLargeMedia()
        var killed = false
        XCTAssertThrowsError(try create([record(attachments: ["large.mov"])]) {
            if !killed, try self.hasStagedFile(extension: "zip", minimumBytes: 1) {
                let pid = try XCTUnwrap(Int32(try self.runTool("/usr/bin/pgrep", ["-P", String(getpid()), "-x", "tar"]).trimmingCharacters(in: .whitespacesAndNewlines)))
                XCTAssertEqual(Darwin.kill(pid, SIGKILL), 0)
                killed = true
            }
        }) { XCTAssertEqual($0 as? MomentsArchive.Failure, .archiveFailed) }
        XCTAssertTrue(killed)
        try assertClean()
    }

    func testCancellationImmediatelyBeforeCommitPublishesNothing() throws {
        var interrupted = false
        XCTAssertThrowsError(try create([record()]) {
            if try self.hasStagedFile(extension: "zip", minimumBytes: 1),
               try !self.stagedPaths().contains(where: { $0.lastPathComponent == "archive-work" }) {
                interrupted = true
                throw Stop.cancelled
            }
        }) { XCTAssertTrue($0 is Stop) }
        XCTAssertTrue(interrupted)
        try assertClean()
    }

    func testFailedCommitCleansOwnStagingAndPreservesOccupiedDestination() throws {
        var occupied: URL?
        XCTAssertThrowsError(try create([record()]) {
            if occupied == nil, try self.hasStagedFile(extension: "zip", minimumBytes: 1),
               try !self.stagedPaths().contains(where: { $0.lastPathComponent == "archive-work" }) {
                let partial = try XCTUnwrap(self.manager.contentsOfDirectory(at: self.temporary.inbox.staging, includingPropertiesForKeys: nil).first)
                let destination = self.temporary.inbox.ready.appendingPathComponent(partial.deletingPathExtension().lastPathComponent)
                try Data("occupied".utf8).write(to: destination)
                occupied = destination
            }
        })
        let destination = try XCTUnwrap(occupied)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "occupied")
        XCTAssertEqual(temporary.reader.loadBatches(), [])
        try assertClean(ready: [destination.lastPathComponent])
    }

    private func record(attachments: [String] = []) -> MomentsRecord {
        MomentsRecord(author: "作者", timestamp: "今天", text: "正文", attachments: attachments)
    }

    private func displayName(_ records: [MomentsRecord]) -> String {
        MomentsArchive.displayName(for: records, exportedAt: namingDate, timeZone: utc)
    }

    private func create(_ records: [MomentsRecord], checkCancellation: () throws -> Void = {}) throws -> URL {
        try MomentsArchive.create(records: records, mediaDirectory: media, in: temporary.inbox, checkCancellation: checkCancellation)
    }

    @discardableResult
    private func makeMedia(_ name: String, data: Data) throws -> URL {
        try manager.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeLargeMedia() throws {
        let url = try makeMedia("large.mov", data: Data())
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Incompressible data keeps the real helper alive across a polling
        // interval; generation and the production copy both use bounded chunks.
        for _ in 0..<512 {
            var chunk = Data(count: 65_536)
            chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            try handle.write(contentsOf: chunk)
        }
    }

    private func readManifest(in directory: URL) throws -> BatchManifest {
        try BatchManifest.decoder().decode(BatchManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }

    private func archiveURL(in directory: URL) throws -> URL {
        let manifest = try readManifest(in: directory)
        XCTAssertEqual(manifest.items.count, 1)
        return directory.appendingPathComponent(try XCTUnwrap(manifest.items.first).relativePath)
    }

    private func extract(_ archive: URL) throws -> (URL, [String]) {
        let entries = try zipEntryNames(archive)
        let directory = temporary.root.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try runTool("/usr/bin/unzip", ["-q", archive.path, "-d", directory.path])
        return (directory, entries)
    }

    private func zipEntryNames(_ archive: URL) throws -> [String] {
        // macOS zipinfo's terminal listing mangles some UTF-8 names even when
        // unzip extracts them correctly. Inspect the actual central-directory
        // bytes, independently of both the writer and extraction below. These
        // small fixtures use ordinary ZIP (not ZIP64) and contain no comment.
        let data = try Data(contentsOf: archive)
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - count else { throw MomentsArchive.Failure.archiveFailed }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        let end = data.count - 22
        XCTAssertEqual(try number(end, 4), 0x06054b50)
        XCTAssertEqual(try number(end + 20, 2), 0)
        let count = try number(end + 10, 2)
        var cursor = try number(end + 16, 4)
        var names: [String] = []
        for _ in 0..<count {
            XCTAssertEqual(try number(cursor, 4), 0x02014b50)
            let length = try number(cursor + 28, 2)
            let extra = try number(cursor + 30, 2)
            let comment = try number(cursor + 32, 2)
            let start = cursor + 46
            guard start <= data.count - length else { throw MomentsArchive.Failure.archiveFailed }
            names.append(try XCTUnwrap(String(data: data.subdata(in: start..<start + length), encoding: .utf8)))
            if data[start..<start + length].contains(where: { $0 >= 0x80 }) {
                XCTAssertNotEqual(try number(cursor + 8, 2) & 0x800, 0, "non-ASCII filenames must declare UTF-8 for other ZIP readers")
            }
            cursor = start + length + extra + comment
        }
        XCTAssertEqual(cursor, end)
        return names
    }

    private func runTool(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
        guard process.terminationStatus == 0 else { throw MomentsArchive.Failure.archiveFailed }
        return output
    }

    private func stagedPaths() throws -> [URL] {
        let enumerator = try XCTUnwrap(manager.enumerator(at: temporary.inbox.staging, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }
    }

    private func hasStagedFile(extension suffix: String, minimumBytes: Int) throws -> Bool {
        try stagedPaths().contains {
            guard $0.pathExtension == suffix else { return false }
            let attributes = try manager.attributesOfItem(atPath: $0.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0 >= minimumBytes
        }
    }

    private func assertClean(staging: [String] = [], ready: [String] = [], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: temporary.inbox.staging.path).sorted(), staging.sorted(), file: file, line: line)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: temporary.inbox.ready.path).sorted(), ready.sorted(), file: file, line: line)
    }
}
