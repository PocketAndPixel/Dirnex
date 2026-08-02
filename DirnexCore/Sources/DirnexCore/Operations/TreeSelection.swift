import Foundation

/// One destination directory's worth of a branch transfer: the sources that land side by side,
/// plus where that is, relative to the operation's destination (PLAN.md §M15 Slice 4).
///
/// `relativeComponents` is empty for items marked at the tree's own level — which is the whole of a
/// list-mode transfer, so the flat path never sees a second group.
public struct TreeTransferGroup: Sendable, Equatable {
    /// Path components below the destination directory, e.g. `["Alpha", "Nested"]`. Empty for a
    /// source that sits directly in the tree's root directory.
    public let relativeComponents: [String]
    /// The items landing in that directory, in the order they were marked (row order).
    public let sources: [FileEntry]

    public init(relativeComponents: [String], sources: [FileEntry]) {
        self.relativeComponents = relativeComponents
        self.sources = sources
    }

    /// Where this group's sources land, under an operation's destination directory.
    public func destination(under directory: VFSPath) -> VFSPath {
        relativeComponents.reduce(directory) { $0.appending($1) }
    }
}

/// The two operation semantics a tree selection needs and a flat one never did — settled ahead of
/// the slice because they are about what F5/F6/F8 *do*, not about how the tree draws (PLAN.md §M15,
/// "Two decisions to settle before Slice 4 opens").
///
/// Both are pure functions over a marked set, and both are **no-ops for a list-mode selection**: a
/// flat listing shows one directory, so every marked item is a sibling of every other — nothing can
/// nest inside anything, and every relative path is empty. That is deliberate. The tree is a
/// projection over the same index space, not a second surface (§6), so these belong on the one path
/// both modes take rather than behind a mode check that would fork it.
public enum TreeSelection {
    /// Drop every item that already travels inside another item of the same set, keeping the
    /// outermost — *"dedupe to the ancestor"*.
    ///
    /// The plan settles this for **F8**: deleting a folder already takes its contents, so passing
    /// both makes the second delete fail on a path that no longer exists. The identical argument
    /// covers a recursive **copy or move**, which is why this is applied there too: copying `Alpha`
    /// reproduces `Alpha/Nested/deep.txt` at exactly the path the separately-marked child would have
    /// been written to, so keeping both buys a conflict prompt over a file the user never chose to
    /// duplicate.
    ///
    /// Containment is decided on the path (`isSelfOrDescendant`), so it costs no I/O and is right
    /// for any backend. Order is preserved — the survivors come back in the order they were given.
    public static func withoutNestedItems(_ entries: [FileEntry]) -> [FileEntry] {
        // Every ancestor of a nested item is itself in the set, so one pass over the paths answers
        // it: an item is dropped exactly when some *other* marked path contains it.
        let paths = Set(entries.map(\.path))
        return entries.filter { entry in
            !entry.path.ancestorsFromRoot.contains { $0 != entry.path && paths.contains($0) }
        }
    }

    /// Group a marked set by the subdirectory each item lands in when the selection is transferred,
    /// **preserving each item's path relative to `root`** — Total Commander's branch-view behaviour,
    /// and the settled answer to "what F5/F6 do with marks spanning levels".
    ///
    /// The alternative — everything flat into one folder — collides the moment two expanded folders
    /// each hold an `x.jpg`, and silently, since both are legitimate sources for the same
    /// destination name.
    ///
    /// A selection entirely at the tree's own level (every list-mode transfer, and the common tree
    /// one) yields a single group with no components, which is byte-for-byte today's operation. An
    /// item that is somehow not under `root` lands at the top level rather than being dropped —
    /// there is no such case in a tree, whose marks are pruned to its own entries, and losing a
    /// source silently would be the worse failure if one ever arose.
    ///
    /// Groups come back shallowest-first and then in path order — deterministic, and every group
    /// after the ones that contain it.
    public static func transferGroups(
        _ entries: [FileEntry],
        relativeTo root: VFSPath
    ) -> [TreeTransferGroup] {
        var order: [[String]] = []
        var grouped: [[String]: [FileEntry]] = [:]
        for entry in entries {
            let components = relativeParentComponents(of: entry.path, under: root)
            if grouped[components] == nil { order.append(components) }
            grouped[components, default: []].append(entry)
        }
        return order
            .sorted { ($0.count, $0.joined(separator: "/")) < ($1.count, $1.joined(separator: "/")) }
            .map { TreeTransferGroup(relativeComponents: $0, sources: grouped[$0] ?? []) }
    }

    /// The components between `root` and the *parent* of `path` — `["Alpha", "Nested"]` for
    /// `<root>/Alpha/Nested/deep.txt`, and `[]` for a direct child of the root or for anything that
    /// isn't under it at all.
    private static func relativeParentComponents(
        of path: VFSPath,
        under root: VFSPath
    ) -> [String] {
        guard path.backend == root.backend, path.isSelfOrDescendant(of: root), path != root else {
            return []
        }
        let rootComponents = components(of: root.path)
        let pathComponents = components(of: path.path)
        return Array(pathComponents.dropFirst(rootComponents.count).dropLast())
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
