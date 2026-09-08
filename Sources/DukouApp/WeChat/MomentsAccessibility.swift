import AppKit
import ApplicationServices
import DukouCore

enum MomentsAutomationError: Error, LocalizedError {
    case timeline, changed, author, incomplete, media, empty
    var errorDescription: String? {
        switch self {
        case .timeline: L10n.text("请在微信中打开朋友圈，关闭图片预览或其他弹窗后重试。")
        case .changed: L10n.text("朋友圈列表发生了变化，已停止。请保持微信窗口不变后重试。")
        case .author: L10n.text("未能读取这条朋友圈的作者，已停止以免记录错配。")
        case .incomplete: L10n.text("朋友圈未能继续加载，已将读到的内容打包，并在文件中注明。")
        case .media: L10n.text("微信未能打开或复制这项媒体。")
        case .empty: L10n.text("没有读到朋友圈内容，请等待微信加载完成后重试。")
        }
    }
}

private func snsAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

private struct SNSNode {
    let element: AXUIElement
    let role: String
    let id: String
    let strings: [String]
    let children: [AXUIElement]
    let rect: CGRect
    let enabled: Bool

    init(_ element: AXUIElement) {
        self.element = element
        let keys = ["AXRole", "AXIdentifier", "AXTitle", "AXValue", "AXDescription", "AXChildren", "AXPosition", "AXSize", "AXEnabled"]
        var copied: CFArray?
        let success = AXUIElementCopyMultipleAttributeValues(element, keys as CFArray, [], &copied) == .success
        let values = success ? (copied as? [Any] ?? []) : keys.map { snsAttribute(element, $0) ?? NSNull() }
        func get(_ i: Int) -> Any? { values.indices.contains(i) ? values[i] : nil }
        role = get(0) as? String ?? ""
        id = get(1) as? String ?? ""
        strings = [2, 3, 4].compactMap { get($0) as? String }.filter { !$0.isEmpty }
        children = get(5) as? [AXUIElement] ?? []
        var point = CGPoint.zero, size = CGSize.zero
        if let value = get(6), CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgPoint, &point) }
        if let value = get(7), CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(value as! AXValue, .cgSize, &size) }
        rect = CGRect(origin: point, size: size)
        enabled = get(8) as? Bool ?? true
    }
    var label: String { strings.first ?? "" }
    func named(_ labels: [String]) -> Bool { strings.contains { labels.contains($0) } }
}

struct MomentsCapture: Sendable {
    let directory: URL
    let count: Int
    let mediaCount: Int
    let incomplete: Bool
    let missingMedia: Int
}

/// Native UI navigation only. The AX row supplies full text; opening a profile
/// resolves the exact author, and the viewer's Copy command supplies media.
final class MomentsAccessibility {
    // The HUD ignores only our own cleanup Esc events, not a physical Esc.
    static let eventTag: Int64 = 0x44554B4F55534E53
    private let app: NSRunningApplication
    private let root: AXUIElement
    private let token: WeChatCancellation
    private let progress: (String) -> Void
    private let clipboard = MomentsClipboard()
    private var ownsOverlay = false
    private var overlayIsMedia = false
    private var cleaningUp = false
    private var windowRect: CGRect?
    private var timelineList: AXUIElement?
    private var timelineWindow: AXUIElement?
    private var missingMedia = 0
    private let clock = { ProcessInfo.processInfo.systemUptime }

    private struct Row {
        let index: Int
        let node: SNSNode
        var identity: String { MomentsContent.identity(node.label) }
    }
    private struct Page {
        let list: SNSNode
        let rows: [Row]
    }

    init(cancellation: WeChatCancellation, progress: @escaping (String) -> Void) throws {
        guard AXIsProcessTrusted() else { throw AutoPaste.Failure.notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: WeChatAccessibility.bundleIdentifier).first else { throw WeChatAutomationError.notRunning }
        self.app = app; self.token = cancellation; self.progress = progress
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.7)
    }

    func capture(_ preset: MomentsForwardPreset, inbox: Inbox) throws -> MomentsCapture {
        guard preset.isValid else { throw MomentsAutomationError.empty }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Dukou-Moments-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer {
            cleanup()
            clipboard.restore()
            try? FileManager.default.removeItem(at: work)
        }
        progress(L10n.text("正在打开并刷新朋友圈…"))
        try openTimeline()
        var records: [MomentsRecord] = []
        var seen: [Int: String] = [:]
        var idle = 0
        var completeRange = true
        while records.count < preset.count {
            try frontmost()
            let page = try page()
            for row in page.rows {
                if let identity = seen[row.index], identity != row.identity { throw MomentsAutomationError.changed }
            }
            if let row = page.rows.first(where: { seen[$0.index] == nil }) {
                let aligned = try align(row, bottom: false)
                progress(L10n.format("正在读取朋友圈 · %d / %d", records.count + 1, preset.count))
                let author = try readAuthor(aligned)
                guard let content = MomentsContent.parse(aligned.node.label, author: author) else { throw MomentsAutomationError.author }
                var record = MomentsRecord(author: author, timestamp: content.timestamp, text: content.text)
                if content.imageCount > 0 {
                    if preset.saveImages {
                        let media = try collectMedia(row: aligned, kind: .image, count: content.imageCount, recordNumber: records.count + 1, directory: work)
                        record.attachments = media
                        if media.count < content.imageCount {
                            record.notes.append(L10n.format("图片未全部保存：%d / %d。", media.count, content.imageCount))
                        }
                    } else { record.notes.append(L10n.format("包含 %d 张图片（未选择保存图片）。", content.imageCount)) }
                } else if content.isVideo {
                    if preset.saveVideos {
                        record.attachments = try collectMedia(row: aligned, kind: .video, count: 1, recordNumber: records.count + 1, directory: work)
                        if record.attachments.isEmpty { record.notes.append(L10n.text("视频未能保存。")) }
                    } else { record.notes.append(L10n.text("包含视频（未选择保存视频）。")) }
                }
                seen[row.index] = row.identity
                records.append(record)
                idle = 0
                continue
            }
            let before = page.rows.map { "\($0.index):\(Int($0.node.rect.minY))" }.joined(separator: "|")
            try scroll(-min(260, page.list.rect.height * 0.3), in: page.list)
            try pause(0.22)
            let after = try self.page()
            // Retain overlap even on a mouse configuration with a larger
            // scroll gain. A jump beyond every anchor must never silently
            // turn a gap in the timeline into a successful export.
            if !after.rows.isEmpty, !page.rows.isEmpty,
               !after.rows.contains(where: { row in page.rows.contains { $0.index == row.index && $0.identity == row.identity } }) {
                completeRange = false
                break
            }
            let signature = after.rows.map { "\($0.index):\(Int($0.node.rect.minY))" }.joined(separator: "|")
            idle = signature == before ? idle + 1 : 0
            if idle >= 6 {
                completeRange = false
                break
            }
            if idle > 0 { try pause(0.65) }
        }
        guard !records.isEmpty else { throw MomentsAutomationError.empty }
        if !completeRange {
            records[records.count - 1].notes.append(L10n.format("本次请求 %d 条，微信仅加载到 %d 条；更早内容未取得。", preset.count, records.count))
        }
        try token.check()
        progress(L10n.text("正在打包朋友圈文字和媒体…"))
        let directory = try MomentsArchive.create(records: records, mediaDirectory: work, in: inbox, checkCancellation: token.check)
        return MomentsCapture(directory: directory, count: records.count, mediaCount: records.reduce(0) { $0 + $1.attachments.count },
                              incomplete: !completeRange, missingMedia: missingMedia)
    }

    private func check() throws { if !cleaningUp { try token.check() } }
    private func pause(_ interval: TimeInterval = 0.08) throws {
        let end = clock() + interval
        repeat { try check(); Thread.sleep(forTimeInterval: min(0.05, max(0, end - clock()))) } while clock() < end
        try check()
    }
    private func frontmost() throws {
        try check()
        guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw WeChatAutomationError.focusChanged }
    }
    private func nodes(stopWhen found: (SNSNode) -> Bool = { _ in false }) throws -> [SNSNode] {
        var queue = [root], index = 0, result: [SNSNode] = []
        while index < queue.count, index < 1600 {
            if index % 24 == 0 { try check() }
            let node = SNSNode(queue[index]); index += 1
            result.append(node)
            if found(node) { break }
            if node.role != "AXMenuBar", !["sns_list", "chat_message_list", "session_list"].contains(node.id) { queue += node.children }
        }
        return result
    }
    private func page() throws -> Page {
        try frontmost()
        // Keep handles, not snapshots: each page still reads current children,
        // bounds and row identities. Invalidated Qt elements trigger discovery.
        var list = timelineList.map(SNSNode.init)
        if list?.id != "sns_list" || list?.rect.isEmpty != false {
            let current = try nodes(stopWhen: { $0.id == "sns_list" })
            list = current.first(where: { $0.id == "sns_list" })
            timelineList = list?.element
            timelineWindow = current.first(where: { $0.role == "AXWindow" && $0.named(["WeChat", "微信"]) })?.element
        }
        guard let list, list.id == "sns_list", !list.rect.isEmpty else { throw MomentsAutomationError.timeline }
        if let element = timelineWindow {
            let window = SNSNode(element)
            guard window.role == "AXWindow", !window.rect.isEmpty else { throw MomentsAutomationError.changed }
            if let expected = windowRect, expected != window.rect { throw MomentsAutomationError.changed }
            windowRect = window.rect
        }
        var rows: [Row] = []
        for (index, element) in list.children.enumerated() {
            if index % 32 == 0 { try check() }
            let node = SNSNode(element)
            guard node.id != "virtual_cell", node.role == "AXStaticText", node.rect.height > 35,
                  !node.label.isEmpty, node.rect.intersects(list.rect),
                  !node.named(["评论区", "Comments"]),
                  node.label.range(of: #"^余下\s*\d+\s*条$"#, options: .regularExpression) == nil else { continue }
            rows.append(Row(index: index, node: node))
        }
        return Page(list: list, rows: rows)
    }
    private func click(_ point: CGPoint, settle: TimeInterval = 0.08) throws {
        try frontmost()
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw AutoPaste.Failure.eventCreationFailed }
        for event in [down, up] { event.flags = []; event.setIntegerValueField(.mouseEventClickState, value: 1); event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag) }
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        up.post(tap: .cghidEventTap)
        try pause(settle)
    }
    private func key(_ code: CGKeyCode, command: Bool = false, raiseWindow: Bool = true, settle: TimeInterval = 0.08, afterPosting: (() throws -> Void)? = nil) throws {
        try frontmost()
        // Qt's inline viewer can leave WeChat active without a key window
        // after changing images. AXRaise restores that window's keyboard
        // focus; merely checking the frontmost application's PID is not enough.
        if raiseWindow {
            let current = try nodes()
            if let window = current.first(where: { $0.role == "AXWindow" && $0.named(["图片和视频", "Photos and Videos"]) })
                ?? current.first(where: { $0.role == "AXWindow" && $0.named(["WeChat", "微信"]) }) {
                AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                try pause(0.06)
            }
        }
        try frontmost()
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw AutoPaste.Failure.eventCreationFailed }
        for event in [down, up] {
            event.flags = command ? .maskCommand : []
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        }
        // Qt's media viewer does not handle Copy/Esc through postToPid even
        // though the chat list handles navigation keys that way. The verified
        // foreground guard permits the same session events AutoPaste uses.
        if command {
            guard let modifierDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true),
                  let modifierUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { throw AutoPaste.Failure.eventCreationFailed }
            modifierDown.flags = .maskCommand
            modifierUp.flags = []
            for event in [modifierDown, modifierUp] { event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag) }
            modifierDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            up.post(tap: .cghidEventTap)
            modifierUp.post(tap: .cghidEventTap)
        } else {
            down.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            up.post(tap: .cghidEventTap)
        }
        try afterPosting?()
        try pause(settle)
    }
    private func copyCommand(kind: MomentsClipboard.Kind) throws {
        try key(8, command: true) {
            // Account for the in-flight Copy before an Esc cancellation can
            // unwind the worker and restore its previous clipboard snapshot.
            let deadline = self.clock() + 0.4
            repeat {
                if try self.clipboard.didCopy(kind: kind) { return }
                Thread.sleep(forTimeInterval: 0.02)
            } while self.clock() < deadline
        }
    }
    private func press(_ node: SNSNode) throws {
        try frontmost()
        guard node.enabled else { throw MomentsAutomationError.timeline }
        // Qt's Moments refresh control reports AXPress success without
        // refreshing. Use its observed frame, then verify the resulting UI.
        guard !node.rect.isEmpty else { throw MomentsAutomationError.timeline }
        try click(CGPoint(x: node.rect.midX, y: node.rect.midY))
    }
    private func scroll(_ pixels: Double, in list: SNSNode) throws {
        try frontmost()
        let point = CGPoint(x: list.rect.maxX - 28, y: list.rect.midY)
        let source = CGEventSource(stateID: .privateState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        for (phase, amount) in [(CGScrollPhase.began, Int32(pixels)), (.ended, Int32(0))] {
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { throw AutoPaste.Failure.eventCreationFailed }
            event.location = point
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            event.post(tap: .cghidEventTap)
        }
        try pause(0.12)
    }
    private func waitNode(_ timeout: TimeInterval = 3, poll: TimeInterval = 0.08, where predicate: (SNSNode) -> Bool) throws -> SNSNode? {
        let deadline = clock() + timeout
        repeat {
            try frontmost()
            if let node = try nodes(stopWhen: predicate).first(where: predicate) { return node }
            try pause(poll)
        } while clock() < deadline
        return nil
    }
    private func openTimeline() throws {
        guard let url = app.bundleURL else { throw WeChatAutomationError.notRunning }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true; configuration.addsToRecentItems = false
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in opened.signal() }
        let deadline = clock() + 3
        while opened.wait(timeout: .now() + 0.05) != .success, clock() < deadline { try check() }
        AutoPaste.restoreWindows(pid: app.processIdentifier)
        try pause(0.2)
        try frontmost()
        let initial = try nodes()
        guard !initial.contains(where: { $0.role == "AXDialog" || $0.id == "cancel_btn" || $0.named(["图片和视频", "Photos and Videos", "关闭（esc 或 空格）"]) }) else { throw MomentsAutomationError.timeline }
        if !initial.contains(where: { $0.id == "sns_list" }) {
            guard let discover = initial.first(where: { $0.role == "AXButton" && $0.named(["发现", "Discover"]) }) else { throw MomentsAutomationError.timeline }
            try press(discover)
            if !(try nodes().contains(where: { $0.id == "sns_list" })) {
                guard let moments = try waitNode(where: { $0.role == "AXButton" && $0.named(["朋友圈", "Moments"]) }) else { throw MomentsAutomationError.timeline }
                try press(moments)
            }
        }
        guard let refresh = try waitNode(where: { $0.role == "AXButton" && $0.named(["刷新", "Refresh"]) }) else { throw MomentsAutomationError.timeline }
        try press(refresh)
        try pause(0.6)
        guard try waitNode(15, where: { $0.role == "AXButton" && $0.named(["刷新", "Refresh"]) }) != nil else { throw MomentsAutomationError.timeline }
        try pause(0.3)
        let page = try page()
        guard let first = page.list.children.first else { throw MomentsAutomationError.empty }
        let header = SNSNode(first)
        guard header.id != "virtual_cell", header.label.isEmpty, header.rect.height > 100,
              header.rect.intersects(page.list.rect) else { throw MomentsAutomationError.timeline }
    }

    private func align(_ original: Row, bottom: Bool, bottomInset: Double = 85) throws -> Row {
        for _ in 0..<14 {
            let page = try page()
            guard let row = page.rows.first(where: { $0.index == original.index }), row.identity == original.identity else { throw MomentsAutomationError.changed }
            let upper = page.list.rect.minY + 18, lower = page.list.rect.maxY - 18
            let y = bottom ? row.node.rect.maxY - bottomInset : row.node.rect.minY + 28
            if y >= upper, y <= lower { return row }
            let delta = y < upper ? upper - y + 25 : lower - y - 25
            try scroll(max(-330, min(330, delta * 0.65)), in: page.list)
        }
        throw MomentsAutomationError.changed
    }
    private func textX(_ row: Row) -> Double {
        // The native Moments column is centered inside sns_list: 64 pt avatar,
        // 12 pt gap, and a 436 pt body. Narrow layouts keep a 24 pt inset.
        max(row.node.rect.minX + 24, row.node.rect.midX - 256) + 76
    }
    private func readAuthor(_ row: Row) throws -> String {
        ownsOverlay = true
        overlayIsMedia = false
        var name: SNSNode?
        for attempt in 0..<2 {
            // The caller has just aligned this exact row. A retry reacquires it.
            let current = attempt == 0 ? row : try align(row, bottom: false)
            try click(CGPoint(x: textX(current) - 44, y: current.node.rect.minY + 32), settle: 0.015)
            name = try waitNode(1.2, poll: 0.025, where: { $0.id == "display_name_text" })
            if name != nil { break }
        }
        // WeCom cards expose name and company separately, while the feed
        // displays name@company. Remarks may also differ from the nickname.
        let profile = try nodes()
        let fields = profile.filter { ["display_name_text", "value_reader_"].contains($0.id) }.map(\.label)
        var candidates = fields
        if let name { candidates += fields.map { name.label + "@" + $0 } }
        let author = candidates.filter { !$0.isEmpty && row.node.label.hasPrefix($0 + " ") }.max(by: { $0.count < $1.count })
        guard let author else {
            try closeOverlay()
            throw MomentsAutomationError.author
        }
        try closeOverlay()
        return author
    }
    private func isViewer(_ nodes: [SNSNode]) -> Bool {
        nodes.contains { $0.named(["关闭（esc 或 空格）", "图片和视频", "Photos and Videos", "用窗口打开"]) }
    }
    private func revealViewer() throws -> [SNSNode] {
        try frontmost()
        let current = try nodes()
        guard let window = current.first(where: { $0.role == "AXWindow" && $0.named(["图片和视频", "Photos and Videos"]) })
            ?? current.first(where: { $0.role == "AXWindow" && $0.named(["WeChat", "微信"]) }), !window.rect.isEmpty else { throw MomentsAutomationError.media }
        // The viewer hides its controls (including AX nodes) when the pointer
        // is idle. Hover without clicking: a click would dismiss the preview.
        for offset in [-2.0, 2.0] {
            guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: .mouseMoved,
                                      mouseCursorPosition: CGPoint(x: window.rect.midX + offset, y: window.rect.midY), mouseButton: .left) else { throw AutoPaste.Failure.eventCreationFailed }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
            event.post(tap: .cghidEventTap)
            try pause(0.06)
        }
        return try nodes()
    }
    private func closeOverlay() throws {
        guard ownsOverlay else { return }
        // A photo preview may still be open with every toolbar node hidden.
        // The caller owns this overlay, so always close it before returning.
        // A profile is already in the key window and closes without the media
        // viewer's animation. Keep that viewer-specific delay only for media.
        try key(53, raiseWindow: overlayIsMedia, settle: overlayIsMedia ? 0.08 : 0.015)
        let deadline = clock() + 2
        repeat {
            let current = try self.nodes(stopWhen: { $0.id == "display_name_text" || self.isViewer([$0]) })
            if !current.contains(where: { $0.id == "display_name_text" }), !isViewer(current) {
                // Qt removes viewer controls before its closing animation
                // stops intercepting clicks on the timeline underneath.
                try pause(overlayIsMedia ? 0.3 : 0.03)
                ownsOverlay = false
                return
            }
            try pause(0.08)
        } while clock() < deadline
        throw MomentsAutomationError.media
    }
    private func cleanup() {
        cleaningUp = true
        defer { cleaningUp = false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
        try? closeOverlay()
    }
    private func collectMedia(row: Row, kind: MomentsClipboard.Kind, count: Int, recordNumber: Int, directory: URL) throws -> [String] {
        guard count > 0, count <= 9 else { missingMedia += count; return [] }
        var saved: [String] = []
        do {
            for index in 0..<count {
                try frontmost()
                // In this Qt viewer, keyboard image navigation can make Copy
                // return empty text. Open each thumbnail from the timeline.
                // The fixed native grid has 114 pt tiles and 4 pt gutters;
                // four photos use two columns, the other grids use three.
                let columns = count == 4 ? 2 : 3
                let lastRow = (count - 1) / columns
                let inset = 85 + Double(lastRow - index / columns) * 118
                let aligned = try align(row, bottom: true, bottomInset: inset)
                let point = CGPoint(x: textX(aligned) + 24 + Double(index % columns) * 118,
                                    y: aligned.node.rect.maxY - inset)
                ownsOverlay = true
                overlayIsMedia = true
                try click(point)
                let deadline = clock() + 5
                while !(try isViewer(nodes())), clock() < deadline { try pause(0.12) }
                guard try isViewer(nodes()) else { throw MomentsAutomationError.media }
                progress(kind == .video
                         ? L10n.format("正在保存第 %d 条朋友圈的视频，请勿操作电脑…", recordNumber)
                         : L10n.format("正在保存第 %d 条朋友圈的图片 · %d / %d", recordNumber, index + 1, count))
                guard try isViewer(revealViewer()) else { throw MomentsAutomationError.media }
                var change = try clipboard.prepare()
                try pause(0.25)
                try copyCommand(kind: kind)
                let end = clock() + (kind == .video ? 60 : 15)
                var retryAt = clock() + 0.8
                var file: String?
                repeat {
                    let ready = try clipboard.didCopy(kind: kind)
                    try frontmost()
                    if ready {
                        file = try clipboard.saveIfReady(after: change, kind: kind, stem: String(format: "%03d-%02d", recordNumber, index + 1),
                                                        directory: directory, checkCancellation: token.check)
                    }
                    if file != nil { break }
                    if clock() >= retryAt {
                        guard try isViewer(revealViewer()) else { throw MomentsAutomationError.media }
                        change = try clipboard.prepare()
                        try copyCommand(kind: kind)
                        retryAt = clock() + 0.8
                    }
                    try pause(0.15)
                } while clock() < end
                if let file { saved.append(file) }
                try closeOverlay()
                guard file != nil else { break }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as WeChatAutomationError { throw error }
        catch MomentsClipboard.Failure.clipboardChanged { throw MomentsClipboard.Failure.clipboardChanged }
        catch MomentsClipboard.Failure.unreadableClipboard { throw MomentsClipboard.Failure.unreadableClipboard }
        catch { /* Missing media is reported beside its post in the TXT. */ }
        try closeOverlay()
        missingMedia += count - saved.count
        return saved
    }
}
