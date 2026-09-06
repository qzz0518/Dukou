import AppKit
import DukouCore

/// What Dukou's two floating capsules — the failure toast and the one-time
/// shelf coach mark — have in common: the panel they live in, how they measure
/// themselves, and where they park next to the shelf.
///
/// Both used to assume the shelf was in the top-right corner, which stopped
/// being true the moment 停靠位置 offered four of them. Everything here is
/// derived from the shelf's actual frame instead.
enum FloatingCapsule {
    /// A borderless, non-activating panel that floats over other people's
    /// windows without ever taking their focus.
    static func panel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: Metrics.toastMinHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        configure(panel)
        return panel
    }

    /// Split out of `panel()` so a subclass can adopt the same behaviour: the
    /// target picker needs its own `NSPanel` subclass for the keyboard, and two
    /// floating panels configured differently is exactly how one of them ends up
    /// vanishing when Dukou is deactivated.
    static func configure(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The capsule owns its own entrance; AppKit's window zoom would play on
        // top of it.
        panel.animationBehavior = .none
        // Hover has to be seen and the action button has to be clickable, so
        // this panel takes mouse events even though it never takes focus.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    /// The size the capsule wants to be.
    ///
    /// Two measured traps, one line of fix each. The hosting view has to already
    /// be in a window — a detached one reports `fittingSize` zero, and a
    /// zero-sized panel is a capsule nobody ever sees. And the measurement has
    /// to start from room to spare rather than from the previous message's
    /// frame: a hosting view laid out narrow reports the narrow width it was
    /// given back, which clipped every message longer than the one before it.
    static func measure(_ hosting: NSView) -> NSSize {
        hosting.frame = NSRect(x: 0, y: 0, width: Metrics.toastMaxWidth * 2, height: 200)
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let intrinsic = hosting.intrinsicContentSize
        return NSSize(
            width: max(fitting.width, intrinsic.width),
            height: max(max(fitting.height, intrinsic.height), Metrics.toastMinHeight)
        )
    }

    /// The frame a capsule may occupy, never smaller than what it drew.
    ///
    /// Round 3 measured the trap on the toast: a hosting view laid out at the
    /// wrong width reports that width back, and the window is then sized to a
    /// fraction of its content. It does not fail loudly — it draws a clipped
    /// fragment, and a user found one of those parked beside the shelf
    /// (2026-09-05: a grey sliver showing the left edge of two app icons). So
    /// the check sits on the way out of every capsule rather than in each
    /// presenter: debug builds trip on it, release builds show the whole thing
    /// rather than a corner of it.
    static func fitted(_ frame: NSRect, to hosting: NSView) -> NSRect {
        let content = hosting.fittingSize
        // Half a point of slack: a fitting size is the result of layout
        // arithmetic, not an integer.
        guard content.width > frame.width + 0.5 || content.height > frame.height + 0.5 else {
            return frame
        }
        assertionFailure("floating capsule content \(content) does not fit \(frame.size)")
        return NSRect(
            origin: frame.origin,
            size: NSSize(
                width: max(frame.width, content.width),
                height: max(frame.height, content.height)
            )
        )
    }

    /// The usable area of the screen the shelf is on, falling back to the one
    /// with the menu bar. `visibleFrame` already excludes the menu bar and the
    /// Dock.
    ///
    /// `NSScreen.main` is deliberately the *last* resort: it means "the screen
    /// with the key window", and a background app has none — measured on a
    /// three-display Mac (2026-09-05), a failure toast raised with no shelf on
    /// screen was placed at (-238, -83), on a display the user was not looking
    /// at. `screens.first` is documented as the screen with the menu bar, which
    /// is the one 「屏幕右上角」 means.
    static func visibleFrame(holding rect: NSRect?) -> NSRect {
        let screen = rect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.screens.first
            ?? NSScreen.main
        // A Mac with no screens is a Mac with nobody looking at it; the fallback
        // is only here so the geometry below stays finite.
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The usable area of the screen the pointer is on. Unlike `visibleFrame(holding:)`
    /// this never falls back to the menu-bar screen while the pointer says which
    /// display the user is actually working on.
    static func visibleFrame(containing point: NSPoint) -> NSRect {
        // `contains` excludes the top and right edges, and a pointer parked on a
        // screen's very edge is a real position — so a miss falls to the nearest
        // screen rather than to the menu bar's, which is the display this method
        // exists to stop choosing.
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.min { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// Hanging off a click, on the click's own screen — `PointerPlacement` carries
    /// the geometry and the reasoning.
    static func near(_ point: NSPoint, size: NSSize) -> NSRect {
        PointerPlacement.frame(
            size: size,
            pointer: point,
            in: visibleFrame(containing: point),
            gap: Metrics.toastGap,
            margin: Metrics.screenMargin
        )
    }

    /// Beside the shelf, tops aligned, on whichever side has more room.
    ///
    /// Tops aligned rather than centred: the two panels then read as one group,
    /// and the capsule stays level with the shelf's ✕ / ⌄ row instead of
    /// drifting down beside a five-row expanded list.
    static func beside(_ shelf: NSRect, size: NSSize, in visible: NSRect) -> NSRect {
        let left = shelf.minX - visible.minX
        let right = visible.maxX - shelf.maxX
        let x = left >= right
            ? shelf.minX - Metrics.toastGap - size.width
            : shelf.maxX + Metrics.toastGap
        return NSRect(x: x, y: shelf.maxY - size.height, width: size.width, height: size.height)
    }

    /// A rect of this size tucked into one corner of the screen, `screenMargin`
    /// in from both edges. The shelf's own home and every capsule that has no
    /// shelf to stand beside are the same geometry, so they share it.
    static func corner(_ corner: ShelfCorner, size: NSSize, in visible: NSRect) -> NSRect {
        NSRect(
            x: corner.isRight
                ? visible.maxX - Metrics.screenMargin - size.width
                : visible.minX + Metrics.screenMargin,
            y: corner.isTop
                ? visible.maxY - Metrics.screenMargin - size.height
                : visible.minY + Metrics.screenMargin,
            width: size.width,
            height: size.height
        )
    }

    /// Inside the screen, margin included. This only ever moves the capsule —
    /// clamping its size instead would crop the sentence it exists to deliver.
    static func clamped(_ frame: NSRect, in visible: NSRect) -> NSRect {
        var clamped = frame
        clamped.origin.x = min(
            max(frame.minX, visible.minX + Metrics.screenMargin),
            visible.maxX - frame.width - Metrics.screenMargin
        )
        clamped.origin.y = min(
            max(frame.minY, visible.minY + Metrics.screenMargin),
            visible.maxY - frame.height - Metrics.screenMargin
        )
        return clamped
    }
}
