import DukouCore
import Foundation

enum WeChatArchive {
    /// The native ZIP is the payload. Text parsing only supplies a display
    /// count; it must not decide whether a message format can be delivered.
    static func messageCount(directory: URL, cancellation: WeChatCancellation) throws -> Int? {
        do {
            return try WeChatNativeArchive.messageCount(data(directory: directory), checkCancellation: cancellation.check)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WeChatAutomationError.invalidArchive
        }
    }

    private static func data(directory: URL) throws -> Data {
        let manifest = try BatchManifest.decoder().decode(BatchManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == BatchManifest.currentSchemaVersion, manifest.action == .shelf,
              manifest.batchID.uuidString == directory.lastPathComponent, manifest.items.count == 1,
              let item = manifest.items.first else { throw WeChatAutomationError.invalidArchive }
        let file = directory.appendingPathComponent(item.relativePath).resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"), file.pathExtension.lowercased() == "zip" else { throw WeChatAutomationError.invalidArchive }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard Int64(data.count) == item.byteCount else { throw WeChatAutomationError.invalidArchive }
        return data
    }
}
