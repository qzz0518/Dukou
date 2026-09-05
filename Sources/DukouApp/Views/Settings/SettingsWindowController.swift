import AppKit
import SwiftUI

/// Dukou's settings window, opened by AppKit and only when something asks for
/// it.
///
/// This started life as a SwiftUI `Window` scene, which is §4.1's other option.
/// Measured on the signed bundle: the scene orders its window on screen during a
/// plain `open Dukou.app`, before the delegate has decided anything — so a
/// launch that was only meant to put a glyph in the menu bar dropped a settings
/// window in front of whatever the user was doing, on 通用 rather than on the
/// pane first run is supposed to show. There is no pre-macOS-15 way to tell the
/// scene not to; `defaultLaunchBehavior(.suppressed)` is 15+ and Dukou targets
/// 14. An `NSWindow` that nobody has ordered in simply is not there.
///
/// Everything about the chrome exists to let the content run to the top edge:
/// no title, transparent title bar, `fullSizeContentView`, and the traffic
/// lights end up floating over the navigation column.
@MainActor
final class SettingsWindowController {
    private let content: () -> SettingsView
    private let router: SettingsRouter
    private var window: NSWindow?

    init(router: SettingsRouter, content: @escaping () -> SettingsView) {
        self.router = router
        self.content = content
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// `tab` is set before the window is ordered in, so the pane the caller
    /// asked for is the first thing drawn rather than a flash of 通用.
    func show(_ tab: SettingsTab?) {
        if let tab { router.tab = tab }

        // An accessory app is never activated by the system on its own — not by
        // `open`, not by a double click in Finder — so a window ordered in
        // without this one call would appear behind the app the user is looking
        // at and take a second click to reach.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            // An external link can change the pane while a control in the old
            // pane still owns focus. Let the next Tab start in this pane.
            if tab != nil { window.makeFirstResponder(nil) }
            return
        }

        let controller = NSHostingController(rootView: content())
        // Measured: left at its default, the hosting controller pushes its
        // preferred content size at the window and AppKit adds a title bar's
        // 28 pt on top of it, so a 560 pt design came out 588 pt tall. The size
        // here is not negotiable, so the controller does not get a vote.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // No `.resizable`: the layout is designed at one size, and §4.1 fixes it
        // at 780 × 560.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        // The window has no title bar to grab, so the background is the handle.
        window.isMovableByWindowBackground = true
        // Closing a menu bar app's only window must not deallocate it.
        window.isReleasedWhenClosed = false
        // `fullSizeContentView` puts the content view over the whole frame, so
        // the frame is the design size — setting the *content* size would add
        // the title bar to it again.
        window.setFrame(
            NSRect(origin: .zero, size: NSSize(width: Metrics.settingsWidth, height: Metrics.settingsHeight)),
            display: false
        )
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // Opening a pane is not a request to edit its first field or focus the
        // first sidebar item. Keyboard navigation starts with the user's Tab.
        window.makeFirstResponder(nil)
    }

    func close() {
        window?.close()
    }
}
