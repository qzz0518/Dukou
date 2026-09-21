import Foundation

/// What Dukou remembers about one WeChat conversation between forwards.
public struct ChatMemory: Codable, Hashable, Sendable {
    /// The prompt this chat uses instead of the selected one. Nil follows the
    /// selection, which is every chat the user never chose anything for.
    public var promptID: UUID?
    /// Per prompt, the time of the last message that prompt has been pasted
    /// with. Per prompt because a summary and a translation of the same group
    /// are two different jobs: having summarised up to 14:32 says nothing about
    /// how far the translation got.
    public var cursors: [String: Date]
    public var updatedAt: Date

    public init(promptID: UUID? = nil, cursors: [String: Date] = [:], updatedAt: Date = Date()) {
        self.promptID = promptID
        self.cursors = cursors
        self.updatedAt = updatedAt
    }
}

/// Every remembered chat, keyed the way a quick forward already names them.
/// Persisted as one JSON blob.
public struct ChatMemories: Codable, Hashable, Sendable {
    /// Enough for every group anyone forwards from regularly. Past it the chat
    /// touched longest ago is forgotten, so the blob cannot grow for ever.
    public static let limit = 200

    public private(set) var chats: [String: ChatMemory]

    public init(chats: [String: ChatMemory] = [:]) {
        self.chats = chats
    }

    public static func key(_ chat: String) -> String {
        WeChatForwardPreset.normalizedChat(chat)
    }

    public func promptID(for chat: String) -> UUID? {
        chats[Self.key(chat)]?.promptID
    }

    /// Nil goes back to following the selection.
    public mutating func setPrompt(_ id: UUID?, for chat: String, at date: Date = Date()) {
        let key = Self.key(chat)
        guard !key.isEmpty else { return }
        var memory = chats[key] ?? ChatMemory()
        memory.promptID = id
        memory.updatedAt = date
        store(memory, for: key)
    }

    public func cursor(for chat: String, prompt: UUID) -> Date? {
        chats[Self.key(chat)]?.cursors[prompt.uuidString]
    }

    /// Only ever moves forward: sending last week's export again must not make
    /// the next one repeat everything since.
    public mutating func advance(_ chat: String, prompt: UUID, to end: Date, at date: Date = Date()) {
        let key = Self.key(chat)
        guard !key.isEmpty else { return }
        var memory = chats[key] ?? ChatMemory()
        memory.cursors[prompt.uuidString] = max(memory.cursors[prompt.uuidString] ?? end, end)
        memory.updatedAt = date
        store(memory, for: key)
    }

    /// A deleted prompt takes its overrides and cursors with it.
    public mutating func forget(prompt id: UUID) {
        for key in chats.keys {
            if chats[key]?.promptID == id { chats[key]?.promptID = nil }
            chats[key]?.cursors[id.uuidString] = nil
        }
        chats = chats.filter { $0.value.promptID != nil || !$0.value.cursors.isEmpty }
    }

    private mutating func store(_ memory: ChatMemory, for key: String) {
        chats[key] = memory
        guard chats.count > Self.limit else { return }
        for stale in chats.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(chats.count - Self.limit) {
            chats[stale.key] = nil
        }
    }
}

/// The sentence added to a prompt when part of this export has been through
/// the same prompt before.
public enum ResumeNote {
    /// Nil unless the export straddles the cursor. One that starts after it
    /// repeats nothing; one that ends at or before it is the user sending the
    /// same messages again on purpose, and telling the agent to skip all of
    /// them would leave it nothing to do.
    public static func text(
        cursor: Date,
        start: Date,
        end: Date,
        timeZone: TimeZone = .current
    ) -> String? {
        guard start <= cursor, cursor < end else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return L10n.format("只处理 %@ 之后的新消息；更早的内容上次已经处理过，仅作上下文。", formatter.string(from: cursor))
    }
}
