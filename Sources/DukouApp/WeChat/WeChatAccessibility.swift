import AppKit
import ApplicationServices
import CryptoKit
import DukouCore
import Foundation
import Vision

enum WeChatAutomationError: Error, LocalizedError {
    case notRunning, wrongChat, busyChat, focusChanged, historyIncomplete, noMessages
    case selection, loading, screenRecording, unsupportedLayout, missingShare, ambiguousReceipt, receiptTimeout, invalidArchive, timeRangeUnavailable
    case control(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: L10n.text("请先打开并登录微信。")
        case .wrongChat: L10n.text("没有找到唯一匹配的群聊。请先在微信中打开这个群，再重新执行。")
        case .busyChat: L10n.text("请先关闭微信的聊天记录窗口，或退出正在进行的多选、转发。")
        case .focusChanged: L10n.text("前台应用或群聊发生了变化，已停止微信操作。")
        case .historyIncomplete: L10n.text("未能读到范围起点。请缩小范围，或先在微信中加载更早的聊天记录。")
        case .noMessages: L10n.text("这个时间范围内没有消息。")
        case .selection: L10n.text("无法准确选中这一批消息，已停止。请缩小范围后重试。")
        case .loading: L10n.text("微信消息列表尚未稳定。请等待加载完成后重试。")
        case .screenRecording: L10n.text("这个转发界面需要识别按钮位置。请在系统设置中为渡口开启屏幕录制权限后重试。")
        case .unsupportedLayout: L10n.text("没有定位到“转发到其他应用”按钮，已停止。请保持微信转发窗口完整可见。")
        case .missingShare: L10n.text("没有找到「暂存到渡口」分享入口。请在设置的「入口」中启用它。")
        case .ambiguousReceipt: L10n.text("同时收到了多次分享，无法确认本次文件，已停止自动粘贴。")
        case .receiptTimeout: L10n.text("等待微信导出超时。已收到的文件会保留在暂存架。")
        case .invalidArchive: L10n.text("微信导出的 ZIP 无法校验，文件已保留在暂存架。")
        case .timeRangeUnavailable: L10n.text("按时间选取暂未开放，请改用条数。")
        case .control(let label): L10n.format("微信没有显示“%@”。请回到普通聊天窗口后重试。", label)
        }
    }
}

/// A worker owns all AX references. Cancelling never releases the forward
/// queue until that worker has stopped posting events and cleaned up its UI.
final class WeChatCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

private func wcAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// One cross-process read per node. Message contents stay in memory; only the
/// external-share control may use a cropped visual fallback.
private struct WCNode {
    static let keys = ["AXRole", "AXIdentifier", "AXTitle", "AXValue", "AXDescription", "AXHelp", "AXChildren", "AXPosition", "AXSize", "AXEnabled"]
    let element: AXUIElement
    let role: String, id: String
    let strings: [String]
    let value: Any?
    let children: [AXUIElement]
    let rect: CGRect
    let enabled: Bool
    let readError: AXError

    init(_ element: AXUIElement) {
        self.element = element
        var copied: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, Self.keys as CFArray, [], &copied)
        readError = error
        let values: [Any] = error == .success ? (copied as? [Any] ?? []) : Self.keys.map { wcAttribute(element, $0) ?? NSNull() }
        func get(_ index: Int) -> Any? { values.indices.contains(index) ? values[index] : nil }
        role = get(0) as? String ?? ""
        id = get(1) as? String ?? ""
        value = get(3)
        strings = [2, 3, 4, 5].compactMap { get($0) as? String }.filter { !$0.isEmpty }
        children = get(6) as? [AXUIElement] ?? []
        var point = CGPoint.zero, size = CGSize.zero
        if let p = get(7), CFGetTypeID(p as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &point) }
        if let s = get(8), CFGetTypeID(s as CFTypeRef) == AXValueGetTypeID() { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        rect = CGRect(origin: point, size: size)
        enabled = get(9) as? Bool ?? true
    }
    var selected: Bool { (value as? NSNumber)?.boolValue == true }

}

struct WeChatCapture: Sendable {
    /// Newest batch first. Delivery reverses this so attached ZIPs read forward.
    let directories: [URL]
    let messageCount: Int
    /// Native boundary probes, retained locally but never pasted.
    let checkpointDirectories: [URL]
    let readSeconds: Double
    let captureSeconds: Double
}

final class WeChatAccessibility {
    static let bundleIdentifier = "com.tencent.xinWeChat"
    private let app: NSRunningApplication
    private let root: AXUIElement
    private let chat: String
    private let cancellation: WeChatCancellation
    private let progress: (String) -> Void
    private var ownsSelection = false
    private var cleaningUp = false
    private let clock = { ProcessInfo.processInfo.systemUptime }
    private var phase = "open"
    private var scrollCount = 0
    private var scrollSeconds = 0.0
    private var scanSeconds = 0.0
    private var scanCalls = 0
    private var stableSeconds = 0.0
    private var exportSeconds = 0.0
    /// When the last scroll gesture ended, and where the wheel was left.
    /// WeChat needs a beat between gestures or two of them coalesce into one
    /// much smaller movement; spending that beat on the snapshot the engine
    /// needs anyway is free, sleeping through it is not.
    private var lastGestureEnded = 0.0
    private var lastHover: CGPoint?
    /// What this run has learned about the list it is navigating: how far a
    /// unit of scroll moves it, and the shortest gap between gestures WeChat
    /// keeps up with. Kept for the whole run — a second batch of 100 in the
    /// same conversation should not have to feel its way again.
    private var gain = 1.5
    private var gainMeasured = false
    private var gesturePause = WeChatScrollStep.baseGesturePause
    private var deltaCeiling = WeChatScrollStep.maximumDelta
    /// The message list, kept across stability checks. Re-found whenever it
    /// stops answering as itself.
    private var settledList: AXUIElement?
    private var checksSinceChatVerified = 0
    /// One entry per navigation step: requested units, the points the content
    /// actually moved, and how far the target still was. Local diagnostics only.
    private var steps: [[String: Any]] = []
    private var scrollsByPhase: [String: Int] = [:]
    private var clickCount = 0
    private var exportCount = 0
    private var rangeClicks = 0
    private var shiftRangeClicks = 0
    private var locator = ""
    private var visualMilliseconds = 0.0
    private var lastNodeCount = 0
    private var scanTruncated = false
    private var controlFailure: [String: Any]?
    private var resumedBatches = 0
    /// What the prefetch pass cost and what it loaded, for diagnostics only.
    private var prefetchSeconds = 0.0
    private var prefetchRows = 0
    private var prefetchLoaded = 0
    private var snapshots: [[String: Any]] = []

    init(chat: String, cancellation: WeChatCancellation, progress: @escaping (String) -> Void) throws {
        guard AXIsProcessTrusted() else { throw AutoPaste.Failure.notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first else { throw WeChatAutomationError.notRunning }
        self.app = app
        self.chat = WeChatForwardPreset.normalizedChat(chat)
        self.cancellation = cancellation
        self.progress = progress
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
    }

    static func currentChat() throws -> String {
        let probe = try WeChatAccessibility(chat: "", cancellation: WeChatCancellation(), progress: { _ in })
        guard let node = try probe.scan().first(where: { $0.id == "current_chat_name_label" }), let name = node.strings.first else { throw WeChatAutomationError.wrongChat }
        return WeChatForwardPreset.normalizedChat(name)
    }

    private func check() throws { if !cleaningUp { try cancellation.check() } }
    private func pause(_ seconds: Double = 0.06) throws {
        try check()
        Thread.sleep(forTimeInterval: seconds)
        try check()
    }
    private func scan() throws -> [WCNode] {
        let started = clock()
        defer { scanSeconds += clock() - started; scanCalls += 1 }
        var queue = [root], index = 0, nodes: [WCNode] = []
        while index < queue.count && nodes.count < 2000 {
            if index % 32 == 0 { try check() }
            let node = WCNode(queue[index]); index += 1
            nodes.append(node)
            if node.role != "AXMenuBar" { queue.append(contentsOf: node.children) }
        }
        lastNodeCount = nodes.count
        // A tree larger than the walk would mean the control being looked for
        // may simply never have been visited.
        scanTruncated = nodes.count >= 2000
        return nodes
    }
    private func matches(_ name: String) -> Bool { WeChatForwardPreset.normalizedChat(name) == chat }
    private func chatMatches(_ nodes: [WCNode]) -> Bool {
        nodes.contains { $0.id == "current_chat_name_label" && $0.strings.contains(where: matches) }
    }
    private func frontmost() throws {
        try check()
        guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw WeChatAutomationError.focusChanged }
    }
    private func verifyChat() throws {
        try frontmost()
        guard chatMatches(try scan()) else { throw WeChatAutomationError.focusChanged }
    }
    private func click(_ point: CGPoint, right: Bool = false, modifiers: CGEventFlags = []) throws {
        try frontmost()
        let source = CGEventSource(stateID: .privateState)
        let button: CGMouseButton = right ? .right : .left
        guard let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: button) else { throw AutoPaste.Failure.eventCreationFailed }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.flags = modifiers; up.flags = modifiers
        clickCount += 1
        lastHover = nil
        settledList = nil
        down.post(tap: .cghidEventTap)
        // Always release a posted button, including when cancellation arrives.
        Thread.sleep(forTimeInterval: 0.025)
        up.post(tap: .cghidEventTap)
        try pause()
    }
    private func press(_ node: WCNode) throws {
        try frontmost()
        guard node.enabled else { throw WeChatAutomationError.selection }
        var copied: CFArray?
        AXUIElementCopyActionNames(node.element, &copied)
        if (copied as? [String] ?? []).contains("AXPress") {
            let result = AXUIElementPerformAction(node.element, "AXPress" as CFString)
            if result == .success { try pause(); return }
            // An unacknowledged action may already have happened. Only an
            // explicitly unsupported action permits a synthetic fallback.
            guard result == .actionUnsupported || result == .notImplemented else { throw WeChatAutomationError.selection }
        }
        guard !node.rect.isEmpty else { throw WeChatAutomationError.selection }
        try click(CGPoint(x: node.rect.midX, y: node.rect.midY))
    }
    private func control(_ label: String, in nodes: [WCNode]) -> WCNode? {
        nodes.first { node in
            ["AXButton", "AXMenuItem", "AXStaticText"].contains(node.role) && node.enabled && !node.rect.isEmpty &&
            node.strings.contains { $0 == label || $0 == label + "…" || $0 == label + "..." }
        }
    }

    /// The same control, found without assuming what kind of thing it is.
    ///
    /// `control` asks for one of the three roles WeChat's own buttons have
    /// answered as. A build that dresses the same row as something else — a
    /// cell, a group, a plain image with a label — puts it out of reach while
    /// it sits on screen, pressable, in front of the user; 选择电脑中的应用 on
    /// macOS 26 is that report. So the fallback drops the role entirely and
    /// keeps only what makes a control a control: enabled, on screen, and
    /// carrying this exact text once spacing is ignored.
    ///
    /// It must also be the only such thing in the tree. Labels like 取消 repeat
    /// across a sheet and its parent window, and pressing the wrong one is
    /// worse than reporting that this could not be found.
    private func looseControl(_ label: String, in nodes: [WCNode]) -> WCNode? {
        let wanted = label.filter { !$0.isWhitespace }
        let matches = nodes.filter { node in
            node.enabled && !node.rect.isEmpty && node.role != "AXWindow" &&
            node.strings.contains { $0.filter { !$0.isWhitespace } == wanted }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func waitControl(_ label: String, timeout: Double = 2) throws -> WCNode {
        let deadline = clock() + timeout
        var relaxed: WCNode?
        repeat {
            try frontmost()
            let nodes = try scan()
            guard chatMatches(nodes) else { throw WeChatAutomationError.focusChanged }
            if let node = control(label, in: nodes) { return node }
            // Kept, not taken: the strict match may still be a frame away, and
            // it is the one that has been verified against this UI.
            if relaxed == nil { relaxed = looseControl(label, in: nodes) }
            try pause(0.02)
        } while clock() < deadline
        if let relaxed {
            locator = locator.isEmpty ? "loose-control" : locator + "+loose-control"
            return relaxed
        }
        recordControlFailure(label)
        throw WeChatAutomationError.control(label)
    }

    /// What was on screen when a control could not be found.
    ///
    /// A layout that moves under a new macOS or WeChat build cannot be taught
    /// in advance, and whoever hits it first is not holding a debugger. One
    /// reproduction now leaves behind the role, label and geometry of
    /// everything that was pressable, which is what a fix is made from.
    ///
    /// Message bodies, conversation names and the placeholder cells behind them
    /// are left out: this is a report about controls, and it is a file the user
    /// may well send someone.
    private func recordControlFailure(_ label: String) {
        let nodes = (try? scan()) ?? []
        controlFailure = [
            "label": label,
            "nodeCount": lastNodeCount,
            "scanTruncated": scanTruncated,
            "candidates": nodes.filter {
                // AXCheckBox is a person in the recipient list or a message in
                // the transcript — never a control this searches for, and both
                // carry names this file should not.
                $0.enabled && !$0.rect.isEmpty && $0.role != "AXCheckBox" && $0.role != "AXWindow" &&
                $0.id != "chat_bubble_item_view" && $0.id != "virtual_cell" && !$0.id.hasPrefix("session_item_")
            }.prefix(80).map { node -> [String: Any] in
                ["role": node.role, "id": node.id, "strings": node.strings.map { String($0.prefix(24)) },
                 "rect": [Int(node.rect.minX), Int(node.rect.minY), Int(node.rect.width), Int(node.rect.height)]]
            },
        ]
    }
    private func scroll(_ list: AXUIElement, delta: Int32, settle: Double = WeChatScrollStep.baseGesturePause) throws {
        let started = clock()
        defer { scrollSeconds += clock() - started }
        try frontmost()
        let rect = WCNode(list).rect
        guard !rect.isEmpty else { throw WeChatAutomationError.selection }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let source = CGEventSource(stateID: .privateState)
        // Whatever is left of the gap between gestures, minus everything the
        // caller already spent looking at the result of the last one.
        while clock() - lastGestureEnded < settle { try pause(0.02) }
        // The wheel is already over this list unless something else moved it.
        if lastHover != point {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            lastHover = point
            try pause(0.025)
        }
        try frontmost()
        func event(_ phase: CGScrollPhase, _ amount: Int32) -> CGEvent? {
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
            event?.location = point
            event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            return event
        }
        guard let began = event(.began, 0), let changed = event(.changed, delta), let ended = event(.ended, 0) else { throw AutoPaste.Failure.eventCreationFailed }
        // Without gesture phases this WeChat build turns even a 1-unit wheel
        // event into a ~298-point jump. Gesture scrolls retain fine movement.
        began.post(tap: .cghidEventTap)
        do {
            try frontmost()
            scrollCount += 1
            scrollsByPhase[phase, default: 0] += 1
            changed.post(tap: .cghidEventTap)
        } catch { ended.post(tap: .cghidEventTap); throw error }
        ended.post(tap: .cghidEventTap)
        lastGestureEnded = clock()
    }

    /// Brings WeChat forward from this worker thread.
    ///
    /// Same finding as `AutoPaste.bringToFront`: on macOS 14+
    /// `NSRunningApplication.activate(options:)` is ignored when the caller is
    /// not the frontmost app, and it never restores a minimized window.
    /// Measured from a background process (2026-09-06), only the LaunchServices
    /// door changed the foreground and un-minimized. The completion-handler
    /// form is used because this engine is synchronous and runs on
    /// `WeChatQuickForward.worker` — the semaphore is waited on there, never on
    /// the main thread, which is where the completion may be delivered.
    private func activate() throws {
        try check()
        guard let url = app.bundleURL else { throw WeChatAutomationError.notRunning }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in opened.signal() }
        // Capped rather than trusted: the frontmost poll below is the real
        // check, and a LaunchServices call that never calls back must not hang
        // a forward the user can no longer cancel.
        _ = opened.wait(timeout: .now() + 3)
        AutoPaste.restoreWindows(pid: app.processIdentifier)
    }

    private func openChat() throws {
        try check()
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        try activate()
        let deadline = clock() + 3
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier && clock() < deadline { try pause(0.04) }
        try frontmost()
        if !wasFrontmost { try pause(0.15) }
        let nodes = try scan()
        guard !nodes.contains(where: { $0.id == "chat_log_message_list" || $0.id == "cancel_btn" }), control("合并转发", in: nodes) == nil else { throw WeChatAutomationError.busyChat }
        if chatMatches(nodes) { return }
        let candidates = nodes.filter { node in
            guard node.id.hasPrefix("session_item_"), !node.rect.isEmpty else { return false }
            return matches(String(node.id.dropFirst("session_item_".count))) || node.strings.contains {
                matches($0.components(separatedBy: "\n").first ?? "") || matches($0.components(separatedBy: ",").first ?? "")
            }
        }
        guard candidates.count == 1, let node = candidates.first else { throw WeChatAutomationError.wrongChat }
        try press(node)
        let opened = clock() + 2
        repeat {
            if chatMatches(try scan()) { return }
            try pause()
        } while clock() < opened
        throw WeChatAutomationError.wrongChat
    }

    private struct Page {
        let list: WCNode
        let rows: [WCNode]
        var signature: String {
            "\(list.rect):\(list.children.count):" + rows.map { "\($0.role):\($0.rect):\($0.selected):\($0.strings)" }.joined(separator: "|")
        }
        func canCheck(_ row: WCNode) -> Bool {
            list.rect.insetBy(dx: 0, dy: 5).contains(CGPoint(x: row.rect.minX + 22, y: row.rect.midY))
        }
        var data: [WeChatViewportRow] {
            rows.map { WeChatViewportRow(text: $0.strings.first ?? "", y: $0.rect.minY, height: $0.rect.height) }
        }
    }

    /// Require two equal materialized snapshots. An empty/loading AX page is
    /// retried; it is never interpreted as a changed conversation or its end.
    private func stablePage(timeout: Double = 3) throws -> Page {
        let started = clock()
        defer { stableSeconds += clock() - started; checksSinceChatVerified += 1 }
        let deadline = clock() + timeout
        var previous: String?
        // Walking WeChat's whole tree is most of what a navigation step costs,
        // and a step only needs to know whether the list has come to rest — the
        // list answers that itself. The walk is kept for the case where the
        // cached list stops answering, and for one check in eight of the
        // conversation's identity. Content is not left to that check: every
        // step also re-matches the rows it already knew through
        // `WeChatViewport`, which no other conversation can satisfy.
        var verifiedHere = false
        repeat {
            try frontmost()
            var found: WCNode?
            if let settledList, checksSinceChatVerified < 8 || verifiedHere {
                let node = WCNode(settledList)
                if node.readError == .success, node.id == "chat_message_list" { found = node }
            }
            if found == nil {
                let nodes = try scan()
                guard chatMatches(nodes) else { throw WeChatAutomationError.focusChanged }
                found = nodes.first { $0.id == "chat_message_list" }
                settledList = found?.element
                checksSinceChatVerified = 0
                verifiedHere = true
            }
            if let list = found, list.readError == .success {
                let rows = list.children.map(WCNode.init).filter {
                    $0.id == "chat_bubble_item_view" && !$0.rect.intersection(list.rect).isNull
                }
                if !rows.isEmpty, rows.allSatisfy({ $0.readError == .success && !$0.strings.isEmpty }),
                   zip(rows, rows.dropFirst()).allSatisfy({ $0.rect.minY < $1.rect.minY }) {
                    let page = Page(list: list, rows: rows)
                    if page.signature == previous { return page }
                    previous = page.signature
                } else { previous = nil; settledList = nil }
            } else { settledList = nil }
            // The list settles on its own; this only paces the next look.
            try pause(0.02)
        } while clock() < deadline
        throw WeChatAutomationError.loading
    }

    private func checkedMessage(_ node: WCNode) throws -> WeChatSelectedMessage {
        guard node.role == "AXCheckBox", let label = node.strings.first else { throw WeChatAutomationError.selection }
        return WeChatSelectedMessage(description: label)
    }

    private func beginSelection(at node: WCNode, viewport: CGRect) throws -> WeChatSelectedMessage {
        phase = "select-anchor-menu"
        // A tall bubble's centre can be inside a quoted-message preview. Its
        // context menu then targets the quote. Click the main body near its top.
        let y = node.rect.minY + min(50, node.rect.height / 2)
        guard y > viewport.minY + 4, y < viewport.maxY - 4 else { throw WeChatAutomationError.selection }
        var multi: WCNode?
        for x in [node.rect.minX + min(85, node.rect.width / 2), node.rect.maxX - min(85, node.rect.width / 2)] {
            try click(CGPoint(x: x, y: y), right: true)
            do { multi = try waitControl("多选", timeout: 0.5); break }
            catch is CancellationError { throw CancellationError() }
            catch { try frontmost() }
        }
        guard let multi else { throw WeChatAutomationError.selection }
        try press(multi)
        ownsSelection = true
        _ = try waitControl("合并转发")
        let page = try stablePage()
        observe("anchor-selected", page)
        let selected = page.rows.filter(\.selected)
        guard selected.count == 1, let first = selected.first,
              node.strings.contains(where: { normal in first.strings.contains { $0 == normal || $0.hasSuffix(" " + normal) } }) else {
            throw WeChatAutomationError.selection
        }
        return try checkedMessage(first)
    }

    private struct Selection {
        let count: Int
        let newest: WeChatSelectedMessage
        let oldest: WeChatSelectedMessage?
        let checkpoint: Checkpoint
    }
    private struct Checkpoint {
        let viewport: WeChatViewport
        let window: AXUIElement
        let windowRect: CGRect
    }
    private enum SelectionStart { case latest, resume(Checkpoint, ordinal: Int) }

    /// Every navigation stage is bounded in both time and input events. A
    /// repeated viewport also catches oscillation across two different pages.
    private struct NavigationBudget {
        let deadline: Double
        let maximumSteps: Int
        var steps = 0
        var visits: [String: Int] = [:]
        mutating func observe(_ page: Page) throws {
            steps += 1
            visits[page.signature, default: 0] += 1
            guard ProcessInfo.processInfo.systemUptime < deadline, steps <= maximumSteps,
                  visits[page.signature, default: 0] <= 3 else { throw WeChatAutomationError.selection }
        }
    }

    private func window(of page: Page) throws -> WCNode {
        // WeChat's list does not expose AXWindow; its AXParent chain does.
        var current = page.list.element
        for _ in 0..<20 {
            let node = WCNode(current)
            if node.role == "AXWindow" { return node }
            guard let parent = wcAttribute(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = parent as! AXUIElement
        }
        throw WeChatAutomationError.selection
    }

    private func checkpoint(_ tracked: WeChatViewport, page: Page) throws -> Checkpoint {
        let owner = try window(of: page)
        return Checkpoint(viewport: tracked, window: owner.element, windowRect: owner.rect)
    }

    private func observe(_ label: String, _ page: Page) {
        snapshots.append(["stage": label, "firstY": page.list.rect.minY, "height": page.list.rect.height,
            "rows": page.rows.map { row -> [String: Any] in
                let hash = SHA256.hash(data: Data((row.strings.first ?? "").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                return ["hash": hash, "y": row.rect.minY, "height": row.rect.height, "selected": row.selected, "role": row.role]
            }])
        if snapshots.count > 8 { snapshots.removeFirst() }
    }

    private func rangeControl() throws -> WCNode? {
        try scan().first { node in
            node.enabled && !node.rect.isEmpty && ["AXStaticText", "AXButton"].contains(node.role) && node.strings.contains {
                let compact = $0.filter { !$0.isWhitespace }
                return compact == "选择到这里" || compact == "最多选择100条"
            }
        }
    }

    private func leaveSelection(page: Page, index: Int) throws -> (WCNode, CGRect) {
        let context = try page.rows.map { try checkedMessage($0).description }
        try restoreSelection()
        let normal = try stablePage()
        let rebound: Int
        do { rebound = try WeChatMessageContext.resolve(selected: context, target: index, normal: normal.rows.map { $0.strings.first ?? "" }) }
        catch { throw WeChatAutomationError.selection }
        return (normal.rows[rebound], normal.list.rect)
    }

    /// Messages WeChat has read into this conversation's list.
    ///
    /// The list carries one child per loaded message — a `virtual_cell`
    /// placeholder for every one but the handful actually on screen — so its
    /// child count is what has been read off disk, not what the conversation
    /// holds. Measured 2026-09-07 on 4.1.13: a conversation opens with about
    /// 36 of them and keeps what it gains, 180 then 218, after the list is
    /// dragged back and returned to the newest message.
    ///
    /// Only meaningful at the newest message and at rest. Mid-scroll the count
    /// is the buffer still ahead of the viewport, and it falls as the list
    /// climbs into it — 180, 170, 159, … 34 — jumping back up each time WeChat
    /// fetches the next thirty. Which is the whole problem, seen directly.
    private func loadedMessages(_ list: AXUIElement) -> Int {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(list, "AXChildren" as CFString, &count) == .success else { return 0 }
        return Int(count)
    }

    /// Load `target` messages of history before anything is selected, so the
    /// batches that follow scroll over rows WeChat already holds.
    ///
    /// Measured 2026-09-07 on 4.1.13: dragging back over history WeChat has
    /// not fetched runs at about 8 rows per second, and over history it has at
    /// about 64. A five-hundred message selection crosses that boundary in
    /// every one of its five batches, inside a per-batch budget sized for the
    /// fast case — which is how it failed rather than merely dragged.
    ///
    /// Coming up short is not a failure: every message loaded is one a later
    /// batch does not pay for.
    private func prefetchHistory(target: Int) throws {
        phase = "prefetch"
        let started = clock()
        defer { prefetchSeconds = clock() - started }
        let deadline = started + WeChatPrefetch.budget(messages: target)
        var page = try returnToLatest(from: try stablePage())
        // A conversation dragged back this far before — earlier in this run, or
        // by the user reading it — has nothing to fetch, and the pass costs
        // nothing beyond the count it just read.
        var loaded = loadedMessages(page.list.element)
        var rounds = 0
        while loaded < target, clock() < deadline, rounds < 3 {
            rounds += 1
            page = try dragBack(from: page, loaded: loaded, target: target, deadline: deadline)
            // The count only means anything back at the newest message, so
            // this is both the return leg and the measurement.
            page = try returnToLatest(from: page)
            let reached = loadedMessages(page.list.element)
            // A round that loaded nothing is at the start of the conversation.
            guard reached > loaded else { break }
            loaded = reached
        }
        prefetchLoaded = loaded
        // A gap the pass had to stretch belongs to the history it was reading
        // off disk, not to the loaded rows the batches now scroll over. What it
        // managed to tighten is worth keeping.
        gesturePause = min(gesturePause, WeChatScrollStep.baseGesturePause)
    }

    /// One climb back through the conversation, from the newest message.
    ///
    /// Nothing here is tracked, clicked or selected — the climb only needs
    /// WeChat to fetch the rows — so gestures go out in bursts with one settled
    /// snapshot per burst instead of per gesture, and the rows a burst covered
    /// are counted from the overlap it left, or estimated past it when it left
    /// none. That estimate is why the caller checks the loaded count afterwards
    /// rather than trusting this to have gone far enough.
    private func dragBack(from start: Page, loaded: Int, target: Int, deadline: Double) throws -> Page {
        phase = "prefetch"
        var page = start
        var travelled = page.rows.count
        var burst = WeChatPrefetch.firstBurst
        var perGesture = WeChatPrefetch.reach(delta: deltaCeiling)
        var idle = 0
        while travelled < target, clock() < deadline {
            progress(L10n.format("正在加载更早的聊天记录 · 已加载 %d 条", max(loaded, travelled)))
            let before = page
            for _ in 0..<burst { try scroll(before.list.element, delta: deltaCeiling, settle: gesturePause) }
            // A conversation being read off disk settles later than one in
            // memory, and this is the pass that meets it there.
            page = try stablePage(timeout: 5)
            guard page.signature != before.signature else {
                // Either the conversation has no more history, or WeChat is
                // still fetching it. One more burst, spaced further apart,
                // tells the two apart.
                idle += 1
                gesturePause = WeChatScrollStep.lengthened(gesturePause)
                if idle >= 2 { break }
                continue
            }
            idle = 0
            let step = WeChatPrefetch.burst(from: before.data, to: page.data,
                                            gestures: burst, delta: deltaCeiling, reach: perGesture)
            travelled += step.rows
            prefetchRows += step.rows
            // A burst that left overlap is one WeChat clamped, and that is the
            // only kind whose reach can be measured. Keeping a plausible one
            // also hands the first batch a measured step instead of a careful.
            if let measured = step.pointsPerGesture {
                let gained = measured / Double(deltaCeiling)
                if WeChatScrollStep.isPlausible(gain: gained) { perGesture = measured; gain = gained; gainMeasured = true }
            }
            burst = WeChatPrefetch.nextBurst(burst, clamped: step.clamped)
            gesturePause = WeChatPrefetch.nextPause(gesturePause, clamped: step.clamped)
        }
        return page
    }

    /// Back to the newest message, however far away it is.
    ///
    /// One enormous gesture does not do it: WeChat clamps anything far past the
    /// largest it honours to about 50 points, so the distance has to be covered
    /// by gestures it does honour. Downwards is over rows WeChat already holds,
    /// so they can go out in bursts with one settled snapshot between them.
    private func returnToLatest(from start: Page) throws -> Page {
        let resuming = phase
        phase = "return-to-latest"
        defer { phase = resuming }
        var page = start
        // Usually the list is already where this wants it — every batch anchor
        // comes through here — so the first burst is small enough to find that
        // out cheaply, and doubles only while there is still distance to cover.
        var burst = 2
        var idle = 0
        let deadline = clock() + 45
        while clock() < deadline {
            let before = page.signature
            for _ in 0..<burst {
                try scroll(page.list.element, delta: -WeChatScrollStep.maximumDelta, settle: WeChatScrollStep.minimumGesturePause)
            }
            page = try stablePage(timeout: 5)
            if page.signature == before {
                idle += 1
                if idle >= 2 { return page }
            } else {
                idle = 0
                burst = min(8, burst * 2)
            }
        }
        throw WeChatAutomationError.selection
    }

    private func selectBatch(limit: Int, start: SelectionStart) throws -> Selection {
        phase = "select-anchor"
        let anchor: WCNode, viewport: CGRect
        switch start {
        case .resume(let saved, let ordinal):
            phase = ordinal == 0 ? "time-boundary-anchor" : "next-batch-anchor"
            var page = try stablePage(), tracked = saved.viewport
            let owner = try window(of: page)
            observe("resume", page)
            let stillSelecting = page.rows.allSatisfy { $0.role == "AXCheckBox" }
            guard CFEqual(owner.element, saved.window), owner.rect == saved.windowRect,
                  stillSelecting || page.rows.allSatisfy({ $0.role == "AXStaticText" }) else { throw WeChatAutomationError.selection }
            // A sheet creates a new observation boundary. No cached AX message
            // handles survive it, and no search starts from an unknown position.
            // External sharing in WeChat 4.1.13 exits multi-select. The viewport
            // stays put, but checkbox descriptions lose their sender prefix.
            // Confirm every row's content/order/geometry before rebinding.
            do { try tracked.resume(page.data, afterLeavingSelection: !stillSelecting) } catch { throw WeChatAutomationError.selection }
            if !stillSelecting { ownsSelection = false }
            var budget = NavigationBudget(deadline: clock() + 15, maximumSteps: 60)
            while true {
                try budget.observe(page)
                if let index = tracked.index(of: ordinal) {
                    let row = page.rows[index]
                    if row.rect.minY >= page.list.rect.minY + 4,
                       row.rect.minY + min(70, row.rect.height) <= page.list.rect.maxY - 4 {
                        // For next batch, the exact adjacent ordinal must be
                        // unchecked; a time trim instead reuses selected newest.
                        guard !stillSelecting || row.selected == (ordinal == 0) else { throw WeChatAutomationError.selection }
                        if ordinal > 0 {
                            guard let previous = tracked.index(of: ordinal - 1), previous == index + 1,
                                  !stillSelecting || page.rows[previous].selected else { throw WeChatAutomationError.selection }
                        }
                        observe("confirmed-anchor", page)
                        if stillSelecting { (anchor, viewport) = try leaveSelection(page: page, index: index) }
                        else { anchor = row; viewport = page.list.rect }
                        resumedBatches += 1
                        break
                    }
                }
                let delta: Int32
                if let index = tracked.index(of: ordinal) {
                    delta = page.rows[index].rect.midY < page.list.rect.midY ? 60 : -60
                } else { delta = ordinal > tracked.firstOrdinal ? 250 : -250 }
                try scroll(page.list.element, delta: delta)
                page = try stablePage()
                do { try tracked.advance(page.data, older: delta > 0) } catch { throw WeChatAutomationError.selection }
            }
        case .latest:
            // This used to open with one -10_000 gesture. Measured twice on
            // 2026-09-07 against 4.1.13, WeChat clamps a gesture that large to
            // about 50 points — a single message — so it only ever looked like
            // it worked, because the list is normally already at the newest
            // message and the loop stopped on the first unchanged snapshot. A
            // user who had scrolled up first found it could not get home.
            let page = try returnToLatest(from: try stablePage())
            guard let latest = page.rows.last, page.canCheck(latest) else { throw WeChatAutomationError.selection }
            anchor = latest; viewport = page.list.rect
        }
        let newest = try beginSelection(at: anchor, viewport: viewport)
        phase = "select-range"
        // Every batch needs the exact first visible message before pressing
        // the range button. Track overlapping content and measured motion,
        // never AX child indices; the exported count is an independent check.
        var page = try stablePage()
        guard let index = page.rows.firstIndex(where: \.selected) else { throw WeChatAutomationError.selection }
        var tracked = WeChatViewport(rows: page.data, anchorIndex: index)
        if limit == 1 { return Selection(count: 1, newest: newest, oldest: newest, checkpoint: try checkpoint(tracked, page: page)) }
        var unchanged = 0
        // Backed off by half whenever a step outruns the viewport tracker.
        var reachFactor = 1.0, overshoots = 0, healthySteps = 0
        var budget = NavigationBudget(deadline: clock() + 35, maximumSteps: 120)
        while true {
            try budget.observe(page)
            let tallest = page.rows.map(\.rect.height).max() ?? page.list.rect.height
            var delta = WeChatScrollStep.delta(
                reach: WeChatScrollStep.reach(listHeight: page.list.rect.height, tallestRow: tallest,
                                              gainMeasured: gainMeasured, reachFactor: reachFactor),
                gain: gain, ceiling: deltaCeiling
            )
            if let target = tracked.index(of: limit - 1) {
                let row = page.rows[target]
                // A short interval at the live bottom cannot be scrolled to
                // the top range button. WeChat's native Shift-click selects
                // the visible interval in one action, including quoted rows.
                if unchanged > 0, limit < 100, let newestIndex = tracked.index(of: 0),
                   target < newestIndex, page.canCheck(row), page.canCheck(page.rows[newestIndex]) {
                    let oldest = try checkedMessage(row)
                    try click(CGPoint(x: row.rect.minX + 22, y: row.rect.midY), modifiers: .maskShift)
                    shiftRangeClicks += 1
                    page = try stablePage()
                    observe("after-shift-range", page)
                    do { try tracked.resume(page.data) } catch { throw WeChatAutomationError.selection }
                    guard page.rows.indices.filter({ page.rows[$0].selected }) == Array(target...newestIndex) else { throw WeChatAutomationError.selection }
                    return Selection(count: limit, newest: newest, oldest: oldest, checkpoint: try checkpoint(tracked, page: page))
                }
                let fullyVisible = page.rows.indices.filter { page.list.rect.contains(page.rows[$0].rect) }
                if fullyVisible.first == target, let button = try rangeControl(), button.strings.contains("选择到这里") {
                    let oldest = try checkedMessage(row)
                    observe("before-range", page)
                    try press(button)
                    rangeClicks += 1
                    page = try stablePage()
                    observe("after-range", page)
                    do { try tracked.resume(page.data) } catch { throw WeChatAutomationError.selection }
                    guard let endpoint = tracked.index(of: limit - 1), page.rows[endpoint].selected else { throw WeChatAutomationError.selection }
                    return Selection(count: limit, newest: newest, oldest: oldest, checkpoint: try checkpoint(tracked, page: page))
                }
                let distance = page.list.rect.minY + 8 - row.rect.minY
                let amount = Int((distance / max(1, gain)).rounded())
                delta = Int32(max(-250, min(250, amount == 0 ? (distance >= 0 ? 1 : -1) : amount)))
            }
            let before = page
            try scroll(page.list.element, delta: delta, settle: gesturePause)
            page = try stablePage()
            unchanged = page.signature == before.signature ? unchanged + 1 : 0
            guard unchanged < 3 else { throw WeChatAutomationError.historyIncomplete }
            do { try tracked.advance(page.data, older: delta > 0) }
            catch {
                // The step outran the tracker: nothing in the new view is also
                // in the old one. Scrolling back the same amount returns to a
                // view the tracker still recognises, so a step that reached too
                // far costs one extra step instead of the whole selection.
                guard overshoots < 2 else { throw WeChatAutomationError.selection }
                overshoots += 1
                reachFactor = max(0.4, reachFactor / 2)
                try scroll(page.list.element, delta: -delta)
                page = try stablePage()
                do { try tracked.advance(page.data, older: delta < 0) }
                catch { throw WeChatAutomationError.selection }
                continue
            }
            let measured = abs(tracked.lastDisplacement / Double(delta))
            if steps.count < 200 {
                steps.append(["delta": Int(delta), "moved": Int(tracked.lastDisplacement.rounded()),
                              "gain": (measured * 100).rounded() / 100, "pause": (gesturePause * 100).rounded() / 100,
                              "ordinal": tracked.firstOrdinal, "want": limit - 1])
            }
            if WeChatScrollStep.isPlausible(gain: measured) {
                gain = measured; gainMeasured = true
                reachFactor = min(1, reachFactor * 1.5)
                healthySteps += 1
                gesturePause = WeChatScrollStep.shortened(gesturePause, healthySteps: healthySteps)
            } else if measured < 0.4 {
                // The gesture was clamped — WeChat is loading older history.
                // Steering by this would ask for a larger gesture and clamp
                // harder; wait longer for the load instead.
                healthySteps = 0
                gesturePause = WeChatScrollStep.lengthened(gesturePause)
                deltaCeiling = max(300, deltaCeiling / 2)
            }
        }
    }

    /// The forward sheet, once it has finished arriving.
    ///
    /// Waited for rather than sampled: 取消 is up before the sheet has settled,
    /// and one look immediately after it has been seen to find no 确定 at all
    /// and call the layout unsupported for a sheet that was merely animating.
    ///
    /// 确定 must still be disabled. It enables the moment a recipient is
    /// selected, so requiring it off is also the check that nothing has been
    /// selected by accident before this clicks anything.
    private func recipientSheet(timeout: Double = 2) throws -> (WCNode, WCNode, WCNode) {
        let deadline = clock() + timeout
        repeat {
            let nodes = try scan()
            if let cancel = nodes.first(where: { $0.id == "cancel_btn" }),
               let confirm = nodes.first(where: { $0.id == "confirm_btn" }), !confirm.enabled {
                var current = cancel.element
                for _ in 0..<10 {
                    let node = WCNode(current)
                    if node.role == "AXSheet", node.rect.contains(cancel.rect), node.rect.contains(confirm.rect) { return (node, cancel, confirm) }
                    guard let parent = wcAttribute(current, "AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    current = parent as! AXUIElement
                }
            }
            try pause(0.04)
        } while clock() < deadline
        recordControlFailure("recipient-sheet")
        throw WeChatAutomationError.unsupportedLayout
    }

    /// Where 转发到其他应用 is, from the shape of the list it lives in.
    ///
    /// The row sits in the recipient list, below whatever promotions WeChat is
    /// showing and above the contacts. There is one promotion per companion app
    /// installed — 企业微信, WorkBuddy — so there may be none, one or two of
    /// them, and the row moves down by one strip for each. A fixed offset from
    /// the sheet could only ever match one of those: this machine has one
    /// promotion, macOS 26 with none put the row 125 points higher, and the old
    /// offset landed in the contact list, which is a click that selects a
    /// person rather than one that misses.
    ///
    /// What does hold across all three is the order and the labels. Promotions
    /// and the tab row carry no accessibility label; every contact carries its
    /// name. So the tab row is the last unlabelled row before the first labelled
    /// one, however many strips are stacked above it — checked against this
    /// machine, where it lands on exactly the point the old offset computed.
    ///
    /// Horizontally the row is 最近聊天 | 创建聊天 | 转发到其他应用 and this is
    /// the third of them, 245 points into the 320 the list is wide. That
    /// proportion does not move with the promotions; only the row does.
    private func externalShareRow(in nodes: [WCNode]) -> CGPoint? {
        guard let list = nodes.first(where: { $0.id == "sp_to_select_contact_list" }), !list.rect.isEmpty else { return nil }
        // Only the head of the list matters, and reading every contact would be
        // one cross-process read per person in the address book.
        let rows = list.children.prefix(12).map(WCNode.init)
            .filter { $0.role == "AXCheckBox" && !$0.rect.isEmpty }
            .sorted { $0.rect.minY < $1.rect.minY }
        guard let firstNamed = rows.firstIndex(where: { !$0.strings.isEmpty }), firstNamed > 0 else { return nil }
        let tabs = rows[firstNamed - 1]
        guard tabs.rect.width > 0, list.rect.contains(tabs.rect) else { return nil }
        return CGPoint(x: tabs.rect.minX + tabs.rect.width * 0.766, y: tabs.rect.midY)
    }

    /// Where 转发到其他应用 is, read off the sheet.
    ///
    /// WeChat draws this row itself: it is in neither of the two conversations
    /// this has been tried against, by role or by text, so there is nothing to
    /// press and nothing to measure from. It has to be looked at.
    ///
    /// It used to be a measured offset from the sheet's corner, which cost no
    /// permission and was only ever right by luck. What sits above the row is a
    /// stack of promotions for whatever else the user has installed — 企业微信,
    /// WorkBuddy — so the row moves down by one strip per promotion, and the
    /// developer's own machine happened to have exactly one. macOS 26 with none
    /// of them put the row 125 points above where the offset aimed, which on
    /// that layout is inside the recipient list: not a click that misses, a
    /// click that selects somebody. The sheet's outer size and its buttons stay
    /// where they were through all of it, so no check on the outline can tell
    /// the layouts apart.
    private func externalSharePoint(_ sheet: WCNode) throws -> CGPoint {
        guard CGPreflightScreenCaptureAccess() else { throw WeChatAutomationError.screenRecording }
        let started = clock()
        // The left column, down far enough to still contain the row when the
        // promotions above it are at their tallest. Each installed companion
        // app (企业微信, WorkBuddy) adds a strip of about 125 points, and two of
        // them push the row to roughly 330 — past the 269 this used to read,
        // which would have found nothing and reported an unsupported layout.
        // Reading more costs a few milliseconds; the recipient names it takes
        // in cannot be mistaken for the label being searched for.
        let crop = CGRect(x: floor(sheet.rect.minX), y: floor(sheet.rect.minY),
                          width: floor(sheet.rect.width * 0.45), height: floor(sheet.rect.height * 0.78))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dukou-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("control.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(Int(crop.minX)),\(Int(crop.minY)),\(Int(crop.width)),\(Int(crop.height))", url.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try frontmost()
        try process.run()
        let deadline = clock() + 5
        while process.isRunning && clock() < deadline {
            do { try pause(0.04) } catch { process.terminate(); throw error }
        }
        if process.isRunning { process.terminate(); throw WeChatAutomationError.unsupportedLayout }
        guard process.terminationStatus == 0 else { throw WeChatAutomationError.unsupportedLayout }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // One fixed Chinese label. Latin script and the language model that
        // second-guesses words are both work for a phrase that is either there
        // exactly or is not the one being looked for.
        request.recognitionLanguages = ["zh-Hans"]
        request.usesLanguageCorrection = false
        request.customWords = ["转发到其他应用"]
        try VNImageRequestHandler(url: url).perform([request])
        let matches = (request.results ?? []).filter { observation in
            observation.topCandidates(3).contains { $0.string.filter { !$0.isWhitespace } == "转发到其他应用" }
        }
        guard matches.count == 1, let match = matches.first,
              try recipientSheet().0.rect == sheet.rect else { throw WeChatAutomationError.unsupportedLayout }
        visualMilliseconds += (clock() - started) * 1000
        locator = "cropped-vision"
        return CGPoint(x: crop.minX + match.boundingBox.midX * crop.width, y: crop.minY + (1 - match.boundingBox.midY) * crop.height)
    }

    private func nativeExport(ready: URL, shelfExtension: URL) throws -> URL {
        phase = "export"
        let exportStarted = clock()
        defer { exportSeconds += clock() - exportStarted }
        func ids() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(at: ready, includingPropertiesForKeys: nil).map(\.lastPathComponent).filter { UUID(uuidString: $0) != nil })
        }
        let baseline = try ids()
        let installed = Bundle(url: shelfExtension)
        guard installed?.bundleIdentifier == "dev.dukou.Dukou.Share", installed?.object(forInfoDictionaryKey: "DKShareAction") as? String == "shelf" else { throw WeChatAutomationError.missingShare }
        try press(try waitControl("合并转发"))
        _ = try waitControl("取消")
        let sheetNodes = try scan()
        // Worth asking twice before falling back to geometry: whatever the row
        // is dressed as, being able to press it directly beats aiming at it.
        if let external = control("转发到其他应用", in: sheetNodes) ?? looseControl("转发到其他应用", in: sheetNodes) {
            locator = "accessibility"
            try press(external)
        } else if let row = externalShareRow(in: sheetNodes) {
            locator = "list-row"
            try click(row)
        } else {
            // Last resort, and the only path that costs a permission: the list
            // is not shaped the way any build so far has shaped it.
            // recipientSheet also asserts 确定 is still disabled, so a stray
            // selection would be caught before anything is clicked.
            let (sheet, _, _) = try recipientSheet()
            try click(try externalSharePoint(sheet))
        }
        // Never retry a possibly successful click. Verify the next UI state.
        try press(try waitControl("选择电脑中的应用"))
        var share: WCNode?
        let deadline = clock() + 4
        repeat {
            try frontmost()
            let menu = try scan()
            share = control("暂存到渡口", in: menu) ?? control("添加到 Dukou", in: menu) ?? control("Stash in Dukou", in: menu)
            if share != nil { break }
            try pause(0.02)
        } while clock() < deadline
        guard let share else { throw WeChatAutomationError.missingShare }
        try press(share)
        let receiptDeadline = clock() + 45
        repeat {
            let candidates = try ids().subtracting(baseline)
            guard candidates.count <= 1 else { throw WeChatAutomationError.ambiguousReceipt }
            if let id = candidates.first {
                let directory = ready.appendingPathComponent(id)
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
                    exportCount += 1
                    // Close a remaining recipient sheet. External sharing may
                    // also exit multi-select; the next stage observes that
                    // transition and rebinds the saved ordered viewport.
                    if let cancel = try scan().first(where: { $0.id == "cancel_btn" }) { try press(cancel) }
                    return directory
                }
            }
            try pause(0.02)
        } while clock() < receiptDeadline
        throw WeChatAutomationError.receiptTimeout
    }

    private func restoreSelection() throws {
        try verifyChat()
        if let cancel = try scan().first(where: { $0.id == "cancel_btn" }) { try press(cancel) }
        if let cancel = control("取消多选", in: try scan()) { try press(cancel) }
        let deadline = clock() + 2
        while control("合并转发", in: try scan()) != nil && clock() < deadline { try pause(0.05) }
        guard control("合并转发", in: try scan()) == nil else { throw WeChatAutomationError.selection }
        ownsSelection = false
    }

    private func cleanup() {
        cleaningUp = true
        defer { cleaningUp = false }
        guard ownsSelection, (try? verifyChat()) != nil else { return }
        try? restoreSelection()
    }

    private func diagnostics(started: Double, outcome: String, count: Int) {
        let report: [String: Any] = ["schemaVersion": 3, "strategy": "native-range-checkpoint", "at": ISO8601DateFormatter().string(from: Date()),
            "outcome": outcome, "phase": phase, "seconds": clock() - started, "messageCount": count,
            "scrolls": scrollCount, "scrollSeconds": scrollSeconds, "scanSeconds": scanSeconds, "scanCalls": scanCalls, "stableSeconds": stableSeconds, "exportSeconds": exportSeconds, "prefetchSeconds": prefetchSeconds, "prefetchRows": prefetchRows, "prefetchLoaded": prefetchLoaded, "scrollsByPhase": scrollsByPhase, "steps": steps, "clicks": clickCount, "rangeClicks": rangeClicks, "shiftRangeClicks": shiftRangeClicks, "exports": exportCount, "resumedBatches": resumedBatches,
            "snapshots": snapshots,
            "locator": locator, "visualMilliseconds": visualMilliseconds, "lastNodeCount": lastNodeCount,
            "scanTruncated": scanTruncated, "controlFailure": controlFailure ?? [:],
            "wechatVersion": app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String } ?? "unknown"]
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dukou/WeChat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("latest.json"), options: .atomic)
        }
    }

    func capture(range: WeChatForwardRange, ready: URL, shelfExtension: URL) throws -> WeChatCapture {
        guard range.unit == .messages else { throw WeChatAutomationError.timeRangeUnavailable }
        guard range.isValid else { throw WeChatAutomationError.selection }
        let started = clock(), end = Date()
        var count = 0, outcome = "failed"
        defer { cleanup(); diagnostics(started: started, outcome: outcome, count: count) }
        progress(L10n.text("正在打开微信群聊…"))
        try openChat()
        // Anything past one native batch reaches history WeChat has not
        // materialised yet. Load it in one pass now rather than a gesture at a
        // time inside every batch's budget.
        if range.value > WeChatPrefetch.threshold { try prefetchHistory(target: range.value) }
        var directories: [URL] = [], checkpoints: [URL] = []
        var start = SelectionStart.latest
        var oldestDate: Date?
        var examined = 0
        let cutoff = range.start(at: end)
        while examined < 2000 {
            try verifyChat()
            let limit = range.unit == .messages ? min(100, range.value - count) : 100
            progress(L10n.format("正在选择并导出消息 · 已完成 %d 条", count))
            var selected = try selectBatch(limit: limit, start: start)
            start = .resume(selected.checkpoint, ordinal: selected.count)
            var included = selected.count
            var directory = try nativeExport(ready: ready, shelfExtension: shelfExtension)
            phase = "verify"
            let records = try WeChatArchive.records(directory: directory, count: selected.count, newest: selected.newest, oldest: selected.oldest, cancellation: cancellation)
            if let oldestDate, let last = records.last, last.date > oldestDate { throw WeChatReadError.transcriptMismatch }
            oldestDate = records.first?.date
            examined += selected.count
            var finished = range.unit == .messages && count + selected.count == range.value
            if cutoff != nil {
                let excluded = try range.excludedPrefix(in: records, at: end)
                if excluded > 0 {
                    finished = true
                    checkpoints.append(directory)
                    if excluded == selected.count { included = 0 }
                    else {
                        included = selected.count - excluded
                        selected = try selectBatch(limit: included, start: .resume(selected.checkpoint, ordinal: 0))
                        directory = try nativeExport(ready: ready, shelfExtension: shelfExtension)
                        phase = "verify-boundary"
                        let trimmed = try WeChatArchive.records(directory: directory, count: selected.count, newest: selected.newest, oldest: selected.oldest, cancellation: cancellation)
                        guard trimmed == Array(records.dropFirst(excluded)) else { throw WeChatReadError.transcriptMismatch }
                    }
                }
            }
            if included > 0 { directories.append(directory); count += included }
            if finished {
                phase = "complete"; outcome = "verified"
                return WeChatCapture(directories: directories, messageCount: count, checkpointDirectories: checkpoints, readSeconds: 0, captureSeconds: clock() - started)
            }
        }
        throw WeChatAutomationError.historyIncomplete
    }
}
