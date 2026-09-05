import Foundation

/// How a batch is named in the two places history is listed: the status menu's
/// 最近记录 submenu and the settings window's 记录 pane.
///
/// Pure string building, kept out of the app target so it can be tested: an
/// `NSMenu` item has no auto-truncation and no second line, so everything the
/// menu says about a batch has to be decided here and decided exactly.
public enum HistoryLabel {
    /// How much of a filename an `NSMenu` row can carry before the menu grows
    /// wider than the screen it drops out of.
    public static let menuNameLimit = 28

    /// 「聊天记录.zip」 or 「聊天记录.zip 等 3 个」.
    ///
    /// `limit` truncates the filename in the middle, which is what keeps the
    /// extension visible — two chat exports differ by their tail, not their
    /// head.
    public static func name(for batch: ReadyBatch, limit: Int? = nil) -> String {
        guard let first = batch.items.first else { return "" }
        let name = limit.map { middleTruncated(first.displayName, limit: $0) } ?? first.displayName
        guard batch.items.count > 1 else { return name }
        return L10n.format("%@ 等 %d 个", name, batch.items.count)
    }

    /// 「14:32」 for today, 「9月4日 14:32」 for any other day, optionally with
    /// 今天 spelled out — the menu has the clock in the corner right above it,
    /// the settings pane does not.
    public static func timestamp(
        _ date: Date,
        now: Date = Date(),
        namesToday: Bool,
        locale: Locale = L10n.locale(),
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone

        let time = date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )
        )
        guard !calendar.isDate(date, inSameDayAs: now) else {
            return namesToday ? L10n.format("今天 %@", time) : time
        }
        // The abbreviated month, not the numeric one: zh-Hans renders "Md" as
        // "9/4", which reads as a fraction next to a clock time.
        let day = date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .omitted,
                locale: locale,
                calendar: calendar,
                timeZone: timeZone
            )
            .month(.abbreviated)
            .day()
        )
        return "\(day) \(time)"
    }

    /// Where a batch went, in the words that were on screen when it was sent.
    ///
    /// 「发送到自定义」 is the name of an entry, not of a destination: on its own
    /// it would leave every custom forward in 记录 saying nothing about where
    /// the files actually went. So a batch that recorded a target names it.
    public static func destination(for batch: ReadyBatch) -> String {
        guard let name = batch.targetName, !name.isEmpty else { return batch.action.entryTitle }
        return L10n.format("发给 %@", name)
    }

    /// One 最近记录 row: 「聊天记录.zip 等 3 个 · 发给 Claude · 14:32」.
    public static func menuTitle(
        for batch: ReadyBatch,
        now: Date = Date(),
        locale: Locale = L10n.locale(),
        timeZone: TimeZone = .current
    ) -> String {
        [
            name(for: batch, limit: menuNameLimit),
            destination(for: batch),
            timestamp(batch.createdAt, now: now, namesToday: false, locale: locale, timeZone: timeZone),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    /// Counted in characters rather than bytes: this is a display width problem,
    /// and one Chinese character is one glyph however many bytes it takes.
    static func middleTruncated(_ text: String, limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        let keep = limit - 1
        let tail = keep / 2
        return "\(text.prefix(keep - tail))…\(text.suffix(tail))"
    }
}
