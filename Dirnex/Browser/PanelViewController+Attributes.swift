import AppKit
import DirnexCore

/// Get Info (PLAN.md §M14 Slice 4) — the pane's half of the attributes panel.
///
/// One item under the cursor opens the full single-item sheet (permissions, dates, the ACL, xattrs);
/// a marked set opens the multi-selection sheet, which edits the fields that make sense in bulk
/// (mode, flags, group, dates) as a per-item patch. Which one is a marks-over-cursor decision, the
/// same rule every file operation uses.
///
/// A row that is **not on this Mac** takes a third route (PLAN.md §M24 Slice 7):
/// ``RemoteAttributesController``, read-only, showing what the listing actually reported and
/// saying plainly what it did not. The decision is made per row rather than per pane, because a
/// results tab holds hits from anywhere and a tree draws several directories at once.
extension PanelViewController {
    @objc func showAttributes(_ sender: Any?) {
        let targets = attributesTargets()
        guard let first = targets.first else {
            presentNothingToShow()
            return
        }
        switch AttributesRoute.decide(for: targets) {
        case .single: showSingleAttributes(first)
        case .multiple: showMultipleAttributes(targets)
        case .remote: showRemoteAttributes(first)
        case .bulkUnavailable: presentBulkNotAvailable()
        }
    }

    // MARK: - A row that is not on this Mac

    /// The read-only panel M24 Slice 7 shipped, with whatever this connection will let the user
    /// change (PLAN.md §M25 Slice 5).
    ///
    /// The capability question is asked of the **backend for this row's path**, not of the pane's:
    /// a results tab holds hits from anywhere and a tree draws several connections at once, which is
    /// the per-row rule `AttributesRoute` already settled for the read half. Asking the pane instead
    /// would offer a control from the wrong account, or withhold one from the right account.
    private func showRemoteAttributes(_ entry: FileEntry) {
        let controller = RemoteAttributesController(
            entry: entry,
            backend: backend,
            editability: remoteEditability(for: entry)
        )
        controller.onApplied = { [weak self] in self?.refreshCurrentDirectory() }
        presentAsMovableWindow(controller)
    }

    /// What the panel over `entry` will let the user change.
    ///
    /// Split from `showRemoteAttributes` for the reason `AttributesRoute` is split from presenting a
    /// panel: this is the part worth pinning, and a test that presents a real window in the test
    /// host makes it do real pane work and destabilizes its neighbours (docs/NOTES.md ▸ Testing). It
    /// is also the one line a regression would fail silently — a pane that always answered
    /// `.readOnly` would show every remote panel exactly as M24 shipped it, with nothing to see.
    func remoteEditability(for entry: FileEntry) -> RemoteAttributeEditability {
        RemoteAttributeEditability.decide(
            for: entry,
            capabilities: backend.editableMetadata(at: entry.path)
        )
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
            controller.enqueueRecursive = { [weak self] job, sources in
                self?.enqueueRecursiveAttributes(job, sources: sources)
            }
            presentAsMovableWindow(controller)
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
        controller.enqueueRecursive = { [weak self] job, sources in
            self?.enqueueRecursiveAttributes(job, sources: sources)
        }
        presentAsMovableWindow(controller)
    }

    // MARK: - Recursive apply

    /// Hand a confirmed recursive apply to the window's queue.
    ///
    /// It goes on the same queue a copy does — the volume rule, pause, cancel and determinate bar are
    /// all engine-agnostic, so a job that changes metadata instead of moving bytes needed no
    /// scheduler of its own. `destinationDirectory` is the pane's own path: nothing is written
    /// anywhere else, and the queue reads it only to work out which volume the job stresses.
    private func enqueueRecursiveAttributes(_ job: AttributeApplyJob, sources: [FileEntry]) {
        host?.enqueue(
            FileOperation(
                kind: .attributes(job),
                sources: sources,
                destinationDirectory: panel.path
            ),
            conflictPolicy: .fail,
            resolveConflict: nil,
            onError: nil
        )
        showTransientStatus(
            String(
                localized: "Changing permissions…",
                comment: "Status while a recursive attributes change is queued."
            )
        )
    }

    private func presentNothingToShow() {
        presentOperationFailure(
            message: String(
                localized: "Nothing to show info for",
                comment: "Get Info failure title when the cursor isn't on a real local item."
            ),
            detail: String(
                localized: """
                Put the cursor on a file or folder. The parent row and the app folders in the \
                merged iCloud Drive listing are the only rows Get Info cannot describe.
                """,
                comment: "Get Info failure detail; names the rows that have nothing to describe."
            )
        )
    }

    /// A marked set that is not all on this Mac.
    ///
    /// The bulk panel is an **editor** — it applies a per-item patch — and a remote row has nothing
    /// editable yet (writing is M25's). Refusing says so; the two alternatives are both quiet
    /// failures. Opening it over the local subset would edit fewer items than the user marked
    /// without mentioning it, which is what the old local-only filter did to a mixed selection; and
    /// describing the cursor row alone would ignore marks that every other gesture in the app obeys.
    private func presentBulkNotAvailable() {
        presentOperationFailure(
            message: String(
                localized: "Get Info describes one item at a time here",
                comment: "Get Info failure title for a multi-selection that is not all local."
            ),
            detail: String(
                localized: """
                The multiple-item panel edits permissions, flags and dates, and an item that is \
                not on this Mac cannot be edited yet. Clear the selection to see one item on its own.
                """,
                comment: "Get Info failure detail for a non-local multi-selection."
            )
        )
    }

    // MARK: - Targets

    /// The items Get Info describes: the marked set when anything is marked (Total Commander operates
    /// on marks over the cursor), otherwise the single cursor entry. The synthetic `..` row is never a
    /// target.
    ///
    /// **Any** row Get Info can describe, local or not (PLAN.md §M24 Slice 7).
    ///
    /// This filtered to `backend == .local` until M24 Slice 7, on the reasoning that a mode, a flags
    /// word and an ACL are things a real inode has. The first half of that is wrong — `sftp` and
    /// FTP's Unix `LIST` print a real mode, and an archive stores one — and the second is a reason
    /// to show *less* about a remote row, not nothing about it. What replaced it is a routing
    /// decision made per row rather than a filter, so a search hit and a row inside an expanded
    /// folder are judged on where **they** live rather than on what container drew them.
    ///
    /// The one row still excluded is the one whose name is not its path's: ``ICloudDrive`` puts an
    /// **app's** name over its `Documents` folder, so a panel opened on it would describe a folder
    /// under a name that is not the folder's. That is ``FileEntry/nameMatchesPath``, which is the
    /// honest form of the `!isVirtualDirectory` gate this used to carry — that one refused every
    /// ordinary file standing beside those rows, and every hit in a results tab, for the sake of a
    /// handful of synthetic ones.
    func attributesTargets() -> [FileEntry] {
        let candidates: [FileEntry]
        if panel.selectionCount > 0 {
            candidates = panel.selectedEntries
        } else if !cursorOnParentRow, let entry = panel.currentEntry {
            candidates = [entry]
        } else {
            candidates = []
        }
        return candidates.filter(\.nameMatchesPath)
    }

    /// Whether Get Info should be enabled.
    var canShowAttributes: Bool { !attributesTargets().isEmpty }
}
