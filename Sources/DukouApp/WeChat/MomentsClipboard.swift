import AppKit
import Darwin
import DukouCore
import UniformTypeIdentifiers

/// The clipboard is borrowed only while collecting media. Keep the previous
/// contents in memory, and never replace something copied by the user later.
final class MomentsClipboard {
    enum Kind { case image, video }
    enum Failure: LocalizedError {
        case clipboardChanged, copyNotRegistered, unreadableClipboard, sourceUnavailable, incompleteSource

        var errorDescription: String? {
            switch self {
            case .clipboardChanged: return L10n.text("剪贴板已被其他操作更新，已停止以保留新内容。")
            case .copyNotRegistered: return L10n.text("微信尚未完成媒体复制，请重试。")
            case .unreadableClipboard: return L10n.text("无法完整读取剪贴板，已停止以保留原内容。")
            case .sourceUnavailable, .incompleteSource: return L10n.text("待保存的文件无法读取，请重新导出。")
            }
        }
    }

    private let board: NSPasteboard
    private let clock: () -> TimeInterval
    private var original: [[NSPasteboard.PasteboardType: Data]]?
    private var ownedCount: Int?
    private var preparedCount: Int?
    private var registeredCount: Int?
    private var candidate: (generation: Int, kind: Kind, since: TimeInterval)?
    private let markerType = NSPasteboard.PasteboardType("dev.dukou.moments-copy")
    private let marker = UUID().uuidString

    init(pasteboard: NSPasteboard = .general,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        board = pasteboard
        self.clock = clock
    }

    private func onMain<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }

    /// Call before each Copy command, including retries. A newer external
    /// generation is never cleared, even when it refers to the same file.
    func prepare() throws -> Int {
        try onMain {
            let generation = board.changeCount
            if original != nil {
                guard generation == ownedCount else { throw Failure.clipboardChanged }
            }
            if original == nil {
                let snapshot = try (board.pasteboardItems ?? []).map { item in
                    var values: [NSPasteboard.PasteboardType: Data] = [:]
                    for type in item.types {
                        if let data = item.data(forType: type) { values[type] = data }
                    }
                    // Qt can advertise aliases with no data. Keep every
                    // readable representation, including zero-length data.
                    guard !values.isEmpty else { throw Failure.unreadableClipboard }
                    return values
                }
                guard board.changeCount == generation else { throw Failure.clipboardChanged }
                original = snapshot
            }
            board.clearContents()
            ownedCount = board.changeCount
            guard board.setString(marker, forType: markerType) else { throw Failure.unreadableClipboard }
            let count = board.changeCount
            ownedCount = count
            preparedCount = count
            registeredCount = nil
            candidate = nil
            return count
        }
    }

    /// Explicitly register the result of the caller's Copy command BEFORE its
    /// next cancellation check. With a kind, require the expected media types
    /// in one generation observed for at least 50 ms, without reading image
    /// promises. False includes Qt's intermediate clear/write generations.
    /// The caller must observe/identify its Copy result; this is an assertion
    /// of provenance, not permission to adopt arbitrary clipboard changes.
    /// Each preparation can register only once. Further writes require a new
    /// prepare/Copy pair; readers and restore never silently take ownership.
    @discardableResult
    func didCopy(kind: Kind? = nil) throws -> Bool {
        try onMain {
            guard original != nil, let preparedCount else { throw Failure.copyNotRegistered }
            let generation = board.changeCount
            if let registeredCount {
                guard generation == registeredCount else { throw Failure.clipboardChanged }
                return true
            }
            if generation == preparedCount { candidate = nil; return false }
            let hasMarker = board.string(forType: markerType) == marker
            guard board.changeCount == generation else { candidate = nil; return false }
            guard !hasMarker else {
                candidate = nil
                if kind != nil { return false }
                throw Failure.clipboardChanged
            }
            if let kind {
                let types = board.types ?? []
                var expected = kind == .image && (types.contains(.png) || types.contains(.tiff))
                if !expected, types.contains(.fileURL),
                   let value = board.string(forType: .fileURL), let url = URL(string: value), url.isFileURL,
                   let type = UTType(filenameExtension: url.pathExtension.lowercased()) {
                    expected = type.conforms(to: kind == .image ? .image : .movie)
                }
                // A lazy file URL provider can replace the pasteboard while
                // being read. No candidate generation has been adopted yet.
                guard board.changeCount == generation, expected else { candidate = nil; return false }
                let now = clock()
                guard let candidate, candidate.generation == generation, candidate.kind == kind else {
                    self.candidate = (generation, kind, now)
                    return false
                }
                guard now - candidate.since >= 0.05 else { return false }
                guard board.changeCount == generation else { self.candidate = nil; return false }
            }
            ownedCount = generation
            registeredCount = generation
            candidate = nil
            return true
        }
    }

    func saveIfReady(after count: Int, kind: Kind, stem: String, directory: URL,
                     checkCancellation: () throws -> Void) throws -> String? {
        try checkCancellation()
        let payload: (url: URL?, generation: Int)? = try onMain {
            guard original != nil, preparedCount == count else { throw Failure.copyNotRegistered }
            let generation = board.changeCount
            guard generation == ownedCount else { throw Failure.clipboardChanged }
            guard let registeredCount else { return nil }
            guard generation == registeredCount else { throw Failure.clipboardChanged }
            let url = board.string(forType: .fileURL).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
            guard board.changeCount == generation else { throw Failure.clipboardChanged }
            return (url, generation)
        }
        guard let payload else { return nil }
        try checkCancellation()
        var fileError: Error?
        if let source = payload.url {
            let type = UTType(filenameExtension: source.pathExtension)
            if type?.conforms(to: kind == .image ? .image : .movie) == true {
                let name = try filename(stem: stem, extension: source.pathExtension.lowercased())
                do {
                    try copy(source, to: directory.appendingPathComponent(name), checkCancellation: checkCancellation)
                    return name
                } catch is CancellationError { throw CancellationError() }
                catch Failure.sourceUnavailable { /* The caller may poll again if no image representation is ready. */ }
                catch { fileError = error }
            }
        }
        // Qt can fulfill image promises lazily. Read each fallback only when
        // the original cannot be saved, and stop as soon as one is usable.
        let fallbackTypes: [NSPasteboard.PasteboardType] = kind == .image ? [.png, .tiff] : []
        for type in fallbackTypes {
            try checkCancellation()
            let data = try onMain {
                guard board.changeCount == payload.generation else { throw Failure.clipboardChanged }
                let data = board.data(forType: type)
                guard board.changeCount == payload.generation else { throw Failure.clipboardChanged }
                return data
            }
            try checkCancellation()
            guard let data else { continue }
            guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            let name = try filename(stem: stem, extension: "png")
            try write(to: directory.appendingPathComponent(name), checkCancellation: checkCancellation) { output in
                for offset in stride(from: 0, to: png.count, by: 1_048_576) {
                    try checkCancellation()
                    try output.write(contentsOf: png.subdata(in: offset..<min(offset + 1_048_576, png.count)))
                }
            }
            return name
        }
        try checkCancellation()
        if let fileError { throw fileError }
        return nil
    }

    func restore() {
        onMain {
            guard let original else { return }
            defer {
                self.original = nil
                ownedCount = nil
                preparedCount = nil
                registeredCount = nil
                candidate = nil
            }
            guard board.changeCount == ownedCount else { return }
            let items = original.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            board.clearContents()
            if !items.isEmpty { board.writeObjects(items) }
        }
    }

    private func filename(stem: String, extension ext: String) throws -> String {
        let name = stem + "." + ext
        guard !stem.isEmpty, !stem.hasPrefix("."), !name.contains("/"), !name.contains(":"),
              !name.utf8.contains(0), name.utf8.count <= 255 else { throw Failure.incompleteSource }
        return name
    }

    private func copy(_ source: URL, to destination: URL, checkCancellation: () throws -> Void) throws {
        try checkCancellation()
        guard !source.path.utf8.contains(0) else { throw Failure.incompleteSource }
        let fd = source.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { throw Failure.sourceUnavailable }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0 else { throw Failure.sourceUnavailable }
        try write(to: destination, checkCancellation: checkCancellation) { output in
            var remaining = before.st_size
            while remaining > 0 {
                try checkCancellation()
                guard let chunk = try input.read(upToCount: Int(min(remaining, 1_048_576))), !chunk.isEmpty else { throw Failure.incompleteSource }
                try checkCancellation()
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            try checkCancellation()
            let extra = try input.read(upToCount: 1)
            var after = stat()
            guard extra?.isEmpty != false, fstat(fd, &after) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_mode == after.st_mode, before.st_nlink == after.st_nlink,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.incompleteSource }
            try input.close()
        }
    }

    private func write(to destination: URL, checkCancellation: () throws -> Void, body: (FileHandle) throws -> Void) throws {
        try checkCancellation()
        let fd = destination.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw posixError(errno, destination) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var completed = false
        defer {
            try? output.close()
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        try body(output)
        try checkCancellation()
        try output.synchronize()
        try output.close()
        try checkCancellation()
        completed = true
    }

    private func posixError(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
