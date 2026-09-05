import AppKit
import SwiftUI

struct ShelfMenuAction {
    let title: String
    let isSeparatorBefore: Bool
    /// A submenu instead of a command. Non-empty means this row does nothing on
    /// its own — 发给 ▸ is a heading over a list of destinations, and the list
    /// grows with every app the user adds.
    let children: [ShelfMenuAction]
    let perform: () -> Void

    init(title: String, isSeparatorBefore: Bool = false, perform: @escaping () -> Void) {
        self.title = title
        self.isSeparatorBefore = isSeparatorBefore
        children = []
        self.perform = perform
    }

    init(title: String, isSeparatorBefore: Bool = false, children: [ShelfMenuAction]) {
        self.title = title
        self.isSeparatorBefore = isSeparatorBefore
        self.children = children
        perform = {}
    }
}

/// AppKit owns the mouse events of anything on the shelf that can be dragged.
///
/// SwiftUI's `onDrag` hands the pasteboard a single item provider, and the point
/// of the shelf is dragging a multi-file share out in one gesture. A real
/// `NSDraggingSession` also lets the drag be copy-only and gives the stacked
/// file icons that tell the user how many files are in flight.
///
/// Because this view sits above its content it must also carry the other
/// gestures — selection, double-click, hover and the context menu — rather than
/// letting them fall into a SwiftUI layer that can no longer be hit.
struct DragArea: NSViewRepresentable {
    /// Resolved at drag time, not at layout time: the selection may have changed
    /// since the row was built.
    var dragURLs: () -> [URL]
    /// What to lift, and where it already sits inside this view. Dropover drags
    /// the icon at the size it is drawn, out of the slot it is drawn in; an
    /// image that jumps to the pointer at half the size reads as a copy of
    /// something rather than as the thing itself.
    var dragPreview: (_ bounds: NSRect) -> (image: NSImage, frame: NSRect)?
    /// Fired only when a destination actually took the files. Dragging out is
    /// how the shelf empties, so a drag that ends over the desktop's dead zone —
    /// or that the user changed their mind about — must leave the shelf as it
    /// was.
    var onDragCompleted: ([URL]) -> Void
    /// True while a session is in flight, so the view can empty the slot the
    /// image was lifted out of.
    var onDragStateChanged: (Bool) -> Void = { _ in }
    var onClick: (_ shift: Bool, _ command: Bool) -> Void
    var onDoubleClick: () -> Void
    var onHover: (Bool) -> Void
    var menuActions: () -> [ShelfMenuAction]

    func makeNSView(context: Context) -> DragOriginView {
        let view = DragOriginView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: DragOriginView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: DragOriginView) {
        view.dragURLs = dragURLs
        view.dragPreview = dragPreview
        view.onDragCompleted = onDragCompleted
        view.onDragStateChanged = onDragStateChanged
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onHover = onHover
        view.menuActions = menuActions
    }
}

final class DragOriginView: NSView {
    var dragURLs: () -> [URL] = { [] }
    var dragPreview: (NSRect) -> (image: NSImage, frame: NSRect)? = { _ in nil }
    var onDragCompleted: ([URL]) -> Void = { _ in }
    var onDragStateChanged: (Bool) -> Void = { _ in }
    var onClick: (Bool, Bool) -> Void = { _, _ in }
    var onDoubleClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var menuActions: () -> [ShelfMenuAction] = { [] }

    private var mouseDownLocation: NSPoint?
    private var isDragging = false
    /// The session does not report what it carried, and the selection may have
    /// changed by the time it ends.
    private var draggedURLs: [URL] = []
    private var trackingArea: NSTrackingArea?
    private var menuTargets: [MenuTarget] = []

    /// The panel is non-activating: a drag has to be able to start from a window
    /// that is not key, or the first click would only raise the shelf.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The shelf window is `isMovableByWindowBackground`, and AppKit asks every
    /// non-opaque view under the press whether the whole window should travel
    /// instead. The default answer is yes, which swallowed the mouse-down before
    /// `mouseDragged` ever ran: dragging a file icon moved the shelf and the
    /// file drag could never start. Dropover's split, and now ours — drag the
    /// file, get a file; drag the frame or the grip, move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownLocation else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        // The same threshold AppKit uses before it treats a press as a drag;
        // below it, a slightly shaky click is still a click.
        guard (dx * dx + dy * dy).squareRoot() > 4 else { return }
        isDragging = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard !isDragging else { return }
        if event.clickCount >= 2 {
            onDoubleClick()
            return
        }
        onClick(
            event.modifierFlags.contains(.shift),
            event.modifierFlags.contains(.command)
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let actions = menuActions()
        guard !actions.isEmpty else { return nil }
        // The targets must outlive this call, submenus included: NSMenuItem does
        // not retain its target, and the menu is displayed after `menu(for:)`
        // returns.
        menuTargets = []
        return buildMenu(actions)
    }

    private func buildMenu(_ actions: [ShelfMenuAction]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions {
            if action.isSeparatorBefore { menu.addItem(.separator()) }
            let menuItem = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = true
            if action.children.isEmpty {
                let target = MenuTarget(action)
                menuTargets.append(target)
                menuItem.action = #selector(MenuTarget.invoke)
                menuItem.target = target
            } else {
                menuItem.submenu = buildMenu(action.children)
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    /// Lifts what is on screen, out of where it is on screen.
    ///
    /// One image for the whole drag, carried by the first item; the rest share
    /// its frame with no contents of their own. `.stack` would fan the files out
    /// into a pile at the pointer, which is the formation that made the previous
    /// build's drag look like a second copy appearing rather than the shelf's
    /// own icon being picked up.
    private func beginDrag(with event: NSEvent) {
        let urls = dragURLs()
        guard !urls.isEmpty else { return }
        // An item with no dragging frame is dragged invisibly, so there is a
        // fallback rather than an optional: whatever goes wrong with the
        // preview, the user must still see what they picked up.
        let preview = dragPreview(bounds) ?? (NSWorkspace.shared.icon(forFile: urls[0].path), bounds)

        let draggingItems = urls.enumerated().map { index, url -> NSDraggingItem in
            // A real file URL, not a promise: the file already exists in the
            // group container, so Finder, Terminal and anything else that reads
            // a standard file URL gets the actual bytes with no callback to run.
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(preview.frame, contents: index == 0 ? preview.image : nil)
            return item
        }

        draggedURLs = urls
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        // Kept on: a refused drop slides the image back into the empty slot, and
        // only then does the shelf put its icon back — which is what tells the
        // user nothing was consumed.
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        onDragStateChanged(true)
    }

    private final class MenuTarget: NSObject {
        let action: ShelfMenuAction
        init(_ action: ShelfMenuAction) { self.action = action }
        @objc func invoke() { action.perform() }
    }
}

extension DragOriginView: NSDraggingSource {
    /// Copy only. A `.move` would let the destination delete Dukou's own copy,
    /// which is the one thing the shelf promises not to lose.
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    /// An empty operation is a drag nobody accepted — dropped on the desktop's
    /// menu bar, on a window that refuses files, or cancelled with Esc. Only a
    /// real drop consumes, which is what makes dragging out feel like a cut
    /// rather than a copy that silently kept a duplicate around.
    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        mouseDownLocation = nil
        onDragStateChanged(false)
        let urls = draggedURLs
        draggedURLs = []
        guard !operation.isEmpty, !urls.isEmpty else { return }
        // A drop that lands back on the shelf is a change of mind. The panel
        // registers no drag types, so AppKit should already be reporting an
        // empty operation for it — but "the files vanished when I let go over
        // the shelf" is the one failure the user would have no way back from.
        if let window, window.frame.contains(screenPoint) { return }
        onDragCompleted(urls)
    }
}
