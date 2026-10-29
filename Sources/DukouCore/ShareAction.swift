import Foundation

/// What the user asked for when they picked an entry in the system Share menu.
///
/// macOS builds that menu from signed extension bundles, so one entry means one
/// `.appex`. All of Dukou's extensions run the same code and tell themselves
/// apart by this value, read from their own `Info.plist`. Which entries are
/// live is the one thing the platform lets the user change, and Dukou's own
/// 入口 pane writes it through `pluginkit` rather than sending them to System
/// Settings.
public enum ShareAction: String, Codable, Sendable, CaseIterable {
    /// Park the files on the floating shelf and let the user drag them out.
    case shelf
    /// Paste into ChatGPT's Codex.
    case codex
    /// Paste into Claude.
    case claude
    /// Put the files on the clipboard and stop there.
    case clipboard
    /// Ask which app, every time. The entry itself names no destination and
    /// neither does the intent the extension writes for it: the extension has no
    /// interface left to ask in, so Dukou answers the question in-process —
    /// straight through for one app, `TargetPickerPanel` for several. The Share
    /// menu is built from signed bundles and cannot grow a row per app the user
    /// installs, which is why one entry stands for all of them.
    case custom

    public static let infoDictionaryKey = "DKShareAction"

    /// The extension's own declaration. Falling back to `.shelf` keeps a
    /// mis-built bundle useful instead of silently dropping the share.
    public static var declared: ShareAction {
        let raw = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        return raw.flatMap(ShareAction.init(rawValue:)) ?? .shelf
    }

    /// The app this action drives, if any. Resolved by bundle identifier rather
    /// than by name so a renamed or relocated app still works.
    public var targetBundleIdentifier: String? {
        switch self {
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        // `.custom` has no fixed destination and no destination in its intent
        // either. `ActionRunner` resolves one from the user's own list, or takes
        // the one a 发给 ▸ menu inside Dukou named.
        case .shelf, .clipboard, .custom: return nil
        }
    }

    /// Whether the app still has something to do once the files are durable.
    ///
    /// The shelf needs no instruction, and 「复制到剪贴板」 is finished by the
    /// extension itself, which writes the pasteboard before it exits and does
    /// not even launch the app. An intent for either could only ever be found
    /// "too late", and was: a copy made while Dukou was closed read 未执行 in
    /// 记录 on the next launch, for a ⌘V that had worked all along.
    public var needsIntent: Bool {
        switch self {
        case .shelf, .clipboard: return false
        case .codex, .claude, .custom: return true
        }
    }

    /// Shown by the extension while it works, and by the app when it reports a
    /// failure. Deliberately names the destination: "已保存" tells the user
    /// nothing about whether the thing they asked for happened.
    public var targetDisplayName: String {
        switch self {
        case .shelf: return L10n.text("暂存架")
        case .codex: return L10n.text("Codex")
        case .claude: return L10n.text("Claude")
        case .clipboard: return L10n.text("剪贴板")
        // Only ever reached when the chosen target is missing — a failure
        // message has to name something, and this build has nothing better.
        case .custom: return L10n.text("所选应用")
        }
    }

    /// The entry as it is worded in the system Share menu.
    ///
    /// The history says what the user picked, not what Dukou did with it, so it
    /// reuses the very words that were on screen when they picked it — the
    /// defaults in `Scripts/share-slots.sh`.
    public var entryTitle: String {
        switch self {
        case .shelf: return L10n.text("暂存到渡口")
        case .codex, .claude: return L10n.format("发给 %@", targetDisplayName)
        case .clipboard: return L10n.text("复制到剪贴板")
        case .custom: return L10n.text("发送到自定义")
        }
    }

    /// The extension bundle that carries this entry, as a suffix on the app's
    /// own identifier. The other half of this table is
    /// `Scripts/share-slots.sh`, which is what `make-app.sh` stamps into each
    /// appex; the two have to be read together.
    public var bundleIdentifierSuffix: String {
        switch self {
        case .shelf: return "Share"
        case .codex: return "ShareCodex"
        case .claude: return "ShareClaude"
        case .clipboard: return "ShareClipboard"
        case .custom: return "ShareCustom"
        }
    }
}

/// A one-shot request attached to a committed batch.
///
/// Kept out of `manifest.json` on purpose: the manifest describes what the batch
/// *is*, and survives for the life of the files. This describes what should
/// happen *once*, and the app deletes it the moment it acts — which is what
/// stops a forward from firing again on the next rescan or relaunch.
public struct BatchIntent: Codable, Sendable, Hashable {
    public static let fileName = "intent.json"
    public static let currentSchemaVersion = 1

    /// A forward is an immediate gesture. If Dukou was not running and takes a
    /// while to start that is fine, but an intent found hours later — because
    /// the Mac was asleep, or the app never launched — must not suddenly paste
    /// into whatever the user happens to have open. Those are recorded as
    /// `expired` and nothing is done with the files, which is why the extension
    /// also puts them on the clipboard before it exits.
    public static let freshnessWindow: TimeInterval = 90

    public let schemaVersion: Int
    public let action: ShareAction
    public let requestedAt: Date
    /// Which app 「发送到自定义」 was pointed at. Nil for every other entry, and
    /// nil in every intent written before this field existed — which is why the
    /// schema version stays 1: an older app reading one of these simply ignores
    /// a field it has no use for, and a newer app reading an older intent gets
    /// exactly what that intent meant.
    public let targetBundleIdentifier: String?
    /// Stored beside the identifier so a failure can name the app even when it
    /// has since been uninstalled and Launch Services can no longer resolve it.
    public let targetDisplayName: String?

    public init(
        action: ShareAction,
        requestedAt: Date,
        target: ForwardTarget? = nil,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.action = action
        self.requestedAt = requestedAt
        targetBundleIdentifier = target?.bundleIdentifier
        targetDisplayName = target?.displayName
    }

    /// The app to forward to, rebuilt from the two flat fields.
    ///
    /// `addedAt` is the request time rather than the moment the user added the
    /// app to their list: nothing downstream sorts by it, and the intent is the
    /// only record here.
    public var target: ForwardTarget? {
        guard let targetBundleIdentifier else { return nil }
        return ForwardTarget(
            bundleIdentifier: targetBundleIdentifier,
            displayName: targetDisplayName ?? targetBundleIdentifier,
            addedAt: requestedAt
        )
    }

    public func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(requestedAt) < Self.freshnessWindow
    }
}
