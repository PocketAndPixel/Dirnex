import AppKit
import DirnexCore

/// Get Info (PLAN.md §M14 Slice 4) — the pane's half of the attributes panel.
///
/// One item under the cursor opens the full single-item sheet (permissions, dates, the ACL, xattrs);
/// a marked set opens the multi-selection sheet, which edits the fields that make sense in bulk
/// (mode, flags, group, dates) as a per-item patch. Which one is a marks-over-cursor decision, the
/// same rule every file operation uses.
extension PanelViewController {
    @objc func showAttributes(_ sender: Any?) {
        let targets = attributesTargets()
        guard let first = targets.first else {
            presentNothingToShow()
            return
        }
        if targets.count == 1 {
            showSingleAttributes(first)
        } else {
            showMultipleAttributes(targets)
        }
    }

    // MARK: - Single item

    private func showSingleAttributes(_ entry: FileEntry) {
        do {
            let snapshot = try AttributesSnapshot.read(entry)
            let controller = AttributesController(snapshot: snapshot)
            // Two hooks the controller needs but should not own: journaling a commit is the window's
            // job (⌘Z spans both panes), and re-listing after one lands is this pane's.
            controller.recordUndo = { [weak self] record in
                self?.host?.recordUndoableAction(record)
            }
            controller.onApplied = { [weak self] in self?.refreshCurrentDirectory() }
            presentAsSheet(controller)
        } catch {
            presentOperationFailure(
                message: String(
                    localized: "Couldn’t read “\(entry.name)”",
                    comment: "Get Info failure title when the item can't be stat'ed; %@ is its name."
                ),
                detail: VFSErrorText.sentence(for: error)
            )
        }
    }

    // MARK: - Multi-selection

    /// Read each marked item once, then open the bulk sheet. Items that can no longer be `lstat`ed
    /// (deleted between marking and opening) are dropped rather than failing the whole sheet; only if
    /// *none* survive is it an error. The ACL-presence read is what lets the panel say the mode is not
    /// the whole story for items that carry one — the same honesty the single-item sheet owes.
    private func showMultipleAttributes(_ entries: [FileEntry]) {
        let items: [MultiAttributesController.Item] = entries.compactMap { entry in
            guard let reading = try? FileAttributeIO.read(at: entry.path) else { return nil }
            let hasACL = ((try? AccessControlListIO.read(
                at: entry.path, actsOnLink: reading.isSymlink
            ))?.isEmpty == false)
            return MultiAttributesController.Item(
                entry: entry,
                attributes: reading.attributes,
                isSymlink: reading.isSymlink,
                hasAccessControlList: hasACL
            )
        }
        guard !items.isEmpty else { presentNothingToShow(); return }

        let controller = MultiAttributesController(items: items)
        controller.recordUndo = { [weak self] record in
            self?.host?.recordUndoableAction(record)
        }
        controller.onApplied = { [weak self] in self?.refreshCurrentDirectory() }
        presentAsSheet(controller)
    }

    private func presentNothingToShow() {
        presentOperationFailure(
            message: String(
                localized: "Nothing to show info for",
                comment: "Get Info failure title when the cursor isn't on a real local item."
            ),
            detail: String(
                localized: """
                Put the cursor on a file or folder on this Mac. Permissions, flags and \
                access-control lists are read from the disk itself, so a server or an archive \
                has none to show.
                """,
                comment: "Get Info failure detail; states the local-only limitation."
            )
        )
    }

    // MARK: - Targets

    /// The items Get Info describes: the marked set when anything is marked (Total Commander operates
    /// on marks over the cursor), otherwise the single cursor entry. The synthetic `..` row is never a
    /// target.
    ///
    /// Local-only, and that is structural rather than an oversight: a mode, a BSD flags word and an
    /// ACL are things a real inode has. An archive member and an SFTP listing have none, so a remote
    /// or virtual pane yields nothing and the menu item greys out.
    func attributesTargets() -> [FileEntry] {
        guard !isVirtualDirectory else { return [] }
        let candidates: [FileEntry]
        if panel.selectionCount > 0 {
            candidates = panel.selectedEntries
        } else if !cursorOnParentRow, let entry = panel.currentEntry {
            candidates = [entry]
        } else {
            candidates = []
        }
        return candidates.filter { $0.path.backend == .local }
    }

    /// Whether Get Info should be enabled.
    var canShowAttributes: Bool { !attributesTargets().isEmpty }
}
