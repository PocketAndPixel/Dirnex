import AppKit
import DirnexCore

/// Inline rename (F2) — an "instant" operation like New Folder, editing the name in
/// place in the table rather than moving bytes, so it needs no progress queue (PLAN.md
/// §M2 "inline rename (F2/Enter-on-name)"). Total Commander semantics: rename acts on
/// the single cursor entry (a marked *set* is the multi-rename tool's job, M4), never
/// the synthetic `..` row.
///
/// The edit is a real editable `NSTextField` swapped into the name cell (see
/// `FileCellView.beginNameEditing`); this file drives its lifecycle and performs the
/// rename through `DirnexCore`'s `moveItem` primitive off the main thread — or, inside a writable
/// archive, by rewriting the container (`ArchiveWriter.rename`).

/// How the row under the cursor would be renamed, and so which of the two mechanisms F2 uses.
/// See `PanelViewController.renameRoute(for:)`.
enum RenameRoute: Equatable {
    /// The backend renames in place: one `moveItem` in the row's own directory.
    case backend
    /// The row is a member of a writable archive, renamed by rewriting the container at this path.
    case archiveMember(archiveOnDiskPath: String)
    /// Nothing here can be renamed — a read-only location, a trash (where a rename orphans the
    /// Put Back record), an S3 account's buckets, or a **nested** archive, whose own bytes are an
    /// extracted temp copy so a rewrite would land somewhere thrown away.
    case unavailable
}

extension PanelViewController {
    // MARK: - Menu action (dispatched to the focused pane via the responder chain)

    @objc func renameSelection(_ sender: Any?) {
        beginRename()
    }

    /// How `path` would be renamed, or `.unavailable`.
    ///
    /// `nil` — the `..` row, or an empty pane — asks about the *location* rather than about a row,
    /// which is what lets the menu validators add their own "is there something to act on" half
    /// rather than duplicating it here.
    ///
    /// **An archive member is answered before the capability**, because a browsed archive is
    /// read-only *through the VFS primitives* by design: its writes go through the app's own
    /// rewrite path, gated by `isWritableArchiveMember` rather than by the caps
    /// (`CompositeBackend.capabilities(for:)` says so in as many words). Asked of the **row** and
    /// not of the pane, so a search hit inside a `.zip` renames exactly as a browsed row does — the
    /// distinction four other properties in this app had to be corrected for (PLAN.md §M22 Slice 5).
    ///
    /// **⇧F2 deliberately does not read this**, and that is a refusal with its own reason rather
    /// than an oversight: `applyMultiRename` renames each target with `backend.moveItem`, which an
    /// archive answers `.unsupported` to, so widening the gate they *share* would have enabled the
    /// multi-rename tool over a flow that fails once per item. Batching N renames into the one
    /// rewrite the container actually wants is its own slice; until it exists ⇧F2 stays on
    /// `canRenameHere` and stays gray inside an archive.
    func renameRoute(for path: VFSPath?) -> RenameRoute {
        if let archiveOnDiskPath = path?.backend.archivePath {
            return host?.nestedArchiveRegistry.isNestedMount(archiveOnDiskPath) ?? false
                ? .unavailable
                : .archiveMember(archiveOnDiskPath: archiveOnDiskPath)
        }
        // The directory whose backend decides is the **row's own**, not the pane's. In a tree they
        // are different directories and can be different backends: an S3 account pane's own rows are
        // buckets, which nothing renames, so asking the pane refused F2 three levels inside an
        // expanded bucket (reported 2026-08-22). A synthesized container — `search:`, `icloud:` —
        // has no capabilities to speak of, and its rows are ordinary files in ordinary directories.
        let directory = path?.parent ?? panel.path
        return backend.capabilities(for: directory).contains(.rename) ? .backend : .unavailable
    }

    /// The row F2 would act on: `nil` on the `..` row, which stands for the pane's own parent rather
    /// than for anything renameable.
    var renameRow: VFSPath? {
        cursorOnParentRow ? nil : panel.currentEntry?.path
    }

    // MARK: - Begin

    /// Start editing the cursor entry's name in place. No-op when already renaming, when
    /// the cursor is on `..`/empty, or when this pane can't rename.
    func beginRename() {
        guard renamingEntryID == nil else { return }
        // The cursor is read three times below — for the gate's *directory*, for the entry, and for
        // the row — and the table's selection is the live one until its change notification fires a
        // runloop pass later. In a tree a stale cursor is a different **directory**, hence a
        // different backend, not merely a different row (docs/NOTES.md ▸ `creationDirectory`).
        reconcileCursorFromTable()
        // `canRenameCursorRow` — the same property File ▸ Rename… grays itself off, rather than a
        // second spelling of it. The two had drifted, and a menu item's own key equivalent is
        // dispatched through the item, so a mismatch is a key that works where the menu says it
        // cannot (or the reverse, which is worse: an enabled item over a flow that returns here in
        // silence).
        guard canRenameCursorRow else { return }
        guard !cursorOnParentRow, let entry = panel.currentEntry else { return }
        guard let columnIndex = nameColumnDisplayIndex else { return }

        let row = row(forEntryIndex: panel.cursor)
        renamingEntryID = entry.path
        renameWasCancelled = false

        // Rebuild just this row so its name cell comes back as an editable field, then
        // hand it first-responder to open the field editor. `beginNameEditing` ran during
        // the reload because `renamingEntryID` now matches this entry.
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
        tableView.scrollRowToVisible(row)
        guard
            let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? FileCellView,
            let field = cell.textField
        else {
            renamingEntryID = nil
            return
        }
        view.window?.makeFirstResponder(field)
        selectBaseName(in: field)
    }

    /// Preselect the base name (everything before the last dot), Finder-style, so typing
    /// replaces the name but keeps the extension — unless the name is all-extension (a
    /// leading dot) or has none, in which case the whole thing is selected. Done here,
    /// right after the field takes first responder (which selects all by default), rather
    /// than in `controlTextDidBeginEditing`: that notification fires on the first *edit*,
    /// not on focus, so a selection set there would land a keystroke too late.
    private func selectBaseName(in field: NSTextField) {
        guard let editor = field.currentEditor() else { return }
        let name = field.stringValue as NSString
        let dot = name.range(of: ".", options: .backwards)
        if dot.location != NSNotFound, dot.location > 0 {
            editor.selectedRange = NSRange(location: 0, length: dot.location)
        } else {
            editor.selectedRange = NSRange(location: 0, length: name.length)
        }
    }

    /// Display index of the Name column, resolved live so a user-reordered column layout
    /// (per-tab column persistence, M1) still finds it.
    private var nameColumnDisplayIndex: Int? {
        tableView.tableColumns.firstIndex { Column(rawValue: $0.identifier.rawValue) == .name }
    }

    // MARK: - Commit

    /// Rename `source` (currently named `oldName`, in the pane's directory) to `newName`.
    /// The cursor lands on the renamed entry by its new identity after the re-list.
    private func performRename(source: VFSPath, oldName: String, to rawName: String) {
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty or unchanged name is a silent cancel.
        guard !newName.isEmpty, newName != oldName else {
            focusTable()
            return
        }
        guard !newName.contains("/") else {
            presentOperationFailure(
                message: String(
                    localized: "Can’t rename “\(oldName)”",
                    comment: "Rename validation failure title; %@ is the current name."
                ),
                detail: String(
                    localized: "Names can’t contain the “/” character.",
                    comment: "Rename validation failure body: slash is not allowed in a name."
                )
            )
            focusTable()
            return
        }

        // The third reader of the route, and the one whose omission is this family's own recorded
        // failure: a decision extracted for a key and a validator, with the *act* below still
        // calling the local-only verb (docs/NOTES.md ▸ Design lessons, the ninth axis).
        switch renameRoute(for: source) {
        case let .archiveMember(archiveOnDiskPath):
            renameArchiveMember(
                source, to: newName, oldName: oldName, inArchiveAt: archiveOnDiskPath
            )
            return
        case .unavailable:
            // Reachable only if the location stopped accepting renames between the key press and
            // the commit — the pane navigated away under an open field editor. Silent, because the
            // gesture was already answered by the field closing.
            focusTable()
            return
        case .backend:
            break
        }

        // The new name lands in the entry's *own* directory, not the pane's. In tree mode the
        // cursor can sit on a row inside an expanded child folder, so `panel.path` (the tree root)
        // is not where `source` lives — rebuilding the destination from it renamed the file *and*
        // moved it up to the root (docs/NOTES.md ▸ the second-index-space trap). `source.parent` is
        // where it actually is; it is `nil` only at the backend root, which is never an entry.
        let destination = (source.parent ?? panel.path).appending(newName)
        // `rename(2)` silently *overwrites* an existing file, so — unlike New Folder, which
        // `mkdir` protects with EEXIST — we must refuse a colliding name ourselves. A
        // case-only change ("foo" → "Foo") is allowed: on case-insensitive APFS the
        // destination "exists" but is the same inode, and `rename` performs the case fix.
        let caseOnlyChange = newName.lowercased() == oldName.lowercased()
        // The entry as the pane already knows it, captured before the attempt: a backend that
        // cannot rename in place (an S3 prefix — `EXDEV`) hands the work to the queue, which needs
        // a `FileEntry`, and re-`stat`ing to get one would be a second billed round trip.
        let sourceEntry = panel.displayedIndex(ofID: source).flatMap { panel.displayedEntry(at: $0) }
        let backend = backend
        Task {
            do {
                try await BlockingWork.run {
                    Result {
                        if !caseOnlyChange, (try? backend.stat(at: destination)) != nil {
                            throw VFSError.alreadyExists(destination)
                        }
                        try backend.moveItem(at: source, to: destination)
                    }
                }.get()
                // A search snapshot cannot re-list itself, so the row it is still drawing has to be
                // put back under the new name by hand; every other listing re-lists or re-gathers
                // below.
                substituteSearchHit(source, renamedTo: newName)
                refreshCurrentDirectory(selecting: destination)
                focusTable()
                host?.recordUndoableAction(.rename(from: source, to: destination))
            } catch {
                // `EXDEV` is the backend asking for the long way round, not a failure: run it as a
                // job (PLAN.md §M21). Without the entry there is nothing to enqueue, so it falls
                // through to the ordinary alert rather than reporting a success nobody performed.
                if RenameDeferral.isDeferred(error), let sourceEntry {
                    focusTable()
                    queueDeferredRenames([DeferredRename(source: sourceEntry, newName: newName)])
                    return
                }
                presentOperationFailure(
                    message: String(
                        localized: "Can’t rename “\(oldName)”",
                        comment: "Rename failure title; %@ is the current name."
                    ),
                    detail: describe(error)
                )
                focusTable()
            }
        }
    }
}

// MARK: - NSTextFieldDelegate (edit lifecycle for the inline name field)

extension PanelViewController: NSTextFieldDelegate {
    /// Esc aborts the rename. Ending first-responder here fires `controlTextDidEndEditing`,
    /// which sees `renameWasCancelled` and reverts instead of committing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renameWasCancelled = true
            view.window?.makeFirstResponder(tableView)
            return true
        }
        return false
    }

    /// Editing ended — via Return (commit), Esc (cancel, flagged above), or focus loss
    /// (commit). Revert the cell to a label and, unless canceled, perform the rename.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let entryID = renamingEntryID,
              let field = notification.object as? NSTextField else { return }
        let newName = field.stringValue
        let canceled = renameWasCancelled
        // A live refresh (FSEvents / directory-size total) that arrived mid-edit was deferred
        // rather than allowed to tear the field editor apart; replay it now so the pane catches
        // up on the change it skipped. The commit path re-lists anyway, but the cancel/no-op
        // paths would otherwise leave the pane stale.
        let owedRefresh = renamePendingRefresh
        renamingEntryID = nil
        renameWasCancelled = false
        renamePendingRefresh = false

        // Revert the edited row back to a plain label (the commit path re-lists anyway,
        // but the cancel/no-op paths rely on this).
        let row = row(forEntryIndex: panel.cursor)
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )

        guard !canceled else {
            focusTable()
            if owedRefresh { refreshCurrentDirectory() }
            return
        }
        performRename(source: entryID, oldName: entryID.lastComponent, to: newName)
        if owedRefresh { refreshCurrentDirectory() }
    }
}
