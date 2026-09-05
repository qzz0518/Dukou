import DukouCore
import SwiftUI

/// Every batch still on disk, newest first.
///
/// The shelf shows what is unfinished; this shows what happened. A batch stays
/// here after it has been dragged out or forwarded, because "did that actually
/// arrive?" is a question the shelf can no longer answer once it is empty.
struct HistoryPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var targets: ForwardTargets
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header

            if let failure = model.inboxFailure {
                Notice(failure, tone: .bad)
            }

            if model.batches.isEmpty {
                empty
            } else {
                LazyVStack(spacing: Space.s) {
                    ForEach(model.batches) { batch in
                        row(for: batch)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Text(L10n.format("共 %d 条 · 占用 %@", model.batches.count, ByteFormat.string(model.historyByteCount)))
                .font(Typo.paneCaption)
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: Space.m)
            Button(L10n.text("在 Finder 中显示")) { model.revealInbox() }
                .buttonStyle(SettingsActionButtonStyle())
            Button(L10n.text("清空记录")) { model.discardHistory() }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(!model.hasDiscardableHistory)
        }
    }

    private var empty: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.inkTertiary)
                .accessibilityHidden(true)
            Text(L10n.text("还没有记录"))
                .font(Typo.paneBodyStrong)
                .foregroundStyle(Theme.ink)
            Text(L10n.text("从微信转发到任意一个 Dukou 入口后，这里会列出来。"))
                .font(Typo.paneCaption)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func row(for batch: ReadyBatch) -> some View {
        // Tight spacing and a priority on the text column: the trailing pill and
        // buttons are fixed-width, and at 780 pt the subtitle is the first thing
        // that runs out of room.
        HStack(spacing: Space.s) {
            if let first = batch.items.first {
                Image(nsImage: IconCache.icon(for: first.url))
                    .resizable()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(HistoryLabel.name(for: batch))
                    .font(Typo.paneBodyStrong)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    // Middle truncation keeps the extension visible, which is
                    // how the user tells two chat exports apart.
                    .truncationMode(.middle)
                Text(subtitle(for: batch))
                    .font(Typo.paneCaption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Everything trailing is `fixedSize`: given the choice, SwiftUI
            // would rather squeeze a button label into two lines than truncate
            // the subtitle, and a two-line button doubles the row's height.
            // A floor, not just `fixedSize`: 「在暂存架上」 is ~26 pt wider than
            // 「已送达」, so without one the title column was a different width
            // on every row and a short filename could be truncated on one line
            // while a longer one sat whole on the next.
            StatusPill(text: statusText(for: batch), tone: statusTone(for: batch))
                .fixedSize()
                .frame(minWidth: 96, alignment: .trailing)

            if batch.shelvedCount > 0, batch.shelvedCount == batch.items.count {
                Button(L10n.text("显示暂存架")) { actions.showShelf() }
                    .buttonStyle(SettingsActionButtonStyle())
                    .fixedSize()
            } else {
                Button(L10n.text("放回暂存架")) { model.restore(batchID: batch.id) }
                    .buttonStyle(SettingsActionButtonStyle())
                    .fixedSize()
            }

            menu(for: batch)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func menu(for batch: ReadyBatch) -> some View {
        SettingsMoreActionsButton(items: actionItems(for: batch), identifier: "history.actions")
    }

    /// A whole batch, acted on again from 记录.
    ///
    /// Flat, because the popover this fills cannot nest a submenu the way the
    /// old `Menu` did. So 发给 stops being a heading and moves into every row —
    /// 「发给 Codex」 rather than 「Codex」, since out here nothing above the row
    /// says what picking an app would do.
    private func actionItems(for batch: ReadyBatch) -> [SettingsAction] {
        let urls = batch.items.map(\.url)
        var items = targets.destinations.map { destination in
            SettingsAction(
                id: "forward.\(destination.id)",
                title: L10n.format("发给 %@", destination.title)
            ) {
                actions.perform(destination.action, destination.target, urls)
            }
        }
        // With nothing of the user's own in the list, 发给 is two built-ins and
        // no sign that it can be grown, so the way to grow it is offered here.
        if targets.isEmpty {
            items.append(SettingsAction(id: "entries", title: L10n.text("添加应用…")) {
                actions.showEntries()
            })
        }
        items.append(SettingsAction(id: "clipboard", title: L10n.text("复制到剪贴板")) {
            actions.perform(.clipboard, nil, urls)
        })
        items.append(SettingsAction(
            id: "reveal",
            title: L10n.text("在 Finder 中显示"),
            isSeparatorBefore: true
        ) {
            batch.items.first.map { model.reveal(id: $0.id) }
        })
        items.append(SettingsAction(id: "discard", title: L10n.text("移到废纸篓")) {
            model.discard(batchID: batch.id)
        })
        return items
    }

    private func subtitle(for batch: ReadyBatch) -> String {
        [
            HistoryLabel.destination(for: batch),
            HistoryLabel.timestamp(batch.createdAt, namesToday: true),
            ByteFormat.string(batch.byteCount),
        ]
        .joined(separator: " · ")
    }

    /// Where the files are beats what once happened to them: a failed forward
    /// the user put back on the shelf reads 在暂存架上, because that is what they
    /// can act on now.
    private func statusText(for batch: ReadyBatch) -> String {
        guard batch.shelvedCount == 0 else { return L10n.text("在暂存架上") }
        switch batch.outcome?.kind {
        case .delivered: return L10n.text("已送达")
        case .copied: return L10n.text("已复制")
        case .failed: return L10n.text("未送达")
        case .shelved: return L10n.text("已移出")
        // No outcome at all means a forward that was noticed and never carried
        // out, which is the same story `expired` tells.
        case .expired, nil: return L10n.text("未执行")
        }
    }

    private func statusTone(for batch: ReadyBatch) -> StatusPill.Tone {
        if batch.shelvedCount > 0 { return .live }
        return batch.outcome?.kind == .failed ? .warn : .neutral
    }
}
