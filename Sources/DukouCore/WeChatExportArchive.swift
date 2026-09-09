import Darwin
import Foundation

/// Names verified native receipts and optionally packages their extracted
/// contents together. Originals stay in history if merging or delivery stops.
public enum WeChatExportArchive {
    public enum Failure: Error, LocalizedError {
        case mergeFailed
        public var errorDescription: String? {
            L10n.text("聊天记录合并失败，原始 ZIP 已保留在暂存架。")
        }
    }

    /// The preview is independent of merging: a single native receipt and each
    /// unmerged part get the same offline reader. Publish all replacements
    /// before the caller consumes any original receipt.
    public static func prepare(_ batches: [ReadyBatch], chat: String, fallbackCounts: [Int],
                               mergeArchives: Bool, htmlPreview: Bool, in inbox: Inbox,
                               selfSender: String? = nil, exportedAt: Date = Date(), checkCancellation: () throws -> Void = {}) throws -> [URL] {
        guard !batches.isEmpty, batches.count == fallbackCounts.count else { throw Failure.mergeFailed }
        if mergeArchives && batches.count > 1 {
            return [try merge(batches, chat: chat, fallbackCounts: fallbackCounts, in: inbox,
                              htmlPreview: htmlPreview, selfSender: selfSender, exportedAt: exportedAt, checkCancellation: checkCancellation)]
        }
        var prepared: [URL] = []
        do {
            for (index, batch) in batches.enumerated() {
                let part = batches.count > 1 ? index + 1 : nil
                if htmlPreview {
                    prepared.append(try merge([batch], chat: chat, fallbackCounts: [fallbackCounts[index]], in: inbox,
                                              htmlPreview: true, selfSender: selfSender, part: part, exportedAt: exportedAt,
                                              checkCancellation: checkCancellation))
                } else {
                    try rename(batch, chat: chat, fallbackCount: fallbackCounts[index], part: part,
                               exportedAt: exportedAt, checkCancellation: checkCancellation)
                    prepared.append(batch.directory)
                }
            }
            return prepared
        } catch {
            // These replacements have no delivery side effects yet. Keep only
            // native receipts on failure, including cancellation between parts.
            if htmlPreview { for directory in prepared { try? FileManager.default.removeItem(at: directory) } }
            throw error
        }
    }

    /// A rename within the item's own directory changes no ZIP bytes. Commit
    /// its manifest before observing another cancellation; roll back on error.
    public static func rename(_ batch: ReadyBatch, chat: String, fallbackCount: Int?, part: Int? = nil, exportedAt: Date = Date(), checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        let (item, data) = try source(batch)
        let transcript: WeChatNativeArchive.Transcript?
        do { transcript = try WeChatNativeArchive.transcript(data, checkCancellation: checkCancellation) }
        catch is CancellationError { throw CancellationError() }
        catch { transcript = nil }
        let name = ForwardArchiveName.make(source: chat, count: transcript?.records?.count ?? fallbackCount,
                                           start: transcript?.start, end: transcript?.end, part: part, exportedAt: exportedAt)
        guard item.displayName != name else { return }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(name)
        let manifestURL = batch.directory.appendingPathComponent(BatchStaging.manifestFileName)
        let manifest = try BatchManifest.decoder().decode(BatchManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.batchID == batch.id, manifest.items.count == 1, let original = manifest.items.first,
              original.id == item.id else { throw WeChatReadError.invalidTranscript }
        let renamed = ManifestItem(id: original.id, displayName: name,
                                   relativePath: (original.relativePath as NSString).deletingLastPathComponent + "/" + name,
                                   contentType: original.contentType, byteCount: original.byteCount,
                                   itemIndex: original.itemIndex, attachmentIndex: original.attachmentIndex, loadStrategy: original.loadStrategy)
        let updated = BatchManifest(batchID: manifest.batchID, createdAt: manifest.createdAt, items: [renamed],
                                    action: manifest.action, schemaVersion: manifest.schemaVersion)
        let encoded = try BatchManifest.encoder().encode(updated)
        try checkCancellation()
        try FileManager.default.moveItem(at: item.url, to: destination)
        do { try encoded.write(to: manifestURL, options: .atomic) }
        catch {
            try FileManager.default.moveItem(at: destination, to: item.url)
            throw error
        }
    }

    /// Batches arrive oldest first. Each keeps a separate directory, preventing
    /// identically named attachments from overwriting one another. The root TXT
    /// combines their texts and supplies explicit paths to all original files.
    public static func merge(_ batches: [ReadyBatch], chat: String, fallbackCounts: [Int], in inbox: Inbox,
                             htmlPreview: Bool = false, selfSender: String? = nil, part: Int? = nil,
                             exportedAt: Date = Date(), checkCancellation: () throws -> Void = {}) throws -> URL {
        try checkCancellation()
        guard !batches.isEmpty, batches.count == fallbackCounts.count else { throw Failure.mergeFailed }
        let staging = try BatchStaging.create(in: inbox)
        defer { staging.discard() }
        let work = staging.directory.appendingPathComponent("merge-work", isDirectory: true)
        let payload = work.appendingPathComponent("payload", isDirectory: true)
        let originals = payload.appendingPathComponent("batches", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let textURL = payload.appendingPathComponent("聊天记录.txt")
        guard FileManager.default.createFile(atPath: textURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.mergeFailed }
        let text = try FileHandle(forWritingTo: textURL)
        defer { try? text.close() }
        try write("聊天：\(chat)\n说明：按导出批次从早到晚排列，原始文字和附件保留在各批次目录。\n\n", to: text, checkCancellation: checkCancellation)
        var first: Date?, last: Date?, count = 0, allDatesKnown = true
        var previewBatches: [WeChatHTMLPreview.Batch] = []
        for (index, batch) in batches.enumerated() {
            try checkCancellation()
            let (_, data) = try source(batch)
            let transcript = try WeChatNativeArchive.transcript(data, checkCancellation: checkCancellation)
            let batchCount = transcript?.records?.count ?? fallbackCounts[index]
            let sum = count.addingReportingOverflow(batchCount)
            guard batchCount >= 0, !sum.overflow else { throw Failure.mergeFailed }
            count = sum.partialValue
            if let start = transcript?.start, let end = transcript?.end {
                first = min(first ?? start, start); last = max(last ?? end, end)
            } else { allDatesKnown = false }
            let number = String(index + 1)
            let prefix = "batches/" + String(repeating: "0", count: max(0, 4 - number.count)) + number
            let folder = payload.appendingPathComponent(prefix, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let paths = try WeChatNativeArchive.extract(data, to: folder, checkCancellation: checkCancellation)
            if htmlPreview {
                previewBatches.append(.init(transcript: transcript, prefix: prefix, paths: paths))
            }
            try write("【第 \(index + 1) 批】\n本批文字中的文件路径相对于：\(prefix)/\n", to: text, checkCancellation: checkCancellation)
            if let transcript {
                try write("原始记录：\(prefix)/\(transcript.path)\n\n", to: text, checkCancellation: checkCancellation)
                try write(transcript.body.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")), to: text, checkCancellation: checkCancellation)
            }
            try write("\n\n本批文件：\n", to: text, checkCancellation: checkCancellation)
            for path in paths { try write("\(prefix)/\(path)\n", to: text, checkCancellation: checkCancellation) }
            try write("\n", to: text, checkCancellation: checkCancellation)
        }
        try text.close()
        if htmlPreview {
            let html = try WeChatHTMLPreview.render(chat: chat, batches: previewBatches, selfSender: selfSender, checkCancellation: checkCancellation)
            try checkCancellation()
            try Data(html.utf8).write(to: payload.appendingPathComponent("index.html"), options: .atomic)
        }
        let name = ForwardArchiveName.make(source: chat, count: count, start: allDatesKnown ? first : nil,
                                           end: allDatesKnown ? last : nil, part: part, exportedAt: exportedAt)
        let itemID = UUID()
        let archive = try staging.destination(for: itemID, displayName: name)
        try compress(payload, to: archive, work: work, htmlPreview: htmlPreview, checkCancellation: checkCancellation)
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else { throw Failure.mergeFailed }
        try FileManager.default.removeItem(at: work)
        let item = ManifestItem(id: itemID, displayName: name, relativePath: staging.relativePath(for: itemID, displayName: name),
                                contentType: "public.zip-archive", byteCount: bytes.int64Value,
                                itemIndex: 0, attachmentIndex: 0, loadStrategy: .fileURL)
        let manifest = BatchManifest(batchID: staging.batchID, createdAt: exportedAt, items: [item], action: .shelf)
        try checkCancellation()
        return try staging.commit(manifest: manifest, diagnostics: nil, intent: nil, in: inbox)
    }

    private static func source(_ batch: ReadyBatch) throws -> (ReadyItem, Data) {
        guard batch.items.count == 1, let item = batch.items.first, item.url.pathExtension.lowercased() == "zip",
              item.url.resolvingSymlinksInPath().path.hasPrefix(batch.directory.resolvingSymlinksInPath().path + "/") else {
            throw WeChatReadError.invalidTranscript
        }
        let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
        guard data.count == item.byteCount else { throw WeChatReadError.invalidTranscript }
        return (item, data)
    }

    private static func write(_ value: String, to file: FileHandle, checkCancellation: () throws -> Void) throws {
        let bytes = value.utf8
        var position = bytes.startIndex
        while position != bytes.endIndex {
            try checkCancellation()
            let end = bytes.index(position, offsetBy: 65_536, limitedBy: bytes.endIndex) ?? bytes.endIndex
            try file.write(contentsOf: Data(bytes[position..<end]))
            position = end
        }
    }

    private static func compress(_ payload: URL, to archive: URL, work: URL, htmlPreview: Bool, checkCancellation: () throws -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-c", "--format=zip", "--options=zip:hdrcharset=UTF-8", "-f", archive.path,
                             "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags",
                             "--uid", "0", "--gid", "0", "--uname", "", "--gname", "",
                             "-C", payload.path, "--", "聊天记录.txt", "batches"]
        if htmlPreview { process.arguments?.append("index.html") }
        process.currentDirectoryURL = work
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
                               "TMPDIR": work.path + "/", "COPYFILE_DISABLE": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try checkCancellation()
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        while process.isRunning {
            try checkCancellation()
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.mergeFailed }
    }
}
