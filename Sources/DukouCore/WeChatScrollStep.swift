import CoreGraphics
import Foundation

/// How far one coarse navigation scroll may travel through WeChat's message
/// list while `WeChatViewport.advance` can still stitch the two snapshots.
///
/// The tracker matches the rows a snapshot shares with the one before it and
/// needs only one of them, so the content may move by the whole visible list
/// except a band the height of the tallest row on screen: whatever sat in that
/// band stays in view. On an ordinary text conversation that is about twice the
/// step this used to take, which is where the wait for a hundred messages went.
///
/// The step is expressed in scroll-event units, not pixels: `gain` is how many
/// points of content one unit moved on the previous step, measured rather than
/// assumed. Before any step has been measured the reach stays at the careful
/// 40 % of a screen the engine always used.
public enum WeChatScrollStep {
    /// The most a step may travel when nothing is known about the list yet.
    public static func careful(listHeight: CGFloat) -> CGFloat { listHeight / 2.5 }

    public static func reach(listHeight: CGFloat, tallestRow: CGFloat, gainMeasured: Bool, reachFactor: Double) -> CGFloat {
        guard listHeight > 0 else { return 0 }
        guard gainMeasured else { return careful(listHeight: listHeight) }
        let overlapBand = max(0, tallestRow) + 24
        return max(listHeight / 3, listHeight - overlapBand) * CGFloat(max(0.1, min(1, reachFactor)))
    }

    /// The largest single gesture WeChat honours.
    ///
    /// Measured 2026-09-06 on 4.1.13: a 438-unit gesture moved the list 398
    /// points, a 600-unit one moved it 50. Past some threshold in between,
    /// WeChat clamps the gesture to a crawl, and because the engine measures
    /// `gain` from what actually moved, one clamped step used to drive the next
    /// delta up to the limit and hold it there — a hundred steps that each
    /// advanced half a message.
    ///
    /// Re-measured 2026-09-07, twice, over rows WeChat already held: this size
    /// moved the list 570 points both times, and 10 000 units moved it 50 both
    /// times. Sizes in between answered differently on the two runs, so the
    /// threshold is not a property of the number alone — which is why nothing
    /// asks for more than this, in either direction.
    public static let maximumDelta: Int32 = 520

    /// A measured gain outside this band is not a property of the list; it is a
    /// clamped gesture or a snapshot taken mid-glide. Keeping the previous
    /// value is better than steering by it.
    public static func isPlausible(gain: Double) -> Bool { gain >= 0.4 && gain <= 5 }

    /// The gap to leave between two scroll gestures.
    ///
    /// Measured 2026-09-06 on 4.1.13: while WeChat fetches older history a
    /// gesture only nudges the list about 50 points however large it is, and
    /// gestures arriving every ~120 ms keep it in that state — a hundred steps
    /// that each advanced half a message. At 220 ms none of them clamped.
    /// Since a navigation step costs little else, this gap is what the whole
    /// phase costs, so it is felt out rather than fixed: shortened while the
    /// list keeps up, doubled the moment it does not.
    public static let baseGesturePause = 0.22
    public static let minimumGesturePause = 0.06
    public static let maximumGesturePause = 0.9

    /// The gap after `healthySteps` steps in a row that moved as asked.
    public static func shortened(_ pause: Double, healthySteps: Int) -> Double {
        guard healthySteps > 0, healthySteps % 4 == 0 else { return pause }
        return max(minimumGesturePause, pause - 0.02)
    }

    /// The gap after a step WeChat clamped. Never shorter than the base: the
    /// shortening above is what got the run here.
    public static func lengthened(_ pause: Double) -> Double {
        min(maximumGesturePause, max(baseGesturePause, pause * 2))
    }

    /// The scroll units that travel `reach`, bounded so one step can neither
    /// stall nor trip WeChat's clamp. `ceiling` is the run's own limit, halved
    /// each time a gesture is clamped, so raising the shared maximum cannot
    /// strand a conversation whose threshold is lower than this one's.
    public static func delta(reach: CGFloat, gain: Double, ceiling: Int32 = maximumDelta) -> Int32 {
        guard reach.isFinite, reach > 0 else { return 10 }
        let units = Int((reach / CGFloat(max(0.5, gain))).rounded())
        return Int32(max(10, min(Int(max(60, min(ceiling, maximumDelta))), units)))
    }
}
