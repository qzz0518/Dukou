import Foundation

/// Where a panel that answers a click belongs on screen.
///
/// The target picker used to park in the shelf's corner, which reads as Dukou's
/// home rather than as an answer to what the user just did — and on more than one
/// display it is not even the display they were working on: the shelf's corner
/// resolves to the screen with the menu bar whenever the shelf itself is down, so
/// a 「发送到自定义」 clicked in WeChat on the left screen opened a panel in the top
/// right of the right one (reported 2026-09-07).
///
/// A question about a click belongs next to that click, the way a context menu
/// does: hanging off the pointer, on the pointer's screen.
public enum PointerPlacement {
    /// Frame for a panel of `size` answering a click at `pointer`, kept `margin`
    /// inside `visible`.
    ///
    /// The panel hangs below-right of the pointer, the direction a macOS menu
    /// opens. Each axis flips to the other side when that side does not fit —
    /// flipping rather than clamping, because a panel clamped against the bottom
    /// of the screen ends up sitting *under* the pointer, hiding the row it is
    /// nearest. Clamping is still the last word, for a panel taller or wider than
    /// any corner it could hang in.
    public static func frame(
        size: CGSize,
        pointer: CGPoint,
        in visible: CGRect,
        gap: CGFloat = 10,
        margin: CGFloat = 12
    ) -> CGRect {
        let room = visible.insetBy(dx: margin, dy: margin)

        var x = pointer.x + gap
        if x + size.width > room.maxX, pointer.x - gap - size.width >= room.minX {
            x = pointer.x - gap - size.width
        }

        // AppKit's y grows upward, so "below the pointer" is a smaller y.
        var y = pointer.y - gap - size.height
        if y < room.minY, pointer.y + gap + size.height <= room.maxY {
            y = pointer.y + gap
        }

        return clamped(CGRect(x: x, y: y, width: size.width, height: size.height), in: room)
    }

    /// Inside `room`, moved rather than resized: cropping a panel would cost the
    /// user a row of the list they are being asked to choose from.
    static func clamped(_ frame: CGRect, in room: CGRect) -> CGRect {
        var clamped = frame
        clamped.origin.x = min(max(frame.minX, room.minX), max(room.minX, room.maxX - frame.width))
        clamped.origin.y = min(max(frame.minY, room.minY), max(room.minY, room.maxY - frame.height))
        return clamped
    }
}
