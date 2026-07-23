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
/// rename through `DirnexCore`'s `moveItem` primitive off the main thread.
extension PanelViewController {
    // MARK: - Menu action (dispatched to the focused pane via the responder chain)

    @objc func renameSelection(_ sender: Any?) {
        beginRename()
    }

    // MARK: - Begin

    /// Start editing the cursor entry's name in place. No-op when already renaming, when
    /// the cursor is on `..`/empty, or when the backend can't rename.
    func beginRename() {
        guard renamingEntryID == nil else { return }
        // Rename computes the new path from the pane's directory — a virtual pane (search
        // results or an archive) hasn't got a writable one; open the real folder first.
        guard !isVirtualDirectory else { return }
        guard backend.capabilities.contains(.rename) else { return }
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

        let destination = panel.path.appending(newName)
        // `rename(2)` silently *overwrites* an existing file, so — unlike New Folder, which
        // `mkdir` protects with EEXIST — we must refuse a colliding name ourselves. A
        // case-only change ("foo" → "Foo") is allowed: on case-insensitive APFS the
        // destination "exists" but is the same inode, and `rename` performs the case fix.
        let caseOnlyChange = newName.lowercased() == oldName.lowercased()
        let backend = backend
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if !caseOnlyChange, (try? backend.stat(at: destination)) != nil {
                        throw VFSError.alreadyExists(destination)
                    }
                    try backend.moveItem(at: source, to: destination)
                }.value
                refreshCurrentDirectory(selecting: destination)
                focusTable()
                host?.recordUndoableAction(.rename(from: source, to: destination))
            } catch {
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
    /// (commit). Revert the cell to a label and, unless cancelled, perform the rename.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let entryID = renamingEntryID,
              let field = notification.object as? NSTextField else { return }
        let newName = field.stringValue
        let cancelled = renameWasCancelled
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

        guard !cancelled else {
            focusTable()
            if owedRefresh { refreshCurrentDirectory() }
            return
        }
        performRename(source: entryID, oldName: entryID.lastComponent, to: newName)
        if owedRefresh { refreshCurrentDirectory() }
    }
}
