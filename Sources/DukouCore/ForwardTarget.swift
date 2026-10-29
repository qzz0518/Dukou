import Foundation

/// An app the user added to 「发送到自定义」.
///
/// Identified by bundle identifier rather than by path: an app that is updated,
/// moved into a subfolder of /Applications or reinstalled keeps working, and a
/// user with two copies of the same app does not end up with two rows that
/// behave identically. `displayName` is stored rather than resolved on every
/// read so 记录 and a failure message can still name an app that has since
/// been uninstalled.
public struct ForwardTarget: Codable, Hashable, Sendable, Identifiable {
    public let bundleIdentifier: String
    public let displayName: String
    public let addedAt: Date
    /// Paste the files' paths as text instead of the files themselves.
    ///
    /// A terminal has nothing to receive a pasted file with: ⌘V over file URLs
    /// does nothing in Terminal, iTerm or an Electron terminal such as Orca,
    /// while dropping the same file on that window types its quoted path. On,
    /// the forward produces exactly what the drop would have (2026-09-05, the
    /// user's Orca screenshot).
    public let pastesPathOnly: Bool
    /// The app also gets its own entry in the Share menu, 「发给 <app>」, so a
    /// forward to it skips 「发送到自定义」's question.
    ///
    /// The Share menu is built from signed extension bundles, so an entry
    /// cannot be made from a row in `UserDefaults` alone: the app generates one
    /// per row with this set (`DirectShareEntries`).
    public let showsInShareMenu: Bool

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        displayName: String,
        addedAt: Date,
        pastesPathOnly: Bool = false,
        showsInShareMenu: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.addedAt = addedAt
        self.pastesPathOnly = pastesPathOnly
        self.showsInShareMenu = showsInShareMenu
    }

    /// A list written before `pastesPathOnly` existed has no such key, and it
    /// meant "paste the files" — which is what the missing key decodes to. The
    /// store has no schema version, so this is the whole migration.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        displayName = try container.decode(String.self, forKey: .displayName)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        pastesPathOnly = try container.decodeIfPresent(Bool.self, forKey: .pastesPathOnly) ?? false
        showsInShareMenu = try container.decodeIfPresent(Bool.self, forKey: .showsInShareMenu) ?? false
    }

    /// Reads the target encoded in a generated Share extension's Info.plist.
    ///
    /// The normal `.custom` extension asks Dukou to choose from the list. A
    /// generated extension represents one row in that list, so it carries the
    /// destination with it and arrives as a one-step forward.
    public static func directShareTarget(in bundle: Bundle = .main) -> ForwardTarget? {
        guard let bundleIdentifier = bundle.object(forInfoDictionaryKey: DirectShareInfoKey.bundleIdentifier) as? String,
              let displayName = bundle.object(forInfoDictionaryKey: DirectShareInfoKey.displayName) as? String,
              !bundleIdentifier.isEmpty,
              !displayName.isEmpty
        else { return nil }

        // The paste mode is not carried: the row this entry was generated from
        // is still in the list, and `ActionRunner` asks the list.
        return ForwardTarget(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            addedAt: Date(),
            showsInShareMenu: true
        )
    }
}

/// Keys written into a generated `.appex` and read by its embedded extension.
public enum DirectShareInfoKey {
    public static let bundleIdentifier = "DKForwardBundleIdentifier"
    public static let displayName = "DKForwardDisplayName"
    /// Dukou.app's bundle identifier, for when `hostAppPath` has gone stale.
    public static let hostBundleIdentifier = "DKHostBundleIdentifier"
    /// Where Dukou.app was when the entry was generated. A generated entry is
    /// not inside Dukou.app, so it cannot find the app by walking up from its
    /// own bundle the way the five built-in entries do.
    public static let hostAppPath = "DKHostAppPath"
    /// The inbox a generated entry writes to instead of the app group's.
    public static let inboxPath = "DKInboxPath"
}

/// The names a generated 「发给 <app>」 entry goes by.
///
/// Derived from the target's bundle identifier rather than stored, so the
/// same row always regenerates under the same identifiers — and pkd keeps the
/// user's on/off choice, which it files under the extension's identifier.
public enum DirectShareEntryName {
    /// The little containing app the entry lives in. A Share-menu row shows
    /// its containing app's icon, never its own (measured 2026-10-30: an appex
    /// `CFBundleIconFile` is ignored), so every entry needs one of these.
    public static func hostBundleIdentifier(owner: String, target: String) -> String {
        let slug = String(target.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "." || scalar == "-"
                ? Character(scalar)
                : "-"
        })
        return "\(owner).Target.\(slug)"
    }

    public static func extensionBundleIdentifier(owner: String, target: String) -> String {
        hostBundleIdentifier(owner: owner, target: target) + ".Share"
    }

    /// 「发给豆包」 but 「发给 Codex」, the way the built-in entries are spelled.
    public static func title(for displayName: String, chinese: Bool) -> String {
        guard chinese else { return "Send to \(displayName)" }
        let latin = displayName.unicodeScalars.first.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) } ?? false
        return latin ? "发给 \(displayName)" : "发给\(displayName)"
    }
}

/// The list of custom forward targets.
///
/// It lives in the app group's `UserDefaults` suite, which is where the
/// `ShareCustom` extension read it from back when it drew the picker itself.
/// The extension has no interface any more (ADR-0005) and the app is the only
/// reader as well as the only writer; the suite stays because that is where
/// every existing install keeps its list.
public struct ForwardTargetStore: Sendable {
    public static let defaultsKey = "dev.dukou.forwardTargets"
    public static let lastUsedKey = "dev.dukou.lastForwardTarget"

    private let appGroupIdentifier: String

    public init(appGroupIdentifier: String = AppGroup.identifier) {
        self.appGroupIdentifier = appGroupIdentifier
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    // MARK: - The list

    /// Stored order, which is the order the user dragged the rows into. Not
    /// re-sorted by `addedAt`: a list the user has arranged and an app that
    /// re-sorts it are two different features, and only one of them was asked
    /// for.
    public func load() -> [ForwardTarget] {
        guard let data = defaults?.data(forKey: Self.defaultsKey) else { return [] }
        return Self.decode(data)
    }

    public func save(_ targets: [ForwardTarget]) {
        guard let defaults, let data = Self.encode(targets) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Last pick first, then stored order. The panel opens on the target the
    /// user chose the previous time, which is the one they are most likely to
    /// want again — and Return is bound to the first row.
    public func orderedTargets() -> [ForwardTarget] {
        Self.ordered(load(), lastUsed: lastUsedBundleIdentifier())
    }

    // MARK: - The wire format
    //
    // Split out as pure functions so the tests can exercise them without
    // creating a `UserDefaults` suite: a suite is a real preferences domain,
    // and cfprefsd leaves its plist in the user's ~/Library/Preferences after
    // the test has removed the domain — measured, eight stray files after one
    // run. The plumbing these sit behind is verified on the signed build
    // instead, which is the only place it can be verified anyway: it spans two
    // processes on opposite sides of the sandbox.

    public static func encode(_ targets: [ForwardTarget]) -> Data? {
        try? encoder().encode(targets)
    }

    /// Anything unreadable is an empty list rather than an error: a corrupt
    /// preference must not stop the share panel from opening.
    public static func decode(_ data: Data) -> [ForwardTarget] {
        (try? decoder().decode([ForwardTarget].self, from: data)) ?? []
    }

    /// A pointer at an app that is no longer in the list changes nothing.
    public static func ordered(_ targets: [ForwardTarget], lastUsed: String?) -> [ForwardTarget] {
        guard let lastUsed,
              let index = targets.firstIndex(where: { $0.bundleIdentifier == lastUsed })
        else { return targets }
        var ordered = targets
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    public func lastUsedBundleIdentifier() -> String? {
        defaults?.string(forKey: Self.lastUsedKey)
    }

    /// Written whenever a forward is carried out, whether it came from a share
    /// or from a 发给 ▸ menu inside Dukou.
    public func recordLastUsed(_ bundleIdentifier: String) {
        defaults?.set(bundleIdentifier, forKey: Self.lastUsedKey)
    }

    // MARK: - Coding

    /// ISO-8601 for the same reason the manifests use it: a field report reads
    /// the plist by hand, and a bare `Double` needs the app to interpret it.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
