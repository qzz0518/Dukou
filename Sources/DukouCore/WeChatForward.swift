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

    /// Message counts have no product limit; only the storage type bounds them.
    /// Keep the limits of legacy time presets unchanged.
    public var maximum: Int { self == .messages ? .max : (self == .days ? 30 : 720) }
}

public struct WeChatForwardRange: Codable, Hashable, Sendable {
    public var unit: WeChatRangeUnit
    public var value: Int

    public init(unit: WeChatRangeUnit = .messages, value: Int = 100) {
        self.unit = unit
        self.value = value
    }

    public var isValid: Bool { value > 0 && value <= unit.maximum }

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
    public static func digits(_ text: String, limit: Int = .max) -> String {
        var result = ""
        var digitCount = 0
        for character in text {
            guard digitCount < limit else { break }
            guard let value = character.wholeNumberValue, (0...9).contains(value) else { continue }
            digitCount += 1
            // Skip leading zeros in one pass, including for a long pasted count.
            if value != 0 || !result.isEmpty { result += String(value) }
        }
        return result.isEmpty && digitCount > 0 ? "0" : result
    }

    /// Time presets remain decodable, but must not start the unverified UI path.
    public var isAvailableForAutomation: Bool { unit == .messages && isValid }

    /// Estimate at 100 messages per 5 seconds, rounded up to a whole second.
    /// Divide before rounding so even Int.max never overflows or loses precision.
    public var estimatedSeconds: Int? {
        guard isAvailableForAutomation else { return nil }
        return value / 20 + (value % 20 == 0 ? 0 : 1)
    }

    public var estimatedTimeTitle: String? {
        guard let seconds = estimatedSeconds else { return nil }
        if seconds < 60 { return L10n.format("预计约 %@ 秒", String(seconds)) }
        if seconds < 3600 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0
                ? L10n.format("预计约 %@ 分钟", String(minutes))
                : L10n.format("预计约 %@ 分 %@ 秒", String(minutes), String(remainder))
        }
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        return minutes == 0
            ? L10n.format("预计约 %@ 小时", String(hours))
            : L10n.format("预计约 %@ 小时 %@ 分钟", String(hours), String(minutes))
    }

    public var title: String {
        switch unit {
        case .hours: L10n.format("最近 %d 小时", value)
        case .days: L10n.format("最近 %d 天", value)
        case .messages: L10n.format("最近 %@ 条消息", String(value))
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
    public var destinationFolder: URL?
    public var pastePath: Bool
    public var mergeArchives: Bool
    public var lastUsed: Date?
    public var id: String { chat }

    public init(chat: String = "", range: WeChatForwardRange = .init(), targetBundleIdentifier: String = "", targetName: String = "", destinationFolder: URL? = nil, pastePath: Bool = false, mergeArchives: Bool = false, lastUsed: Date? = nil) {
        self.chat = Self.normalizedChat(chat)
        self.range = range
        self.targetBundleIdentifier = destinationFolder == nil ? targetBundleIdentifier : ""
        self.targetName = destinationFolder == nil ? targetName : ""
        self.destinationFolder = destinationFolder
        self.pastePath = destinationFolder == nil && pastePath
        self.mergeArchives = mergeArchives
        self.lastUsed = lastUsed
    }

    private enum CodingKeys: String, CodingKey {
        case chat, range, targetBundleIdentifier, targetName, destinationFolder, pastePath, mergeArchives, lastUsed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            chat: try values.decode(String.self, forKey: .chat),
            range: try values.decode(WeChatForwardRange.self, forKey: .range),
            targetBundleIdentifier: try values.decode(String.self, forKey: .targetBundleIdentifier),
            targetName: try values.decode(String.self, forKey: .targetName),
            destinationFolder: try values.decodeIfPresent(URL.self, forKey: .destinationFolder),
            pastePath: try values.decode(Bool.self, forKey: .pastePath),
            mergeArchives: try values.decodeIfPresent(Bool.self, forKey: .mergeArchives) ?? false,
            lastUsed: try values.decodeIfPresent(Date.self, forKey: .lastUsed)
        )
    }

    /// A recommendation only: the user can still send the individual archives.
    public var recommendsMergingArchives: Bool {
        destinationFolder == nil && !mergeArchives && range.isAvailableForAutomation && range.value > 500
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
        case .invalidTranscript: L10n.text("微信导出的文件为空或无法完整读取，文件已保留。")
        case .transcriptMismatch: L10n.text("未能继续定位微信消息，已收到的文件会保留在暂存架。")
        }
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
