import Foundation

/// The one identifier the app and its share extension must agree on.
///
/// It is read from `Info.plist` rather than hard-coded so a single build-script
/// substitution can retarget both bundles at once; a mismatch between the two
/// entitlements is otherwise invisible until a share silently lands in a
/// container the app cannot see. `Scripts/check-release-config.sh` asserts that
/// all four files carry the same string.
public enum AppGroup {
    public static let infoDictionaryKey = "DKAppGroupIdentifier"

    /// Used by `swift run`, unit tests and previews, which have no bundle.
    /// Team-prefixed because macOS provisions app groups per team, and the same
    /// literal then works for both an ad-hoc local build and a Developer ID one.
    public static let fallbackIdentifier = "H2P566W3PA.dev.dukou.shared"

    public static var identifier: String {
        let declared = Bundle.main.object(forInfoDictionaryKey: infoDictionaryKey) as? String
        guard let declared, !declared.isEmpty else { return fallbackIdentifier }
        return declared
    }
}
