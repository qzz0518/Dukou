import DukouCore
import Foundation

/// Installs the pre-signed helper apps that provide direct third-party entries.
///
/// A Share extension must be signed with the containing distribution's Team
/// identity. That private key is not available on a user's Mac, so Dukou cannot
/// manufacture an executable extension at runtime. `make-app.sh` therefore
/// ships one signed helper per curated target, and this type only copies,
/// registers, enables, and removes those helpers.
enum DirectShareMenuInstaller {
    static let helperNamePrefix = "Dukou Share Target "
    static let generatedHostKey = "DKGeneratedShareTargetHost"

    private static let builtinsDirectoryName = "Builtins"
    private static let pluginTool = "/usr/bin/pluginkit"
    private static let openTool = "/usr/bin/open"

    enum InstallerError: LocalizedError {
        case missingResources
        case supportDirectoryUnavailable
        case commandFailed(String, Int32, String)
        case registrationTimedOut(String)

        var errorDescription: String? {
            switch self {
            case .missingResources:
                return L10n.text("这次安装缺少生成共享入口所需的文件。")
            case .supportDirectoryUnavailable:
                return L10n.text("无法创建 Dukou 的共享入口支持目录。")
            case .commandFailed(let tool, let status, let output):
                let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? L10n.format("%@ 执行失败（%d）。", tool, status)
                    : L10n.format("%@ 执行失败（%d）：%@", tool, status, detail)
            case .registrationTimedOut(let identifier):
                return L10n.format("系统没有登记共享入口 %@，请稍后重试。", identifier)
            }
        }
    }

    private struct BuiltinTemplate {
        let appURL: URL
        let appexIdentifier: String
        let targetIdentifier: String
        let ownerIdentifier: String
        let templateVersion: Int
        let appVersion: String
        let appBuild: String
    }

    static func supportedBundleIdentifiers(mainBundle: Bundle = .main) -> Set<String> {
        guard let templates = try? builtinTemplates(mainBundle: mainBundle) else { return [] }
        return Set(templates.keys)
    }

    /// Copies only target helpers that are missing or built from a different
    /// Dukou version. The copied app is already signed and is never modified.
    static func synchronize(
        _ targets: [ForwardTarget],
        mainBundle: Bundle = .main
    ) throws {
        guard let ownerIdentifier = mainBundle.bundleIdentifier else {
            throw InstallerError.missingResources
        }
        let templates = try builtinTemplates(mainBundle: mainBundle)
        let directTargets = targets.filter {
            $0.showsInShareMenu && templates[$0.bundleIdentifier] != nil
        }
        guard !directTargets.isEmpty else {
            removeGeneratedHosts(
                ownerIdentifier: ownerIdentifier,
                keeping: []
            )
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: installRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw InstallerError.supportDirectoryUnavailable
        }

        for target in directTargets {
            guard let template = templates[target.bundleIdentifier] else { continue }
            let destination = hostURL(
                ownerIdentifier: ownerIdentifier,
                targetIdentifier: target.bundleIdentifier
            )
            if !installedHostMatches(
                destination,
                template: template,
                ownerIdentifier: ownerIdentifier
            ) {
                unregisterHost(at: destination)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: template.appURL, to: destination)
            }
            try activateHelper(at: destination, appexIdentifier: template.appexIdentifier)
        }

        removeGeneratedHosts(
            ownerIdentifier: ownerIdentifier,
            keeping: Set(directTargets.map(\.bundleIdentifier))
        )
        try enableDirectExtensions(for: directTargets, templates: templates)
    }

    private static func builtinTemplates(
        mainBundle: Bundle
    ) throws -> [String: BuiltinTemplate] {
        guard let resourceURL = mainBundle.resourceURL?
            .appendingPathComponent("ShareTargets", isDirectory: true)
            .appendingPathComponent(builtinsDirectoryName, isDirectory: true),
            let entries = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw InstallerError.missingResources
        }

        var templates: [String: BuiltinTemplate] = [:]
        for appURL in entries where appURL.pathExtension == "app" {
            let hostInfo = readInfo(at: appURL.appendingPathComponent("Contents/Info.plist"))
            let appexInfo = readInfo(
                at: appURL.appendingPathComponent(
                    "Contents/PlugIns/DukouShareTarget.appex/Contents/Info.plist"
                )
            )
            guard let targetIdentifier = hostInfo?["DKTargetBundleIdentifier"] as? String,
                  let ownerIdentifier = hostInfo?["DKShareTargetOwner"] as? String,
                  let templateVersion = hostInfo?["DKTemplateVersion"] as? Int,
                  let appexIdentifier = appexInfo?["CFBundleIdentifier"] as? String,
                  let appVersion = hostInfo?["CFBundleShortVersionString"] as? String,
                  let appBuild = hostInfo?["CFBundleVersion"] as? String
            else { continue }
            templates[targetIdentifier] = BuiltinTemplate(
                appURL: appURL,
                appexIdentifier: appexIdentifier,
                targetIdentifier: targetIdentifier,
                ownerIdentifier: ownerIdentifier,
                templateVersion: templateVersion,
                appVersion: appVersion,
                appBuild: appBuild
            )
        }
        guard !templates.isEmpty else { throw InstallerError.missingResources }
        return templates
    }

    private static func installedHostMatches(
        _ url: URL,
        template: BuiltinTemplate,
        ownerIdentifier: String
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let hostInfo = readInfo(at: url.appendingPathComponent("Contents/Info.plist"))
        let appexInfo = readInfo(
            at: url.appendingPathComponent(
                "Contents/PlugIns/DukouShareTarget.appex/Contents/Info.plist"
            )
        )
        return hostInfo?[generatedHostKey] as? Bool == true
            && hostInfo?["DKShareTargetOwner"] as? String == ownerIdentifier
            && hostInfo?["DKTargetBundleIdentifier"] as? String == template.targetIdentifier
            && (hostInfo?["DKTemplateVersion"] as? Int) == template.templateVersion
            && hostInfo?["CFBundleShortVersionString"] as? String == template.appVersion
            && hostInfo?["CFBundleVersion"] as? String == template.appBuild
            && appexInfo?["CFBundleIdentifier"] as? String == template.appexIdentifier
    }

    private static func activateHelper(at url: URL, appexIdentifier: String) throws {
        let result = try run(openTool, ["-g", url.path])
        guard result.status == 0 else {
            throw InstallerError.commandFailed("open", result.status, result.output)
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let probe = try run(pluginTool, ["-m", "-i", appexIdentifier])
            if probe.status == 0, probe.output.contains(appexIdentifier) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw InstallerError.registrationTimedOut(appexIdentifier)
    }

    private static func enableDirectExtensions(
        for targets: [ForwardTarget],
        templates: [String: BuiltinTemplate]
    ) throws {
        for target in targets {
            guard let template = templates[target.bundleIdentifier] else { continue }
            let election = try run(
                pluginTool,
                ["-e", "use", "-i", template.appexIdentifier]
            )
            guard election.status == 0 else {
                throw InstallerError.commandFailed("pluginkit", election.status, election.output)
            }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let probe = try run(pluginTool, ["-m", "-i", template.appexIdentifier])
                let line = probe.output.split(whereSeparator: \.isNewline).first {
                    $0.contains(template.appexIdentifier)
                }
                if let line, line.first == "+" { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let finalProbe = try run(pluginTool, ["-m", "-i", template.appexIdentifier])
            let finalLine = finalProbe.output.split(whereSeparator: \.isNewline).first {
                $0.contains(template.appexIdentifier)
            }
            guard let finalLine, finalLine.first == "+" else {
                throw InstallerError.registrationTimedOut(template.appexIdentifier)
            }
        }
    }

    private static func removeGeneratedHosts(
        ownerIdentifier: String,
        keeping targetIDs: Set<String>
    ) {
        let root = installRoot
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries where url.pathExtension == "app"
            && url.lastPathComponent.hasPrefix(helperNamePrefix) {
            let info = readInfo(at: url.appendingPathComponent("Contents/Info.plist"))
            guard info?[generatedHostKey] as? Bool == true else { continue }
            guard info?["DKShareTargetOwner"] as? String == ownerIdentifier else { continue }
            let targetID = info?["DKTargetBundleIdentifier"] as? String
            if let targetID, targetIDs.contains(targetID) { continue }
            unregisterHost(at: url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func unregisterHost(at root: URL) {
        let plugins = root.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: plugins,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.pathExtension == "appex" {
            _ = try? run(pluginTool, ["-r", entry.path])
        }
    }

    private static func readInfo(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func hostURL(
        ownerIdentifier: String,
        targetIdentifier: String
    ) -> URL {
        let key = "\(ownerIdentifier)|\(targetIdentifier)"
        return installRoot.appendingPathComponent(
            "\(helperNamePrefix)\(slotSuffix(for: key)).app",
            isDirectory: true
        )
    }

    private static var installRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dukou/Share Targets", isDirectory: true)
    }

    /// FNV-1a keeps the generated path stable across launches.
    private static func slotSuffix(for identifier: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in identifier.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}
