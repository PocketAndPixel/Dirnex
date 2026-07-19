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
    public static func size(
        of path: VFSPath,
        using backend: some VFSBackend,
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
