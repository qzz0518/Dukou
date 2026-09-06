import AppKit
import ApplicationServices
import DukouCore

/// Activates another app and presses ⌘V in it.
///
/// This is the only part of Dukou that reaches outside its own windows, and it
/// is gated by the system: synthesising a keystroke requires the Accessibility
/// permission, which only the user can grant. Everything here is written so that
/// a refusal degrades to "the files are on your clipboard, press ⌘V yourself"
/// rather than to a silent no-op.
enum AutoPaste {
    enum Failure: Error, LocalizedError {
        case notInstalled(name: String)
        case notTrusted
        case didNotBecomeActive(name: String)
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .notInstalled(let name):
                return L10n.format("这台 Mac 上没有找到 %@。", name)
            case .notTrusted:
                return L10n.text("Dukou 还没有「辅助功能」权限，没法代你按 ⌘V。")
            case .didNotBecomeActive(let name):
                return L10n.format("%@ 没有切到前台，已经放弃自动粘贴。", name)
            case .eventCreationFailed:
                return L10n.text("系统没有接受这次按键事件。")
            }
        }
    }

    /// Synchronous, side-effect free and safe to call from anywhere, so the
    /// first frame of any UI that depends on it already shows the truth.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    static func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    /// Brings the target forward and pastes into it.
    ///
    /// The wait is not decoration: `openApplication` returns as soon as the
    /// process is running, which on a cold launch is long before it has a window
    /// or a focused text field. Pressing ⌘V at that moment types into nothing.
    static func activateAndPaste(
        applicationAt url: URL,
        bundleIdentifier: String,
        displayName: String,
        plan: [PastePayload]
    ) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        // The same raise `bringToFront` runs, so both paths leave the target in
        // the same state: the window the user last had focused is on top, and
        // out of the Dock if that is where the whole app was, before ⌘V goes
        // anywhere near it.
        if let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier {
            restoreWindows(pid: pid)
        }
        try await waitUntilFrontmost(bundleIdentifier: bundleIdentifier, displayName: displayName)
        // A short settle after the app is frontmost, so the window has had a
        // turn of its own run loop to focus its input field.
        try? await Task.sleep(nanoseconds: 350_000_000)

        guard isTrusted else { throw Failure.notTrusted }
        for (index, payload) in plan.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: betweenPastes) }
            guard FilePasteboard.write(payload) else { throw Failure.eventCreationFailed }
            try pressCommandV()
        }
    }

    /// Between the two pastes of a prompt-plus-files plan. The target has to
    /// take the first one — attach the file, insert the text — before the
    /// pasteboard is rewritten under it; a chat app that is still reading a
    /// file URL when the text lands drops one or the other.
    private static let betweenPastes: UInt64 = 450_000_000

    /// A quick forward targets the exact running process selected at its start.
    /// The clipboard is written only after that process owns the foreground.
    @MainActor
    static func pasteIntoRunning(pid: pid_t, bundleIdentifier: String, displayName: String, plan: [PastePayload], checkCancellation: () throws -> Void) async throws {
        try checkCancellation()
        guard isTrusted else { throw Failure.notTrusted }
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == bundleIdentifier, !app.isTerminated else { throw Failure.didNotBecomeActive(name: displayName) }
        try await bringToFront(app, displayName: displayName, checkCancellation: checkCancellation)
        try await Task.sleep(nanoseconds: 350_000_000)
        for (index, payload) in plan.enumerated() {
            if index > 0 { try await Task.sleep(nanoseconds: betweenPastes) }
            try checkCancellation()
            guard isTrusted, !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Failure.didNotBecomeActive(name: displayName) }
            guard FilePasteboard.write(payload) else { throw Failure.eventCreationFailed }
            let generation = NSPasteboard.general.changeCount
            // Recheck immediately before posting; no suspension can interleave
            // a second Dukou forward between the clipboard and this keystroke.
            try checkCancellation()
            guard NSPasteboard.general.changeCount == generation, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw Failure.didNotBecomeActive(name: displayName) }
            try pressCommandV()
        }
    }

    /// Brings an already-running app forward, the way clicking its Dock icon
    /// does, and waits until it actually owns the foreground.
    ///
    /// Not `NSRunningApplication.activate(options:)`. Since macOS 14 activation
    /// is cooperative: the request is granted to whoever the system thinks the
    /// user is interacting with, and a process that is not itself frontmost is
    /// simply ignored. Dukou is `LSUIElement` and WeChat owns the foreground for
    /// the whole of a quick forward, so that call was always the ignored kind —
    /// and the forward then failed on its own 4 s timeout. Measured from a
    /// background process (2026-09-06):
    ///
    ///     before:                front = 访达      minimized: [true]
    ///     after activate():      front = 访达      minimized: [true]
    ///     after openApplication: front = 文本编辑  minimized: [false]
    ///
    /// `openApplication(activates: true)` goes through LaunchServices, which is
    /// the same door a Dock click uses: it changes the foreground from a
    /// background caller *and* restores a minimized window. That is the whole
    /// reason the Share-menu path (`activateAndPaste`) has always worked while
    /// this one could not.
    @MainActor
    static func bringToFront(
        _ app: NSRunningApplication,
        displayName: String,
        timeout: TimeInterval = 4,
        checkCancellation: () throws -> Void = {}
    ) async throws {
        // An app with no bundle on disk cannot be opened by LaunchServices, and
        // there is no second way in that a background caller may use.
        guard let url = app.bundleURL else { throw Failure.didNotBecomeActive(name: displayName) }
        let pid = app.processIdentifier

        try await activate(url, displayName: displayName)
        restoreWindows(pid: pid)

        let started = Date()
        var askedTwice = false
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            try checkCancellation()
            let waited = Date().timeIntervalSince(started)
            guard waited < timeout else { throw Failure.didNotBecomeActive(name: displayName) }
            // One retry at the halfway mark. A LaunchServices activation that
            // arrives while the target is still showing a modal sheet, or while
            // Mission Control is on screen, is dropped without an error; asking
            // again costs nothing when the first one worked.
            if !askedTwice, waited >= timeout / 2 {
                askedTwice = true
                try await activate(url, displayName: displayName)
                restoreWindows(pid: pid)
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    private static func activate(_ url: URL, displayName: String) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // A forward is not something the user opened; it must not push the
        // target to the top of 最近使用的项目.
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw Failure.didNotBecomeActive(name: displayName)
        }
    }

    /// Raises the target's focused window, and takes it out of the Dock only
    /// when the app has nothing else on screen.
    ///
    /// Belt and braces behind `activate`, and deliberately timid. Restoring
    /// *every* minimized window is the obvious reading of 「还原目标」 and is
    /// wrong twice: it reopens windows the user put away on purpose, and —
    /// measured 2026-09-06 with TextEdit, window A focused and window B in the
    /// Dock — deminiaturizing makes a window key, so B ends up focused and ⌘V
    /// lands in the window the user was not looking at. WeChat pays the same
    /// price: a popped-out chat coming back reads as wrongChat.
    ///
    /// So the focused window is read *before* anything is touched, that one is
    /// the only window ever unminimized, and only when there is no other way to
    /// see the app — the case LaunchServices already covers, kept as the
    /// fallback for when it does not. Every error is ignored on purpose: this
    /// backs up a foreground change that has already been asked for, and an app
    /// that exposes no AX windows (one still launching) is the ordinary case,
    /// not a failure.
    static func restoreWindows(pid: pid_t) {
        guard isTrusted else { return }
        let application = AXUIElementCreateApplication(pid)
        // One second, the same cap the WeChat engine puts on its own AX reads.
        // `bringToFront` runs on the MainActor, and the global default would let
        // an app that has stopped answering freeze Dukou's own windows.
        AXUIElementSetMessagingTimeout(application, 1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return }
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
        // The type check before the cast is the same guard `window(of:)` uses:
        // an AX attribute is a `CFTypeRef` and a forced cast on the wrong kind
        // traps rather than returning nil.
        let raise: AXUIElement
        if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            raise = focused as! AXUIElement
        } else {
            raise = windows[0]
        }
        if windows.allSatisfy(isMinimized) {
            AXUIElementSetAttributeValue(raise, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(raise, kAXRaiseAction as CFString)
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var minimized: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success else { return false }
        return (minimized as? Bool) == true
    }

    private static func waitUntilFrontmost(
        bundleIdentifier: String,
        displayName: String,
        timeout: TimeInterval = 4
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
                return
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        throw Failure.didNotBecomeActive(name: displayName)
    }

    /// `kVK_ANSI_V` is a physical key position, not the letter "V", so this
    /// works on Dvorak and on non-Latin layouts where a character-based lookup
    /// would send the wrong key.
    private static let virtualKeyV: CGKeyCode = 0x09

    private static func pressCommandV() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else { throw Failure.eventCreationFailed }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // The HID tap posts as if the key were physically pressed, which is what
        // reaches an app that is not listening for annotated session events.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
