import Foundation
import zlib

/// Reads the original ZIP in memory, without extracting paths or launching a
/// helper. WeChat currently writes ordinary UTF-8, deflated ZIP entries. ZIP64,
/// encryption and unknown compression methods fail closed.
public enum WeChatNativeArchive {
    /// Returns the authoritative native timestamps only after every ZIP entry
    /// passes CRC and the transcript matches the actual checked messages.
    public static func records(_ data: Data, selected: [WeChatSelectedMessage], checkCancellation: () throws -> Void = {}) throws -> [WeChatTranscriptRecord] {
        try transcripts(data, checkCancellation: checkCancellation) { records, names in
            records.count == selected.count && zip(selected, records).allSatisfy { $0.matches($1, attachmentNames: names) }
        }
    }

    /// Native range selection already defines the intervening messages. Its
    /// count and observed endpoints are checked independently of navigation.
    public static func records(_ data: Data, count: Int, newest: WeChatSelectedMessage, oldest: WeChatSelectedMessage?, checkCancellation: () throws -> Void = {}) throws -> [WeChatTranscriptRecord] {
        try transcripts(data, checkCancellation: checkCancellation) { records, names in
            guard records.count == count, let first = records.first, let last = records.last,
                  newest.matches(last, attachmentNames: names) else { return false }
            return oldest?.matches(first, attachmentNames: names) ?? true
        }
    }

    private static func transcripts(_ data: Data, checkCancellation: () throws -> Void, matchesSelection: ([WeChatTranscriptRecord], [String]) -> Bool) throws -> [WeChatTranscriptRecord] {
        let entries = try directory(data)
        let attachments = entries.filter { !$0.name.hasSuffix("/") }.map { ($0.name as NSString).lastPathComponent }
        var matches: [[WeChatTranscriptRecord]] = []
        for entry in entries where !entry.name.hasSuffix("/") {
            try checkCancellation()
            let isText = entry.name.lowercased().hasSuffix(".txt")
            let body = try read(entry, from: data, collect: isText, checkCancellation: checkCancellation)
            guard isText, let text = String(data: body, encoding: .utf8), let records = try? WeChatTranscriptRecord.parse(text) else { continue }
            let names = attachments.filter { $0 != (entry.name as NSString).lastPathComponent }
            if matchesSelection(records, names),
               zip(records, records.dropFirst()).allSatisfy({ $0.date <= $1.date }) { matches.append(records) }
        }
        guard matches.count == 1, let records = matches.first else { throw WeChatReadError.transcriptMismatch }
        return records
    }

    private struct Entry {
        let name: String
        let method: Int
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
    }
    private static func number(_ data: Data, _ offset: Int, _ bytes: Int) throws -> Int {
        guard offset >= 0, offset <= data.count - bytes else { throw WeChatReadError.invalidTranscript }
        return (0..<bytes).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
    }
    private static func directory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw WeChatReadError.invalidTranscript }
        let end = try stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1).first {
            try number(data, $0, 4) == 0x06054b50 && $0 + 22 + number(data, $0 + 20, 2) == data.count
        }
        guard let end, try number(data, end + 4, 2) == 0, try number(data, end + 6, 2) == 0 else { throw WeChatReadError.invalidTranscript }
        let count = try number(data, end + 10, 2)
        let size = try number(data, end + 12, 4)
        var cursor = try number(data, end + 16, 4)
        let start = cursor
        guard (1...1000).contains(count), try number(data, end + 8, 2) == count, cursor + size == end else { throw WeChatReadError.invalidTranscript }
        var entries: [Entry] = [], seen = Set<String>(), total = 0
        for _ in 0..<count {
            guard try number(data, cursor, 4) == 0x02014b50 else { throw WeChatReadError.invalidTranscript }
            let flags = try number(data, cursor + 8, 2), method = try number(data, cursor + 10, 2)
            let nameLength = try number(data, cursor + 28, 2), extra = try number(data, cursor + 30, 2), comment = try number(data, cursor + 32, 2)
            guard flags & 1 == 0, [0, 8].contains(method), try number(data, cursor + 34, 2) == 0,
                  cursor + 46 + nameLength + extra + comment <= end else { throw WeChatReadError.invalidTranscript }
            let rawName = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = String(data: rawName, encoding: .utf8), !name.isEmpty, seen.insert(name).inserted else { throw WeChatReadError.invalidTranscript }
            let entry = Entry(name: name, method: method, crc: UInt32(try number(data, cursor + 16, 4)),
                              compressed: try number(data, cursor + 20, 4), expanded: try number(data, cursor + 24, 4), offset: try number(data, cursor + 42, 4))
            total += entry.expanded
            guard total <= 1_073_741_824, entry.offset < start else { throw WeChatReadError.invalidTranscript }
            entries.append(entry)
            cursor += 46 + nameLength + extra + comment
        }
        guard cursor == end else { throw WeChatReadError.invalidTranscript }
        return entries
    }
    private static func read(_ entry: Entry, from data: Data, collect: Bool, checkCancellation: () throws -> Void) throws -> Data {
        guard !collect || entry.expanded <= 16_777_216,
              try number(data, entry.offset, 4) == 0x04034b50,
              try number(data, entry.offset + 8, 2) == entry.method else { throw WeChatReadError.invalidTranscript }
        let start = try entry.offset + 30 + number(data, entry.offset + 26, 2) + number(data, entry.offset + 28, 2)
        guard start <= data.count, entry.compressed <= data.count - start else { throw WeChatReadError.invalidTranscript }
        var result = Data(), crc = crc32(0, nil, 0), expanded = 0
        if collect { result.reserveCapacity(entry.expanded) }
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            let source = input.bindMemory(to: Bytef.self).baseAddress!.advanced(by: start)
            if entry.method == 0 {
                guard entry.expanded == entry.compressed else { throw WeChatReadError.invalidTranscript }
                for offset in stride(from: 0, to: entry.compressed, by: 65_536) {
                    try checkCancellation()
                    let count = min(65_536, entry.compressed - offset)
                    crc = crc32(crc, source.advanced(by: offset), uInt(count))
                    if collect { result.append(source.advanced(by: offset), count: count) }
                }
                expanded = entry.compressed
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw WeChatReadError.invalidTranscript }
                defer { inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: source)
                stream.avail_in = uInt(entry.compressed)
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var status: Int32 = Z_OK
                repeat {
                    try checkCancellation()
                    let produced: Int = buffer.withUnsafeMutableBufferPointer { output in
                        stream.next_out = output.baseAddress!
                        stream.avail_out = uInt(output.count)
                        status = inflate(&stream, Z_NO_FLUSH)
                        let count = output.count - Int(stream.avail_out)
                        crc = crc32(crc, output.baseAddress!, uInt(count))
                        if collect { result.append(output.baseAddress!, count: count) }
                        return count
                    }
                    expanded += produced
                    guard expanded <= entry.expanded, status == Z_OK || status == Z_STREAM_END,
                          produced > 0 || status == Z_STREAM_END else { throw WeChatReadError.invalidTranscript }
                } while status != Z_STREAM_END
                guard stream.avail_in == 0 else { throw WeChatReadError.invalidTranscript }
            }
        }
        guard expanded == entry.expanded, UInt32(crc) == entry.crc else { throw WeChatReadError.invalidTranscript }
        return result
    }
}
