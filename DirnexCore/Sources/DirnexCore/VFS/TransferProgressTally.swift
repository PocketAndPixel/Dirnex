import Foundation

/// Turns successive observations of "how much has moved" into the forward-only **deltas**
/// `VFSBackend.copyFile`'s `progress` takes (PLAN.md §M21 Slice 12).
///
/// Every remote transport reports progress by watching something that only counts upward — a
/// destination file that grows, or `curl`'s percentage meter — while the queue's tally only *adds*.
/// The conversion between the two is four lines and three rules, and it was written out once per
/// transport until FTP and SFTP came to need it too, which is this milestone's most repeated finding
/// (one rule, several spellings, and the compiler checks none of them). So it lives here, where the
/// rules are testable without a server:
///
/// - **It only ever reports forward.** An observation that has not advanced reports nothing, and one
///   that goes *backwards* reports nothing rather than a negative — a bar that has drawn those bytes
///   cannot un-draw them, and a queue that subtracts would end the job short.
/// - **A resume's existing bytes are not this transfer's.** The destination's size when the process
///   was spawned is the baseline, so a `-C -` continuation reports the remainder it actually moved
///   rather than re-counting what was already on disk.
/// - **A destination that shrinks is a fresh transfer.** `curl` and `sftp` both truncate a partial
///   they are not resuming from, so a size below the last one means the baseline is gone and
///   everything now arriving is new.
///
/// The estimate never decides the final count. A caller reconciles against the exact figure the tool
/// reported when it exited (``remainder(against:)``), so the bar is smooth while the number the job
/// settles on is the measured one.
public struct TransferProgressTally: Sendable, Equatable {
    /// Bytes that were already in the destination when this transfer started, and are therefore not
    /// its to report.
    private var baseline: Int64
    /// The last destination size seen, to notice a truncation.
    private var lastSeenSize: Int64
    /// How much has been handed to `progress` so far.
    private var reported: Int64 = 0

    /// - Parameter destinationAlreadyHolds: the destination's size at spawn — nonzero only when
    ///   resuming. It is the caller's to read, since only the caller knows which file that is.
    public init(destinationAlreadyHolds baseline: Int64 = 0) {
        self.baseline = baseline
        lastSeenSize = baseline
    }

    /// The delta to report now that the destination file is `size` bytes, or `nil` when nothing new
    /// has landed.
    public mutating func delta(forDestinationSize size: Int64) -> Int64? {
        if size < lastSeenSize { baseline = 0 }
        lastSeenSize = size
        return delta(movedSoFar: max(0, size - baseline))
    }

    /// The delta to report now that `moved` bytes are known to have moved, or `nil` when that is no
    /// more than has already been reported.
    public mutating func delta(movedSoFar moved: Int64) -> Int64? {
        guard moved > reported else { return nil }
        defer { reported = moved }
        return moved - reported
    }

    /// Record a delta somebody else has already reported, so ``remainder(against:)`` knows what is
    /// left. This is the backend's half: the *transport* watches the transfer and reports as it
    /// goes, and the backend only has to reconcile at the end.
    public mutating func add(_ delta: Int64) {
        reported += max(0, delta)
    }

    /// What is left to report once the transfer is over and its exact byte count is known, or `nil`
    /// when the estimates already covered it.
    ///
    /// An overshoot is left standing rather than corrected: the estimate is at one-per-cent
    /// resolution, and a bar that jumps back is worse than a bar that arrived early.
    public mutating func remainder(against exact: Int64) -> Int64? {
        delta(movedSoFar: exact)
    }
}
