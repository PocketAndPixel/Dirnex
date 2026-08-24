import AppKit
import DirnexCore

extension PanelViewController {
    /// Offer the permanent delete for items a volume with no Trash refused to take.
    ///
    /// The same degradation `deleteStrategy` already performs for a Trash-less backend (SFTP, FTP,
    /// S3), arriving one step later because a local volume's answer cannot be had in advance
    /// (``LocalBackend/trashFailure(_:path:)``). Nothing has been deleted when this is raised — the
    /// refusal happens before any bytes move — so the confirmation is a genuine question and not a
    /// report, and declining leaves the files exactly where they are.
    ///
    /// Shared by the three flows that move items to the Trash: F8, the F6 move into an archive, and
    /// a directory sync's deletes. All three ask the *same* question, so it is asked in one place —
    /// what differs is what each does with the answer, which is what the two closures are for.
    /// `declined` exists because for two of them a "no" is not simply "nothing happened": an F6
    /// move whose originals stay put has silently become a copy, and the user is owed that.
    ///
    /// The refused paths are handed back to `confirmed` rather than left for the caller to
    /// re-derive, so the delete it performs cannot be a different set from the one the sheet
    /// counted.
    ///
    /// The question is the ordinary permanent-delete one and only the *reason* is new — see the
    /// note at the wording below.
    func offerPermanentDelete(
        forVolumeWithoutTrash paths: [VFSPath],
        confirmed: @escaping ([VFSPath]) -> Void,
        declined: @escaping () -> Void = {}
    ) {
        guard !paths.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        // The *question* is the ordinary permanent-delete one, deliberately — those two keys are
        // already translated in all fourteen languages, and asking it differently here would only
        // make the same decision look like a different one. What is new is the **reason**, which
        // the user is owed because they pressed the key that means "put this in the Trash".
        // Finder's own share dialog has this shape: the question in the title, why it cannot be
        // undone in the body.
        alert.messageText = paths.count == 1
            ? String(
                localized: "Delete “\(paths[0].lastComponent)” permanently?",
                comment: "Permanent-delete confirmation for a single item; %@ is its name."
            )
            : String(
                localized: "Delete \(paths.count) items permanently?",
                comment: "Permanent-delete confirmation for several items; %lld is the count."
            )
        alert.informativeText = String(
            localized: "There’s no Trash on this volume, so this can’t be undone.",
            comment: """
            Body of the delete confirmation raised when a volume — typically a network share — \
            refuses a move-to-Trash, explaining why the item can only be deleted for good.
            """
        )
        alert.addButton(
            withTitle: String(
                localized: "Delete",
                comment: "Confirm button on the permanent-delete confirmation."
            )
        )
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { confirmed(paths) } else { declined() }
        }
        // `beginSheetIfVisible` is deliberately not used: a user pressed a key and is waiting for
        // the answer, so an alert detached from the app beats no answer at all (docs/NOTES.md, the
        // "who is waiting?" rule).
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}
