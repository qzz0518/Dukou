import Foundation

/// A short instruction pasted along with the files, so the agent on the other
/// end knows what it is looking at without the user typing it every time.
///
/// No name: three prompts of two lines each are told apart by reading them,
/// and a name field only asks the user to write the same thing twice.
public struct AttachedPrompt: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// The two places a prompt can be attached. Each has its own switch; the
/// library and the selection are shared, because a user with one favourite
/// prompt should not have to keep it in two places.
public enum PromptSurface: Sendable {
    /// 发给 Codex / Claude / 自定义 — from the Share menu, the shelf or 记录.
    case forward
    /// 快捷微信转发.
    case wechat
}

/// The prompt library and how it is used. Persisted as one JSON blob.
public struct PromptSettings: Codable, Hashable, Sendable {
    /// Three is enough to switch between a summary, a translation and one of
    /// the user's own without the list becoming a second settings pane.
    public static let maximumPrompts = 3

    public var prompts: [AttachedPrompt]
    public var selectedID: UUID?
    public var attachToForwards: Bool
    public var attachToWeChat: Bool

    public init(
        prompts: [AttachedPrompt],
        selectedID: UUID? = nil,
        attachToForwards: Bool = false,
        attachToWeChat: Bool = false
    ) {
        self.prompts = prompts
        self.selectedID = selectedID
        self.attachToForwards = attachToForwards
        self.attachToWeChat = attachToWeChat
        normalize()
    }

    /// One prompt, selected, both switches off: the text is ready the moment
    /// the user turns a switch on, and nothing changes for a user who never
    /// does.
    public static func makeDefault(text: String) -> PromptSettings {
        let prompt = AttachedPrompt(text: text)
        return PromptSettings(prompts: [prompt], selectedID: prompt.id)
    }

    /// A stored blob written by any build stays usable: the list is clamped
    /// and the selection always points at a prompt that exists. Keys an older
    /// build wrote — `position`, and a `title` on each prompt — are simply not
    /// read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prompts = try container.decodeIfPresent([AttachedPrompt].self, forKey: .prompts) ?? []
        selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedID)
        attachToForwards = try container.decodeIfPresent(Bool.self, forKey: .attachToForwards) ?? false
        attachToWeChat = try container.decodeIfPresent(Bool.self, forKey: .attachToWeChat) ?? false
        normalize()
    }

    public var selected: AttachedPrompt? {
        prompts.first { $0.id == selectedID }
    }

    public var canAdd: Bool { prompts.count < Self.maximumPrompts }

    /// The prompt to paste on this surface, or nil when the switch is off,
    /// nothing is selected, or the selected prompt is blank.
    public func attachment(for surface: PromptSurface) -> AttachedPrompt? {
        let enabled: Bool
        switch surface {
        case .forward: enabled = attachToForwards
        case .wechat: enabled = attachToWeChat
        }
        guard enabled, let prompt = selected else { return nil }
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : prompt
    }

    /// Appends and selects it — a prompt the user just wrote is the one they
    /// are about to use. Returns false when the library is full.
    @discardableResult
    public mutating func add(_ prompt: AttachedPrompt) -> Bool {
        guard canAdd else { return false }
        prompts.append(prompt)
        selectedID = prompt.id
        return true
    }

    public mutating func remove(id: UUID) {
        prompts.removeAll { $0.id == id }
        normalize()
    }

    private mutating func normalize() {
        if prompts.count > Self.maximumPrompts {
            prompts = Array(prompts.prefix(Self.maximumPrompts))
        }
        if !prompts.contains(where: { $0.id == selectedID }) {
            selectedID = prompts.first?.id
        }
    }
}

/// One thing the pasteboard holds for one ⌘V.
public enum PastePayload: Hashable, Sendable {
    case files([URL])
    case text(String)
}

/// What a forward pastes, in the order it pastes it.
///
/// A prompt and a file cannot share one ⌘V: a pasteboard that offers both
/// text and file URLs makes the target pick, and a chat app picks the files.
/// So a prompt before the files is two pastes. A terminal takes only text, so
/// there the prompt and the quoted paths become one line.
///
/// The prompt always goes first: an instruction read after its attachments is
/// an instruction the agent has already started guessing at.
public enum PastePlan {
    public static func make(urls: [URL], pathOnly: Bool, prompt: String?) -> [PastePayload] {
        let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pathOnly else {
            guard let prompt, !prompt.isEmpty else { return [.files(urls)] }
            return [.text(prompt), .files(urls)]
        }
        let paths = FilePasteboard.shellLine(for: urls)
        guard let prompt, !prompt.isEmpty else { return [.text(paths)] }
        // A newline pasted into a shell is Return: it would run whatever was
        // typed so far, with the paths still to come. One line, always.
        let flat = prompt.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return [.text("\(flat) \(paths)")]
    }

    /// What a manual ⌘V should produce when the automated paste is refused:
    /// the files, or the one line a terminal would have received.
    public static func manualPayload(_ plan: [PastePayload]) -> PastePayload? {
        plan.first { if case .files = $0 { return true } else { return false } } ?? plan.first
    }
}
