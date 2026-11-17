import Foundation

/// A copy or move seen file by file, below its top-level sources: what Total Commander's progress
/// dialog draws as the bar for the file being written now, and as "file 34 of 340" (PLAN.md §M41).
///
/// `OperationProgress` already says how far the whole job is in bytes, and its `currentItem` names a
/// top-level source. A folder of three thousand files is one item there, and the engine reported
/// only every 8 MiB, so a small file was never named: measured 2026-11-17 on a folder of 3 000 4 KB
/// files and one of 200 MB, copied by the chunked path, 29 updates arrived and none named a small
/// file, and the copy went half a second without one. This is the level below `currentItem`. Only
/// the copy engine fills it in; every other kind of job leaves it `nil`.
public struct TransferFiles: Sendable, Equatable {
    /// Every file the job will write, counted by the pre-scan at any depth
    /// (``DirectorySizeMeasurement/files``). A symlink and any other non-directory count as one; a
    /// directory counts as none.
    public let total: Int
    /// Files written so far, at any depth. A source taken whole (a clone, a same-volume rename, a
    /// skipped conflict) adds all of its files at once. A failed attempt's files are taken back,
    /// as its bytes are, so a source that fails and is skipped leaves this short of `total`.
    public let completed: Int
    /// The file being written now, at any depth. `nil` before the first file, once a top-level
    /// source is done, and while a source is taken whole, when there is no file to name.
    public let current: VFSPath?
    /// Bytes of `current` written so far.
    public let currentCompletedBytes: Int64
    /// `current`'s size, from the listing that found it.
    public let currentTotalBytes: Int64

    public init(
        total: Int,
        completed: Int,
        current: VFSPath?,
        currentCompletedBytes: Int64,
        currentTotalBytes: Int64
    ) {
        self.total = total
        self.completed = completed
        self.current = current
        self.currentCompletedBytes = currentCompletedBytes
        self.currentTotalBytes = currentTotalBytes
    }

    /// How far through `current` the copy is, in `0...1`. `0` with no current file and for an empty
    /// one, which has nothing to draw.
    public var currentFraction: Double {
        guard current != nil, currentTotalBytes > 0 else { return 0 }
        return min(1, Double(currentCompletedBytes) / Double(currentTotalBytes))
    }
}
