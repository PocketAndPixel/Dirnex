import AppKit
import DirnexCore

extension PanelViewController {
    /// The share recycle bin that would catch a delete of **every** one of `paths`, if there is one.
    ///
    /// Measured 2026-09-20 on a live Synology: `trashItem` is refused on an SMB share, F8 degrades
    /// to the confirmed *permanent* delete, and that delete is a plain `unlink` — which Samba's
    /// `vfs_recycle` then moves into `#recycle` instead of destroying. So the sheet promising
    /// destruction was wrong there, in the **safe** direction and still wrong, and this is what the
    /// two permanent-delete confirmations ask before they word themselves. One funnel because the
    /// *fact* is one fact; the sentences differ per sheet and stay with their sheets.
    ///
    /// Three conditions, and each is load-bearing:
    ///
    /// - **A network volume.** `volumeIsLocal` is `false` for a mounted share and `true` for a disk
    ///   (measured on the same run), which is what stops a folder somebody happens to have called
    ///   `#recycle` at the root of a USB drive from softening a warning that is perfectly true.
    ///   Softening wrongly is the *under*-warning direction, so the test is deliberately strict:
    ///   a read that throws, or a volume that does not answer the key, keeps the strong wording.
    /// - **The directory is really there.** `vfs_recycle` is off per shared folder, and DSM leaves
    ///   the folder behind when it is switched off — which is exactly why the sentence this gates
    ///   says the server *may* keep a copy rather than promising it does.
    /// - **All of them, and the same bin.** A mixed set answers `nil` rather than softening for
    ///   the ones it does not cover.
    ///
    /// **A path already in a bin is not covered by one**, which is the case this shipped wrong
    /// (reported 2026-09-20): deleting out of `#recycle` is permanent — measured — and was being
    /// offered the softened sentence that is true everywhere else on the same share. Asked first,
    /// because it is the one condition that costs no syscall.
    func shareRecycleBinGoverning(_ paths: [VFSPath]) -> VFSPath? {
        var governing: VFSPath?
        for path in paths {
            guard path.backend == .local, !ShareRecycleBin.isBinOrInside(path),
                  let root = networkVolumeRoot(of: path) else { return nil }
            let bin = ShareRecycleBin.bin(atShareRoot: root)
            guard isDirectory(bin), governing == nil || governing == bin else { return nil }
            governing = bin
        }
        return governing
    }

    /// The mount point of the **network** volume `path` is on, or `nil` for anything else.
    ///
    /// `resourceValues` is bound before either key is read: `try?` on the whole expression would
    /// flatten "the read threw" into "the key is absent" (docs/NOTES.md), and here those must both
    /// land on the same safe answer for the same reason rather than by luck.
    private func networkVolumeRoot(of path: VFSPath) -> VFSPath? {
        let url = URL(fileURLWithPath: path.path)
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey]),
              values.volumeIsLocal == false,
              let volume = values.volume
        else {
            return nil
        }
        return .local(volume.path)
    }

    private func isDirectory(_ path: VFSPath) -> Bool {
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &directory)
        return exists && directory.boolValue
    }

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
        alert.informativeText = shareRecycleBinGoverning(paths) != nil
            ? String(
                localized: """
                There’s no Trash on this volume, so Dirnex can’t undo this. The share has its own \
                recycle bin (#recycle) and the server may keep a copy there.
                """,
                comment: """
                Body of the same confirmation on a share that has a recycle bin of its own, where \
                the delete is beyond Dirnex's reach but may not be beyond the server's. It says \
                "may" on purpose: the folder being there does not prove the setting is still on. \
                "#recycle" is a folder name and is never translated.
                """
            )
            : String(
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
