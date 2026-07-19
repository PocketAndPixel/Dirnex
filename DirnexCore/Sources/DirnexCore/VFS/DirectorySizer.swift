import Foundation

/// Recursively totals the logical byte size of a directory subtree by walking a
/// `VFSBackend`. This is the engine behind Total Commander's Space-on-directory
/// in-place sizing (PLAN.md §M1): the panel shows a folder's real weight in the size
/// column instead of a dash.
///
/// It lives in `DirnexCore` because it touches bytes ("if it touches bytes, it lives
/// in DirnexCore and has tests" — §2), and is a plain synchronous function so the
/// caller decides where it runs. The app runs it on a background queue and applies
/// the result on the main actor.
public enum DirectorySizer {
    /// The recursive byte total of everything beneath `path`.
    ///
    /// - Only files (and non-directory special entries) contribute bytes; a directory
    ///   adds its contents, not its own inode size — matching how TC reports a folder's
    ///   weight.
    /// - Symlinks are counted by their own (link) size and never followed, so a symlink
    ///   cycle cannot wedge the walk. The top-level `path` is still opened normally, so
    ///   sizing a directory reached through a symlink works.
    /// - An unreadable subdirectory is skipped rather than aborting the whole total; a
    ///   partial number beats no number, and permission gaps are common.
    ///
    /// The walk is iterative (an explicit stack) so arbitrarily deep trees cannot blow
    /// the call stack. Pass `isCancelled` to abandon a huge tree when the user has
    /// navigated away — it throws `CancellationError` in that case.
    ///
    /// `isExcluded` leaves a subtree out of the total entirely — the `.gitignore`-aware sizing of
    /// §M6, whose predicate is `GitStatusSnapshot.isExcludedFromSize`. An excluded *directory* is
    /// never pushed onto the stack, so it costs nothing to leave out rather than being walked and
    /// then discarded. That pruning is most of the point: walk cost tracks **entry count**, not
    /// bytes (a 1 TB `~/Movies` walks fast where a 17 GB `node_modules` does not), so skipping the
    /// build output is also what makes the mode fast enough to leave on.
    ///
    /// The top-level `path` is never tested — sizing a folder you explicitly pointed at must
    /// produce a number even when it is itself ignored, or the ignored rows in a listing would all
    /// read as empty.
    ///
    /// **Label both closures at the call site.** With two of them a bare trailing closure binds to
    /// `excluding`, not to `isCancelled` — which is silently the opposite of what every pre-existing
    /// caller meant, and only failed loudly here because the two have different arities.
    public static func size(
        of path: VFSPath,
        using backend: some VFSBackend,
        excluding isExcluded: (VFSPath) -> Bool = { _ in false },
        isCancelled: () -> Bool = { false }
    ) throws -> Int64 {
        var total: Int64 = 0
        var stack: [VFSPath] = [path]
        while let directory = stack.popLast() {
            if isCancelled() { throw CancellationError() }
            let entries: [FileEntry]
            do {
                entries = try backend.listDirectory(at: directory)
            } catch {
                continue // unreadable subtree contributes nothing
            }
            for entry in entries {
                if isExcluded(entry.path) { continue }
                if entry.kind == .directory {
                    stack.append(entry.path)
                } else {
                    total += entry.byteSize
                }
            }
        }
        return total
    }
}
