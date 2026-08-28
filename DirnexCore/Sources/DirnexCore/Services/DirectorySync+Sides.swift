import Foundation

/// Where one side of a comparison gets a directory's children from (PLAN.md §M25 Slice 5c).
///
/// ``DirectorySync/compare(left:right:leftBackend:rightBackend:comparison:tolerance:includingIdentical:isCancelled:contentsEqual:)``
/// walks the two trees in lock-step, one `listDirectory` per directory pair, which is right on a
/// disk and is a **connection** per directory on a server. Measured 2026-08-28 against a real
/// `sshd` over loopback, where there is no latency to blame: seventeen directories cost **1010 ms**
/// as separate `sftp` invocations (59 ms each) and **76 ms** as one exec-channel walk. The gap is
/// the handshake, so it grows with the directory count and is far larger over a real link — and on
/// S3 each of those listings is also a *billed* request.
///
/// So a side asks its backend for the whole subtree first (``VFSBackend/subtreeListing(at:isCancelled:)``,
/// the seam M22 built for search), and serves the walk from that when it gets one. What does **not**
/// change is the walk itself: the lock-step descent, the rule that a directory present on only one
/// side is a single row for its whole subtree, and the refusal to descend into a type mismatch are
/// all decided exactly as before. The shortcut only changes where a directory's children come from,
/// which is the smallest thing it could change and the reason every existing comparison test still
/// pins the same behaviour.
struct SyncSide {
    /// The prefetched subtree, keyed by relative directory path (`""` for the root) and then by
    /// child name — or `nil` when this backend offers no shortcut and the walk must list.
    private let prefetched: [String: [String: FileEntry]]?

    /// Ask `backend` for everything under `root` in one go, falling back to `nil` — "walk instead" —
    /// whenever it cannot answer completely.
    ///
    /// **An incomplete listing falls back to the walk rather than being used or refused**, and that
    /// is the one hazard the shortcut brings with it. SFTP's answer is capped at a row limit it
    /// chose, and it says so (``VFSSubtreeListing/isComplete``); search is content to report a
    /// truncated result, and a *sync* cannot be, because a mirror over a subtree that stopped early
    /// deletes the other side's matching files. Slower and right beats faster and destructive, and
    /// the caller can still stop it.
    ///
    /// A local side gets the protocol's `nil` and pays nothing for asking.
    static func gather(
        under root: VFSPath,
        using backend: some VFSBackend,
        isCancelled: () -> Bool
    ) throws -> SyncSide {
        guard let listing = try backend.subtreeListing(at: root, isCancelled: isCancelled),
              listing.isComplete else {
            return SyncSide(prefetched: nil)
        }
        return SyncSide(prefetched: childrenByDirectory(of: listing.entries, under: root))
    }

    /// The children of the directory at `relative` below the root, listing it if this side has no
    /// prefetched subtree.
    ///
    /// A prefetched side never lists: a directory it holds no key for is **empty**, not unknown.
    /// Falling through to `listDirectory` there would put back exactly the per-directory round trip
    /// the gather paid once to avoid, on every leaf folder in the tree.
    func children(
        at absolute: VFSPath,
        relative: String,
        using backend: some VFSBackend
    ) throws -> [String: FileEntry] {
        if let prefetched { return prefetched[relative] ?? [:] }
        let entries = try backend.listDirectory(at: absolute)
        return Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Every entry bucketed by the relative path of the directory holding it, spelled the way the
    /// walk spells its own prefix (`""` at the root, `"docs/api"` two levels down) so the two agree
    /// without either knowing about the other.
    private static func childrenByDirectory(
        of entries: [FileEntry],
        under root: VFSPath
    ) -> [String: [String: FileEntry]] {
        // The root's own path, with the trailing slash a child prefix needs; `"/"` contributes none.
        let base = root.path == "/" ? "" : root.path
        var byDirectory: [String: [String: FileEntry]] = [:]
        for entry in entries {
            let full = entry.path.path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            guard !relative.isEmpty else { continue }
            let directory = relative.lastIndex(of: "/").map { String(
                relative[relative.startIndex..<$0]
            ) } ?? ""
            byDirectory[directory, default: [:]][entry.name] = entry
        }
        return byDirectory
    }
}
