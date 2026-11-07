import Foundation

/// A message as the resume search compares it: what its label hashes to and
/// how tall its row is. Never its text.
public struct WeChatMessageMark: Codable, Hashable, Sendable {
    public let hash: String
    public let height: Double
    public init(hash: String, height: Double) { self.hash = hash; self.height = height }
}

/// Where an interrupted quick forward stopped, so a later run can carry on
/// from there instead of starting again at the newest message.
///
/// Positions count messages from the newest one as it stood when the
/// interrupted run began. Whatever has arrived since sits below that message,
/// and `newest` is how a later run finds it again.
public struct WeChatForwardInterruption: Codable, Hashable, Sendable {
    public var chat: String
    /// Messages already selected and exported.
    public var exported: Int
    /// The rows on screen at the bottom of the chat when that run began,
    /// newest first.
    public var newest: [WeChatMessageMark]
    /// The native exports already made, newest batch first: their directory
    /// names in the inbox, and the messages each holds.
    public var batches: [String]
    public var counts: [Int]
    public var at: Date

    public init(chat: String, exported: Int, newest: [WeChatMessageMark], batches: [String], counts: [Int], at: Date = Date()) {
        self.chat = chat; self.exported = exported; self.newest = newest
        self.batches = batches; self.counts = counts; self.at = at
    }
}

/// Finds an interrupted run's newest messages again, among messages read one
/// at a time from the newest message up.
///
/// Where they turn up is how many messages have arrived since. Labels alone
/// repeat — every photo reads 图片 — so a row's height settles a tie, and a
/// tie heights cannot settle is refused rather than guessed: a wrong guess
/// would export the wrong messages without a word.
public struct WeChatResumeSearch: Sendable {
    /// How many messages may have arrived before the search gives up.
    public static let maximumArrivals = 500

    public enum Failure: Error, Equatable { case notFound, ambiguous }

    public struct Candidate: Equatable, Sendable {
        public let arrivals: Int
        public let sameHeights: Bool
    }

    public let window: [WeChatMessageMark]
    public private(set) var seen = 0
    public private(set) var candidates: [Candidate] = []
    private var recent: [WeChatMessageMark] = []

    public init(window: [WeChatMessageMark]) { self.window = window }

    /// The next message up.
    public mutating func add(_ mark: WeChatMessageMark) {
        seen += 1
        recent.append(mark)
        if recent.count > window.count { recent.removeFirst() }
        guard !window.isEmpty, recent.count == window.count,
              zip(recent, window).allSatisfy({ $0.hash == $1.hash }) else { return }
        candidates.append(Candidate(arrivals: seen - window.count,
                                    sameHeights: zip(recent, window).allSatisfy { abs($0.height - $1.height) < 3 }))
    }

    /// Messages that have arrived since, as far as the rows read so far tell;
    /// nil while they cannot. Asked again after every row: a later exact
    /// match can still settle two that only share labels.
    public func arrivals() throws -> Int? {
        guard !window.isEmpty else { throw Failure.notFound }
        let matching = candidates.filter(\.sameHeights)
        if matching.count > 1 { throw Failure.ambiguous }
        if let found = matching.first { return found.arrivals }
        // Labels alone, as after the window was resized: taken only unique.
        if candidates.count == 1 { return candidates[0].arrivals }
        if seen >= Self.maximumArrivals + window.count { throw candidates.isEmpty ? Failure.notFound : Failure.ambiguous }
        return nil
    }
}
