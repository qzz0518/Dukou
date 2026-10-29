import Foundation

/// The shared inbox on disk.
///
/// ```text
/// <group container>/Inbox/
///   Staging/<batch-id>.partial/   ← only the extension writes here
///     items/<item-id>/<display name>
///     manifest.json.partial
///   Ready/<batch-id>/             ← only the app writes here (deletes)
///     items/<item-id>/<display name>
///     manifest.json
///     diagnostics.json
///   Failures/<uuid>.json          ← the extension writes, the app reads once
/// ```
///
/// A batch becomes visible by a single `rename(2)` from `Staging` to `Ready`,
/// so a share that is interrupted at any point leaves debris in `Staging` and
/// nothing half-formed in front of the user.
public struct Inbox: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func resolve(
        appGroupIdentifier: String = AppGroup.identifier,
        fileManager: FileManager = .default
    ) throws -> Inbox {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw InboxError.containerUnavailable(identifier: appGroupIdentifier)
        }
        return Inbox(root: container.appendingPathComponent("Inbox", isDirectory: true))
    }

    /// The inbox an extension writes to: the app group's, unless its own
    /// Info.plist names another.
    ///
    /// Only a generated 「发给 <app>」 entry names one. It is signed on the
    /// user's Mac, ad hoc, so it has no team to be granted the app group with —
    /// measured 2026-10-30: such an extension cannot write into
    /// `~/Library/Group Containers/H2P566W3PA.dev.dukou.shared` even with a
    /// sandbox exception for that path, but can write into a directory under
    /// Application Support named by one. The app moves what lands there into
    /// this inbox (`drain(into:)`).
    public static func resolve(
        info: [String: Any]?,
        fileManager: FileManager = .default
    ) throws -> Inbox {
        if let path = info?[DirectShareInfoKey.inboxPath] as? String, !path.isEmpty {
            return Inbox(root: URL(fileURLWithPath: path, isDirectory: true))
        }
        return try resolve(fileManager: fileManager)
    }

    /// Moves every published batch, failure report and diagnostics record from
    /// this inbox into `destination`, where the rest of the app looks.
    ///
    /// Batches go through `destination.staging` first: the two trees are both
    /// under the home folder, so each move is normally one `rename(2)`, but if
    /// they ever sit on different volumes `moveItem` becomes copy-then-delete,
    /// and the app must never see a half-copied batch in `Ready`. The intent
    /// travels inside the batch directory, so the forward goes with it.
    @discardableResult
    public func drain(into destination: Inbox, fileManager: FileManager = .default) -> Int {
        try? destination.prepareDirectories(fileManager: fileManager)
        var moved = 0
        for batch in Self.children(of: ready, fileManager: fileManager) {
            let name = batch.lastPathComponent
            let transit = destination.staging.appendingPathComponent(name + ".relay", isDirectory: true)
            let target = destination.ready.appendingPathComponent(name, isDirectory: true)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try? fileManager.removeItem(at: transit)
            do {
                try fileManager.moveItem(at: batch, to: transit)
                try fileManager.moveItem(at: transit, to: target)
                moved += 1
            } catch {
                continue
            }
        }
        for (from, to) in [(failures, destination.failures), (diagnostics, destination.diagnostics)] {
            for file in Self.children(of: from, fileManager: fileManager) {
                let target = to.appendingPathComponent(file.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path) else { continue }
                if (try? fileManager.moveItem(at: file, to: target)) != nil { moved += 1 }
            }
        }
        return moved
    }

    private static func children(of directory: URL, fileManager: FileManager) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    public var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    public var ready: URL { root.appendingPathComponent("Ready", isDirectory: true) }
    /// Redacted import records, including for shares that were rejected and so
    /// never produced a batch. This is where a P0 field report comes from.
    public var diagnostics: URL { root.appendingPathComponent("Diagnostics", isDirectory: true) }
    /// One file per share the extension could not complete. The extension has
    /// no interface to report into, so it leaves the message here and the app
    /// reads it — and deletes it — on its next scan.
    public var failures: URL {
        root.appendingPathComponent(ShareFailure.directoryName, isDirectory: true)
    }

    public func prepareDirectories(fileManager: FileManager = .default) throws {
        for directory in [staging, ready, diagnostics, failures] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Removes staging directories that no live extension can still be filling.
    ///
    /// Age is measured from the newest modification date anywhere in the tree,
    /// not from the directory itself: a 1 GB copy touches only the file being
    /// written, and pruning by the parent's timestamp would delete a share that
    /// is still in progress.
    @discardableResult
    public func pruneStaging(
        olderThan interval: TimeInterval = 30 * 60,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        let contents = (try? fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var removed = 0
        for candidate in contents {
            let newest = Self.newestModificationDate(at: candidate, fileManager: fileManager) ?? .distantPast
            guard now.timeIntervalSince(newest) > interval else { continue }
            if (try? fileManager.removeItem(at: candidate)) != nil { removed += 1 }
        }
        return removed
    }

    static func newestModificationDate(at url: URL, fileManager: FileManager) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return newest }

        for case let child as URL in enumerator {
            guard let date = (try? child.resourceValues(forKeys: Set(keys)))?.contentModificationDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }
}
