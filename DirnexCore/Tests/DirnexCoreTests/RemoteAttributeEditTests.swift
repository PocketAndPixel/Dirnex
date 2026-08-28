import Foundation
import Testing

@testable import DirnexCore

/// Get Info's write half, in the core (PLAN.md §M25 Slice 5).
///
/// Three rules, and every one of them came out of a probe against a real `sshd` rather than a man
/// page: which fields a connection can be asked to change, what a change actually sends, and — the
/// one this whole slice turns on — whether it worked, which a clean exit does not answer.
@Suite("Remote attribute editing")
struct RemoteAttributeEditTests {
    private func entry(
        permissions: UInt16? = 0o644,
        modified: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        name: String = "report.txt"
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: .local, path: "/srv/\(name)"),
            name: name,
            kind: .file,
            byteSize: 12,
            modificationDate: modified ?? FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: permissions,
            inode: 1
        )
    }

    // MARK: - What a connection may be asked to change

    @Test("an SFTP account offers the mode and not the date")
    func sftpOffersModeOnly() {
        // `sftp`'s batch language has no verb that sets a time — `help` lists chmod, chown and chgrp
        // and stops — so the asymmetry is the protocol's rather than a gap in the panel.
        let editable = RemoteAttributeEditability.decide(
            for: entry(),
            capabilities: .sftp
        )
        #expect(editable.allows(.permissions))
        #expect(!editable.allows(.modificationTime))
        #expect(!editable.isReadOnly)
    }

    @Test("an FTP account offers both, which is the richer protocol here")
    func ftpOffersBoth() {
        let editable = RemoteAttributeEditability.decide(for: entry(), capabilities: .ftp)
        #expect(editable.editable == [.permissions, .modificationTime])
    }

    @Test("a field the listing never reported is not offered")
    func absentFieldsAreNotOffered() {
        // An S3 object reports no mode at all, and a common prefix has no `LastModified` — offering
        // a control for either would have to invent the value it starts from.
        let noMode = RemoteAttributeEditability.decide(
            for: entry(permissions: nil),
            capabilities: .ftp
        )
        #expect(noMode.editable == [.modificationTime])

        let noDate = RemoteAttributeEditability.decide(
            for: entry(modified: nil),
            capabilities: .ftp
        )
        #expect(noDate.editable == [.permissions])

        let neither = RemoteAttributeEditability.decide(
            for: entry(permissions: nil, modified: nil),
            capabilities: .ftp
        )
        #expect(neither.isReadOnly)
    }

    @Test("a connection that has refused the verb offers nothing")
    func refusedVerbWithdrawsTheControl() {
        // The panel reads the connection's *current* capabilities, so a server that answered 500 to
        // `SITE CHMOD` once stops being offered the control rather than being refused every time.
        let support = RemoteMetadataSupport(offering: .ftp)
        support.recordUnsupported(.changeMode)
        let editable = RemoteAttributeEditability.decide(
            for: entry(),
            capabilities: support.capabilities
        )
        #expect(editable.editable == [.modificationTime])
    }

    @Test("a backend with no write verbs leaves the panel read-only")
    func noCapabilitiesIsReadOnly() {
        #expect(RemoteAttributeEditability.decide(for: entry(), capabilities: []).isReadOnly)
    }

    // MARK: - What a change sends

    @Test("only the fields that actually changed reach the wire")
    func onlyChangedFieldsAreSent() {
        let current = entry(permissions: 0o644)
        let unchanged = RemoteAttributeChange.between(
            current: current,
            permissions: POSIXPermissions(rawValue: 0o644),
            modificationTime: current.modificationDate,
            editable: RemoteAttributeEditability(editable: [.permissions, .modificationTime])
        )
        #expect(unchanged.isEmpty)
        #expect(unchanged.steps.isEmpty)
    }

    @Test("a field the connection cannot change can never reach the wire")
    func uneditableFieldsAreDroppedFromTheChange() {
        // Applied here rather than trusted from the caller: a control left enabled by mistake still
        // cannot send a verb the connection has refused.
        let change = RemoteAttributeChange.between(
            current: entry(permissions: 0o644),
            permissions: POSIXPermissions(rawValue: 0o755),
            modificationTime: Date(timeIntervalSince1970: 1),
            editable: RemoteAttributeEditability(editable: [.permissions])
        )
        #expect(change.permissions?.rawValue == 0o755)
        #expect(change.modificationTime == nil)
        #expect(change.steps == [.setMode(POSIXPermissions(rawValue: 0o755))])
    }

    @Test("a change spells itself in the same steps a copy rides on")
    func changeUsesTheTransferVocabulary() {
        let when = Date(timeIntervalSince1970: 1_528_358_950)
        let change = RemoteAttributeChange(
            permissions: POSIXPermissions(rawValue: 0o4755),
            modificationTime: when
        )
        #expect(change.steps == [
            .setMode(POSIXPermissions(rawValue: 0o4755)),
            .setModificationTime(when)
        ])
        #expect(change.fields == [.permissions, .modificationTime])
        #expect(change.steps.capabilitiesUsed == [.changeMode, .setModificationTime])
    }

    // MARK: - Whether it worked

    @Test("a mode the server silently did not store is reported refused")
    func silentlyDowngradedModeIsCaught() {
        // The measurement this whole type exists for (2026-08-28, real `sshd`): `chmod 2755` on a
        // file whose group the account is not in exits 0, prints nothing, and leaves `100755`.
        let change = RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o2755))
        let verdict = RemoteAttributeVerdict.weigh(
            change,
            refusals: [],
            landed: entry(permissions: 0o755)
        )
        #expect(verdict.refused == [.permissions])
        #expect(!verdict.isComplete)
        #expect(verdict.landed.permissions == 0o755)
    }

    @Test("a mode that landed exactly is complete")
    func exactModeIsComplete() {
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o4755)),
            refusals: [],
            landed: entry(permissions: 0o4755)
        )
        #expect(verdict.isComplete)
    }

    @Test("a refused step is reported over every field the change set")
    func refusalCoversEveryFieldSent() {
        // `sftp` names the failing *path*, never the failing attribute, so two steps in one batch
        // produce one indistinguishable line. Over-reporting a loss is the safe direction.
        let when = Date(timeIntervalSince1970: 1_528_358_950)
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(
                permissions: POSIXPermissions(rawValue: 0o755),
                modificationTime: when
            ),
            refusals: [.itemRefused("remote setstat \"/srv/report.txt\": Permission denied")],
            landed: entry(permissions: 0o755)
        )
        #expect(verdict.refused == [.permissions, .modificationTime])
    }

    @Test("a timestamp is never judged by the listing that reads it back")
    func timestampIsNotVerifiedAgainstAListing() {
        // The narrowness control for the read-back, and the reason it is narrow: a remote `stat` is
        // a listing row — `ls -la` is minute-resolution and FTP's `LIST` is zone-less on the
        // server's clock — so comparing a written time against one would report a false refusal for
        // an exact `MFMT`, an hour off for every user in a different zone from their server.
        let asked = Date(timeIntervalSince1970: 1_528_358_950)
        let coarse = Date(timeIntervalSince1970: 1_528_358_950 - 10800)
        let verdict = RemoteAttributeVerdict.weigh(
            RemoteAttributeChange(modificationTime: asked),
            refusals: [],
            landed: entry(modified: coarse)
        )
        #expect(verdict.isComplete)
    }

    @Test("a field nobody asked to change is never reported refused")
    func untouchedFieldsAreNeverRefused() {
        // The other narrowness control: the panel redraws from `landed`, which routinely differs
        // from what was on screen, and none of that is a refusal.
        let verdict = RemoteAttributeVerdict.weigh(
            .none,
            refusals: [],
            landed: entry(permissions: 0o600)
        )
        #expect(verdict.isComplete)
        #expect(verdict.refused.isEmpty)
    }
}
