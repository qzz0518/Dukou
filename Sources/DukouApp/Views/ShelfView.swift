import AppKit
import DukouCore
import SwiftUI

/// File icons come from Launch Services over IPC. A shelf redraws on every
/// hover, so they are cached by the only thing that determines them here: the
/// extension.
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        let key = url.pathExtension.lowercased()
        if let hit = cache[key] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 128, height: 128)
        if !key.isEmpty { cache[key] = icon }
        return icon
    }
}

/// The shelf: a small square that holds what just arrived and lets the user drag
/// it somewhere else.
///
/// Icon-first rather than list-first on purpose. The gesture this window exists
/// for is *grab and drag*, and a row of small text is a worse handle than one
/// big file icon. The list is still there for a share of many files — behind the
/// chevron, where it costs nothing until it is needed.
struct ShelfView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: ShelfPresentation
    @ObservedObject var targets: ForwardTargets
    let onClose: () -> Void
    let onToggleExpanded: () -> Void
    let onAction: (ShareAction, ForwardTarget?, [URL]) -> Void
    /// Opens 设置 → 入口, which is the only place the destination list is built.
    let onAddTarget: () -> Void

    @State private var hoveredID: UUID?
    @State private var isHoveringStack = false
    /// The stack has been lifted off the shelf and is following the pointer.
    @State private var isLifted = false

    var body: some View {
        // A `ZStack`, so that for the length of the change both states are on
        // screen at once and the outgoing one has something to fade into. The
        // card itself — material, hairline, grip — is outside it and never
        // changes identity, which is what keeps the shape continuous while its
        // contents are swapped.
        ZStack {
            if presentation.isExpanded {
                expanded.transition(.opacity)
            } else {
                collapsed.transition(.opacity)
            }
        }
        // The card is the size of the window, not the size of whatever is in it.
        // The panel's frame is being animated between the square and the list,
        // and a card that took its size from its contents would jump to the new
        // shape on the first frame and leave the window's corners and shadow
        // trailing 180 ms behind it. The two states keep their own fixed sizes
        // and are simply centred — and clipped — inside the card while they
        // cross over.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Radius.shelf, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.shelf, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .overlay(alignment: .top) { grip }
        // Dimmed while its contents are in flight, the way a Dropover shelf
        // reads as emptied rather than duplicated.
        .overlay {
            RoundedRectangle(cornerRadius: Radius.shelf, style: .continuous)
                .fill(.black.opacity(isLifted ? 0.12 : 0))
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.12), value: isLifted)
        // Scaled inside the window, then padded: the entrance settle and the
        // arrival bump both overflow the card, and the transparent ring the
        // padding creates is what keeps the window from shearing it off.
        .scaleEffect(presentation.scale)
        .padding(Metrics.shelfBumpInset)
    }

    /// Dropover's handle. It does nothing on its own — the card's own background
    /// is what `isMovableByWindowBackground` drags — but a floating window with
    /// no title bar otherwise gives no hint that it can be moved at all.
    ///
    /// `allowsHitTesting(false)` is the whole trick: measured, a plain filled
    /// shape reports itself as hittable and AppKit then refuses to start a
    /// window drag under it, so the one pixel row that advertises "drag me here"
    /// was the one place dragging did nothing.
    private var grip: some View {
        Capsule()
            .fill(Palette.pillFill)
            .frame(width: Metrics.shelfGripSize.width, height: Metrics.shelfGripSize.height)
            .padding(.top, 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Collapsed

    private var collapsed: some View {
        VStack(spacing: 0) {
            HStack {
                CircleIconButton(symbol: "xmark", label: L10n.text("移出暂存架"), action: onClose)
                Spacer(minLength: 0)
                CircleIconButton(
                    symbol: "chevron.down",
                    label: L10n.text("展开文件列表"),
                    action: onToggleExpanded
                )
            }
            .padding(Space.s + 2)
            // The grip lives in the card's top 9 pt; at the shared padding the
            // 22 pt circles reached into its band and it read as stuck to the
            // edge rather than as a handle above the controls.
            .padding(.top, 4)

            Spacer(minLength: 0)
            iconStack
            Spacer(minLength: 0)

            namePill
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.m)
        }
        .frame(width: Metrics.shelfBlobSide, height: Metrics.shelfBlobSide)
    }

    /// Up to three shoulders behind the top icon, so a multi-file share reads as
    /// a stack before the badge is even noticed.
    private var iconStack: some View {
        ZStack {
            ForEach(Array(shoulders.enumerated()), id: \.offset) { index, url in
                Image(nsImage: IconCache.icon(for: url))
                    .resizable()
                    .frame(width: Metrics.shelfIconSide, height: Metrics.shelfIconSide)
                    .rotationEffect(.degrees(Double(index + 1) * -4))
                    .offset(x: CGFloat(index + 1) * -5, y: CGFloat(index + 1) * 3)
                    .opacity(0.55)
            }
            if let top = model.shelfItems.first {
                Image(nsImage: IconCache.icon(for: top.url))
                    .resizable()
                    .frame(width: Metrics.shelfIconSide, height: Metrics.shelfIconSide)
            }
            if model.shelfItems.count > 1 {
                Text("\(model.shelfItems.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    // The app's own green, not `Color.accentColor` — that is the
                    // user's macOS accent, so on a machine set to graphite or
                    // pink the badge quietly stopped being Dukou's colour while
                    // the icon behind it did not.
                    .background(Theme.accent, in: Capsule())
                    .offset(x: Metrics.shelfIconSide / 2 - 2, y: -Metrics.shelfIconSide / 2 + 4)
            }
        }
        .scaleEffect(isHoveringStack ? 1.04 : 1)
        .animation(Motion.reduced(Motion.ui), value: isHoveringStack)
        // The slot the drag image was lifted out of has to look empty, or the
        // user sees their files in two places at once and cannot tell which one
        // they are actually holding.
        .opacity(isLifted ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: isLifted)
        .frame(width: Metrics.shelfIconSide + 24, height: Metrics.shelfIconSide + 16)
        .contentShape(Rectangle())
        .overlay(
            DragArea(
                dragURLs: { model.shelfItems.map(\.url) },
                dragPreview: { bounds in (stackDragImage(size: bounds.size), bounds) },
                onDragCompleted: { model.consume(urls: $0, via: .drag) },
                onDragStateChanged: { isLifted = $0 },
                onClick: { _, _ in },
                onDoubleClick: { model.shelfItems.first.map { model.reveal(id: $0.id) } },
                onHover: { isHoveringStack = $0 },
                menuActions: { stackMenuActions() }
            )
        )
        .accessibilityElement()
        .accessibilityLabel(Text(stackAccessibilityLabel))
    }

    private var shelfIDs: Set<UUID> { Set(model.shelfItems.map(\.id)) }

    private var shoulders: [URL] {
        Array(model.shelfItems.dropFirst().prefix(2).map(\.url).reversed())
    }

    /// The stack, redrawn into a bitmap for the drag to carry.
    ///
    /// Composed from the same URLs and the same offsets rather than snapshotted:
    /// `cacheDisplay(in:to:)` over the overlay would bring the material behind
    /// the icons with it, and a translucent square is not what the user picked
    /// up. The one place these numbers are duplicated, so they are read from the
    /// same constants the view uses.
    private func stackDragImage(size: NSSize) -> NSImage {
        let side = Metrics.shelfIconSide
        // Resolved here, on the main actor, and captured as plain images. AppKit
        // may run a drawing handler on any thread — this one is rasterised by
        // the drag machinery, not by the caller — and `IconCache` is main-actor
        // isolated over a shared dictionary, so reaching into it from the block
        // would be an unsynchronised read and insert.
        let shoulderIcons = shoulders.map { IconCache.icon(for: $0) }
        let topIcon = model.shelfItems.first.map { IconCache.icon(for: $0.url) }
        return NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let box = NSRect(x: -side / 2, y: -side / 2, width: side, height: side)
            for (index, icon) in shoulderIcons.enumerated() {
                context.saveGState()
                // SwiftUI's +y offset goes down and its rotation is clockwise;
                // this context's +y goes up and its rotation is anticlockwise.
                context.translateBy(
                    x: centre.x + CGFloat(index + 1) * -5,
                    y: centre.y - CGFloat(index + 1) * 3
                )
                context.rotate(by: CGFloat(index + 1) * 4 * .pi / 180)
                icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 0.55)
                context.restoreGState()
            }
            if let topIcon {
                context.saveGState()
                context.translateBy(x: centre.x, y: centre.y)
                topIcon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
                context.restoreGState()
            }
            return true
        }
    }

    private var namePill: some View {
        Text(pillText)
            .font(Typo.captionStrong)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 5)
            .background(Palette.pillFill, in: Capsule())
            .frame(maxWidth: .infinity)
    }

    private var pillText: String {
        guard let first = model.shelfItems.first else { return "" }
        guard model.shelfItems.count > 1 else { return first.displayName }
        return L10n.format("%@ 等 %d 个", first.displayName, model.shelfItems.count)
    }

    private var stackAccessibilityLabel: String {
        guard let first = model.shelfItems.first else { return L10n.text("暂存架是空的") }
        return model.shelfItems.count > 1
            ? L10n.format("%@ 等 %d 个文件，可拖出", first.displayName, model.shelfItems.count)
            : L10n.format("%@，可拖出", first.displayName)
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                CircleIconButton(
                    symbol: "chevron.up",
                    label: L10n.text("收起为图标"),
                    action: onToggleExpanded
                )
                Text(model.shelfItems.count == 1
                    ? L10n.text("1 个文件")
                    : L10n.format("%d 个文件", model.shelfItems.count))
                    .font(Typo.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                CircleIconButton(symbol: "trash", label: L10n.text("全部移到废纸篓")) {
                    model.discard(ids: shelfIDs)
                }
                CircleIconButton(symbol: "xmark", label: L10n.text("移出暂存架"), action: onClose)
            }
            .padding(.horizontal, Space.s + 2)
            .frame(height: Metrics.shelfHeaderHeight)

            Divider().overlay(Palette.hairline)

            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(model.shelfItems) { item in
                        row(for: item)
                    }
                }
                .padding(Space.xs + 2)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: Metrics.shelfListWidth)
    }

    private func row(for item: ReadyItem) -> some View {
        HStack(spacing: Space.s) {
            Image(nsImage: IconCache.icon(for: item.url))
                .resizable()
                .frame(width: Metrics.shelfRowIconSide, height: Metrics.shelfRowIconSide)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(Typo.label)
                    .lineLimit(1)
                    // Middle truncation keeps the extension visible, which is
                    // how the user tells two chat exports apart.
                    .truncationMode(.middle)
                Text(detail(for: item))
                    // Not `Font.numeral`: `ByteFormat` renders 「231 字节」 in
                    // zh, and a rounded face is a no-op on CJK — one Text would
                    // draw the digits rounded and the unit in PingFang.
                    .font(Typo.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.s)
        .frame(height: Metrics.shelfRowHeight)
        .background(background(for: item))
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay(interaction(for: item))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.displayName), \(detail(for: item))"))
    }

    private func background(for item: ReadyItem) -> Color {
        if model.selection.contains(item.id) { return Palette.rowSelected }
        if hoveredID == item.id { return Palette.rowHover }
        return .clear
    }

    private func detail(for item: ReadyItem) -> String {
        let size = ByteFormat.string(item.byteCount)
        let time = item.createdAt.formatted(date: .omitted, time: .shortened)
        return "\(size) · \(time)"
    }

    private func interaction(for item: ReadyItem) -> some View {
        DragArea(
            dragURLs: {
                // Finder's rule: dragging an unselected row makes it the
                // selection first, so what you drag is what you can see is
                // selected.
                if !model.selection.contains(item.id) {
                    model.selection = [item.id]
                    model.selectionAnchor = item.id
                }
                return model.dragURLs(startingAt: item.id)
            },
            // The row's own icon, lifted out of the row. The overlay covers the
            // whole row, so the icon's place in it is rebuilt from the same
            // padding and height the row lays out with.
            dragPreview: { bounds in
                let side = Metrics.shelfRowIconSide
                return (
                    IconCache.icon(for: item.url),
                    NSRect(
                        x: Space.s,
                        y: (bounds.height - side) / 2,
                        width: side,
                        height: side
                    )
                )
            },
            onDragCompleted: { model.consume(urls: $0, via: .drag) },
            onClick: { shift, command in
                select(item, extending: shift, toggling: command)
            },
            onDoubleClick: { model.reveal(id: item.id) },
            onHover: { isHovering in
                hoveredID = isHovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
            },
            menuActions: { rowMenuActions(for: item) }
        )
    }

    // MARK: - Menus

    private func stackMenuActions() -> [ShelfMenuAction] {
        let urls = model.shelfItems.map(\.url)
        return forwardActions(urls: urls) + [
            ShelfMenuAction(title: L10n.text("在 Finder 中显示"), isSeparatorBefore: true) {
                model.shelfItems.first.map { model.reveal(id: $0.id) }
            },
            ShelfMenuAction(title: L10n.text("移出暂存架")) { model.consumeAll() },
            ShelfMenuAction(title: L10n.text("移到废纸篓")) { model.discard(ids: shelfIDs) },
        ]
    }

    private func rowMenuActions(for item: ReadyItem) -> [ShelfMenuAction] {
        let targets = model.selection.contains(item.id) ? model.selection : [item.id]
        let urls = model.shelfItems.filter { targets.contains($0.id) }.map(\.url)
        return forwardActions(urls: urls) + [
            ShelfMenuAction(title: L10n.text("在 Finder 中显示"), isSeparatorBefore: true) {
                model.reveal(id: item.id)
            },
            ShelfMenuAction(title: L10n.text("用默认 App 打开")) { model.open(id: item.id) },
            ShelfMenuAction(title: L10n.text("移出暂存架")) { model.consume(ids: targets, via: .dismissed) },
            ShelfMenuAction(title: L10n.text("移到废纸篓")) { model.discard(ids: targets) },
        ]
    }

    /// The same destinations the Share menu offers, for files that are already
    /// on the shelf — the second time you need a chat export, WeChat is no
    /// longer the place you are starting from.
    ///
    /// A submenu rather than a flat row per app: the list is the user's and can
    /// be as long as they like, and a context menu that grows past 移到废纸篓
    /// buries the commands that were there first.
    private func forwardActions(urls: [URL]) -> [ShelfMenuAction] {
        let destinations = targets.destinations
        var children = destinations.filter(\.isBuiltIn).map { destination in
            ShelfMenuAction(title: destination.title) {
                onAction(destination.action, destination.target, urls)
            }
        }
        if targets.isEmpty {
            children.append(
                ShelfMenuAction(title: L10n.text("添加应用…"), isSeparatorBefore: true) { onAddTarget() }
            )
        } else {
            for (index, destination) in destinations.filter({ !$0.isBuiltIn }).enumerated() {
                children.append(
                    ShelfMenuAction(title: destination.title, isSeparatorBefore: index == 0) {
                        onAction(destination.action, destination.target, urls)
                    }
                )
            }
        }
        return [
            ShelfMenuAction(title: L10n.text("发给"), children: children),
            ShelfMenuAction(title: L10n.text("复制到剪贴板")) { onAction(.clipboard, nil, urls) },
        ]
    }

    /// Finder's rules: plain click replaces the selection, ⌘ toggles, ⇧ extends
    /// from the last clicked row — the anchor, not whichever selected row a
    /// `Set` happens to yield first.
    private func select(_ item: ReadyItem, extending: Bool, toggling: Bool) {
        if toggling {
            if model.selection.contains(item.id) {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
            model.selectionAnchor = item.id
            return
        }
        if extending, let anchor = model.selectionAnchor,
           let start = model.shelfItems.firstIndex(where: { $0.id == anchor }),
           let end = model.shelfItems.firstIndex(where: { $0.id == item.id }) {
            let range = start <= end ? start...end : end...start
            model.selection = Set(model.shelfItems[range].map(\.id))
            return
        }
        model.selection = [item.id]
        model.selectionAnchor = item.id
    }
}
