import AppKit
import DirnexCore

/// Get Info (PLAN.md §M14 Slice 4) — the pane's half of the attributes panel.
///
/// Everything shown is read by the tested `DirnexCore` attribute, ACL and xattr readers; this file
/// decides only *which* item and raises the sheet.
extension PanelViewController {
    @objc func showAttributes(_ sender: Any?) {
        guard let entry = attributesTarget() else {
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
            return
        }
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

    /// The item Get Info describes: the row under the cursor.
    ///
    /// Cursor-only, never the marked set. Multi-selection applies a *diff* and is its own pass
    /// (PLAN.md §M14 Slice 4); a read-only panel over several items would have to answer "what are
    /// the permissions" with a mixed value for nearly every field, which is a worse answer than
    /// naming one file. The `..` row is excluded — it names the parent, which is not what the cursor
    /// is pointing at.
    ///
    /// Local-only, and that is structural rather than an oversight: a mode, a BSD flags word and an
    /// ACL are things a real inode has. An archive member and an SFTP listing have none.
    private func attributesTarget() -> FileEntry? {
        guard !cursorOnParentRow,
              let entry = panel.currentEntry,
              entry.path.backend == .local,
              !isVirtualDirectory else { return nil }
        return entry
    }

    /// Whether Get Info should be enabled.
    var canShowAttributes: Bool { attributesTarget() != nil }
}
