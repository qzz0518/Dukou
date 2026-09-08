import Foundation

/// WeChat 4.1.13 exposes this popover, but not the ad badge in the AX row.
/// Require both native controls; a post merely mentioning ads is not evidence.
public enum MomentsAdvertisementMenu {
    public static let notice = "赞助商提供的广告信息"

    public static func matches(staticTexts: [String], buttonLabels: [String]) -> Bool {
        staticTexts.contains(notice) && buttonLabels.contains("关闭该广告")
    }
}

public struct MomentsForwardPreset: Codable, Sendable {
    public var count = 20
    public var saveImages = false
    public var saveVideos = false
    public var targetBundleIdentifier = ""
    public var targetName = ""
    public var destinationFolder: URL?
    public var pastePath = false

    public init() {}
    public var isValid: Bool { count > 0 }

    public static func decode(_ data: Data?) -> Self {
        guard let data, var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if !value.isValid { value.count = 20 }
        if value.destinationFolder != nil { value.pastePath = false }
        return value
    }
}

/// A Moments AX row has a complete body, but flattens the author's name and
/// body into one string. The caller supplies the name read from the profile;
/// splitting at the first space would attribute posts to the wrong person.
public struct MomentsContent: Sendable, Equatable {
    public let text: String
    public let timestamp: String
    public let imageCount: Int
    public let isVideo: Bool

    private static let timePattern = #"(?:\d{4}年)?\d{1,2}月\d{1,2}日(?:\s+\d{1,2}:\d{2})?|(?:昨天|前天)(?:\s+\d{1,2}:\d{2})?|\d+\s*(?:分钟|小时|天)前|刚刚|\d+\s*(?:minutes?|hours?|days?)\s+ago|Just now|Yesterday(?:\s+\d{1,2}:\d{2})?"#
    // These immutable expressions are shared by all parses and identity reads.
    private static let timeRegex = try? NSRegularExpression(pattern: timePattern, options: .caseInsensitive)
    private static let imageRegex = try? NSRegularExpression(pattern: #"包含\d+张图片|(?:Contains?\s+)?\d+\s+photos?"#, options: .caseInsensitive)
    private static let videoRegex = try? NSRegularExpression(pattern: #"(?:^|\s)(?:视频|Video)(?=\s|$)"#, options: .caseInsensitive)

    public static func parse(_ label: String, author: String) -> Self? {
        guard !author.isEmpty, label.hasPrefix(author + " ") else { return nil }
        let remainder = String(label.dropFirst(author.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let time = matches(timeRegex, in: remainder).last
        let timestamp = time.map { String(remainder[$0]) } ?? ""
        var body = time.map { String(remainder[..<$0.lowerBound]) } ?? remainder
        let source = time.map { String(remainder[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let imageMatch = matches(imageRegex, in: body).last
        var count = 0
        if let imageMatch {
            count = Int(String(body[imageMatch]).filter(\.isNumber)) ?? 0
        }
        // AX flattens media/location labels into the body. Keep those tokens
        // in the transcript too: identical words may be part of the author's
        // actual text, so removing a regex match would silently lose content.
        let videoMatch = matches(videoRegex, in: body).last
        let isVideo = count == 0 && videoMatch != nil
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty { body += (body.isEmpty ? "" : "\n") + source }
        return Self(text: body, timestamp: timestamp, imageCount: count, isVideo: isVideo)
    }

    /// Relative time ticks while a long media export is running. It is not an
    /// identity change. Child positions, not body text, distinguish duplicates.
    public static func identity(_ label: String) -> String {
        guard let time = matches(timeRegex, in: label).last else { return label }
        var result = label
        result.removeSubrange(time)
        return result
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> [Range<String.Index>] {
        guard let regex else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
}
