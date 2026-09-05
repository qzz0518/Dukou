import AppKit

/// The floating shelf window.
///
/// `.nonactivatingPanel` is the whole point: the user shares from WeChat and the
/// shelf appears without pulling focus out of WeChat, and a drag can start from
/// it while another app stays active. Every other setting here follows from
/// that — the panel must be reachable from any Space and alongside a full-screen
/// app, and it must not vanish when Dukou is deactivated.
final class ShelfPanel: NSPanel {
    var onCancel: () -> Void = {}
    var onDeleteSelection: () -> Void = {}
    var onTrashSelection: () -> Void = {}
    var onSelectAll: () -> Void = {}

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // `.borderless` is the empty option set: a titled panel would draw a
            // title bar above the SwiftUI content it cannot round off.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        // Measured: with this on, a non-activating panel takes key status only
        // when the clicked view needs to be first responder — a text field.
        // Nothing on the shelf is one, so clicking it never made the panel key
        // and ⌫, ⌘⌫, ⌘A and Esc below were all dead. Off, the panel becomes key
        // on a click and still does not activate the app, because the style
        // mask is `.nonactivatingPanel`.
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // `.utilityWindow` is AppKit's own zoom-from-nothing on order-in, and it
        // fights the 180 ms fade the controller runs. The shelf owns its
        // entrance; the window system must not add a second one.
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// A borderless window refuses key status by default, which would make Esc,
    /// ⌫ and ⌘A dead. It still does not activate the app, because the panel is
    /// non-activating.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117] // delete, forward delete
        if deleteKeys.contains(event.keyCode) {
            // Finder's split: ⌫ takes it out of the window, ⌘⌫ destroys it.
            if event.modifierFlags.contains(.command) {
                onTrashSelection()
            } else {
                onDeleteSelection()
            }
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            onSelectAll()
            return
        }
        super.keyDown(with: event)
    }
}
