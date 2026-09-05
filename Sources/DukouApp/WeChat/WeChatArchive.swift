import DukouCore
import Foundation

enum WeChatArchive {
    static func records(directory: URL, selected: [WeChatSelectedMessage], cancellation: WeChatCancellation) throws -> [WeChatTranscriptRecord] {
        try WeChatNativeArchive.records(data(directory: directory), selected: selected, checkCancellation: cancellation.check)
    }

    static func records(directory: URL, count: Int, newest: WeChatSelectedMessage, oldest: WeChatSelectedMessage?, cancellation: WeChatCancellation) throws -> [WeChatTranscriptRecord] {
        try WeChatNativeArchive.records(data(directory: directory), count: count, newest: newest, oldest: oldest, checkCancellation: cancellation.check)
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
