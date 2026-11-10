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

/// A **bounded** flat listing, for a search across an account's buckets (PLAN.md §M38 Slice 5).
///
/// The unbounded one above suits a search inside one bucket, which the user pointed at and which a
/// runaway guard of a million keys covers. An account is a different question: every bucket the
/// key can see, so a share of each is what a search can honestly promise, and the dialog states it
/// before anything is asked (``S3AccountSearch/objectsPerBucket``).
extension S3Backend {
    /// The first `objectLimit` objects beneath `path`, in the order the server lists keys, as the
    /// rows a walk of them would have produced.
    ///
    /// Here, unlike the unbounded listing, ``VFSSubtreeListing/isComplete`` `== false` is an honest
    /// answer: the slice is "the first N keys", which is what the user was told would be searched,
    /// rather than wherever a failure happened to stop. It is `false` when the bound was reached
    /// with objects left over, and when `isCancelled` answered `true` part-way; the caller tells the
    /// two apart by asking `isCancelled` itself.
    ///
    /// A stop **returns** what it has rather than throwing, where the unbounded listing throws
    /// `CancellationError`. That listing is one request's worth of answer to one search; this is one
    /// bucket of many, and the pages already paid for hold real matches the user is about to see
    /// beside every other bucket's.
    ///
    /// The last page is cut to the bound, so "the first 10,000 objects" is exactly that on a server
    /// whose pages are not 1000 long. A directory marker counts as an object, because to S3 it is
    /// one.
    ///
    /// - Parameter firstPage: the page the caller already fetched at `path`'s prefix, used in place
    ///   of asking for it again.
    func boundedSubtreeListing(
        at path: VFSPath,
        objectLimit: Int,
        firstPage: S3ListingPage? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> VFSSubtreeListing {
        try requireOwnBackend(path)
        var listing = S3SubtreeListing(root: path)
        var listed = 0
        var cut = false
        let run = try enumeratePages(
            prefix: S3Key.listingPrefix(for: path),
            delimiter: nil,
            at: path,
            firstPage: firstPage,
            isCancelled: isCancelled,
            wantsMore: { listed < objectLimit && !isCancelled() },
            body: { page in
                let room = max(objectLimit - listed, 0)
                if page.objects.count > room {
                    cut = true
                    listing.add(page.keepingFirst(room))
                    listed = objectLimit
                } else {
                    listing.add(page)
                    listed += page.objects.count
                }
            }
        )
        return VFSSubtreeListing(entries: listing.entries, isComplete: run == .exhausted && !cut)
    }
}

private extension S3ListingPage {
    /// This page with only its first `count` objects.
    func keepingFirst(_ count: Int) -> S3ListingPage {
        S3ListingPage(
            objects: Array(objects.prefix(count)),
            commonPrefixes: commonPrefixes,
            nextContinuationToken: nextContinuationToken,
            isTruncated: isTruncated,
            isURLEncoded: isURLEncoded
        )
    }
}
