import Foundation

/// A running count of what one connection has failed to carry — the shape that makes "what did
/// *this job* lose" answerable (PLAN.md §M25 Slice 5b).
///
/// ``RemoteMetadataSupport`` accumulates for the life of a **connection**, which is the right expiry
/// for a fact about a server and the wrong window for a sentence about a copy: a user reading "the
/// modification times weren't kept" after their second transfer must not be told about the first.
/// Slice 2 wrote a draining `takeLoss()` alongside the accumulator and deleted it, on the grounds
/// that the run boundary belonged to whoever ended up reporting. This is that boundary, and it is a
/// **difference of two readings** rather than a drain, for one reason: a drain has to be called
/// exactly once by exactly one caller, and nothing in the type system says so. Two readings can be
/// taken by anybody, in any order, as many times as they like.
///
/// Counts per aspect rather than a set, because only a count subtracts. A set of aspects that were
/// already lost before a run cannot be told from the same aspect lost again during it — the
/// difference would silently report nothing, which is this milestone's own failure direction.
public struct RemoteMetadataTally: Sendable, Hashable {
    /// How many items have lost at least one aspect.
    public let itemCount: Int
    /// How many items lost each aspect. An absent key is zero.
    public let perAspect: [RemoteMetadataAspect: Int]

    public init(itemCount: Int, perAspect: [RemoteMetadataAspect: Int]) {
        self.itemCount = itemCount
        self.perAspect = perAspect
    }

    /// Nothing lost — what a local backend, an archive and an object store all answer, and what a
    /// healthy connection answers for as long as it stays healthy.
    public static let zero = RemoteMetadataTally(itemCount: 0, perAspect: [:])

    /// Two connections' readings added together, for a job whose ends are on different accounts.
    ///
    /// A relayed copy touches two backends, and each records what **its own** leg could not carry —
    /// so the sum is the job's loss. The one inexactness is deliberate and is the direction this
    /// milestone always chooses: a file whose *download* leg also failed to write metadata on this
    /// machine would be counted by both legs. That needs a `chmod` to fail on a staging file the app
    /// just created, and over-reporting a loss is safe where claiming a carry that did not happen is
    /// not (the rule ``SFTPBackend/record(_:against:)`` already states).
    public func adding(_ other: RemoteMetadataTally) -> RemoteMetadataTally {
        RemoteMetadataTally(
            itemCount: itemCount + other.itemCount,
            perAspect: perAspect.merging(other.perAspect, uniquingKeysWith: +)
        )
    }

    /// What happened *since* `earlier` — the reading taken before a run subtracted from the one
    /// taken after it.
    ///
    /// Clamped at zero rather than trusted, because the two readings can legitimately come from
    /// different objects: a connection dropped and re-established mid-job answers from a fresh
    /// accumulator, so the later reading can be the smaller one. A negative count is not a
    /// meaningful thing to report, and a crash is not either.
    public func since(_ earlier: RemoteMetadataTally) -> RemoteMetadataTally {
        var delta: [RemoteMetadataAspect: Int] = [:]
        for (aspect, count) in perAspect {
            let difference = count - (earlier.perAspect[aspect] ?? 0)
            if difference > 0 { delta[aspect] = difference }
        }
        return RemoteMetadataTally(
            itemCount: max(0, itemCount - earlier.itemCount),
            perAspect: delta
        )
    }

    /// This tally as something worth saying, or `nil` when there is nothing to say — which is the
    /// good case and by far the common one.
    ///
    /// Both halves have to be non-empty. A tally with a count and no aspects cannot be worded (there
    /// is nothing to name), and one with aspects and no count is a reading taken across a
    /// reconnection rather than a loss anybody suffered.
    public var loss: RemoteMetadataLoss? {
        guard !perAspect.isEmpty, itemCount > 0 else { return nil }
        return RemoteMetadataLoss(aspects: Set(perAspect.keys), itemCount: itemCount)
    }
}
