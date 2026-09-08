// Named pasteboards only; this executable does not launch or interact with WeChat.
// From the repository root, using the existing DukouCore build:
// clipboard_test_output="$(mktemp -d /tmp/dukou-clipboard-tests.XXXXXX)"
// clipboard_test_sdk="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
// mise exec -- swiftc -swift-version 5 -D MOMENTS_CLIPBOARD_TEST_MAIN -I .build/debug/Modules \
//   -F "$clipboard_test_sdk/Library/Frameworks" -L "$clipboard_test_sdk/usr/lib" \
//   -Xlinker -rpath -Xlinker "$clipboard_test_sdk/Library/Frameworks" \
//   -Xlinker -rpath -Xlinker "$clipboard_test_sdk/Library/PrivateFrameworks" \
//   -Xlinker -rpath -Xlinker "$clipboard_test_sdk/usr/lib" \
//   .build/debug/DukouCore.build/L10n.swift.o \
//   Sources/DukouApp/WeChat/MomentsClipboard.swift Tests/MomentsClipboardTests.swift \
//   -o "$clipboard_test_output/runner"
// "$clipboard_test_output/runner"
// Pass --registration-only to run just the typed registration regressions.
// Pass --snapshot-only to run just the clipboard backup regressions.
import AppKit
import XCTest

final class MomentsClipboardTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var destination: URL!
    private var board: NSPasteboard!
    private var clipboard: MomentsClipboard!
    private var uptime: TimeInterval = 0

    private final class ImageProvider: NSObject, NSPasteboardItemDataProvider {
        let values: [NSPasteboard.PasteboardType: Data]
        var requestedTypes: [NSPasteboard.PasteboardType] = []
        var onRequest: (() -> Void)?

        init(_ values: [NSPasteboard.PasteboardType: Data]) { self.values = values }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            requestedTypes.append(type)
            let action = onRequest
            onRequest = nil
            action?()
            if let data = values[type] { item.setData(data, forType: type) }
        }
    }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("dukou-clipboard-tests-" + UUID().uuidString, isDirectory: true)
        destination = root.appendingPathComponent("output", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        board = NSPasteboard(name: .init("dev.dukou.tests.moments-" + UUID().uuidString))
        uptime = 0
        clipboard = MomentsClipboard(pasteboard: board, clock: { [unowned self] in self.uptime })
        put([.string: Data("original clipboard".utf8)])
    }

    override func tearDownWithError() throws {
        clipboard.restore()
        board.releaseGlobally()
        try fm.removeItem(at: root)
    }

    private func put(_ representations: [NSPasteboard.PasteboardType: Data]) {
        let item = NSPasteboardItem()
        for (type, data) in representations { item.setData(data, forType: type) }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
    }

    private func source(_ name: String = "source.mov", data: Data = Data(repeating: 0x51, count: 3 * 1_048_576)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func media(_ url: URL, extra: [NSPasteboard.PasteboardType: Data] = [:]) {
        var values = extra
        values[.fileURL] = Data(url.absoluteString.utf8)
        put(values)
    }

    private func image(_ format: NSBitmapImageRep.FileType = .png) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 0x7f, count: 24)
        return try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
    }

    private func save(_ count: Int, kind: MomentsClipboard.Kind = .image,
                      check: () throws -> Void = {}) throws -> String? {
        try clipboard.saveIfReady(after: count, kind: kind, stem: "001-01", directory: destination, checkCancellation: check)
    }

    private func expectEmptyOutput(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.path), [], file: file, line: line)
    }

    private func assertImage(_ name: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        let name = try XCTUnwrap(name, file: file, line: line)
        XCTAssertEqual(name, "001-01.png", file: file, line: line)
        let data = try Data(contentsOf: destination.appendingPathComponent(name))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), file: file, line: line)
        XCTAssertEqual(bitmap.pixelsWide, 3, file: file, line: line)
        XCTAssertEqual(bitmap.pixelsHigh, 2, file: file, line: line)
    }

    func testCopyRegistrationBeforeCancellationRestoresEveryOriginalRepresentation() throws {
        let custom = NSPasteboard.PasteboardType("dev.dukou.tests.custom")
        let a = NSPasteboardItem(), b = NSPasteboardItem()
        a.setString("first", forType: .string)
        a.setData(Data([0, 1, 2, 255]), forType: custom)
        b.setString("second", forType: .string)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([a, b]))
        let count = try clipboard.prepare()
        put([.png: try image()])
        XCTAssertTrue(try clipboard.didCopy())
        XCTAssertThrowsError(try save(count, check: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError) }
        clipboard.restore()
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.pasteboardItems?[0].string(forType: .string), "first")
        XCTAssertEqual(board.pasteboardItems?[0].data(forType: custom), Data([0, 1, 2, 255]))
        XCTAssertEqual(board.pasteboardItems?[1].string(forType: .string), "second")
        try expectEmptyOutput()
    }

    func testSnapshotPreservesReadableRepresentationsAndSkipsNilAlias() throws {
        let readable = NSPasteboard.PasteboardType("dev.dukou.tests.readable-alias")
        let missing = NSPasteboard.PasteboardType("dev.dukou.tests.nil-alias")
        let provider = ImageProvider([:])
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data(), forType: .string))
        XCTAssertTrue(item.setData(Data([0, 1, 255]), forType: readable))
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [missing]))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertTrue(board.pasteboardItems?[0].types.contains(missing) == true)

        _ = try clipboard.prepare()
        XCTAssertTrue(provider.requestedTypes.contains(missing))
        clipboard.restore()
        XCTAssertEqual(board.pasteboardItems?.count, 1)
        XCTAssertEqual(board.pasteboardItems?[0].data(forType: .string), Data())
        XCTAssertEqual(board.pasteboardItems?[0].data(forType: readable), Data([0, 1, 255]))
        XCTAssertFalse(board.pasteboardItems?[0].types.contains(missing) == true)
    }

    func testSnapshotRejectsAnyWhollyUnreadableItemWithoutChangingBoard() throws {
        let missingA = NSPasteboard.PasteboardType("dev.dukou.tests.nil-a")
        let missingB = NSPasteboard.PasteboardType("dev.dukou.tests.nil-b")
        let provider = ImageProvider([:])
        let readable = NSPasteboardItem(), unreadable = NSPasteboardItem()
        XCTAssertTrue(readable.setString("keep first item", forType: .string))
        XCTAssertTrue(unreadable.setDataProvider(provider, forTypes: [missingA, missingB]))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([readable, unreadable]))
        let generation = board.changeCount
        let types = board.pasteboardItems?.map(\.types)

        XCTAssertThrowsError(try clipboard.prepare()) {
            guard case MomentsClipboard.Failure.unreadableClipboard = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(Set(provider.requestedTypes), Set([missingA, missingB]))
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(board.pasteboardItems?.map(\.types), types)
        XCTAssertEqual(board.pasteboardItems?[0].string(forType: .string), "keep first item")
        clipboard.restore()
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.pasteboardItems?.map(\.types), types)
    }

    func testSnapshotAllowsAnEmptyPasteboard() throws {
        board.clearContents()
        XCTAssertTrue((board.pasteboardItems ?? []).isEmpty)
        _ = try clipboard.prepare()
        clipboard.restore()
        XCTAssertTrue((board.pasteboardItems ?? []).isEmpty)
        XCTAssertEqual(board.types ?? [], [])
    }

    func testCancellationBeforeAResultRestoresTheMarkerAndRetriesCanPrepare() throws {
        let first = try clipboard.prepare()
        XCTAssertFalse(try clipboard.didCopy())
        XCTAssertNil(try save(first))
        let retry = try clipboard.prepare()
        XCTAssertNotEqual(first, retry)
        XCTAssertFalse(try clipboard.didCopy())
        clipboard.restore()
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }

    func testExternalCopyBlocksNextPrepareAndIsNeverRestoredOver() throws {
        _ = try clipboard.prepare()
        put([.png: try image()])
        try clipboard.didCopy()
        put([.string: Data("new user copy".utf8)])
        let generation = board.changeCount
        XCTAssertThrowsError(try clipboard.prepare()) {
            guard case MomentsClipboard.Failure.clipboardChanged = $0 else { return XCTFail("\($0)") }
        }
        clipboard.restore()
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    func testExternalCopyOfTheSameFileStillWins() throws {
        let url = try source()
        _ = try clipboard.prepare()
        media(url)
        try clipboard.didCopy()
        media(url, extra: [.string: Data("new user metadata".utf8)])
        let generation = board.changeCount
        clipboard.restore()
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.string(forType: .string), "new user metadata")
    }

    func testReadersAndRepeatedRegistrationCannotAdoptNewExternalImage() throws {
        let count = try clipboard.prepare()
        put([.png: try image()])
        try clipboard.didCopy()
        put([.png: try image(.tiff)])
        let generation = board.changeCount
        XCTAssertThrowsError(try save(count))
        XCTAssertThrowsError(try clipboard.didCopy())
        clipboard.restore()
        XCTAssertEqual(board.changeCount, generation)
        try expectEmptyOutput()
    }

    func testUnregisteredChangesAreNeitherSavedNorRestoredOver() throws {
        let count = try clipboard.prepare()
        put([.string: Data("external copy before registration".utf8)])
        let generation = board.changeCount
        XCTAssertThrowsError(try save(count))
        XCTAssertThrowsError(try clipboard.prepare())
        clipboard.restore()
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.string(forType: .string), "external copy before registration")
    }

    func testNewCopyCycleRetainsOriginalAndRejectsAnOldGeneration() throws {
        let old = try clipboard.prepare()
        put([.png: try image()])
        try clipboard.didCopy()
        let current = try clipboard.prepare()
        put([.tiff: try image(.tiff)])
        try clipboard.didCopy()
        XCTAssertThrowsError(try save(old))
        try assertImage(save(current))
        clipboard.restore()
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }

    func testTypedCopyRequiresAtLeastFiftyMilliseconds() throws {
        _ = try clipboard.prepare()
        put([.png: try image()])
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.049
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.050
        XCTAssertTrue(try clipboard.didCopy(kind: .image))
        XCTAssertTrue(try clipboard.didCopy(kind: .image))
        clipboard.restore()
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }

    func testQtClearThenWriteRegistersOnlyTheFinalMediaGeneration() throws {
        let count = try clipboard.prepare()
        board.clearContents()
        let cleared = board.changeCount
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.100
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        // Qt redeclares ownership for its payload. writeObjects alone under
        // the same owner does not advance NSPasteboard.changeCount.
        put([.png: try image()])
        XCTAssertNotEqual(board.changeCount, cleared)
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.149
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.151
        XCTAssertTrue(try clipboard.didCopy(kind: .image))
        try assertImage(save(count))
        clipboard.restore()
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }

    func testTypedCopyDoesNotAdoptStableTextOrNonMediaURLs() throws {
        _ = try clipboard.prepare()
        let values: [[NSPasteboard.PasteboardType: Data]] = [
            [.string: Data("user copy".utf8)],
            [.fileURL: Data(root.appendingPathComponent("document.txt").absoluteString.utf8)],
            [.fileURL: Data("https://example.com/image.png".utf8)]
        ]
        for value in values {
            put(value)
            XCTAssertFalse(try clipboard.didCopy(kind: .image))
            uptime += 1
            XCTAssertFalse(try clipboard.didCopy(kind: .image))
            XCTAssertThrowsError(try clipboard.prepare())
        }
        let generation = board.changeCount
        clipboard.restore()
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.string(forType: .fileURL), "https://example.com/image.png")
    }

    func testTypedVideoRequiresMovieURLAndRejectsImageFlavors() throws {
        _ = try clipboard.prepare()
        media(root.appendingPathComponent("image.png"), extra: [.png: try image(), .tiff: try image(.tiff)])
        XCTAssertFalse(try clipboard.didCopy(kind: .video))
        uptime = 0.100
        XCTAssertFalse(try clipboard.didCopy(kind: .video))
        media(root.appendingPathComponent("movie.MOV"))
        XCTAssertFalse(try clipboard.didCopy(kind: .video))
        uptime = 0.151
        XCTAssertTrue(try clipboard.didCopy(kind: .video))
    }

    func testTypedImageAcceptsPNGOrTIFFWithoutReadingImagePromises() throws {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            _ = try clipboard.prepare()
            let provider = ImageProvider([type: try image(type == .png ? .png : .tiff)])
            let item = NSPasteboardItem()
            item.setString(root.appendingPathComponent("unknown-extension").absoluteString, forType: .fileURL)
            XCTAssertTrue(item.setDataProvider(provider, forTypes: [type]))
            board.clearContents()
            XCTAssertTrue(board.writeObjects([item]))
            XCTAssertFalse(try clipboard.didCopy(kind: .image))
            uptime += 0.060
            XCTAssertTrue(try clipboard.didCopy(kind: .image))
            XCTAssertEqual(provider.requestedTypes, [])
            clipboard.restore()
        }
    }

    func testTypedCandidateRestartsItsWaitAfterAnotherWrite() throws {
        _ = try clipboard.prepare()
        put([.png: try image()])
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.040
        put([.png: try image()])
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.060
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.091
        XCTAssertTrue(try clipboard.didCopy(kind: .image))
    }

    func testTypedCandidateRestartsItsWaitWhenExpectedKindChanges() throws {
        _ = try clipboard.prepare()
        media(root.appendingPathComponent("movie.mov"), extra: [.png: try image()])
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.040
        XCTAssertFalse(try clipboard.didCopy(kind: .video))
        uptime = 0.060
        XCTAssertFalse(try clipboard.didCopy(kind: .video))
        uptime = 0.091
        XCTAssertTrue(try clipboard.didCopy(kind: .video))
    }

    func testPendingTypedCandidateIsNotOwnedByPrepareOrRestore() throws {
        _ = try clipboard.prepare()
        put([.png: try image()])
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        let generation = board.changeCount
        uptime = 1
        XCTAssertThrowsError(try clipboard.prepare())
        clipboard.restore()
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertNotNil(board.data(forType: .png))
    }

    func testTypedRegistrationStillRejectsNewExternalCopies() throws {
        let count = try clipboard.prepare()
        put([.png: try image()])
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.050
        XCTAssertTrue(try clipboard.didCopy(kind: .image))
        put([.string: Data("new external copy".utf8)])
        let generation = board.changeCount
        XCTAssertThrowsError(try clipboard.didCopy(kind: .image)) {
            guard case MomentsClipboard.Failure.clipboardChanged = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try save(count))
        XCTAssertThrowsError(try clipboard.prepare())
        clipboard.restore()
        XCTAssertEqual(board.changeCount, generation)
        XCTAssertEqual(board.string(forType: .string), "new external copy")
    }

    func testFileURLProviderGenerationChangeIsPendingUntilTheNewResultSettles() throws {
        let bytes = try image()
        let finalURL = try source("final.png", data: bytes)
        let count = try clipboard.prepare()
        let provider = ImageProvider([.fileURL: Data(root.appendingPathComponent("intermediate.jpg").absoluteString.utf8)])
        provider.onRequest = { self.media(finalURL) }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.fileURL]))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertEqual(provider.requestedTypes, [])
        let generation = board.changeCount
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        XCTAssertEqual(provider.requestedTypes, [.fileURL])
        XCTAssertNotEqual(board.changeCount, generation)
        XCTAssertFalse(try clipboard.didCopy(kind: .image))
        uptime = 0.050
        XCTAssertTrue(try clipboard.didCopy(kind: .image))
        let name = try XCTUnwrap(save(count))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), bytes)
        clipboard.restore()
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }

    func testReadableOriginalImageIsPreferredToClipboardFallback() throws {
        let bytes = try image()
        let url = try source("original.png", data: bytes)
        let count = try clipboard.prepare()
        media(url, extra: [.png: Data("invalid fallback must not be decoded".utf8)])
        try clipboard.didCopy()
        let name = try XCTUnwrap(save(count))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), bytes)
    }

    func testMissingFileUsesActualClipboardPNG() throws {
        let count = try clipboard.prepare()
        media(root.appendingPathComponent("missing.jpg"), extra: [.png: try image()])
        try clipboard.didCopy()
        try assertImage(save(count))
    }

    func testReadableOriginalDoesNotRequestAnyPromisedImages() throws {
        let bytes = try image()
        let url = try source("original.png", data: bytes)
        let count = try clipboard.prepare()
        let provider = ImageProvider([.png: bytes, .tiff: try image(.tiff)])
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.png, .tiff]))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        try clipboard.didCopy()
        let name = try XCTUnwrap(save(count))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), bytes)
        XCTAssertEqual(provider.requestedTypes, [])
    }

    func testSuccessfulPNGFallbackDoesNotRequestPromisedTIFF() throws {
        let count = try clipboard.prepare()
        let provider = ImageProvider([.png: try image(), .tiff: try image(.tiff)])
        let item = NSPasteboardItem()
        item.setString(root.appendingPathComponent("not-ready.jpg").absoluteString, forType: .fileURL)
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.png, .tiff]))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        try clipboard.didCopy()
        try assertImage(save(count))
        XCTAssertEqual(provider.requestedTypes, [.png])
    }

    func testUnknownFileExtensionUsesActualClipboardTIFF() throws {
        let url = try source("no-extension", data: Data([1, 2, 3]))
        let count = try clipboard.prepare()
        media(url, extra: [.tiff: try image(.tiff)])
        try clipboard.didCopy()
        try assertImage(save(count))
    }

    func testInvalidPNGDoesNotHideAValidTIFFFallback() throws {
        let count = try clipboard.prepare()
        media(root.appendingPathComponent("not-ready.jpg"), extra: [.png: Data([0, 1, 2]), .tiff: try image(.tiff)])
        try clipboard.didCopy()
        try assertImage(save(count))
    }

    func testEmptyOriginalImageUsesPNGAndUnavailableFileWithoutFallbackCanBePolled() throws {
        let url = try source("empty.jpg", data: Data())
        var count = try clipboard.prepare()
        media(url)
        try clipboard.didCopy()
        XCTAssertNil(try save(count))
        count = try clipboard.prepare()
        media(url, extra: [.png: try image()])
        try clipboard.didCopy()
        try assertImage(save(count))
    }

    func testVideoNeverFallsBackToClipboardImage() throws {
        let count = try clipboard.prepare()
        media(root.appendingPathComponent("missing.mov"), extra: [.png: try image()])
        try clipboard.didCopy()
        XCTAssertNil(try save(count, kind: .video))
        try expectEmptyOutput()
    }

    func testStableOriginalIsStreamedWithoutChangingItsBytes() throws {
        let bytes = Data((0..<(2 * 1_048_576 + 7)).map { UInt8($0 % 251) })
        let url = try source(data: bytes)
        let count = try clipboard.prepare()
        media(url)
        try clipboard.didCopy()
        let name = try XCTUnwrap(save(count, kind: .video))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), bytes)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testTruncationGrowthAndSameSizeRewriteFailAndRemovePartialOutput() throws {
        for mutation in ["truncate", "append", "rewrite"] {
            let url = try source(mutation + ".mov")
            let count = try clipboard.prepare()
            media(url)
            try clipboard.didCopy()
            let output = destination.appendingPathComponent("001-01.mov")
            var changed = false
            XCTAssertThrowsError(try save(count, kind: .video, check: {
                let size = (try? self.fm.attributesOfItem(atPath: output.path)[.size]) as? NSNumber
                guard !changed, (size?.intValue ?? 0) > 0 else { return }
                changed = true
                let writer = try FileHandle(forUpdating: url)
                defer { try? writer.close() }
                switch mutation {
                case "truncate": try writer.truncate(atOffset: 0)
                case "append": try writer.seekToEnd(); try writer.write(contentsOf: Data([0xff]))
                default:
                    try writer.write(contentsOf: Data([0xff]))
                    try self.fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
                }
            })) {
                guard case MomentsClipboard.Failure.incompleteSource = $0 else { return XCTFail("\(mutation): \($0)") }
            }
            XCTAssertTrue(changed)
            try expectEmptyOutput()
        }
    }

    func testStreamCancellationIsNotSwallowedByImageFallback() throws {
        let url = try source("large.jpg")
        let count = try clipboard.prepare()
        media(url, extra: [.png: try image()])
        try clipboard.didCopy()
        let output = destination.appendingPathComponent("001-01.jpg")
        XCTAssertThrowsError(try save(count, check: {
            let size = (try? self.fm.attributesOfItem(atPath: output.path)[.size]) as? NSNumber
            if (size?.intValue ?? 0) > 0 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        try expectEmptyOutput()
        clipboard.restore()
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }

    func testPNGCancellationRemovesItsPartialFile() throws {
        let count = try clipboard.prepare()
        put([.png: try image()])
        try clipboard.didCopy()
        XCTAssertThrowsError(try save(count, check: {
            if self.fm.fileExists(atPath: self.destination.appendingPathComponent("001-01.png").path) { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
        try expectEmptyOutput()
    }

    func testOutputCollisionDoesNotOverwriteTheExistingFile() throws {
        let url = try source()
        let output = destination.appendingPathComponent("001-01.mov")
        try Data("keep".utf8).write(to: output)
        let count = try clipboard.prepare()
        media(url)
        try clipboard.didCopy()
        XCTAssertThrowsError(try save(count, kind: .video))
        XCTAssertEqual(try Data(contentsOf: output), Data("keep".utf8))
    }
}

#if MOMENTS_CLIPBOARD_TEST_MAIN
@main
enum MomentsClipboardTestRunner {
    static func main() {
        let all = MomentsClipboardTests.defaultTestSuite
        let suite: XCTestSuite
        if CommandLine.arguments.contains("--snapshot-only") {
            suite = XCTestSuite(name: "MomentsClipboardSnapshotTests")
            for test in all.tests where test.name.contains("Snapshot") { suite.addTest(test) }
        } else if CommandLine.arguments.contains("--registration-only") {
            suite = XCTestSuite(name: "MomentsClipboardRegistrationTests")
            for test in all.tests where test.name.contains("Typed") || test.name.contains("QtClearThenWrite") || test.name.contains("FileURLProviderGenerationChange") {
                suite.addTest(test)
            }
        } else { suite = all }
        suite.run()
        guard let run = suite.testRun, run.executionCount > 0, run.hasSucceeded else { exit(1) }
    }
}
#endif
