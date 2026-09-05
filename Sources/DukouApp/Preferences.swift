import DukouCore
import Foundation

/// Where the user dragged the shelf, as its top-right corner. `nil` means they
/// never did, and the shelf sits in `shelfCorner`.
///
/// The top-right rather than the origin: the shelf grows downwards when it
/// expands, so remembering the origin would move the window every time it
/// changed size. The screen's frame travels with it because a point remembered
/// on a monitor that is no longer attached has to be recognised as unusable
/// rather than clamped to somewhere arbitrary.
struct ShelfAnchor: Codable, Sendable, Hashable {
    var topRight: CGPoint
    var screenFrame: CGRect
}

/// Which corner of the screen the shelf docks to when the user has not dragged
/// it somewhere of their own.
///
/// Four cases rather than a stored point: a corner survives a resolution change,
/// a second monitor and an expanding list, all of which a remembered coordinate
/// only survives by accident.
enum ShelfCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

/// One switch, one retention window, one corner and one remembered position.
/// Everything else about Dukou's state lives in the shared inbox on disk, where
/// both processes can see it.
@MainActor
final class Preferences: ObservableObject {
    private enum Key {
        static let onboardingCompleted = "dev.dukou.onboardingCompleted"
        /// The one key here without the `dev.dukou.` prefix. It is the name the
        /// reference implementation uses and the name the acceptance check for
        /// §11.2 reads, and a progress counter is worth less than the confusion
        /// of two spellings of it.
        static let onboardingStep = "onboardingStep"
        static let historyRetentionDays = "dev.dukou.historyRetentionDays"
        static let shelfCorner = "dev.dukou.shelfCorner"
        static let shelfAnchor = "dev.dukou.shelfAnchor"
        static let hasShownShelfCoachMark = "dev.dukou.hasShownShelfCoachMark"
        static let prompt = "dev.dukou.attachedPrompt"
    }

    /// A week: long enough that last Friday's chat export is still there on
    /// Monday, short enough that the group container does not quietly become the
    /// user's archive of every file they ever forwarded.
    static let defaultHistoryRetentionDays = 7

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        onboardingStep = defaults.object(forKey: Key.onboardingStep) as? Int ?? 0
        // `object(forKey:)` distinguishes "never set" from "set to 0"; a plain
        // `integer(forKey:)` would silently turn a fresh install into "从不".
        historyRetentionDays = defaults.object(forKey: Key.historyRetentionDays) as? Int
            ?? Self.defaultHistoryRetentionDays
        // An unreadable value falls back to the top-right rather than to the
        // first case: the default has to be the same one the 停靠位置 picker
        // shows, or a fresh install would disagree with itself.
        shelfCorner = (defaults.string(forKey: Key.shelfCorner))
            .flatMap(ShelfCorner.init(rawValue:)) ?? .topRight
        shelfAnchor = (defaults.data(forKey: Key.shelfAnchor))
            .flatMap { try? JSONDecoder().decode(ShelfAnchor.self, from: $0) }
        hasShownShelfCoachMark = defaults.bool(forKey: Key.hasShownShelfCoachMark)
        // Seeded in the app's language on first read. The default text is a
        // starting point the user is expected to rewrite, not a resource that
        // follows the system language afterwards.
        prompt = defaults.data(forKey: Key.prompt)
            .flatMap { try? JSONDecoder().decode(PromptSettings.self, from: $0) }
            ?? PromptSettings.makeDefault(
                text: L10n.text("附件是微信导出的聊天记录（TXT 加图片、视频）。请通读，按时间线总结要点、结论和待办。")
            )
    }

    /// Set only by finishing the guide. Closing its window half way through is
    /// not an answer, so the guide comes back on the next activation and picks
    /// up at `onboardingStep`.
    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    /// Which step of the guide is on screen, written on every step change.
    ///
    /// The permission step sends the user into System Settings, and macOS is
    /// free to hand focus back — or not — whenever it likes; without this, a
    /// user who came back an hour later would start again at step one.
    @Published var onboardingStep: Int {
        didSet { defaults.set(onboardingStep, forKey: Key.onboardingStep) }
    }

    /// 0 means "从不". History that is still on the shelf is never aged out
    /// whatever this says.
    @Published var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: Key.historyRetentionDays) }
    }

    /// Where the shelf docks. Changing it clears `shelfAnchor` — picking a
    /// corner is the user saying "not where I dragged it, there" — and the
    /// shelf moves at once if it is on screen.
    @Published var shelfCorner: ShelfCorner {
        didSet { defaults.set(shelfCorner.rawValue, forKey: Key.shelfCorner) }
    }

    @Published var shelfAnchor: ShelfAnchor? {
        didSet {
            guard let shelfAnchor, let data = try? JSONEncoder().encode(shelfAnchor) else {
                defaults.removeObject(forKey: Key.shelfAnchor)
                return
            }
            defaults.set(data, forKey: Key.shelfAnchor)
        }
    }

    /// The 「拖出去就送达」 capsule is shown beside the shelf once in the app's
    /// lifetime. It explains a gesture, and a hint that keeps explaining a
    /// gesture the user already performs is an interruption.
    @Published var hasShownShelfCoachMark: Bool {
        didSet { defaults.set(hasShownShelfCoachMark, forKey: Key.hasShownShelfCoachMark) }
    }

    /// The 附加 Prompt library, its selection, and the switch for each
    /// surface. One blob, because the pieces only mean anything together.
    @Published var prompt: PromptSettings {
        didSet {
            guard let data = try? JSONEncoder().encode(prompt) else { return }
            defaults.set(data, forKey: Key.prompt)
        }
    }
}
