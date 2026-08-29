import Foundation

/// How two same-named files are judged equal, and which of those judgements a given pair of
/// locations can honestly support (PLAN.md §M25 Slices 5c and 5d).
///
/// Split out of ``DirectorySync`` when the second question arrived: what a comparison *is* stayed
/// one line each, while what a pair of sides may be *offered* is a rule with measurements behind it
/// and belongs beside the cases it selects from rather than inside the engine that runs them.
public enum SyncComparison: Sendable, Equatable, CaseIterable {
    /// Equal when the byte sizes match. Nothing else is read and no clock is consulted.
    ///
    /// The honest comparison wherever a listing's modification time cannot be trusted — which is
    /// every remote backend here, for three different reasons (see
    /// ``VFSBackendID/hasComparableModificationTimes``). It is blind to an edit that preserved the
    /// size, and says so by never ranking: two differing files come back
    /// ``SyncStatus/differ`` rather than one of them "newer", because with no clock there is
    /// nothing that could have decided which.
    case size
    /// Equal when byte sizes match *and* modification times agree within the tolerance.
    /// Fast — reads no file contents — but blind to an edit that preserved size and mtime.
    case sizeAndDate
    /// Equal only when the bytes are identical (via the content comparator). Exact, and the only
    /// comparison a coarse listing cannot make dishonest — bytes are bytes wherever they live.
    ///
    /// It still short-circuits on a size mismatch, which is what bounds its cost: only pairs that
    /// are the same size are ever read, and where a side is not on this disk those pairs — and no
    /// others — are fetched first, by the gesture, at a total it states before it starts
    /// (``DirectorySync/contentCandidates(in:)``). What it does *not* buy is a clock: a difference
    /// it finds is ranked only where both listings keep a stamp worth reading, which is
    /// ``believesModificationDates(between:and:)``.
    case content

    /// Whether this comparison consults a modification time at all — for equality, or for deciding
    /// which side is newer.
    ///
    /// Named rather than spelled `!= .size` at the sites that read it, because what it decides is
    /// not "is this case special" but "does the clock come into this at all", and a second clockless
    /// comparison added later must inherit that answer rather than a comparison somebody has to
    /// find.
    ///
    /// It is a fact about the **comparison** and is deliberately not the whole rule: whether the
    /// clock may be *believed* also depends on the two sides, which is
    /// ``believesModificationDates(between:and:)``. Splitting them is what M25 Slice 5d forced —
    /// ``content`` consults the clock (to rank a difference its bytes found, and to judge a symlink
    /// it cannot read) and can now span a side whose listing has no usable stamp.
    public var usesModificationDates: Bool { self != .size }

    /// Whether a scan of this pair may believe a modification time — for ranking a difference, and
    /// for the metadata fallback ``content`` uses on the items it cannot read bytes from.
    ///
    /// Both halves have to hold: the comparison has to consult the clock at all, and **both** sides
    /// have to keep one worth comparing (``VFSBackendID/hasComparableModificationTimes``). It is the
    /// same rule ``available(between:and:)`` applies when it withdraws ``sizeAndDate``, said again
    /// where the engine needs it — because ``content`` is offered over pairs that rule withdraws
    /// dates from, and a content scan that ranked by a coarse stamp would hand a bidirectional sync
    /// exactly the `.leftNewer` that milestone withdrew.
    ///
    /// For ``sizeAndDate`` it can only ever be `true` at the sheet, which never offers that
    /// comparison over a coarse pair — so this changes nothing there, and refuses to invent a
    /// ranking for a caller that reached the engine directly.
    public func believesModificationDates(
        between left: VFSBackendID,
        and right: VFSBackendID
    ) -> Bool {
        usesModificationDates
            && left.hasComparableModificationTimes
            && right.hasComparableModificationTimes
    }

    /// The comparisons that can honestly be offered between a location on `left` and one on
    /// `right`, in the order a picker should show them.
    ///
    /// Three rules, and only the first is about honesty:
    ///
    /// 1. ``size`` is always available. A byte count is a byte count on every backend here.
    /// 2. ``sizeAndDate`` needs a comparable clock on **both** sides
    ///    (``VFSBackendID/hasComparableModificationTimes``). One coarse side is enough to poison it,
    ///    and so is *two* coarse sides of the same dialect — two files thirty seconds apart both
    ///    read as the same minute over `sftp`, so a mirror would call them identical and skip the
    ///    one that changed, which is the quiet direction.
    /// 3. ``content`` is always available too, and since M25 Slice 5d that is the *whole* rule.
    ///    Bytes are bytes on every backend: what used to withdraw it was not honesty but what was
    ///    **built** — the engine reads through an injected comparator whose default is
    ///    ``ByteComparator``, which only ever sees real local paths, so a side that was not on this
    ///    disk had nothing to hand it. Every candidate pair is now fetched first, by the gesture,
    ///    at a price ``MaterializationPlan`` states up front, and the comparator still sees only
    ///    files that are already here.
    ///
    /// The order is increasing strictness, which is also increasing cost — and past ``sizeAndDate``
    /// that cost is no longer only this machine's: a content scan over a server reads every
    /// same-size pair end to end, which is what the confirmation in front of it is for.
    public static func available(between left: VFSBackendID, and right: VFSBackendID) -> [
        SyncComparison
    ] {
        var available: [SyncComparison] = [.size]
        if left.hasComparableModificationTimes, right.hasComparableModificationTimes {
            available.append(.sizeAndDate)
        }
        available.append(.content)
        return available
    }

    /// The comparison to start with over this pair — the strongest cheap one available.
    ///
    /// ``sizeAndDate`` where both clocks can be believed, which is what a local-to-local sync has
    /// always opened on, and ``size`` otherwise. Never ``content``: it reads every candidate file,
    /// and a scan that expensive is something to ask for rather than something to land in.
    public static func `default`(between left: VFSBackendID, and right: VFSBackendID) -> SyncComparison {
        available(between: left, and: right).contains(.sizeAndDate) ? .sizeAndDate : .size
    }
}
