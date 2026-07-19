import Foundation

/// Recursive directory totals kept across navigation (PLAN.md §M6 "computed async, cached").
///
/// The cache exists because the walk is slow in human terms — measured with the real
/// `DirectorySizer` on this machine: 7.5 s for `~/Dev`, 8.5 s for `/Applications`, 8 s to size
/// every child of `~`. Without it, stepping out of a folder and back re-earns that wait, and
/// size-visualization mode becomes unusable as a browsing mode.
///
/// **It is a latency optimization and never an authority.** The intended app-side policy is
/// stale-while-revalidate: seed the panel from the cache so bars appear instantly, and re-walk
/// in the background to correct them. That matters because the app watches only the *displayed*
/// directory — a tree that changes while you are looking elsewhere generates no event, so a cached
/// total can be silently wrong. ncdu has the same property (its scan is a point-in-time snapshot
/// until you press `r`), but ncdu looks like a snapshot where a file panel looks live.
///
/// Kept separate from `DirectoryModel.directorySizes`, which is the *panel's* copy: pruned to the
/// entries actually present and discarded on navigation. This one outlives both.
public struct DirectorySizeCache: Sendable {
    /// Bounded so a long session cannot grow it without limit.
    ///
    /// The default is large because **the unit of caching here is one directory's total**, and a
    /// panel in size-visualization mode stores one per child row — so the capacity has to be
    /// counted in "several panels' worth of children", not in "a few repositories" the way
    /// `GitStatusProvider`'s 8 snapshots are. An entry is a path string and an `Int64`; 512 of them
    /// cost tens of kilobytes, which is nothing set against re-walking a tree for eight seconds.
    public let capacity: Int

    private var sizes: [VFSPath: Int64]
    /// Keys least-recently-*stored* first. See `size(for:)` on why storage, not access, orders this.
    private var order: [VFSPath]

    public init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
        sizes = [:]
        order = []
    }

    public var count: Int { sizes.count }

    public var isEmpty: Bool { sizes.isEmpty }

    /// The cached total for `path`, or `nil` if absent.
    ///
    /// Deliberately **non-mutating**: eviction is ordered by last *store*, not last read. The app's
    /// stale-while-revalidate re-stores a total every time it revisits a directory, so the two
    /// orders coincide where it matters — and a mispredicted eviction costs a re-walk, never a
    /// wrong number. That is worth more than making every row lookup on the render path mutate.
    public func size(for path: VFSPath) -> Int64? {
        sizes[path]
    }

    /// Record a freshly-walked total, evicting the least-recently-stored entries past `capacity`.
    /// Negatives are clamped to zero, as at every other boundary that accepts a backend's bytes.
    public mutating func store(_ bytes: Int64, for path: VFSPath) {
        if sizes.updateValue(max(0, bytes), forKey: path) != nil {
            order.removeAll { $0 == path }
        }
        order.append(path)
        while sizes.count > capacity, !order.isEmpty {
            sizes.removeValue(forKey: order.removeFirst())
        }
    }

    /// Drop every total that a change somewhere beneath `path` could have altered.
    ///
    /// This is shaped by what an FSEvents ping actually proves. `DirectoryWatcher` reports *no
    /// paths* — its callback discards them — and an FSEvents stream is recursive, so the only fact
    /// available is "something under the watched directory changed". The sound response is to drop
    /// every cached total lying on the same root-to-leaf line as `path`:
    /// - **`path` itself and its descendants**, because the ping does not say which one changed; and
    /// - **`path`'s ancestors**, because their totals are sums that include whatever it was.
    ///
    /// Siblings survive: a change under `/a/b` cannot alter `/a/c`'s total. That is the whole value
    /// of the rule — it is the mirror image of `GitStatusSnapshot`'s ancestor roll-up, which pushes
    /// a leaf's *status* up the same line this pushes a leaf's *staleness* up.
    ///
    /// Conservative by construction, and correct for either caller: handed an exact event path it
    /// invalidates precisely, handed a watched root it invalidates that root's whole line. Over-
    /// invalidating costs a re-walk; under-invalidating shows a wrong number, so the trade is not
    /// symmetric. Comparison goes through `VFSPath.isSelfOrDescendant`, which is backend-scoped and
    /// gets the `/a` vs `/ab` boundary right — the reason not to hand-roll a string prefix test.
    public mutating func invalidate(under path: VFSPath) {
        let doomed = sizes.keys.filter {
            $0.isSelfOrDescendant(of: path) || path.isSelfOrDescendant(of: $0)
        }
        guard !doomed.isEmpty else { return }
        let removed = Set(doomed)
        for key in doomed { sizes.removeValue(forKey: key) }
        order.removeAll { removed.contains($0) }
    }

    /// Forget everything — the explicit-refresh path (ncdu's `r`).
    public mutating func removeAll() {
        sizes.removeAll()
        order.removeAll()
    }
}
