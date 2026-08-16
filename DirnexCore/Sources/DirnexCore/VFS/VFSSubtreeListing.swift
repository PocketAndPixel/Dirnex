import Foundation

/// What ``VFSBackend/subtreeListing(at:isCancelled:)`` hands back: every entry beneath a folder,
/// gathered without walking it, **plus whether that was all of them** (PLAN.md §M22).
///
/// The second field is the whole reason this is a type rather than the bare `[FileEntry]` the seam
/// returned when only S3 filled it. S3 pages until the bucket is exhausted, so it is always complete
/// and the question never came up; SFTP's shortcut is one remote command whose output is *capped*,
/// because a `find` over somebody's home directory can print hundreds of megabytes down a channel
/// this process has to hold in memory. A cap that could not be reported would make a search over a
/// large tree quietly answer "here is everything, and it is complete" about the first slice of it —
/// which is the quiet direction, and worse than the walk it replaces because the walk at least says
/// ``SubtreeSearch/Completion/budgetExceeded`` when it gives up.
public struct VFSSubtreeListing: Sendable, Equatable {
    /// The entries, indistinguishable from what a walk would have produced.
    public let entries: [FileEntry]
    /// Whether `entries` is the whole subtree. `false` means the backend stopped early of its own
    /// accord — not that anything failed, and not that the caller asked it to.
    public let isComplete: Bool

    public init(entries: [FileEntry], isComplete: Bool = true) {
        self.entries = entries
        self.isComplete = isComplete
    }
}
