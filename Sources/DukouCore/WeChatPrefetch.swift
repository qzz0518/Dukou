import Foundation

/// Pacing for the phase that drags a conversation back over history WeChat has
/// not materialised yet, before anything is selected.
///
/// A chat opens with a window of itself in memory and fetches what is older
/// from disk as the list is dragged over the edge of that window. Selecting
/// three hundred messages walks that edge three times — once per batch of a
/// hundred — and each batch pays for the fetch again, a settled snapshot per
/// gesture, inside a budget meant for a hundred messages WeChat already holds.
/// Dragging the whole distance once before anything is selected pays for the
/// fetches once and without that budget over it; every batch after it scrolls
/// over rows WeChat has in hand.
///
/// The phase has nowhere in particular to stop, so it does not need a settled
/// snapshot per gesture: gestures go out in bursts and only the burst is
/// measured. How long a burst may be is felt out rather than fixed, for the
/// same reason the gesture gap is — a gesture arriving while WeChat is fetching
/// moves the list about 50 points however large it is — so a burst that stops
/// earning rows is cut short and its gestures spaced further apart, and one
/// that keeps earning them grows.
public enum WeChatPrefetch {
    /// Selections up to a single native batch already run entirely inside the
    /// window WeChat opens the conversation with. Only what reaches past it
    /// pays for the fetches, so only that is worth loading up front.
    public static let threshold = 100

    /// Gestures in the first burst, before anything is known about this list.
    public static let firstBurst = 2
    public static let maximumBurst = 12

    /// Points one gesture of `delta` units moves the list, before this run has
    /// measured it. The engine reads 1.1 to 1.2 on WeChat 4.1.13.
    public static func reach(delta: Int32) -> Double { Double(delta) * 1.1 }

    /// What one burst did to the list.
    ///
    /// A gesture WeChat honours moves the list about a screen, so a burst worth
    /// sending outruns the overlap two snapshots share and leaves nothing to
    /// count rows against — the distance is then read from what a gesture was
    /// last measured to reach. A burst that *did* leave overlap is the clamped
    /// one: its gestures moved the list about 50 points however large they
    /// were, which is what WeChat does while it reads history off disk. That is
    /// also the only moment the reach can be measured again, so the two answers
    /// arrive together.
    public struct Burst: Equatable, Sendable {
        public let rows: Int
        /// Points one of the burst's gestures moved the list, when the burst
        /// left enough overlap to measure it.
        public let pointsPerGesture: Double?
        /// The burst did not travel the screen it was asked for.
        public let clamped: Bool
    }

    public static func burst(from before: [WeChatViewportRow], to after: [WeChatViewportRow],
                             gestures: Int, delta: Int32, reach: Double) -> Burst {
        let gestures = max(1, gestures)
        let shift = advance(from: before, to: after)
        guard shift < after.count, !before.isEmpty, after.indices.contains(shift) else {
            // No overlap, so the burst cleared a screen and then some: most of
            // its gestures travelled, and `reach` is what a travelling one
            // covers. The screen it left behind is the floor.
            let height = averageHeight(after)
            let estimate = height > 0 ? Int((Double(gestures) * reach / height).rounded()) : 0
            return Burst(rows: max(after.count, estimate), pointsPerGesture: nil, clamped: false)
        }
        let moved = abs(after[shift].y - before[0].y) / Double(gestures)
        // Same threshold the engine rejects a clamped gain by, in points.
        return Burst(rows: shift, pointsPerGesture: moved, clamped: moved < Double(delta) * 0.4)
    }

    public static func nextBurst(_ burst: Int, clamped: Bool) -> Int {
        clamped ? max(1, burst / 2) : min(maximumBurst, burst + 1)
    }

    public static func nextPause(_ pause: Double, clamped: Bool) -> Double {
        clamped ? WeChatScrollStep.lengthened(pause) : max(WeChatScrollStep.minimumGesturePause, pause - 0.02)
    }

    /// How long the phase may drag before it settles for the history it has.
    ///
    /// Generous on purpose: this is not time added to the run, it is time the
    /// batches would otherwise spend one gesture at a time — and spend inside a
    /// per-batch budget that a conversation this cold cannot meet, which is how
    /// a three-hundred-message forward failed instead of merely dragging.
    /// Coming up short here still leaves every row it did reach loaded.
    public static func budget(messages: Int) -> Double {
        min(180, 40 + Double(max(0, messages)) * 0.3)
    }

    private static func averageHeight(_ rows: [WeChatViewportRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.height } / Double(rows.count)
    }

    /// Rows the list travelled between two snapshots, matched on content so a
    /// recycled AX child index can never be read as movement.
    ///
    /// Saturates at one screen: a burst that outran the overlap entirely is
    /// credited with the rows it left behind and no more, which is why `burst`
    /// estimates past it rather than trusting this number.
    public static func advance(from before: [WeChatViewportRow], to after: [WeChatViewportRow]) -> Int {
        guard !before.isEmpty, !after.isEmpty else { return after.count }
        for shift in 0..<after.count {
            let overlap = min(after.count - shift, before.count)
            guard overlap > 0 else { break }
            if (0..<overlap).allSatisfy({
                after[shift + $0].text == before[$0].text && abs(after[shift + $0].height - before[$0].height) < 3
            }) { return shift }
        }
        return after.count
    }
}
