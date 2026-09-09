import Foundation

/// The account section is the source of the nickname, not a message, quote or
/// contact name. Only the observed section shape is accepted; unknown layouts
/// leave the offline reader's manual sender selector available.
public enum WeChatAccountIdentity {
    public struct Field: Sendable {
        public let role: String
        public let text: String
        public init(role: String, text: String) { self.role = role; self.text = text }
    }

    public static func nickname(in fields: [Field]) -> String? {
        let headings = ["账号", "帳號", "Account"]
        let logout = ["退出登录", "登出", "Log Out", "Log out"]
        var candidates: [String] = []
        for start in fields.indices where fields[start].role == "AXStaticText" && headings.contains(fields[start].text) {
            // macOS WeChat 4.1: heading, unlabeled avatar button, nickname,
            // WeChat ID, Log Out. Reading the ID only validates this boundary;
            // it is never returned, persisted or embedded in the exported HTML.
            guard start + 4 < fields.count else { continue }
            let avatar = fields[start + 1], name = fields[start + 2], account = fields[start + 3], end = fields[start + 4]
            guard avatar.role == "AXButton", avatar.text.isEmpty,
                  name.role == "AXStaticText", account.role == "AXStaticText",
                  end.role == "AXButton", logout.contains(end.text),
                  !name.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !name.text.contains("\n"), !name.text.contains("\r"),
                  !account.text.isEmpty, account.text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { continue }
            // Keep spaces and punctuation in the nickname for exact matching
            // against the original transcript.
            candidates.append(name.text)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
