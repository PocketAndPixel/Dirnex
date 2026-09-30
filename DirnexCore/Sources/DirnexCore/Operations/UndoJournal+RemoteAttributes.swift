import Foundation

// The undo journal's *remote* attributes corner (PLAN.md §4 ▸ *Still open*, taken 2026-09-01):
// what ⌘Z does to a mode written over SFTP, or a mode and a modification time written over FTP.
//
// Its own file rather than a second half of `UndoJournal+Attributes.swift`, because that file's
// whole stated concept is the opposite of this one's: a local attributes step runs through
// `FileAttributeIO`'s syscalls and never touches the backend it is handed, and every line here is
// a backend verb. Two halves of "an attributes change" that share a label and share nothing else
// (docs/NOTES.md ▸ Lint ceilings: split by concept).

public extension UndoRecord {
    /// The record that reverses a remote Get Info commit — or `nil` when there is nothing to
    /// reverse.
    ///
    /// What "nothing to reverse" means here is the whole of the builder, and it is not the same
    /// question the local one asks. A local edit either happened or did not; a remote one is sent
    /// to a stranger's server, which may store it, refuse it, or store *something else* — so what
    /// goes on the stack is what the item actually moved by, judged the way
    /// ``RemoteAttributeVerdict`` judges it, field by field:
    ///
    /// - The **mode** rests on the item's own answer. The record carries it whenever the read-back
    ///   disagrees with what was there before, which covers both a write that landed as asked and
    ///   the measured silent downgrade — `chmod 2755` on a file whose group the account is not in
    ///   stores `0755`, and a file that went `0644 → 0755` has moved and is worth putting back even
    ///   though the verdict calls the write refused.
    /// - The **modification time** rests on the *verb's* answer, because a remote `stat` here is a
    ///   listing row and cannot measure one: `sftp`'s `ls -la` has minute resolution and FTP's
    ///   `LIST` stamp is zone-less on the server's clock (docs/NOTES.md ▸ Parsing a year-less
    ///   timestamp). So it is journaled only where the transport refused nothing.
    ///
    /// Both rules err the same way on purpose. Declining to journal a change that did land costs a
    /// ⌘Z that does nothing — the state before this pass, for one item — while journaling one that
    /// did *not* land would have ⌘Z write an old value over a field the save never touched, which
    /// is a real write nobody asked for.
    ///
    /// - Parameters:
    ///   - previous: the item as the panel had it before Save.
    ///   - change: what Save sent. A field it did not set can never enter the record.
    ///   - verdict: what the write achieved, read back from the server.
    static func remoteAttributeChange(
        from previous: FileEntry,
        asked change: RemoteAttributeChange,
        verdict: RemoteAttributeVerdict,
        date: Date = Date()
    ) -> UndoRecord? {
        var undoPermissions: POSIXPermissions?
        var redoPermissions: POSIXPermissions?
        if change.permissions != nil,
           let before = previous.permissions,
           let now = verdict.landed.permissions,
           before != now {
            undoPermissions = POSIXPermissions(rawValue: before)
            redoPermissions = POSIXPermissions(rawValue: now)
        }

        var undoTime: Date?
        var redoTime: Date?
        if let asked = change.modificationTime,
           !verdict.refused.contains(.modificationTime),
           previous.hasModificationDate,
           asked != previous.modificationDate {
            undoTime = previous.modificationDate
            redoTime = asked
        }

        let undo = RemoteAttributeChange(
            permissions: undoPermissions,
            modificationTime: undoTime
        )
        let redo = RemoteAttributeChange(
            permissions: redoPermissions,
            modificationTime: redoTime
        )
        guard !undo.isEmpty else { return nil }
        return UndoRecord(
            label: .changeAttributes,
            date: date,
            steps: [.restoreRemoteAttributes(path: previous.path, apply: undo, reverse: redo)]
        )
    }
}

extension UndoJournal {
    /// Send a patch of previous values back to the server, and check that it took.
    ///
    /// Three steps and the middle one is the point, exactly as `RemoteAttributesController`'s Save
    /// is: write, **re-read the item**, and weigh the two. A clean answer from a server is
    /// necessary and not sufficient — `sftp`'s `chmod` exits 0 for a mode it did not store — so an
    /// undo that reported success on the exit code would be claiming a reversal it did not have,
    /// which is precisely the failure the forward path was built to avoid. The read-back costs one
    /// round trip, which a keystroke the user is waiting on can afford where a bulk carry cannot.
    ///
    /// It goes through ``VFSBackend/applyMetadata(_:at:)`` and ``RemoteAttributeVerdict/weigh(_:refusals:landed:)``
    /// rather than a private spelling of either, so "what a remote metadata write is" and "did it
    /// land" each have one definition that Save and ⌘Z both read.
    ///
    /// A refusal is a **failed step**, collected like every other, so a record holding several items
    /// still puts back the ones the server will take. The connection breaking is a different answer
    /// and keeps the backend's own error, because "the server said no" and "there is no server" send
    /// the user to different places.
    static func restoreRemoteAttributes(
        _ change: RemoteAttributeChange,
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard !change.isEmpty else { return }
        do {
            let refusals = try backend.applyMetadata(change.steps, at: path)
            let landed = try backend.stat(at: path)
            let verdict = RemoteAttributeVerdict.weigh(change, refusals: refusals, landed: landed)
            guard verdict.isComplete else {
                let reason = VFSUnsupportedReason
                    .remoteAttributeRestoreRefused(name: path.lastComponent)
                failures.append(.init(path: path, error: .unsupported(reason)))
                return
            }
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }
}
