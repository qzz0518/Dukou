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
        app.activate(options: [])
        let deadline = Date().addingTimeInterval(4)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid && Date() < deadline {
            try checkCancellation()
            try await Task.sleep(nanoseconds: 60_000_000)
        }
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
