import Foundation

/// The export as one Markdown note: front matter, a heading per day, and every
/// attachment linked where its message names it. Written beside 聊天记录.txt so
/// the links are the same archive-relative paths the HTML preview uses, which
/// is what lets the unpacked folder be dropped into an Obsidian vault as it is.
enum WeChatMarkdown {
    static let fileName = "聊天记录.md"

    static func render(chat: String, batches: [WeChatHTMLPreview.Batch], exportedAt: Date = Date(),
                       timeZone: TimeZone = .current, checkCancellation: () throws -> Void = {}) throws -> String {
        let day = DateFormatter(), time = DateFormatter(), stamp = DateFormatter()
        for formatter in [day, time, stamp] {
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
        }
        day.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HH:mm"
        stamp.dateFormat = "yyyy-MM-dd HH:mm"

        var timeline: [(date: Date, order: Int, sender: String, body: [String])] = []
        var appendix: [String] = []
        for (index, batch) in batches.enumerated() {
            try checkCancellation()
            var files: [String: WeChatHTMLPreview.Attachment] = [:]
            for path in batch.paths where path != batch.transcript?.path {
                if let file = WeChatHTMLPreview.attachment(path, prefix: batch.prefix) { files[path] = file }
            }
            let attachable = Set(files.keys)
            let byName = Dictionary(grouping: files.keys, by: { ($0 as NSString).lastPathComponent })
            var used = Set<String>()
            if let records = batch.transcript?.records, !records.isEmpty {
                for record in records {
                    try checkCancellation()
                    var body: [String] = []
                    for line in record.text.components(separatedBy: "\n") {
                        if let path = WeChatAttachmentKind.attachment(in: line, paths: attachable, byName: byName)?.path, let file = files[path] {
                            body.append(link(file))
                            used.insert(path)
                        } else {
                            body.append(escape(line))
                        }
                    }
                    timeline.append((record.date, timeline.count, record.sender, body))
                }
                let unused = batch.paths.filter { !used.contains($0) }.compactMap { files[$0] }
                if !unused.isEmpty {
                    appendix.append("## 第 \(index + 1) 批 · 其他附件\n\n" + unused.map { "- " + link($0, embedding: false) }.joined(separator: "\n"))
                }
            } else {
                // A transcript whose dates cannot be read is kept word for
                // word. Indented, so nothing in it is taken for Markdown.
                var section = "## 第 \(index + 1) 批 · 原始记录（未识别时间）\n"
                if let text = batch.transcript?.body {
                    section += "\n" + text.components(separatedBy: .newlines).map { "    " + $0 }.joined(separator: "\n") + "\n"
                }
                let listed = batch.paths.compactMap { files[$0] }
                if !listed.isEmpty { section += "\n" + listed.map { "- " + link($0, embedding: false) }.joined(separator: "\n") }
                appendix.append(section)
            }
        }
        try checkCancellation()
        timeline.sort { $0.date == $1.date ? $0.order < $1.order : $0.date < $1.date }

        var lines = ["---", "title: \(quoted(chat))", "source: WeChat", "chat: \(quoted(chat))"]
        if let first = timeline.first?.date, let last = timeline.last?.date {
            lines += ["start: \(stamp.string(from: first))", "end: \(stamp.string(from: last))"]
        }
        lines += ["messages: \(timeline.count)", "exported: \(stamp.string(from: exportedAt))", "---", "", "# \(escape(chat))"]
        var currentDay = ""
        for message in timeline {
            try checkCancellation()
            let messageDay = day.string(from: message.date)
            if messageDay != currentDay {
                currentDay = messageDay
                lines += ["", "## \(messageDay)"]
            }
            lines += ["", "**\(escape(message.sender))** \(time.string(from: message.date))", ""]
            // Two trailing spaces: a message's own line breaks survive in
            // renderers that would otherwise fold them into one paragraph.
            lines += message.body.enumerated().map { index, line in
                index + 1 < message.body.count && !line.isEmpty ? line + "  " : line
            }
        }
        for section in appendix { lines += ["", section] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Images, video and audio are embedded; anything else is a link.
    private static func link(_ file: WeChatHTMLPreview.Attachment, embedding: Bool = true) -> String {
        let label = file.name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return (embedding && file.kind != "file" ? "!" : "") + "[\(label)](\(file.href))"
    }

    /// Chat text is data. Only what would change the structure of the note is
    /// escaped — a leading block marker, raw HTML, a link — so ordinary
    /// messages, URLs included, stay readable in the source.
    static func escape(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "<", with: "\\<")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "`", with: "\\`")
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        let indent = text.count - trimmed.count
        guard let first = trimmed.first else { return text }
        let rest = trimmed.dropFirst()
        let isRule = trimmed.count >= 3 && trimmed.allSatisfy { $0 == first || $0 == " " } && "-=*_".contains(first)
        let isMarker = "#>".contains(first) || ("-+*".contains(first) && (rest.first == " " || rest.isEmpty))
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        let isOrdered = !digits.isEmpty && [".", ")"].contains(trimmed.dropFirst(digits.count).first)
        if isOrdered {
            text.insert("\\", at: text.index(text.startIndex, offsetBy: indent + digits.count))
        } else if isRule || isMarker {
            text.insert("\\", at: text.index(text.startIndex, offsetBy: indent))
        }
        // Four leading spaces would make an indented code block of the line.
        return indent >= 4 ? String(text.drop { $0 == " " || $0 == "\t" }) : text
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .components(separatedBy: .newlines).joined(separator: " ") + "\""
    }
}
