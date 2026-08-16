import Foundation

/// S3's answer to ``VFSBackend/subtreeListing(at:isCancelled:)`` — the one backend in this project
/// that can hand over a whole subtree without walking it (PLAN.md §M22).
///
/// The asymmetry is real rather than an optimization anyone could copy. FTP and SFTP browse a
/// genuine filesystem, so "everything under this folder" is one round trip **per directory** and
/// there is no other way to ask. A bucket is not a tree at all: it is a flat map from key to bytes
/// that *renders* as a tree because a listing asks for `delimiter=/`. Drop the delimiter and the
/// same request answers the entire subtree, 1000 keys at a time — so a search over ten thousand
/// objects in a thousand folders costs ten requests, not a thousand.
public extension S3Backend {
    /// Every entry beneath `path`, from a delimiter-less enumeration.
    ///
    /// Two things it does **not** do, both of which follow from the seam's contract rather than from
    /// S3:
    ///
    /// It never returns `nil`. That value means "there is no shortcut here, walk instead", and there
    /// always is one — a bucket cannot be in a state where the flat query is unavailable while the
    /// per-directory one works, since they are the same request with one parameter changed.
    ///
    /// It has nothing partial to offer, so it is never ``VFSSubtreeListing/isComplete`` `== false`.
    /// A failure part-way through leaves an arbitrary lexicographic slice of the subtree, which is
    /// not "the shallow part" or "the part nearest what you asked for" — it is wherever the paging
    /// happened to stop, so ``SubtreeSearch`` is right to let the error through rather than present
    /// it as a truncated result. That is the opposite of SFTP's shortcut, which stops at a row cap
    /// it chose and can say so honestly. Cancellation is the one exception and it is the caller's
    /// own doing: it throws `CancellationError`, which the search converts back into the stop it
    /// asked for, so the two routes are indistinguishable at the Stop button.
    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        try requireOwnBackend(path)
        var listing = S3SubtreeListing(root: path)
        try enumeratePages(
            prefix: S3Key.listingPrefix(for: path),
            delimiter: nil,
            at: path,
            isCancelled: isCancelled
        ) { page in
            listing.add(page)
        }
        return VFSSubtreeListing(entries: listing.entries)
    }
}
