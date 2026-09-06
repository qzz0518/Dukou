import Foundation

/// Short-lived geometry used to navigate a native range of at most 100 messages.
/// Native ZIP count and endpoints independently validate the resulting range.
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

    /// A sheet transition invalidates AX handles. Resume only after a fresh
    /// snapshot confirms the same ordered viewport, including repeated rows.
    public mutating func resume(_ next: [WeChatViewportRow], afterLeavingSelection: Bool = false) throws {
        guard !rows.isEmpty, rows.count == next.count else { throw WeChatReadError.transcriptMismatch }
        let shift = next[0].y - rows[0].y
        guard zip(rows, next).allSatisfy({
            let sameText = $0.text == $1.text || (afterLeavingSelection && !$1.text.isEmpty && $0.text.hasSuffix(" " + $1.text))
            return sameText && abs($0.height - $1.height) < 3 && abs($1.y - $0.y - shift) < 3
        }) else { throw WeChatReadError.transcriptMismatch }
        rows = next; lastDisplacement = shift
    }

    public mutating func advance(_ next: [WeChatViewportRow], older: Bool) throws {
        guard !rows.isEmpty, !next.isEmpty else { throw WeChatReadError.transcriptMismatch }
        var candidates: [(base: Int, count: Int, shift: Double)] = []
        for base in (firstOrdinal - rows.count + 1)...(firstOrdinal + next.count - 1) {
            var shifts: [Double] = [], valid = true
            for (j, row) in next.enumerated() {
                let i = firstOrdinal - (base - j)
                guard rows.indices.contains(i) else { continue }
                guard rows[i].text == row.text, abs(rows[i].height - row.height) < 3 else { valid = false; break }
                shifts.append(row.y - rows[i].y)
            }
            guard valid, let shift = shifts.first, shifts.allSatisfy({ abs($0 - shift) < 3 }),
                  older ? shift >= -2 : shift <= 2 else { continue }
            candidates.append((base, shifts.count, shift))
        }
        // Never use recycled AX child indices. Maximal visible overlap is a
        // navigation estimate; identical rows are still checked by native count.
        guard let best = candidates.max(by: { $0.count < $1.count }), best.count > 0 else { throw WeChatReadError.transcriptMismatch }
        firstOrdinal = best.base; lastDisplacement = best.shift; rows = next
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
/// prefix. Match an ordered context, retaining duplicates; never pick the first
/// row with a matching body or reuse an AX child index from another snapshot.
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
            if valid, overlap >= min(3, selected.count, normal.count) { matches.append((candidate, overlap)) }
        }
        guard let best = matches.map(\.overlap).max(), matches.filter({ $0.overlap == best }).count == 1,
              let result = matches.first(where: { $0.overlap == best }) else { throw WeChatReadError.transcriptMismatch }
        return result.target
    }
}
