import Foundation

/// Short-lived geometry used to navigate a native range of at most 100 messages.
/// Existing message ordinals survive live arrivals and recycled visible rows.
public struct WeChatViewportRow: Equatable, Sendable {
    public let text: String
    public let y: Double
    public let height: Double
    public init(text: String, y: Double, height: Double) { self.text = text; self.y = y; self.height = height }
}

public struct WeChatViewport: Sendable {
    public private(set) var rows: [WeChatViewportRow]
    /// Ordinal of the first visible row; larger values are older messages.
    public private(set) var firstOrdinal: Int
    public private(set) var lastDisplacement: Double = 0

    /// Reconstruct a fresh viewport around a message whose ordinal is known.
    public init(rows: [WeChatViewportRow], anchorIndex: Int, anchorOrdinal: Int = 0) {
        self.rows = rows; firstOrdinal = anchorOrdinal + anchorIndex
    }

    /// A sheet transition invalidates AX handles. Rebind the existing message
    /// context even when arrivals or layout changes add/remove visible rows.
    public mutating func resume(_ next: [WeChatViewportRow], afterLeavingSelection: Bool = false) throws {
        guard let best = nearest(overlaps(next, afterLeavingSelection: afterLeavingSelection)) else { throw WeChatReadError.transcriptMismatch }
        firstOrdinal = best.base; lastDisplacement = best.shift; rows = next
    }

    public mutating func advance(_ next: [WeChatViewportRow], older: Bool) throws {
        let candidates = overlaps(next)
        guard let context = nearest(candidates) else { throw WeChatReadError.transcriptMismatch }
        let directional = nearest(candidates.filter { $0.rigid && (older ? $0.shift >= -2 : $0.shift <= 2) })
        // Ordinary scrolling keeps its geometry/direction path. An arrival can
        // reverse the net translation, so retain stronger old context instead
        // of failing or shifting a repeated run to satisfy that direction.
        let best: Overlap
        if let directional, directional.count == context.count,
           abs(directional.base - firstOrdinal) <= abs(context.base - firstOrdinal) {
            best = directional
        } else { best = context }
        firstOrdinal = best.base; lastDisplacement = best.shift; rows = next
    }

    private typealias Overlap = (base: Int, count: Int, shift: Double, rigid: Bool)

    private func overlaps(_ next: [WeChatViewportRow], afterLeavingSelection: Bool = false) -> [Overlap] {
        guard !rows.isEmpty, !next.isEmpty else { return [] }
        var candidates: [Overlap] = []
        for base in (firstOrdinal - rows.count + 1)...(firstOrdinal + next.count - 1) {
            var shifts: [Double] = [], valid = true, sameHeights = true
            for (j, row) in next.enumerated() {
                let i = firstOrdinal - (base - j)
                guard rows.indices.contains(i) else { continue }
                let sameText = !row.text.isEmpty && (rows[i].text == row.text || (afterLeavingSelection && rows[i].text.hasSuffix(" " + row.text)))
                guard sameText else { valid = false; break }
                sameHeights = sameHeights && abs(rows[i].height - row.height) < 3
                shifts.append(row.y - rows[i].y)
            }
            guard valid, !shifts.isEmpty else { continue }
            let shift = shifts.sorted()[shifts.count / 2]
            let rigid = sameHeights && shifts.allSatisfy({ abs($0 - shift) < 3 })
            candidates.append((base, shifts.count, shift, rigid))
        }
        return candidates
    }

    private func nearest(_ candidates: [Overlap]) -> Overlap? {
        candidates.min {
            if $0.count != $1.count { return $0.count > $1.count }
            let left = abs($0.base - firstOrdinal), right = abs($1.base - firstOrdinal)
            if left != right { return left < right }
            if $0.rigid != $1.rigid { return $0.rigid }
            return abs($0.shift) < abs($1.shift)
        }
    }

    public func index(of ordinal: Int) -> Int? {
        let index = firstOrdinal - ordinal
        return rows.indices.contains(index) ? index : nil
    }

    /// Qt excludes an endpoint flush against the list's top edge. A message
    /// taller than the viewport can only qualify with a keyboard-verified ordinal.
    public func canSelectRange(endingAt ordinal: Int, listTop: Double, listHeight: Double, keyboardVerified: Bool) -> Bool {
        guard let target = index(of: ordinal), rows[target].y >= listTop + 4 else { return false }
        let firstFullyVisible = rows.firstIndex { $0.y >= listTop && $0.y + $0.height <= listTop + listHeight }
        if firstFullyVisible == target { return true }
        return keyboardVerified && rows.firstIndex(where: { $0.y >= listTop + 4 }) == target
    }
}

/// Rebind a message after leaving multi-select. The normal UI omits the sender
/// prefix. Prefer the longest old context, using proximity when identical runs
/// cannot be distinguished. New messages do not impose a larger overlap minimum.
public enum WeChatMessageContext {
    public static func resolve(selected: [String], target: Int, normal: [String]) throws -> Int {
        guard selected.indices.contains(target), !normal.isEmpty else { throw WeChatReadError.transcriptMismatch }
        var matches: [(target: Int, overlap: Int)] = []
        for offset in (-selected.count + 1)..<normal.count {
            let candidate = target + offset
            guard normal.indices.contains(candidate) else { continue }
            var overlap = 0, valid = true
            for (i, label) in selected.enumerated() where normal.indices.contains(i + offset) {
                let body = normal[i + offset]
                if body.isEmpty || !(label == body || label.hasSuffix(" " + body)) { valid = false; break }
                overlap += 1
            }
            if valid, overlap > 0 { matches.append((candidate, overlap)) }
        }
        guard let result = matches.min(by: {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            return abs($0.target - target) < abs($1.target - target)
        }) else { throw WeChatReadError.transcriptMismatch }
        return result.target
    }
}
