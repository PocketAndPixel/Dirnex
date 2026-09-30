import AppKit
import DirnexCore

/// Committing a remote attribute change, and saying what actually landed (PLAN.md §M25 Slice 5).
///
/// Three steps, and the middle one is the slice: send the change, **read the item back**, and report
/// the difference. A clean answer from the server is necessary and not sufficient — `sftp`'s `chmod`
/// exits 0 for a mode the server did not store (measured 2026-08-28 against a real `sshd`: `2755` on
/// a file whose group the account is not in lands as `100755`, silently) — so a panel that reported
/// "saved" on a clean exit would be doing exactly what this milestone exists to prevent.
///
/// The read-back costs one round trip. A gesture the user made and is waiting on can afford it,
/// where the bulk *carry* deliberately cannot: Slice 2 pays nothing per file for the same reason.
extension RemoteAttributesController {
    @objc func save(_ sender: Any?) {
        let change = pendingChange
        // Nothing edited: closing is the honest answer, and sending a mode the item already has
        // would spend a round trip that a server is free to refuse.
        guard !change.isEmpty else { dismiss(sender); return }

        setBusy(true)
        let backend = backend
        let path = entry.path
        Task {
            let outcome = await BlockingWork.run { () -> Result<RemoteAttributeVerdict, any Error> in
                do {
                    let refusals = try backend.applyMetadata(change.steps, at: path)
                    // The read-back is the evidence. It is separate from the write on purpose: a
                    // transport reports whether a *step* was refused, and only the item can say
                    // what it now carries.
                    let landed = try backend.stat(at: path)
                    return .success(
                        RemoteAttributeVerdict.weigh(change, refusals: refusals, landed: landed)
                    )
                } catch {
                    return .failure(error)
                }
            }
            finishSave(outcome, change: change)
        }
    }

    private func finishSave(
        _ outcome: Result<RemoteAttributeVerdict, any Error>,
        change: RemoteAttributeChange
    ) {
        setBusy(false)
        switch outcome {
        case let .failure(error):
            // The connection itself went wrong — nothing was read back, so nothing can be said about
            // what landed. The panel stays open over its old values rather than redrawing from a
            // reading it does not have.
            presentFailure(VFSErrorText.sentence(for: error))
        case let .success(verdict):
            lastVerdict = verdict
            // Journal what landed **before** redrawing, because `reload` replaces `entry` with the
            // server's answer and the record needs the values the item had going in. The builder
            // takes the verdict rather than the two entries: what may be put back is what actually
            // moved, and over a listing whose timestamps are coarse only the mode can be measured
            // that way (``UndoRecord/remoteAttributeChange(from:asked:verdict:date:)``).
            if let record = UndoRecord.remoteAttributeChange(
                from: entry, asked: change, verdict: verdict
            ) {
                recordUndo?(record)
            }
            // Redraw from the server's answer **before** deciding what to say, so whatever the panel
            // shows next is what the item carries — including in the case where that disagrees with
            // what was asked.
            reload(with: verdict.landed)
            onApplied?()
            if verdict.isComplete {
                dismiss(nil)
            } else {
                presentPartial(verdict, change: change)
            }
        }
    }

    /// What the server would not do, over a panel already redrawn to show what it did.
    ///
    /// It stays open. A refusal here is not the end of the gesture — the mode on screen is now the
    /// real one, and the user is one checkbox away from asking for something the server will take —
    /// so closing would hide the answer at the moment it became useful.
    private func presentPartial(_ verdict: RemoteAttributeVerdict, change: RemoteAttributeChange) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "The server didn’t make every change to “\(entry.name)”",
            comment: "Remote Get Info: the server stored less than was asked; %@ is the item's name."
        )
        alert.informativeText = Self.partialDetail(verdict.refused)
        alert.addButton(withTitle: String(
            localized: "OK",
            comment: "Dismiss button on a file-operation failure alert."
        ))
        alert.enableEscapeToCancel()
        alert.beginSheetIfVisible(over: view.window)
    }

    /// Which fields did not take, as whole sentences rather than a spliced list.
    ///
    /// Internal and `static` so the wording is reachable from a test with no window: presenting a
    /// real panel in the test host is what destabilizes its neighbours (docs/NOTES.md ▸ Testing),
    /// and the part worth pinning is that each combination says something true.
    static func partialDetail(_ refused: Set<RemoteAttributeField>) -> String {
        switch (refused.contains(.permissions), refused.contains(.modificationTime)) {
        case (true, true):
            String(
                localized: """
                Neither the permissions nor the modification time were stored as asked. The panel \
                now shows what the item actually carries.
                """,
                comment: "Remote Get Info: neither field was stored."
            )
        case (true, false):
            String(
                localized: """
                The permissions were not stored as asked — a server drops the set-group-ID bit for \
                an account that is not in the item’s group, and may refuse a change outright. The \
                panel now shows the mode the item actually carries.
                """,
                comment: "Remote Get Info: the mode was refused or silently changed."
            )
        case (false, true):
            String(
                localized: """
                The modification time was not stored. This server refused the command that sets one.
                """,
                comment: "Remote Get Info: the modification time was refused."
            )
        case (false, false):
            // Unreachable: `presentPartial` runs only for a verdict that refused something. Stated
            // rather than force-unwrapped, since a switch that cannot fail still has to compile.
            String(
                localized: "The change was not stored as asked.",
                comment: "Remote Get Info: a refusal with no field named."
            )
        }
    }

    private func presentFailure(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Couldn’t change “\(entry.name)”",
            comment: "Remote Get Info failure title; %@ is the item's name."
        )
        alert.informativeText = detail
        alert.addButton(withTitle: String(
            localized: "OK",
            comment: "Dismiss button on a file-operation failure alert."
        ))
        alert.enableEscapeToCancel()
        alert.beginSheetIfVisible(over: view.window)
    }

    /// Hold the controls still while the round trip is in flight, so a second Save cannot be sent
    /// against a panel whose values are already being written.
    private func setBusy(_ busy: Bool) {
        saveButton?.isEnabled = !busy && !pendingChange.isEmpty
        for entry in modeBoxes { entry.box.isEnabled = !busy }
        for entry in specialBoxes { entry.box.isEnabled = !busy }
        modificationPicker?.isEnabled = !busy
    }
}
