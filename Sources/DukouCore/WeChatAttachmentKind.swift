import Foundation

/// Whether an attachment in WeChat's merged-forward ZIP is an image, a video or
/// anything else. Only images and videos can be left out of a quick forward;
/// files, voice, stickers and cards count as text and always stay.
enum WeChatAttachmentKind {
    case image, video, other

    /// The attachment a transcript line names, with the kind its marker gives
    /// it: `[文件] photo.png` was sent as a file, not as an image. WeChat's TXT
    /// gives a basename after the marker while the ZIP keeps the file in
    /// 聊天记录内的图片、视频和文件/. Never choose an ambiguous match.
    static func attachment(in line: String, paths: Set<String>, byName: [String: [String]]) -> (path: String, marked: Self?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var reference = trimmed
        var marked: Self?
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]"), let kind = markers[trimmed[...close].lowercased()] {
            let rest = trimmed[trimmed.index(after: close)...].drop { $0 == " " || $0 == "\t" }
            if !rest.isEmpty { reference = String(rest); marked = kind }
        }
        if reference.hasPrefix("./") { reference.removeFirst(2) }
        if paths.contains(reference) { return (reference, marked) }
        guard !reference.contains("/"), let candidates = byName[reference], candidates.count == 1 else { return nil }
        return (candidates[0], marked)
    }

    /// For a file no marker names.
    static func of(path: String) -> Self {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "heic": .image
        case "mp4", "m4v", "mov", "webm", "ogv": .video
        default: .other
        }
    }

    /// The attachment markers WeChat 4.1.13 writes in Simplified, Traditional
    /// and English, matched as a whole token so `[视频号]` is not `[视频]`.
    private static let markers: [String: Self] = {
        let groups: [(Self, [String])] = [
            (.image, ["图片", "圖片", "photo", "image"]),
            (.video, ["视频", "小视频", "影片", "微影片", "video"]),
            (.other, ["文件", "檔案", "file", "语音", "語音", "录音", "錄音", "音频", "音訊", "voice", "audio", "recording",
                      "表情", "动画表情", "動態貼圖", "sticker"]),
        ]
        var result: [String: Self] = [:]
        for (kind, names) in groups { for name in names { result["[\(name)]"] = kind } }
        return result
    }()
}
