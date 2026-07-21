import AppKit
import DirnexCore

/// Drop *in* — receiving a drag onto a pane as a real copy or move through the window's
/// shared operation queue (PLAN.md §M2 "Drop onto panel = real copy/move through the
/// queue"). Files can arrive from the other pane, from the same pane onto a subfolder, or
/// from an external app such as Finder.
///
/// These are the receiving `NSTableViewDataSource` drop methods; the conformance is
/// declared in `PanelViewController+Table` and the source (drag-out) half lives in
/// `PanelViewController+Drag`. All byte work runs through `submitTransfer`
/// (`PanelViewController+Copy`), so conflict handling, progress, and the both-panes
/// refresh are shared with F5/F6.
extension PanelViewController {
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let plan = dropPlan(info, row: row, dropOperation: dropOperation) else {
            return []
        }
        // Highlight the specific folder row for an "into this folder" drop, else the whole
        // pane (row -1, `.on`) for a drop into the current directory.
        tableView.setDropRow(plan.highlightRow ?? -1, dropOperation: .on)
        return plan.operation
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let plan = dropPlan(info, row: row, dropOperation: dropOperation) else {
            return false
        }
        let backend = backend
        let urls = plan.urls
        let destination = plan.destination
        let kind = plan.kind
        Task {
            // Stat the dropped items off-main into the entries the engine copies. A URL
            // that can no longer be stat'd (deleted between drag start and drop) is
            // dropped silently rather than failing the whole operation.
            let sources = await Task.detached(priority: .userInitiated) { () -> [FileEntry] in
                urls.compactMap { try? backend.stat(at: VFSPath.local($0.path)) }
            }.value
            guard !sources.isEmpty else { return }
            submitTransfer(kind: kind, sources: sources, destination: destination)
            // A drop makes this pane the active one, matching Finder's focus-follows-drop.
            host?.panelDidBecomeActive(self)
            focusTable()
        }
        return true
    }

    // MARK: - Plan

    /// The resolved intent of a drag hovering over (or released on) this pane, or `nil`
    /// when the drop is invalid or a no-op. Computed identically in `validateDrop` (for
    /// the cursor feedback) and `acceptDrop` (for the real work).
    private struct DropPlan {
        let kind: FileOperation.Kind
        /// The AppKit operation reported back for the drag cursor badge.
        let operation: NSDragOperation
        let destination: VFSPath
        let urls: [URL]
        /// A directory row to highlight for an "into this folder" drop, or `nil` to
        /// highlight the whole pane (a drop into the current directory).
        let highlightRow: Int?
    }

    private func dropPlan(
        _ info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> DropPlan? {
        // A drop needs a real, writable on-disk directory to land in — never a virtual pane (search
        // results, the Trash, or a read-only archive whose write support lands in a later M4 pass).
        // `writeDirectory` is that directory, and it is what makes the merged iCloud listing a drop
        // target: its root is the CloudDocs container underneath (PLAN.md §M9).
        guard let base = writeDirectory, base.backend == .local,
              backend.capabilities.contains(.write) else { return nil }
        guard let urls = droppedFileURLs(info), !urls.isEmpty else { return nil }

        let (destination, highlightRow) = dropDestination(
            row: row, dropOperation: dropOperation, base: base
        )
        let sources = urls.map { VFSPath.local($0.path) }

        // No-op: every dropped item already lives in the destination (e.g. dragging a
        // pane's own files onto its own background). Reject so the cursor shows "no drop".
        if sources.allSatisfy({ $0.parent == destination }) { return nil }

        // Never drop a folder onto itself or into its own subtree — that would recurse.
        let recurses = sources.contains { source in
            destination == source || destination.path.hasPrefix(source.path + "/")
        }
        if recurses { return nil }

        guard let kind = resolvedKind(
            mask: info.draggingSourceOperationMask,
            sources: sources,
            destination: destination
        ) else { return nil }

        return DropPlan(
            kind: kind,
            operation: kind == .copy ? .copy : .move,
            destination: destination,
            urls: urls,
            highlightRow: highlightRow
        )
    }

    /// Where a drop lands: into a directory row it's released *on* (a real subfolder or
    /// the `..` parent, for a move up a level), else into the pane's current directory.
    private func dropDestination(
        row: Int,
        dropOperation: NSTableView.DropOperation,
        base: VFSPath
    ) -> (destination: VFSPath, highlightRow: Int?) {
        if dropOperation == .on {
            if isParentRow(row), let parent = panel.parentPath {
                return (parent, row)
            }
            if let index = entryIndex(forRow: row) {
                let entry = panel.model[index]
                if entry.isDirectoryLike {
                    return (entry.path, row)
                }
            }
        }
        return (base, nil)
    }

    /// Copy or move, following Finder's conventions: an explicit Option forces copy and
    /// Command forces move; otherwise the default is move within a volume and copy across
    /// volumes (so dragging to another disk never silently deletes the source). Constrained
    /// by what the drag source actually offers (`mask`).
    private func resolvedKind(
        mask: NSDragOperation,
        sources: [VFSPath],
        destination: VFSPath
    ) -> FileOperation.Kind? {
        let canCopy = mask.contains(.copy) || mask.contains(.generic)
        let canMove = mask.contains(.move)
        guard canCopy || canMove else { return nil }

        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.option), canCopy { return .copy }
        if modifiers.contains(.command), canMove { return .move }

        if canMove, sameVolume(sources, as: destination) { return .move }
        return canCopy ? .copy : .move
    }

    /// Whether the sources sit on the same physical volume as the destination — the first
    /// source is taken as representative to keep this cheap during hover (a drag is almost
    /// always from one folder). A backend that can't tell its volumes apart is treated as
    /// one volume, so the default stays "move".
    private func sameVolume(_ sources: [VFSPath], as destination: VFSPath) -> Bool {
        guard let destVolume = backend.volumeIdentifier(for: destination),
              let first = sources.first else { return true }
        return backend.volumeIdentifier(for: first) == destVolume
    }

    private func droppedFileURLs(_ info: NSDraggingInfo) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL]
    }
}
