import Foundation

public enum WeChatRangeUnit: String, Codable, CaseIterable, Sendable {
    case hours, days, messages

    public var title: String {
        switch self {
        case .hours: L10n.text("小时")
        case .days: L10n.text("天")
        case .messages: L10n.text("条消息")
        }
    }

    public var maximum: Int { self == .messages ? 2000 : (self == .days ? 30 : 720) }
}

public struct WeChatForwardRange: Codable, Hashable, Sendable {
    public var unit: WeChatRangeUnit
    public var value: Int

    public init(unit: WeChatRangeUnit = .messages, value: Int = 100) {
        self.unit = unit
        self.value = value
    }

    public var isValid: Bool { (1...unit.maximum).contains(value) }

    /// What the amount field may hold, filtered as it is typed.
    ///
    /// A `TextField(value:format:)` is free text until it loses focus, so
    /// whatever the input method offers can sit in it — "②00" arrived from a
    /// Chinese IME offering a circled numeral. Digits in any script are folded
    /// to ASCII rather than dropped, so ②00, ２００ and 二00 all read as 200;
    /// everything else is refused at the keystroke.
    ///
    /// The range itself is not enforced here. A number outside it is still a
    /// number the field should show while the form says what is wrong with it.
    public static func digits(_ text: String, limit: Int = 6) -> String {
        var result = ""
        for character in text {
            guard result.count < limit, let value = character.wholeNumberValue, (0...9).contains(value) else { continue }
            result += String(value)
        }
        while result.count > 1, result.hasPrefix("0") { result.removeFirst() }
        return result
    }
    /// Time presets remain decodable, but must not start the unverified UI path.
    public var isAvailableForAutomation: Bool { unit == .messages && isValid }

    public var title: String {
        switch unit {
        case .hours: L10n.format("最近 %d 小时", value)
        case .days: L10n.format("最近 %d 天", value)
        case .messages: L10n.format("最近 %d 条消息", value)
        }
    }

    /// WeChat's accessible timestamps contain minutes, not seconds. Rounding
    /// is explicit and shared by the collector and archive comparison.
    public func start(at end: Date) -> Date? {
        guard unit != .messages else { return nil }
        let seconds = Double(value) * (unit == .days ? 86_400 : 3600)
        return Date(timeIntervalSince1970: floor((end.timeIntervalSince1970 - seconds) / 60) * 60)
    }

    /// Native TXT supplies the time boundary. Preserve repeated messages and
    /// reject future/non-chronological records rather than guessing at UI dates.
    public func excludedPrefix(in records: [WeChatTranscriptRecord], at end: Date) throws -> Int {
        guard isValid, zip(records, records.dropFirst()).allSatisfy({ $0.date <= $1.date }) else { throw WeChatReadError.transcriptMismatch }
        guard let cutoff = start(at: end) else { return 0 }
        let endMinute = floor(end.timeIntervalSince1970 / 60) * 60
        guard records.allSatisfy({ $0.date.timeIntervalSince1970 <= endMinute }) else { throw WeChatReadError.transcriptMismatch }
        return records.prefix { $0.date < cutoff }.count
    }

}

public struct WeChatForwardPreset: Codable, Hashable, Identifiable, Sendable {
    public var chat: String
    public var range: WeChatForwardRange
    public var targetBundleIdentifier: String
    public var targetName: String
    public var pastePath: Bool
    public var lastUsed: Date?
    public var id: String { chat }

    public init(chat: String = "", range: WeChatForwardRange = .init(), targetBundleIdentifier: String = "", targetName: String = "", pastePath: Bool = false, lastUsed: Date? = nil) {
        self.chat = Self.normalizedChat(chat)
        self.range = range
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetName = targetName
        self.pastePath = pastePath
        self.lastUsed = lastUsed
    }

    public static func normalizedChat(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s*[（(]\d+[)）]\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct WeChatForwardPreferences: Codable, Sendable {
    public var draft: WeChatForwardPreset = .init()
    public var recent: [WeChatForwardPreset] = []
    public init() {}

    public mutating func recordSuccess(_ preset: WeChatForwardPreset, at date: Date = Date()) {
        var saved = preset
        saved.chat = WeChatForwardPreset.normalizedChat(saved.chat)
        saved.lastUsed = date
        recent.removeAll { $0.chat == saved.chat }
        recent.insert(saved, at: 0)
        recent = Array(recent.prefix(12))
        draft = saved
    }

    public static func decode(_ data: Data?) -> Self {
        guard let data, let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var result = decoded
        if !result.draft.range.isValid { result.draft.range = .init() }
        var seen = Set<String>()
        result.recent = Array(result.recent.filter { !$0.chat.isEmpty && $0.range.isValid && seen.insert($0.chat).inserted }.prefix(12))
        return result
    }
}

public enum WeChatReadError: Error, LocalizedError {
    case invalidTranscript, transcriptMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidTranscript: L10n.text("无法识别微信导出的聊天记录格式，文件已保留。")
        case .transcriptMismatch: L10n.text("导出记录与所选消息不一致，已停止自动粘贴，文件已保留。")
        }
    }
}

/// The checkbox's accessible description contains sender and body, even for
/// identical adjacent messages. Selection state, rather than array indices,
/// is the cursor while the virtual list scrolls.
public struct WeChatSelectedMessage: Equatable, Sendable {
    public let description: String
    public init(description: String) {
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func matches(_ record: WeChatTranscriptRecord, attachmentNames: [String]) -> Bool {
        // AX uses the group display name, whereas exported TXT can use the
        // account nickname. Neither is a stable user ID. Verify exact body,
        // count and physical checked order without inventing a name mapping.
        func hasBody(_ value: String, _ body: String) -> Bool { value == body || value.hasSuffix(" " + body) }
        if hasBody(description, record.text) { return true }
        // AX includes the quoted preview; WeChat's native transcript keeps the
        // reply body. Only this explicit AX suffix is ignored, not arbitrary
        // truncation or fuzzy text matching.
        if let quote = description.range(of: "\n引用 "), hasBody(String(description[..<quote.lowerBound]), record.text) { return true }
        guard let kind = ["图片", "视频", "文件", "语音", "动画表情", "表情"].first(where: { hasBody(description, $0) || hasBody(description, "[\($0)]") }) else { return false }
        // Native WeChat exports some non-file message types as placeholders.
        // Accept that exact representation without claiming an attachment.
        if ["语音", "动画表情", "表情"].contains(kind), record.text == "[\(kind)]" { return true }
        return !record.text.isEmpty && attachmentNames.contains { record.text.contains($0) }
    }
}

public struct WeChatTranscriptRecord: Equatable, Sendable {
    public let sender: String
    public let date: Date
    public let text: String

    public static func parse(_ body: String, timeZone: TimeZone = .current) throws -> [Self] {
        let body = body.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        let regex = try NSRegularExpression(pattern: #"(?m)^·([^\n]+)\n(\d{4}年\d{1,2}月\d{1,2}日 \d{2}:\d{2})\n"#)
        let matches = regex.matches(in: body, range: NSRange(body.startIndex..., in: body))
        guard matches.first?.range.location == 0 else { throw WeChatReadError.invalidTranscript }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        let source = body as NSString
        return try matches.enumerated().map { index, match in
            guard let date = formatter.date(from: source.substring(with: match.range(at: 2))) else { throw WeChatReadError.invalidTranscript }
            let start = NSMaxRange(match.range)
            let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            return Self(sender: source.substring(with: match.range(at: 1)), date: date,
                        text: source.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

}
