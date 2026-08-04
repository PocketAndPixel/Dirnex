/// A pane's recursively-computed directory totals (Space-on-dir since §M1; the size-visualization
/// scan since §M6; per-level in a tree since §M15). Split from `Panel` proper for SwiftLint's
/// type-body limit, along the seam the concern already draws — every method here reads or writes the
/// *drawing surface*'s size map, dispatching tree vs. flat list in one place so the size column and
/// the bar projection can never disagree about a row's total.
public extension Panel {
    /// A row's recursively-computed directory total, or `nil` if it has none yet. Reads whichever
    /// surface is drawing — the tree's cross-level map in tree mode, the flat model's otherwise — so
    /// the size column and the size-bar projection agree on one answer per row (PLAN.md §M15). A file
    /// row is not a directory total and never carries one.
    func computedSize(of entry: FileEntry) -> Int64? {
        if let tree { return tree.computedSize(of: entry) }
        return model.computedSize(of: entry)
    }

    /// The computed directory totals for whichever surface is drawing — the tree's if in tree mode,
    /// the flat model's otherwise. The app reads this to tell a freshly-cached total apart from one it
    /// already holds before re-seeding, without knowing which surface owns it.
    var directorySizes: [VFSPath: Int64] {
        tree?.directorySizes ?? model.directorySizes
    }

    /// Record a recursively-computed size for the directory at `id` (Space-on-dir),
    /// keeping the cursor anchored on its entry by identity since size-sorting may
    /// reorder rows once the total lands. Routed to whichever surface is drawing: a tree stores it
    /// across levels (so a sized child at depth 2 keeps its number through a root refresh), a flat
    /// list in the model.
    mutating func setDirectorySize(_ id: VFSPath, bytes: Int64) {
        mutatingPreservingCursor {
            if $0.tree != nil {
                $0.tree?.setDirectorySizes([id: bytes])
            } else {
                $0.model.setDirectorySize(id, bytes: bytes)
            }
        }
    }

    /// Record many computed directory sizes at once — seeding size-visualization mode from the
    /// `DirectorySizeCache` — with one re-sort rather than one per entry, and the cursor kept
    /// anchored on its entry by identity since size-sorting reorders rows as the totals land. Routed
    /// to the drawing surface as `setDirectorySize` is.
    mutating func setDirectorySizes(_ sizes: [VFSPath: Int64]) {
        mutatingPreservingCursor {
            if $0.tree != nil {
                $0.tree?.setDirectorySizes(sizes)
            } else {
                $0.model.setDirectorySizes(sizes)
            }
        }
    }

    /// Forget every computed total — the `.gitignore`-aware mode being switched, or its rules
    /// changing (see `DirectoryModel.clearDirectorySizes`). Cursor anchored by identity as above,
    /// since dropping the totals can re-sort a size-sorted listing just as landing them can. Routed
    /// to the drawing surface as the setters are.
    mutating func clearDirectorySizes() {
        mutatingPreservingCursor {
            if $0.tree != nil {
                $0.tree?.clearDirectorySizes()
            } else {
                $0.model.clearDirectorySizes()
            }
        }
    }
}
