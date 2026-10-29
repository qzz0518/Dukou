import AppKit
import CoreServices
import DukouCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The 「发给 <app>」 entries Dukou generates on this Mac, one per row of
/// 「发送到自定义」's list with `showsInShareMenu` set.
///
/// The Share menu only lists signed extension bundles, and it draws each one
/// with its *containing app's* icon — an appex's own `CFBundleIconFile` is
/// ignored (measured 2026-10-30). So an entry that shows the target's icon is a
/// small app of its own: a placeholder executable, the target's icon, and a
/// copy of the 「发送到自定义」 extension that names its destination in its
/// Info.plist (`DirectShareInfoKey`).
///
/// Dukou's Developer ID key is not on the user's Mac, so the copy is signed
/// there, ad hoc. Measured 2026-10-30 on macOS 27.2: pkd registers an ad-hoc
/// share extension, a sandboxed host can invoke it, and it runs. What it cannot
/// do is open the app group, which needs a team: it writes into `relayInbox`
/// instead, and the app moves the batch across (`Inbox.drain(into:)`).
///
/// Generated, not shipped: nothing in the bundle came from a download, so
/// there is no quarantine to trip Gatekeeper, and any installed app can have an
/// entry. The entries live outside Dukou.app — writing into the app would break
/// its signature — which also means trashing Dukou leaves them behind until the
/// rows are unticked first.
enum DirectShareEntries {
    /// Bumped when the generated bundle changes shape, so every entry is rebuilt.
    private static let generatorVersion = 1
    private static let appexName = "DukouShareTarget.appex"
    private static let hostExecutable = "DukouShareTargetsHost"
    private static let markerKey = "DKGeneratedShareEntry"
    private static let ownerKey = "DKShareEntryOwner"
    private static let targetKey = "DKShareEntryTarget"
    private static let stampKey = "DKShareEntryStamp"
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    private static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dukou", isDirectory: true)
    }

    private static var root: URL { support.appendingPathComponent("Share Entries", isDirectory: true) }

    /// Where generated entries leave their batches. The extension's sandbox
    /// exception is written relative to the home folder, so it is spelled
    /// twice: once as a URL for the app, once as the exception's path.
    static var relayInbox: Inbox { Inbox(root: support.appendingPathComponent("Relay", isDirectory: true)) }
    private static let relayHomeRelativePath = "/Library/Application Support/Dukou/Relay/"

    /// Blocking: process work and pkd round trips. Call it off the main thread.
    ///
    /// Brings the entries on disk in line with `targets` and returns, by bundle
    /// identifier, the rows it could not give an entry, each with a sentence.
    /// An entry that is already current costs a plist read and nothing else —
    /// no pkd call, so a choice made in System Settings is never overridden.
    static func synchronize(_ targets: [ForwardTarget], app: Bundle = .main) -> [String: String] {
        // `swift run` has no bundle and nothing to copy; neither touches disk.
        guard let owner = app.bundleIdentifier, app.bundleURL.pathExtension == "app" else { return [:] }
        let wanted = targets.filter(\.showsInShareMenu)
        let existing = installedEntries(owner: owner)

        for (target, url) in existing where !wanted.contains(where: { $0.bundleIdentifier == target }) {
            remove(url)
        }

        var failures: [String: String] = [:]
        for target in wanted {
            let stamp = stamp(for: target, app: app)
            if let url = existing[target.bundleIdentifier], info(at: url)?[stampKey] as? String == stamp {
                continue
            }
            do {
                try install(target, owner: owner, stamp: stamp, replacing: existing[target.bundleIdentifier], app: app)
            } catch {
                failures[target.bundleIdentifier] = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
        return failures
    }

    // MARK: - One entry

    private enum EntryError: LocalizedError {
        case missingTemplate
        case targetNotInstalled(String)
        case failed(String)
        case notRegistered(String)

        var errorDescription: String? {
            switch self {
            case .missingTemplate:
                return L10n.text("这次安装缺少生成入口所需的文件，请重新安装 Dukou。")
            case .targetNotInstalled(let name):
                return L10n.format("没有找到 %@，装好后再勾选。", name)
            case .failed(let name):
                return L10n.format("没能生成「%@」的入口。", name)
            case .notRegistered(let name):
                return L10n.format("系统没有登记「%@」的入口，请稍后再勾选一次。", name)
            }
        }
    }

    private static func install(
        _ target: ForwardTarget,
        owner: String,
        stamp: String,
        replacing previous: URL?,
        app: Bundle
    ) throws {
        guard let template = app.builtInPlugInsURL?.appendingPathComponent("DukouShareCustom.appex"),
              FileManager.default.fileExists(atPath: template.path)
        else { throw EntryError.missingTemplate }
        let hostBinary = app.bundleURL.appendingPathComponent("Contents/Helpers/\(hostExecutable)")
        guard FileManager.default.isExecutableFile(atPath: hostBinary.path) else { throw EntryError.missingTemplate }
        guard let targetApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) else {
            throw EntryError.targetNotInstalled(target.displayName)
        }

        let hostID = DirectShareEntryName.hostBundleIdentifier(owner: owner, target: target.bundleIdentifier)
        let appexID = DirectShareEntryName.extensionBundleIdentifier(owner: owner, target: target.bundleIdentifier)
        let destination = root.appendingPathComponent("\(target.bundleIdentifier).app", isDirectory: true)
        let staging = root.appendingPathComponent(".\(target.bundleIdentifier).building", isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: staging) }

        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        let appex = contents.appendingPathComponent("PlugIns/\(appexName)", isDirectory: true)
        do {
            for directory in ["MacOS", "Resources", "PlugIns"] {
                try fileManager.createDirectory(
                    at: contents.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
            // `ditto` rather than `copyItem`: the template sits inside an app
            // that may carry a download's quarantine, and `copyItem` keeps it
            // (measured on PR #14's copy) — on ad-hoc code that is a refusal.
            try copy(hostBinary, to: contents.appendingPathComponent("MacOS/\(hostExecutable)"))
            try copy(template, to: appex)
            try writeIcon(of: targetApp, to: contents.appendingPathComponent("Resources/AppIcon.icns"))
            try writePlist(hostInfo(target: target, owner: owner, hostID: hostID, stamp: stamp, app: app),
                           to: contents.appendingPathComponent("Info.plist"))
            try rewriteExtension(at: appex, target: target, appexID: appexID, owner: owner, app: app)
            try sign(appex, entitlements: true)
            try sign(staging, entitlements: false)
        } catch {
            throw EntryError.failed(target.displayName)
        }

        // Swapped in only once the new bundle is whole and signed, so a failed
        // rebuild leaves the previous entry working.
        let previousState = previous.map { _ in ShareEntryProbe.probe(appexID) }
        if let previous { remove(previous) }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw EntryError.failed(target.displayName)
        }
        LSRegisterURL(destination as CFURL, true)
        _ = ShareEntryProbe.run(["-a", destination.appendingPathComponent("Contents/PlugIns/\(appexName)").path])

        // pkd files the user's on/off choice under the identifier, which a
        // rebuild keeps. A new entry is blank — registered, never elected, and
        // not in the menu — so it is switched on; a rebuilt one keeps whatever
        // System Settings last said.
        guard waitForRegistration(appexID) else { throw EntryError.notRegistered(target.displayName) }
        if previousState == nil || previousState == .enabled {
            _ = ShareEntryProbe.run(["-e", "use", "-i", appexID])
        }
    }

    private static func hostInfo(
        target: ForwardTarget,
        owner: String,
        hostID: String,
        stamp: String,
        app: Bundle
    ) -> [String: Any] {
        [
            "CFBundleDevelopmentRegion": "zh-Hans",
            "CFBundleExecutable": hostExecutable,
            "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": hostID,
            "CFBundleInfoDictionaryVersion": "6.0",
            // What System Settings → 共享 lists the entry under.
            "CFBundleName": "Dukou · \(target.displayName)",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "CFBundleVersion": app.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            "LSMinimumSystemVersion": app.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "14.0",
            "LSUIElement": true,
            markerKey: true,
            ownerKey: owner,
            targetKey: target.bundleIdentifier,
            stampKey: stamp,
        ]
    }

    private static func rewriteExtension(
        at appex: URL,
        target: ForwardTarget,
        appexID: String,
        owner: String,
        app: Bundle
    ) throws {
        let plist = appex.appendingPathComponent("Contents/Info.plist")
        guard var info = Self.info(at: appex) else { throw CocoaError(.fileReadCorruptFile) }
        info["CFBundleIdentifier"] = appexID
        info["CFBundleDisplayName"] = DirectShareEntryName.title(for: target.displayName, chinese: true)
        info[DirectShareInfoKey.bundleIdentifier] = target.bundleIdentifier
        info[DirectShareInfoKey.displayName] = target.displayName
        info[DirectShareInfoKey.hostBundleIdentifier] = owner
        info[DirectShareInfoKey.hostAppPath] = app.bundleURL.path
        info[DirectShareInfoKey.inboxPath] = relayInbox.root.path
        try writePlist(info, to: plist)

        // The template's localized name says 「发送到自定义」; every language it
        // ships gets this entry's name instead.
        let resources = appex.appendingPathComponent("Contents/Resources", isDirectory: true)
        let languages = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        for language in languages where language.hasSuffix(".lproj") {
            let title = DirectShareEntryName.title(for: target.displayName, chinese: language.hasPrefix("zh"))
            let strings = "\"CFBundleDisplayName\" = \"\(escaped(title))\";\n\"CFBundleName\" = \"Dukou\";\n"
            try strings.write(
                to: resources.appendingPathComponent("\(language)/InfoPlist.strings"),
                atomically: true,
                encoding: .utf8
            )
        }
        try? FileManager.default.removeItem(at: appex.appendingPathComponent("Contents/_CodeSignature"))
    }

    /// The bundle's whole identity in one string: rebuilt when Dukou is
    /// updated or moved (the extension carries the app's path), when the row is
    /// renamed, or when this file changes what it writes.
    private static func stamp(for target: ForwardTarget, app: Bundle) -> String {
        let build = app.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(generatorVersion)|\(build)|\(app.bundleURL.path)|\(target.displayName)"
    }

    // MARK: - On disk

    private static func installedEntries(owner: String) -> [String: URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var found: [String: URL] = [:]
        for url in entries where url.pathExtension == "app" {
            guard let info = info(at: url),
                  info[markerKey] as? Bool == true,
                  info[ownerKey] as? String == owner,
                  let target = info[targetKey] as? String
            else { continue }
            found[target] = url
        }
        return found
    }

    private static func remove(_ entry: URL) {
        _ = ShareEntryProbe.run(["-r", entry.appendingPathComponent("Contents/PlugIns/\(appexName)").path])
        _ = ShareEntryProbe.run(["-u", entry.path], tool: lsregister)
        try? FileManager.default.removeItem(at: entry)
    }

    /// pkd indexes a new bundle a moment after Launch Services hears of it.
    private static func waitForRegistration(_ identifier: String) -> Bool {
        for _ in 0..<20 {
            if ShareEntryProbe.probe(identifier) != .unregistered { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        let result = ShareEntryProbe.run(
            ["--noextattr", "--noqtn", source.path, destination.path],
            tool: "/usr/bin/ditto",
            timeout: 20
        )
        guard result?.status == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func sign(_ bundle: URL, entitlements: Bool) throws {
        var arguments = ["--force", "--sign", "-"]
        var entitlementsFile: URL?
        if entitlements {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("dukou-share-entry-\(UUID().uuidString).entitlements")
            try writePlist(
                [
                    "com.apple.security.app-sandbox": true,
                    "com.apple.security.temporary-exception.files.home-relative-path.read-write": [relayHomeRelativePath],
                ],
                to: file
            )
            arguments += ["--entitlements", file.path]
            entitlementsFile = file
        }
        defer { entitlementsFile.map { try? FileManager.default.removeItem(at: $0) } }
        let result = ShareEntryProbe.run(arguments + [bundle.path], tool: "/usr/bin/codesign", timeout: 30)
        guard result?.status == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The target's own icon, at every size an `.icns` holds, drawn at exact
    /// pixel sizes because the ICNS writer rejects anything else.
    private static func writeIcon(of app: URL, to destination: URL) throws {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.icns.identifier as CFString,
            sizes.count,
            nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        for size in sizes {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: size,
                pixelsHigh: size,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            if let image = bitmap.cgImage { CGImageDestinationAddImage(output, image, nil) }
        }
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func info(at bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func writePlist(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
