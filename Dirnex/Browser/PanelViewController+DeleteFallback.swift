import AppKit
import DirnexCore

/// Whether a delete failure is really the volume saying it keeps no Trash.
///
/// Its own type for the reason `RenameDeferral` is: this is the decision that routes a failure away
/// from the errno alert, it is the half a test can drive with no window, and spelling it inline in
/// `runDelete` would leave the rule where nothing can assert it.
///
/// The predicate is narrow on purpose. `VFSError.unsupported(.trash)` reaches a delete from exactly
/// two places — the protocol default, for a backend with no `trashItem` at all, and `LocalBackend`'s
/// ``LocalBackend/trashFailure(_:path:)``, for a volume that refused one — and the delete path can
/// only have *attempted* a trash on a backend whose `deleteStrategy` was `.trash`, so reaching this
/// at all means the second. Every other failure is a real one and keeps its own alert: a permission
/// problem is not answered by offering to delete the file for good.
enum TrashRefusal {
    static func isVolumeWithoutTrash(_ error: any Error) -> Bool {
        guard let error = error as? VFSError, case .unsupported(.trash) = error else { return false }
        return true
    }
}

extension PanelViewController {
    /// Offer the permanent delete for items a volume with no Trash refused to take.
    ///
    /// The same degradation `deleteStrategy` already performs for a Trash-less backend (SFTP, FTP,
    /// S3), arriving one step later because a local volume's answer cannot be had in advance
    /// (``LocalBackend/trashFailure(_:path:)``). Nothing has been deleted when this is raised — the
    /// refusal happens before any bytes move — so the confirmation is a genuine question and not a
    /// report, and declining leaves the files exactly where they are.
    ///
    /// The question is the ordinary permanent-delete one and only the *reason* is new — see the
    /// note at the wording below.
    func offerPermanentDelete(forVolumeWithoutTrash targets: [FileEntry]) {
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        // The *question* is the ordinary permanent-delete one, deliberately — those two keys are
        // already translated in all fourteen languages, and asking it differently here would only
        // make the same decision look like a different one. What is new is the **reason**, which
        // the user is owed because they pressed the key that means "put this in the Trash".
        // Finder's own share dialog has this shape: the question in the title, why it cannot be
        // undone in the body.
        alert.messageText = targets.count == 1
            ? String(
                localized: "Delete “\(targets[0].name)” permanently?",
                comment: "Permanent-delete confirmation for a single item; %@ is its name."
            )
            : String(
                localized: "Delete \(targets.count) items permanently?",
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

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runDelete(targets, permanent: true)
        }
        // `beginSheetIfVisible` is deliberately not used: a user pressed F8 and is waiting for the
        // answer, so an alert detached from the app beats no answer at all (docs/NOTES.md, the
        // "who is waiting?" rule).
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}
