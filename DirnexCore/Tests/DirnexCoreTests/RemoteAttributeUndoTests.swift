import Foundation
import Testing

@testable import DirnexCore

/// Undo and redo of a **remote** attributes change — the journal step that writes back through the
/// backend's own `applyMetadata` (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// The local twin of this suite (`AttributeUndoTests`) runs against real temp files and lets the OS
/// judge. There is no OS here: the whole subject is what reaches a *server*, so the fake records
/// every step it is sent and answers whatever the test wants a server to answer — which is the only
/// way to reach the two cases that matter and cannot be arranged against a healthy `sshd`, a step
/// the transport refuses and a mode that lands as something other than what was asked.
@Suite("Remote attribute undo")
struct RemoteAttributeUndoTests {
    private let backendID = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func path(_ name: String = "report.txt") -> VFSPath {
        VFSPath(backend: backendID, path: "/home/oleg/\(name)")
    }

    private func entry(
        permissions: UInt16? = 0o644,
        modified: Date? = nil
    ) -> FileEntry {
        FileEntry(
            path: path(),
            name: "report.txt",
            kind: .file,
            byteSize: 10,
            modificationDate: modified ?? epoch,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: permissions,
            ownerName: "oleg",
            groupName: "staff",
            inode: 1
        )
    }

    /// The shape every save produces: what was asked, and what the item reads as afterwards.
    private func verdict(
        _ change: RemoteAttributeChange,
        refusals: [RemoteMetadataRefusal] = [],
        landed: FileEntry
    ) -> RemoteAttributeVerdict {
        RemoteAttributeVerdict.weigh(change, refusals: refusals, landed: landed)
    }

    // MARK: - What goes on the stack

    @Test("a mode that landed is journaled as the mode the item had before")
    func modeThatLandedIsJournaled() throws {
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600))
        let record = try #require(UndoRecord.remoteAttributeChange(
            from: entry(permissions: 0o644),
            asked: change,
            verdict: verdict(change, landed: entry(permissions: 0o600))
        ))
        #expect(record.label == .changeAttributes)
        guard case let .restoreRemoteAttributes(path, apply, reverse) = try #require(
            record.steps.first
        ) else {
            Issue.record("expected a remote attributes step")
            return
        }
        #expect(path == self.path())
        #expect(apply.permissions?.rawValue == 0o644)
        #expect(reverse.permissions?.rawValue == 0o600)
        // A patch in both directions: the panel touched no date, so neither does its undo.
        #expect(apply.modificationTime == nil)
        #expect(reverse.modificationTime == nil)
    }

    @Test("a save that changed nothing never enters the journal")
    func unchangedSaveIsNotJournaled() {
        // The server took the request and stored what was already there. There is nothing to put
        // back, and a step that wrote 0o644 over 0o644 would be a round trip for no reason.
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o644))
        #expect(UndoRecord.remoteAttributeChange(
            from: entry(permissions: 0o644),
            asked: change,
            verdict: verdict(change, landed: entry(permissions: 0o644))
        ) == nil)
    }

    @Test("a mode that landed as something else is still journaled, from what the item now carries")
    func silentDowngradeIsJournaledFromTheReadBack() throws {
        // The measurement this whole area rests on: `chmod 2755` on a file whose group the account
        // is not in exits 0 and stores 0755. The verdict calls that refused — and the file *did*
        // move, 0644 → 0755, so ⌘Z has something real to put back. Journaling nothing here would
        // leave a change the user can see and cannot reverse.
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o2755))
        let judged = verdict(change, landed: entry(permissions: 0o755))
        #expect(judged.refused == [.permissions])
        let record = try #require(UndoRecord.remoteAttributeChange(
            from: entry(permissions: 0o644), asked: change, verdict: judged
        ))
        guard case let .restoreRemoteAttributes(_, apply, reverse) = try #require(
            record.steps.first
        ) else {
            Issue.record("expected a remote attributes step")
            return
        }
        #expect(apply.permissions?.rawValue == 0o644)
        // Redo re-applies what the server actually stored, not the set-group-ID bit it dropped.
        #expect(reverse.permissions?.rawValue == 0o755)
    }

    @Test("a modification time the transport refused is not journaled")
    func refusedTimeIsNotJournaled() {
        // A listing cannot measure a timestamp — `sftp`'s `ls -la` is minute-resolution and FTP's
        // `LIST` is zone-less on the server's clock — so the time rests on the verb's own answer.
        // Journaling one the verb refused would have ⌘Z write an old date over a field the save
        // never moved.
        let asked = epoch.addingTimeInterval(86_400)
        let change = RemoteAttributeChange(modificationTime: asked)
        let judged = verdict(
            change,
            refusals: [.verbUnimplemented("500 SITE UTIME not understood")],
            landed: entry(modified: epoch)
        )
        #expect(UndoRecord.remoteAttributeChange(
            from: entry(modified: epoch), asked: change, verdict: judged
        ) == nil)
    }

    @Test("a modification time the transport took is journaled from the values, not the read-back")
    func acceptedTimeIsJournaled() throws {
        // The narrowness half of the rule above, and the case a read-back comparison would get
        // wrong: `MFMT` is exact, and the listing that reads it back rounds — so `landed` here
        // reports the *old* stamp while the write was perfect. The record must still carry it.
        let asked = epoch.addingTimeInterval(86_400)
        let change = RemoteAttributeChange(modificationTime: asked)
        let record = try #require(UndoRecord.remoteAttributeChange(
            from: entry(modified: epoch),
            asked: change,
            verdict: verdict(change, landed: entry(modified: epoch))
        ))
        guard case let .restoreRemoteAttributes(_, apply, reverse) = try #require(
            record.steps.first
        ) else {
            Issue.record("expected a remote attributes step")
            return
        }
        #expect(apply.modificationTime == epoch)
        #expect(reverse.modificationTime == asked)
    }

    @Test("a row whose listing reported no mode has nothing to journal")
    func absentModeIsNotJournaled() {
        // An S3 object and a DOS-dialect FTP row report no mode at all, so there is no prior value
        // to put back even if something wrote one.
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600))
        #expect(UndoRecord.remoteAttributeChange(
            from: entry(permissions: nil),
            asked: change,
            verdict: verdict(change, landed: entry(permissions: 0o600))
        ) == nil)
    }

    // MARK: - What the step does

    @Test("reverting sends the previous mode back through the backend's own verb")
    func revertSendsThePreviousMode() throws {
        let backend = MetadataWritingBackend(id: backendID, stored: entry(permissions: 0o600))
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600))
        let record = try #require(UndoRecord.remoteAttributeChange(
            from: entry(permissions: 0o644),
            asked: change,
            verdict: verdict(change, landed: entry(permissions: 0o600))
        ))
        // The server takes it: the item reads as 0o644 again afterwards.
        backend.stored = entry(permissions: 0o644)
        let report = UndoJournal.revert(record, using: backend)
        #expect(report.succeeded)
        #expect(backend.sent == [[.setMode(POSIXPermissions(rawValue: 0o644))]])
    }

    @Test("redo re-applies the change the inverse record carries")
    func redoReappliesTheChange() throws {
        let backend = MetadataWritingBackend(id: backendID, stored: entry(permissions: 0o600))
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600))
        let record = try #require(UndoRecord.remoteAttributeChange(
            from: entry(permissions: 0o644),
            asked: change,
            verdict: verdict(change, landed: entry(permissions: 0o600))
        ))
        let report = UndoJournal.revert(record.inverted, using: backend)
        #expect(report.succeeded)
        #expect(backend.sent == [[.setMode(POSIXPermissions(rawValue: 0o600))]])
    }

    @Test("a read-back that disagrees fails the step rather than reporting an undo that happened")
    func refusedRestoreIsReported() throws {
        // The forward save's own finding, arriving at ⌘Z: a clean exit is not proof. The fake
        // accepts the write and goes on reporting the mode it had, which is exactly what a real
        // server does for a bit the account cannot set.
        let backend = MetadataWritingBackend(id: backendID, stored: entry(permissions: 0o600))
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600))
        let record = try #require(UndoRecord.remoteAttributeChange(
            from: entry(permissions: 0o644),
            asked: change,
            verdict: verdict(change, landed: entry(permissions: 0o600))
        ))
        let report = UndoJournal.revert(record, using: backend) // `stored` left at 0o600
        #expect(!report.succeeded)
        let failure = try #require(report.failures.first)
        #expect(failure.error == .unsupported(.remoteAttributeRestoreRefused(name: "report.txt")))
    }

    @Test("a connection that broke keeps the backend's own error")
    func brokenConnectionKeepsItsError() throws {
        // Not the same answer as a refusal, and the two send the user to different places: "the
        // server said no" is about this file, "there is no server" is about the connection.
        let backend = MetadataWritingBackend(id: backendID, stored: entry(permissions: 0o600))
        backend.failure = .io(path: path(), code: ETIMEDOUT)
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600))
        let record = try #require(UndoRecord.remoteAttributeChange(
            from: entry(permissions: 0o644),
            asked: change,
            verdict: verdict(change, landed: entry(permissions: 0o600))
        ))
        let report = UndoJournal.revert(record, using: backend)
        #expect(report.failures.first?.error == .io(path: path(), code: ETIMEDOUT))
        // And nothing is claimed to have been written.
        #expect(backend.sent.isEmpty)
    }

    @Test("the step survives the round trip the journal persists it through")
    func stepIsCodable() throws {
        // The journal is JSON in `UserDefaults`, so a step that cannot be re-read is a ⌘Z that
        // silently disappears on the next launch.
        let step = UndoStep.restoreRemoteAttributes(
            path: path(),
            apply: RemoteAttributeChange(
                permissions: POSIXPermissions(rawValue: 0o644),
                modificationTime: epoch
            ),
            reverse: RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o600))
        )
        let data = try JSONEncoder().encode(step)
        #expect(try JSONDecoder().decode(UndoStep.self, from: data) == step)
    }
}

/// A backend that answers the one write verb and reports whatever the test wants a server to say.
///
/// It records the steps it was sent, because the claim under test is **which values reach the
/// wire** — a fake that merely succeeded would prove the step calls something, not that it sends
/// the previous mode rather than the new one.
private final class MetadataWritingBackend: VFSBackend, @unchecked Sendable {
    let id: VFSBackendID
    /// What a `stat` reports. The read-back is the whole mechanism, so a test sets this directly.
    var stored: FileEntry
    /// What `applyMetadata` answers — empty is "the transport reported nothing wrong".
    var refusals: [RemoteMetadataRefusal] = []
    /// A connection-level failure, thrown instead of writing.
    var failure: VFSError?
    private(set) var sent: [[RemoteMetadataStep]] = []

    init(id: VFSBackendID, stored: FileEntry) {
        self.id = id
        self.stored = stored
    }

    var capabilities: VFSCapabilities { [.read, .write] }

    func listDirectory(at _: VFSPath) throws -> [FileEntry] { [] }

    func stat(at _: VFSPath) throws -> FileEntry { stored }

    func editableMetadata(at _: VFSPath) -> RemoteMetadataCapabilities { .sftp }

    func applyMetadata(
        _ steps: [RemoteMetadataStep],
        at _: VFSPath
    ) throws -> [RemoteMetadataRefusal] {
        if let failure { throw failure }
        sent.append(steps)
        return refusals
    }
}
