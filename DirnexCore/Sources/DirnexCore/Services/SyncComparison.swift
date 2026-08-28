import Foundation

/// How two same-named files are judged equal, and which of those judgements a given pair of
/// locations can honestly support (PLAN.md §M25 Slice 5c).
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
    /// Equal only when the bytes are identical (via the content comparator). Exact, but
    /// reads both files; still short-circuits on a size mismatch.
    case content

    /// Whether this comparison consults a modification time at all — for equality, or for deciding
    /// which side is newer.
    ///
    /// Named rather than spelled `!= .size` at the two sites that read it, because what it decides
    /// is not "is this case special" but "may the clock be believed here", and a second clockless
    /// comparison added later must inherit that answer rather than a comparison somebody has to
    /// find. It is what keeps ``SyncStatus/leftNewer``/``SyncStatus/rightNewer`` out of a scan whose
    /// whole premise is that neither side's stamp means what it says.
    public var usesModificationDates: Bool { self != .size }

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
    /// 3. ``content`` needs both sides on this disk, and that is a fact about what is **built**
    ///    rather than about what is honest: ``DirectorySync/compare(left:right:leftBackend:rightBackend:comparison:tolerance:includingIdentical:isCancelled:contentsEqual:)``
    ///    reads bytes through an injected comparator whose default is ``ByteComparator`` and only
    ///    ever sees real local paths. Comparing contents across a server means fetching every
    ///    candidate pair, at a price a plan has to state up front, and that is its own slice.
    ///
    /// The order is increasing strictness, which is also increasing cost.
    public static func available(between left: VFSBackendID, and right: VFSBackendID) -> [
        SyncComparison
    ] {
        var available: [SyncComparison] = [.size]
        if left.hasComparableModificationTimes, right.hasComparableModificationTimes {
            available.append(.sizeAndDate)
        }
        if left == .local, right == .local {
            available.append(.content)
        }
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
