import Foundation

/// Whether WeChat is showing its controls to accessibility clients at all.
///
/// WeChat 4.1 decides this per account: for some it publishes the window shell
/// — the window, its three title-bar buttons, one empty group — and nothing
/// inside. Every quick forward then fails at its first step with 「没有找到唯一
/// 匹配的群聊」, which sends the user off to retype a name that was never the
/// problem. Telling the two apart needs only the first level of each window.
public enum WeChatInterfaceVisibility: Sendable, Equatable {
    case visible
    /// Windows are on screen and none of them has anything inside.
    case hidden
    /// No window to judge by — closed to the Dock, or still launching.
    case unknown

    /// One direct child of a window: its role and how many children it has.
    public struct Child: Sendable, Equatable {
        public let role: String
        public let childCount: Int

        public init(role: String, childCount: Int) {
            self.role = role
            self.childCount = childCount
        }
    }

    /// `windows` holds the direct children of each window that is not
    /// minimised. The title-bar buttons carry a child of their own even in the
    /// collapsed tree, so they are not evidence of content.
    public static func evaluate(_ windows: [[Child]]) -> Self {
        guard !windows.isEmpty else { return .unknown }
        let hasContent = windows.contains { window in
            window.contains { $0.role != "AXButton" && $0.childCount > 0 }
        }
        return hasContent ? .visible : .hidden
    }
}
