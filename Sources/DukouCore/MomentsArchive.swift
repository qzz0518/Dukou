import Darwin
import Foundation

public struct MomentsRecord: Sendable {
    public let author: String
    public let timestamp: String
    public let text: String
    public var attachments: [String]
    public var notes: [String]

    public init(author: String, timestamp: String, text: String, attachments: [String] = [], notes: [String] = []) {
        self.author = author
        self.timestamp = timestamp
        self.text = text
        self.attachments = attachments
        self.notes = notes
    }
}

public enum MomentsArchive {
    public enum Failure: Error, LocalizedError, Equatable {
        case invalidRecordCount, unsafeMedia, mediaUnavailable, archiveFailed

        public var errorDescription: String? {
            switch self {
            case .invalidRecordCount: L10n.text("请至少选择 1 条朋友圈。")
            case .unsafeMedia: L10n.text("朋友圈媒体文件名或文件类型不安全，未生成 ZIP。")
            case .mediaUnavailable: L10n.text("朋友圈引用的媒体无法完整读取，未生成 ZIP。")
            case .archiveFailed: L10n.text("朋友圈 ZIP 打包失败，请重试。")
            }
        }
    }

    private static let chunkSize = 65_536
    private static let transcriptName = "朋友圈.txt"

    /// Records arrive newest first; their original time labels are never
    /// rewritten or used to sort the transcript. The TXT starts with the
    /// generation time and its time-zone offset, providing context for WeChat's
    /// relative labels without inferring record dates. Only explicitly
    /// referenced, regular media files are copied.
    /// Run off the main thread. Cancellation is checked during text/media I/O,
    /// while the ZIP helper runs, and immediately before the atomic commit.
    /// Once committed, success is returned without another cancellation check.
    public static func create(
        records: [MomentsRecord],
        mediaDirectory: URL,
        in inbox: Inbox,
        exportedAt: Date = Date(),
        timeZone: TimeZone = .current,
        checkCancellation: () throws -> Void = {}
    ) throws -> URL {
        try checkCancellation()
        guard !records.isEmpty else { throw Failure.invalidRecordCount }
        let generatedAt = exportedAt
        let archiveName = displayName(for: records, exportedAt: generatedAt, timeZone: timeZone)
        let names = try referencedNames(in: records, checkCancellation: checkCancellation)
        let staging = try makeStaging(in: inbox)
        // After commit the old path no longer exists. Never remove from Ready.
        defer { staging.discard() }

        let manager = FileManager.default
        let work = staging.directory.appendingPathComponent("archive-work", isDirectory: true)
        let payload = work.appendingPathComponent("payload", isDirectory: true)
        try manager.createDirectory(at: payload, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeTranscript(records, generatedAt: generatedAt, timeZone: timeZone, to: payload.appendingPathComponent(transcriptName), checkCancellation: checkCancellation)

        if !names.isEmpty {
            let source = try openMediaDirectory(mediaDirectory)
            defer { Darwin.close(source) }
            let media = payload.appendingPathComponent("media", isDirectory: true)
            try manager.createDirectory(at: media, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in names {
                try checkCancellation()
                try copyMedia(name, from: source, to: media.appendingPathComponent(name), checkCancellation: checkCancellation)
            }
        }

        let itemID = UUID()
        let archive = try staging.destination(for: itemID, displayName: archiveName)
        try compress(payload, hasMedia: !names.isEmpty, to: archive, temporaryDirectory: work, checkCancellation: checkCancellation)
        let attributes = try manager.attributesOfItem(atPath: archive.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else { throw Failure.archiveFailed }
        // The published batch contains just the ZIP and the inbox protocol files.
        try manager.removeItem(at: work)
        let item = ManifestItem(
            id: itemID, displayName: archiveName,
            relativePath: staging.relativePath(for: itemID, displayName: archiveName),
            contentType: "public.zip-archive", byteCount: bytes.int64Value,
            itemIndex: 0, attachmentIndex: 0, loadStrategy: .fileURL
        )
        let manifest = BatchManifest(batchID: staging.batchID, createdAt: generatedAt, items: [item], action: .shelf)
        try checkCancellation()
        return try staging.commit(manifest: manifest, diagnostics: nil, intent: nil, in: inbox)
    }

    /// A name can be previewed independently of ZIP creation. Only explicit
    /// year/month/day/hour/minute labels can supply an actual content range;
    /// relative or date-only labels never acquire an inferred year or minute.
    public static func displayName(
        for records: [MomentsRecord],
        exportedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let author = records.first?.author ?? ""
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleAuthor = !trimmedAuthor.isEmpty && records.allSatisfy { $0.author == author }
        let source = singleAuthor ? "\(trimmedAuthor)的朋友圈" : "朋友圈"
        let dates = records.compactMap { absoluteTimestamp($0.timestamp, timeZone: timeZone) }
        let completeRange = dates.count == records.count
        return ForwardArchiveName.make(
            source: source, count: records.count,
            start: completeRange ? dates.min() : nil,
            end: completeRange ? dates.max() : nil,
            exportedAt: exportedAt, timeZone: timeZone
        )
    }

    private static func absoluteTimestamp(_ label: String, timeZone: TimeZone) -> Date? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept only whole labels, with an explicit year and minute. A strict
        // calendar round trip rejects impossible dates and DST clock gaps.
        let patterns = [
            #"^([0-9]{4})年([0-9]{1,2})月([0-9]{1,2})日[ \t]+([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?$"#,
            #"^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})[ T]([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}))?$"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            func number(_ group: Int) -> Int? {
                guard let range = Range(match.range(at: group), in: text) else { return nil }
                return Int(text[range])
            }
            guard let year = number(1), let month = number(2), let day = number(3),
                  let hour = number(4), let minute = number(5), year > 0,
                  (1...12).contains(month), (1...31).contains(day),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            let second = number(6) ?? 0
            guard (0...59).contains(second) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
            guard let date = calendar.date(from: components) else { return nil }
            let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            guard actual.year == year, actual.month == month, actual.day == day,
                  actual.hour == hour, actual.minute == minute, actual.second == second else { return nil }
            // A clock repeated at a DST transition has two possible instants.
            // Without an offset in the source label, neither can be assumed.
            let beforeDay = calendar.startOfDay(for: date).addingTimeInterval(-1)
            let clock = DateComponents(hour: hour, minute: minute, second: second)
            let first = calendar.nextDate(after: beforeDay, matching: clock, matchingPolicy: .strict, repeatedTimePolicy: .first)
            let last = calendar.nextDate(after: beforeDay, matching: clock, matchingPolicy: .strict, repeatedTimePolicy: .last)
            guard let first, let last, first == last else { return nil }
            return date
        }
        return nil
    }

    private static func makeStaging(in inbox: Inbox) throws -> BatchStaging {
        let id = UUID()
        do {
            return try BatchStaging.create(in: inbox, batchID: id)
        } catch {
            // createDirectory can fail after creating part of the tree.
            let partial = inbox.staging.appendingPathComponent("\(id.uuidString).\(BatchStaging.partialSuffix)")
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func referencedNames(in records: [MomentsRecord], checkCancellation: () throws -> Void) throws -> [String] {
        var names: [String] = []
        var seen: [String: String] = [:]
        for record in records {
            for name in record.attachments {
                try checkCancellation()
                try validateName(name)
                // Refuse aliases that would collide on common receiving file
                // systems. Exact repeated references share one ZIP entry.
                let key = name.precomposedStringWithCanonicalMapping.lowercased()
                if let previous = seen[key] {
                    guard previous.utf8.elementsEqual(name.utf8) else { throw Failure.unsafeMedia }
                } else {
                    seen[key] = name
                    names.append(name)
                }
            }
        }
        return names
    }

    private static func validateName(_ name: String) throws {
        let forbidden = CharacterSet(charactersIn: "/\\:<>\"|?*%")
        guard !name.isEmpty, name.utf8.count <= 255,
              !name.hasPrefix("."), !name.hasSuffix("."),
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: {
                  forbidden.contains($0) || [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
              }) else { throw Failure.unsafeMedia }
        let base = name.split(separator: ".", maxSplits: 1)[0].uppercased()
        let devices = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        guard !devices.contains(base) else { throw Failure.unsafeMedia }
    }

    private static func openMediaDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.utf8.contains(0),
              url.host == nil || url.host == "" || url.host == "localhost" else { throw Failure.unsafeMedia }
        var path = url.path
        // Foundation returns /var for NSTemporaryDirectory even when resolving
        // symlinks. Accept only Apple's known root aliases, after checking the
        // actual link; every user-controlled path component must be link-free.
        for alias in ["var", "tmp", "etc"] where path.hasPrefix("/\(alias)/") {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/\(alias)") {
                guard target == "private/\(alias)" || target == "/private/\(alias)" else { throw Failure.unsafeMedia }
                path = "/private" + path
            }
        }
        // Pin the directory, so replacing/renaming it during a copy cannot
        // redirect subsequent leaf lookups. Refuse symlinks in its ancestry too.
        let descriptor = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafeMedia }
        return descriptor
    }

    private static func copyMedia(_ name: String, from directory: Int32, to destination: URL, checkCancellation: () throws -> Void) throws {
        // O_NONBLOCK prevents a substituted FIFO from blocking before fstat.
        // Validation and reads use this descriptor, never a second path open.
        let descriptor = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ELOOP ? Failure.unsafeMedia : Failure.mediaUnavailable
        }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else { throw Failure.mediaUnavailable }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw Failure.unsafeMedia }
        let output = try newFile(at: destination)
        defer { try? output.close() }

        // Bound the read by the original size: an actively growing file cannot
        // keep the export running forever. Reject a changing/truncated source.
        var remaining = before.st_size
        while remaining > 0 {
            try checkCancellation()
            guard let data = try input.read(upToCount: Int(min(Int64(chunkSize), remaining))), !data.isEmpty else {
                throw Failure.mediaUnavailable
            }
            try output.write(contentsOf: data)
            remaining -= Int64(data.count)
        }
        try checkCancellation()
        let extra = try input.read(upToCount: 1)
        var after = stat()
        guard extra?.isEmpty != false, Darwin.fstat(descriptor, &after) == 0,
              before.st_size == after.st_size, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.mediaUnavailable }
        try output.close()
    }

    private static func newFile(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.archiveFailed }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func writeTranscript(_ records: [MomentsRecord], generatedAt: Date, timeZone: TimeZone, to url: URL, checkCancellation: () throws -> Void) throws {
        let output = try newFile(at: url)
        defer { try? output.close() }
        func write(_ text: String) throws {
            let bytes = text.utf8
            var start = bytes.startIndex
            while start != bytes.endIndex {
                try checkCancellation()
                let end = bytes.index(start, offsetBy: chunkSize, limitedBy: bytes.endIndex) ?? bytes.endIndex
                try output.write(contentsOf: Data(bytes[start..<end]))
                start = end
            }
        }
        // Fixed Chinese field labels are part of the archive format, like its
        // required Chinese filename. User text/time labels are preserved as-is.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        try write("生成时间：\(formatter.string(from: generatedAt))\n")
        try write("时间说明：记录的原始时间按微信显示保留，未推算为绝对时间。\n\n")
        for (index, record) in records.reversed().enumerated() {
            try checkCancellation()
            try write("[\(index + 1)]\n作者：")
            try write(record.author)
            try write("\n原始时间：")
            try write(record.timestamp)
            try write("\n正文：\n")
            try write(record.text)
            try write("\n媒体：\n")
            if record.attachments.isEmpty { try write("无\n") }
            for name in record.attachments { try write("media/\(name)\n") }
            try write("说明：\n")
            if record.notes.isEmpty { try write("无\n") }
            for note in record.notes {
                try write(note)
                try write("\n")
            }
            try write("\n")
        }
        try output.close()
    }

    private static func compress(_ payload: URL, hasMedia: Bool, to archive: URL, temporaryDirectory: URL, checkCancellation: () throws -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // macOS bsdtar/libarchive supports streaming ZIP/ZIP64 and marks UTF-8
        // names explicitly. ditto writes UTF-8 bytes without that flag, which
        // breaks the TXT's references in ZIP readers that default to CP437.
        process.arguments = [
            "-c", "--format=zip", "--options=zip:hdrcharset=UTF-8", "-f", archive.path,
            "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags",
            "--uid", "0", "--gid", "0", "--uname", "", "--gname", "",
            "-C", payload.path, "--", transcriptName,
        ] + (hasMedia ? ["media"] : [])
        process.currentDirectoryURL = temporaryDirectory
        process.environment = [
            "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            "TMPDIR": temporaryDirectory.path + "/", "COPYFILE_DISABLE": "1",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try checkCancellation()
        do { try process.run() } catch { throw Failure.archiveFailed }
        defer {
            if process.isRunning {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            // Reap the helper before discard can remove files it is writing.
            process.waitUntilExit()
        }
        while process.isRunning {
            try checkCancellation()
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try checkCancellation()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.archiveFailed }
    }
}
